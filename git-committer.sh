#!/bin/bash

# git-committer: Maximum commits
#
# It REQUIRES `gawk` for high-speed date string generation.
#
# Usage: ./git-committer.sh

set -e

# --- Configuration & Globals ---
CONFIG_FILE="committer-config.json"
COMMIT_FILE="commit.txt"

# Global values
declare -a BLOB_HASHES=() # Holds pre-calculated blob hashes for digits 0-9

# Default values, loaded from config file
BATCH_SIZE=100000
MAX_COMMITS_PER_DAY=1440
MAX_WORKERS=8
PUSH_QUEUE_SIZE=3

# Multithreading variables
declare -a WORKER_PIDS=()
declare -a PUSH_PIDS=()
COMMIT_QUEUE_DIR="/tmp/git-committer-$$"
PUSH_QUEUE_DIR="/tmp/git-push-queue-$$"


# --- Cross-platform Date Helper Functions ---
get_current_date() { if [[ "$OSTYPE" == "darwin"* ]]; then date '+%Y-%m-%d'; else date '+%Y-%m-%d'; fi; }
get_future_date() { local days_ahead=$1; if [[ "$OSTYPE" == "darwin"* ]]; then date -v+"${days_ahead}d" '+%Y-%m-%d'; else date -d "today + ${days_ahead} days" '+%Y-%m-%d'; fi; }
date_to_timestamp() { local date_str=$1; if [[ "$OSTYPE" == "darwin"* ]]; then date -j -f "%Y-%m-%d" "$date_str" "+%s"; else date -d "$date_str" "+%s"; fi; }


# --- Threading Environment Setup & Cleanup ---
setup_threading() {
    mkdir -p "$COMMIT_QUEUE_DIR" "$PUSH_QUEUE_DIR"
    local cpu_cores; if command -v nproc &> /dev/null; then cpu_cores=$(nproc); elif command -v sysctl &> /dev/null; then cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo "4"); else cpu_cores=4; fi
    MAX_WORKERS=$((cpu_cores * 3 / 4)); if [[ $MAX_WORKERS -gt 12 ]]; then MAX_WORKERS=12; elif [[ $MAX_WORKERS -lt 2 ]]; then MAX_WORKERS=2; fi
    echo "Detected $cpu_cores CPU cores, using $MAX_WORKERS workers for data preparation."
}

cleanup_threading() {
    echo -e "\nCaught signal, cleaning up..."
    for pid in "${WORKER_PIDS[@]}" "${PUSH_PIDS[@]}"; do if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi; done
    rm -rf "$COMMIT_QUEUE_DIR" "$PUSH_QUEUE_DIR" 2>/dev/null || true
    echo "Cleanup complete."
}


# --- Configuration and Repository Initialization ---
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then echo "Creating default configuration..."; cat > "$CONFIG_FILE" << EOF
{
  "start_date": "$(get_current_date)", "end_date": "$(get_future_date 7)", "repo_name": "git-committer", "github_username": "your-username",
  "git_user_name": "Your Name", "git_user_email": "your.email@example.com", "commit_interval_seconds": 0,
  "batch_size": 100000, "max_commits_per_day": 1440, "max_workers": 8, "push_queue_size": 3
}
EOF
        echo "Please edit $CONFIG_FILE with your settings and run again."; exit 1; fi
    START_DATE=$(jq -r '.start_date' "$CONFIG_FILE"); END_DATE=$(jq -r '.end_date' "$CONFIG_FILE"); REPO_NAME=$(jq -r '.repo_name' "$CONFIG_FILE"); GITHUB_USERNAME=$(jq -r '.github_username' "$CONFIG_FILE"); GIT_USER_NAME=$(jq -r '.git_user_name' "$CONFIG_FILE"); GIT_USER_EMAIL=$(jq -r '.git_user_email' "$CONFIG_FILE"); COMMIT_INTERVAL=$(jq -r '.commit_interval_seconds' "$CONFIG_FILE"); BATCH_SIZE=$(jq -r '.batch_size' "$CONFIG_FILE"); MAX_COMMITS_PER_DAY=$(jq -r '.max_commits_per_day' "$CONFIG_FILE"); MAX_WORKERS=$(jq -r '.max_workers' "$CONFIG_FILE"); PUSH_QUEUE_SIZE=$(jq -r '.push_queue_size' "$CONFIG_FILE")
}

init_repo() {
    echo "Initializing repository..."
    if [[ ! -d ".git" ]]; then
        git init
        # Set user configuration from config file
        if [[ "$GIT_USER_NAME" != "null" && "$GIT_USER_EMAIL" != "null" ]]; then
            echo "Setting Git user to: $GIT_USER_NAME <$GIT_USER_EMAIL>"
            git config user.name "$GIT_USER_NAME"
            git config user.email "$GIT_USER_EMAIL"
        else
            if ! git config user.name >/dev/null 2>&1 || ! git config user.email >/dev/null 2>&1; then 
                echo "Error: Git user.name/email must be configured either globally or in the config file." >&2
                echo "Either run 'git config --global user.name \"Your Name\"' and 'git config --global user.email \"your.email@example.com\"'" >&2
                echo "Or add git_user_name and git_user_email to your $CONFIG_FILE" >&2
                exit 1
            fi
        fi
        echo "Initial content for README" > README.md; git add README.md; git commit -m "Initial commit"
        if command -v gh &> /dev/null; then gh repo create "$REPO_NAME" --public --source=. --remote=origin --push; else echo "Error: GitHub CLI 'gh' not found." >&2; exit 1; fi
    else
        # Update user configuration if specified in config
        if [[ "$GIT_USER_NAME" != "null" && "$GIT_USER_EMAIL" != "null" ]]; then
            echo "Updating Git user to: $GIT_USER_NAME <$GIT_USER_EMAIL>"
            git config user.name "$GIT_USER_NAME"
            git config user.email "$GIT_USER_EMAIL"
        fi
        if ! git diff --quiet --cached && ! git diff --quiet; then echo "Error: Uncommitted changes found." >&2; exit 1; fi
        echo "Repository already initialized and clean."
    fi
}


# --- Core High-Performance Functions ---

pre_calculate_blobs() {
    echo "Pre-calculating blob hashes for maximum speed..."
    for i in {0..9}; do
        BLOB_HASHES+=("$(echo "$i" | git hash-object -w --stdin)")
    done
}

# Fixed gawk script that properly distributes commits evenly across all days
prepare_commit_data_gawk() {
    local worker_id=$1; local start_commit=$2; local end_commit=$3; local period_start_ts=$4; local total_days=$5; local commits_per_day=$6
    local worker_file="$COMMIT_QUEUE_DIR/worker_${worker_id}.txt"
    gawk -v start="$start_commit" -v end="$end_commit" -v period_start_ts="$period_start_ts" -v total_days="$total_days" -v commits_per_day="$commits_per_day" \
    'BEGIN { 
        seconds_per_day = 86400;
        
        for (i = start; i <= end; i++) {
            # Calculate which day this commit belongs to (0-based)
            day_index = int((i - 1) / commits_per_day);
            
            # Calculate position within that day (0 to commits_per_day-1)
            position_in_day = (i - 1) % commits_per_day;
            
            # Calculate base timestamp for this day
            day_start_ts = period_start_ts + (day_index * seconds_per_day);
            
            # Distribute commits evenly throughout the day
            if (commits_per_day > 1) {
                # Spread commits across the day with some randomness
                time_offset = (position_in_day * seconds_per_day) / commits_per_day;
                # Add some random variation (±30 minutes) to make it look more natural
                random_offset = (rand() - 0.5) * 3600; # ±30 minutes in seconds
                current_ts = day_start_ts + time_offset + random_offset;
            } else {
                # Single commit per day - place it at a random time during the day
                random_offset = rand() * seconds_per_day;
                current_ts = day_start_ts + random_offset;
            }
            
            # Ensure timestamp is within bounds
            if (current_ts < day_start_ts) current_ts = day_start_ts;
            if (current_ts >= day_start_ts + seconds_per_day) current_ts = day_start_ts + seconds_per_day - 1;
            
            date_str = strftime("%Y-%m-%dT%H:%M:%SZ", current_ts, 1);
            content = i % 10;
            print i "|" date_str "|" content;
        }
    }' > "$worker_file"
}

make_commits_plumbing_ultimate() {
    local parent_commit; parent_commit=$(git rev-parse HEAD)
    local count=0
    local other_files_tree_content; other_files_tree_content=$(git ls-tree "$parent_commit" | grep -v "\t${COMMIT_FILE}$" || true)

    while IFS='|' read -r commit_num git_date file_content; do
        [[ -n "$commit_num" ]] || continue
        local blob_hash=${BLOB_HASHES[$file_content]}
        local tree_hash; tree_hash=$( (
            if [[ -n "$other_files_tree_content" ]]; then
                echo "$other_files_tree_content"
            fi
            printf "100644 blob %s\t%s\n" "$blob_hash" "$COMMIT_FILE"
        ) | git mktree )
        export GIT_AUTHOR_DATE="$git_date"; export GIT_COMMITTER_DATE="$git_date"
        export GIT_AUTHOR_NAME="$GIT_USER_NAME"; export GIT_AUTHOR_EMAIL="$GIT_USER_EMAIL"
        export GIT_COMMITTER_NAME="$GIT_USER_NAME"; export GIT_COMMITTER_EMAIL="$GIT_USER_EMAIL"
        parent_commit=$(git commit-tree "$tree_hash" -p "$parent_commit" -m "feat: commit $commit_num")
        unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
        ((count++))
    done

    local current_branch; current_branch=$(get_current_branch)
    git update-ref "refs/heads/$current_branch" "$parent_commit"
    git reset --hard HEAD >/dev/null
    echo "$count"
}


# --- Multithreading & Execution Logic ---
get_current_branch() { git branch --show-current 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main"; }

prepare_batch_parallel() {
    local batch_start=$1; local batch_end=$2; local period_start_ts=$3; local total_days=$4; local commits_per_day=$5
    local batch_size=$((batch_end - batch_start + 1))
    local commits_per_worker=$((batch_size / MAX_WORKERS)); local remaining_commits=$((batch_size % MAX_WORKERS))
    rm -f "$COMMIT_QUEUE_DIR"/worker_*.txt
    local current_commit=$batch_start
    WORKER_PIDS=()

    for ((worker=0; worker<MAX_WORKERS; worker++)); do
        local worker_commits=$commits_per_worker
        if [[ $worker -lt $remaining_commits ]]; then worker_commits=$((worker_commits + 1)); fi
        if [[ $worker_commits -gt 0 ]]; then
            local worker_end=$((current_commit + worker_commits - 1))
            prepare_commit_data_gawk "$worker" "$current_commit" "$worker_end" "$period_start_ts" "$total_days" "$commits_per_day" &
            WORKER_PIDS+=($!); current_commit=$((worker_end + 1))
        fi
    done
    for pid in "${WORKER_PIDS[@]}"; do wait "$pid"; done
    WORKER_PIDS=()
}

run_committer() {
    pre_calculate_blobs
    echo "Starting optimized commit generation..."
    echo "============================================"
    local start_timestamp; start_timestamp=$(date_to_timestamp "$START_DATE")
    local end_timestamp; end_timestamp=$(date_to_timestamp "$END_DATE"); end_timestamp=$((end_timestamp + 86399)) # End of day
    local total_seconds=$((end_timestamp - start_timestamp))
    local total_days=$(((total_seconds + 86399) / 86400))
    
    # Calculate commits per day and total commits
    local commits_per_day=$MAX_COMMITS_PER_DAY
    local total_commits=$((total_days * commits_per_day))
    
    # If using fixed interval, recalculate
    if [[ $COMMIT_INTERVAL -gt 0 ]]; then
        total_commits=$((total_seconds / COMMIT_INTERVAL))
        commits_per_day=$(((total_commits + total_days - 1) / total_days)) # Round up
        echo "Using fixed interval of ${COMMIT_INTERVAL}s between commits"
        echo "This results in approximately $commits_per_day commits per day"
    else
        echo "Using exactly ${commits_per_day} commits per day"
    fi
    
    [[ $total_commits -lt 1 ]] && total_commits=1
    [[ $commits_per_day -lt 1 ]] && commits_per_day=1
    
    echo "Date range: $START_DATE to $END_DATE ($total_days days)"
    echo "Total commits to generate: $total_commits"
    echo "Commits per day: $commits_per_day"
    echo "This ensures EVERY day in the range will have commits!"
    
    local commit_count=0; local batch_count=0; local overall_start_time=$(date +%s)
    while [[ $commit_count -lt $total_commits ]]; do
        local batch_start=$((commit_count + 1)); local batch_end=$((commit_count + BATCH_SIZE)); [[ $batch_end -gt $total_commits ]] && batch_end=$total_commits
        local batch_size=$((batch_end - batch_start + 1))
        [[ $batch_size -le 0 ]] && break # Exit if there's nothing left to do
        echo -e "\n--- Preparing Batch $((batch_count + 1)): Commits $batch_start-$batch_end ($batch_size) ---"
        
        # Pass the parameters needed for proper daily distribution
        prepare_batch_parallel "$batch_start" "$batch_end" "$start_timestamp" "$total_days" "$commits_per_day"

        echo "Executing batch..."
        local batch_start_time=$(date +%s)
        local commits_made; commits_made=$(cat "$COMMIT_QUEUE_DIR"/worker_*.txt | make_commits_plumbing_ultimate)
        rm -f "$COMMIT_QUEUE_DIR"/worker_*.txt
        commit_count=$((commit_count + commits_made))
        local batch_end_time=$(date +%s); local batch_duration=$((batch_end_time - batch_start_time))
        local commits_per_second; if [[ $batch_duration -gt 0 ]]; then commits_per_second=$((commits_made / batch_duration)); else commits_per_second="> $commits_made"; fi
        batch_count=$((batch_count + 1))
        echo "Queueing batch $batch_count for background push... (Batch Speed: ~${commits_per_second}/sec)"
        start_background_push
        local elapsed=$((batch_end_time - overall_start_time)); local overall_speed=0; [[ $elapsed -gt 0 ]] && overall_speed=$((commit_count / elapsed))
        echo "Progress: $commit_count/$total_commits commits (${overall_speed}/sec overall)"
    done
    wait_for_all_pushes
    local end_time=$(date +%s); local total_duration=$((end_time - overall_start_time)); local final_speed=0; [[ $total_duration -gt 0 ]] && final_speed=$((commit_count / total_duration))
    echo -e "\n--- COMPLETED ---"; echo "Total commits created: $commit_count"; echo "Total time: ${total_duration}s"; echo "Average speed: ${final_speed} commits/sec"
}


# --- Background Push Management ---
background_push_worker() { local current_branch=$(get_current_branch); echo "Background push started..."; if git push origin "$current_branch" --quiet; then echo "Push successful."; else echo "Error: Push failed." >&2; fi; }
start_background_push() { local new_pids=(); for pid in "${PUSH_PIDS[@]}"; do if kill -0 "$pid" 2>/dev/null; then new_pids+=("$pid"); fi; done; PUSH_PIDS=("${new_pids[@]}"); while [[ ${#PUSH_PIDS[@]} -ge $PUSH_QUEUE_SIZE ]]; do echo "Push queue full..."; sleep 1; local np=(); for p in "${PUSH_PIDS[@]}"; do if kill -0 "$p" 2>/dev/null; then np+=("$p"); fi; done; PUSH_PIDS=("${np[@]}"); done; background_push_worker & PUSH_PIDS+=("$!"); }
wait_for_all_pushes() { echo "Waiting for pushes..."; for pid in "${PUSH_PIDS[@]}"; do if kill -0 "$pid" 2>/dev/null; then wait "$pid"; fi; done; echo "All pushes finished."; PUSH_PIDS=(); }


# --- Main Execution Block ---
main() {
    echo "Git Committer - The Ultimate Performance & Safety Edition"; echo "======================================================="
    if ! command -v gawk &>/dev/null; then echo "Error: 'gawk' (GNU Awk) is required." >&2; echo "Please install it (e.g., 'brew install gawk' or 'sudo apt-get install gawk')." >&2; exit 1; fi
    for cmd in git jq gh; do if ! command -v $cmd &>/dev/null; then echo "Error: Required command '$cmd' is not installed." >&2; exit 1; fi; done
    load_config; setup_threading
    echo -e "\nConfig: $MAX_WORKERS workers, $PUSH_QUEUE_SIZE pushes, batch size $BATCH_SIZE"; echo -e "Press Enter to continue or Ctrl+C to abort..."; read -r
    init_repo; run_committer
}

trap cleanup_threading EXIT INT TERM
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi