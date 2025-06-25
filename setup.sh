#!/bin/bash

# setup.sh - Setup script for git-committer project

set -e

echo "Git Committer Setup"
echo "=================="

# Check and install dependencies
check_dependencies() {
    echo "Checking dependencies..."
    
    local missing_deps=()
    
    if ! command -v git &> /dev/null; then
        missing_deps+=("git")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v gh &> /dev/null; then
        missing_deps+=("gh (GitHub CLI)")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "Missing dependencies: ${missing_deps[*]}"
        echo ""
        echo "Install instructions:"
        echo "- git: https://git-scm.com/downloads"
        echo "- jq: https://stedolan.github.io/jq/download/"
        echo "- gh: https://cli.github.com/"
        echo ""
        echo "On Ubuntu/Debian: sudo apt-get install git jq gh"
        echo "On macOS: brew install git jq gh"
        exit 1
    fi
    
    echo "✓ All dependencies found"
}

# Setup GitHub authentication
setup_github_auth() {
    echo "Setting up GitHub authentication..."
    
    if ! gh auth status &> /dev/null; then
        echo "GitHub CLI not authenticated. Please run:"
        echo "gh auth login"
        echo ""
        echo "Then run this setup script again."
        exit 1
    fi
    
    echo "✓ GitHub CLI authenticated"
}

# Create project structure
setup_project() {
    echo "Setting up project structure..."
    
    # Create configuration file if it doesn't exist
    if [[ ! -f "committer-config.json" ]]; then
        cat > committer-config.json << 'EOF'
{
  "start_date": "2025-06-25",
  "end_date": "2025-07-02",
  "repo_name": "git-committer",
  "github_username": "your-username",
  "commit_interval_seconds": 1,
  "batch_size": 100,
  "max_commits_per_day": 1440
}
EOF
        echo "✓ Created committer-config.json"
    else
        echo "✓ Configuration file already exists"
    fi
    
    # Make main script executable
    if [[ -f "git-committer.sh" ]]; then
        chmod +x git-committer.sh
        echo "✓ Made git-committer.sh executable"
    fi
    
    # Create .gitignore
    cat > .gitignore << 'EOF'
# Logs
*.log

# OS generated files
.DS_Store
.DS_Store?
._*
.Spotlight-V100
.Trashes
ehthumbs.db
Thumbs.db

# Editor files
*.swp
*.swo
*~
.vscode/
.idea/
EOF
    echo "✓ Created .gitignore"
    
    # Create README
    cat > README.md << 'EOF'
# Git Committer
This is so stupid.
EOF
    echo "✓ Created README.md"
}

# Validate configuration
validate_config() {
    echo "Validating configuration..."
    
    if [[ ! -f "committer-config.json" ]]; then
        echo "❌ Configuration file not found"
        return 1
    fi
    
    # Check if jq can parse the config
    if ! jq . committer-config.json > /dev/null 2>&1; then
        echo "❌ Invalid JSON in configuration file"
        return 1
    fi
    
    # Check required fields
    local required_fields=("start_date" "end_date" "repo_name" "github_username")
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" committer-config.json > /dev/null 2>&1; then
            echo "❌ Missing required field: $field"
            return 1
        fi
    done
    
    echo "✓ Configuration valid"
}

# Main setup function
main() {
    check_dependencies
    setup_github_auth
    setup_project
    validate_config
    
    echo ""
    echo "Setup complete! 🎉"
    echo ""
    echo "Next steps:"
    echo "1. Edit committer-config.json with your settings"
    echo "2. Run ./git-committer.sh to start generating commits"
    echo ""
    echo "Configuration file location: committer-config.json"
}

# Utility functions for managing the committer

# Stop committer function
stop_committer() {
    echo "Stopping git-committer processes..."
    pkill -f "git-committer.sh" || echo "No running processes found"
}

# Stats function
show_stats() {
    echo "Repository Statistics"
    echo "===================="
    
    if [[ ! -d ".git" ]]; then
        echo "Not a git repository"
        return 1
    fi
    
    echo "Total commits: $(git rev-list --count HEAD)"
    echo "Repository size: $(du -sh .git | cut -f1)"
    echo "Last commit: $(git log -1 --format='%h %s %cd' --date=short)"
    echo "Commits today: $(git log --since='today' --oneline | wc -l)"
    echo "Remote URL: $(git remote get-url origin 2>/dev/null || echo 'No remote set')"
}

# Cleanup function
cleanup_repo() {
    echo "Cleaning up repository..."
    echo "This will remove all commit history and start fresh."
    echo "Are you sure? (y/N)"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf .git
        rm -f commit.txt
        echo "Repository cleaned"
    else
        echo "Cleanup cancelled"
    fi
}

# Handle command line arguments
case "${1:-setup}" in
    "setup")
        main
        ;;
    "stop")
        stop_committer
        ;;
    "stats")
        show_stats
        ;;
    "cleanup")
        cleanup_repo
        ;;
    *)
        echo "Usage: $0 [setup|stop|stats|cleanup]"
        echo ""
        echo "Commands:"
        echo "  setup   - Setup project and dependencies (default)"
        echo "  stop    - Stop running committer processes"
        echo "  stats   - Show repository statistics"
        echo "  cleanup - Clean repository and start fresh"
        ;;
esac