#!/bin/bash

#############################################################################
# Update Local Repository Remotes Script
# 
# Purpose: Update local git repositories to point to new GitHub remotes
# Strategy: Rename old remote to 'gitlab-backup', add new 'origin' pointing to GitHub
# Configuration: Uses config.ini for all settings
#
# Usage:
#   ./update-local-repos.sh [--dry-run] [--config FILE]
#
#############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration library
source "${SCRIPT_DIR}/lib-config.sh"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Default configuration
DRY_RUN=false
CUSTOM_CONFIG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --config)
            CUSTOM_CONFIG="$2"
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--config FILE]"
            exit 1
            ;;
    esac
done

# Load configuration
load_config

# Load local repositories
mapfile -t LOCAL_REPOS < <(load_local_repositories)

SUCCESS_COUNT=0
FAILED_COUNT=0

print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║     Update Local Repository Remotes                               ║"
    printf "║     New Remote: %-50s ║\n" "${GITHUB_HOST}/${GITHUB_USER}"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_section() {
    echo -e "\n${BOLD}${BLUE}━━━ $1 ━━━${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${CYAN}ℹ${NC} $1"
}

update_repository() {
    local repo_path="$1"
    local repo_name="$2"
    
    print_section "Updating: $repo_name"
    print_info "Path: $repo_path"
    
    # Check if directory exists
    if [[ ! -d "$repo_path" ]]; then
        print_error "Directory not found: $repo_path"
        return 1
    fi
    
    # Check if it's a git repository
    if [[ ! -d "$repo_path/.git" ]]; then
        print_error "Not a git repository: $repo_path"
        return 1
    fi
    
    cd "$repo_path"
    
    # Get current remote URL
    local current_remote=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ -z "$current_remote" ]]; then
        print_error "No origin remote found"
        return 1
    fi
    
    print_info "Current remote: $current_remote"
    
    # Check for uncommitted changes
    if [[ -n "$(git status --porcelain)" ]]; then
        print_warning "Repository has uncommitted changes"
        git status --short
        echo ""
    fi
    
    # New GitHub remote URL
    local new_remote="git@${GITHUB_HOST}:${GITHUB_USER}/${repo_name}.git"
    print_info "New remote: $new_remote"
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[DRY-RUN] Would execute:"
        echo "  1. git remote rename origin gitlab-backup"
        echo "  2. git remote add origin $new_remote"
        echo "  3. git fetch origin"
        echo "  4. git branch --set-upstream-to=origin/main main"
        return 0
    fi
    
    # Step 1: Rename current origin to gitlab-backup
    print_info "Renaming origin to gitlab-backup..."
    if git remote rename origin gitlab-backup 2>/dev/null; then
        print_success "Renamed origin → gitlab-backup"
    else
        # Check if gitlab-backup already exists
        if git remote get-url gitlab-backup &>/dev/null; then
            print_warning "gitlab-backup remote already exists, removing old origin"
            git remote remove origin 2>/dev/null || true
        else
            print_error "Failed to rename remote"
            return 1
        fi
    fi
    
    # Step 2: Add new GitHub remote as origin
    print_info "Adding new GitHub remote..."
    if git remote add origin "$new_remote" 2>/dev/null; then
        print_success "Added GitHub remote as origin"
    else
        print_error "Failed to add new remote"
        return 1
    fi
    
    # Step 3: Fetch from new remote
    print_info "Fetching from GitHub..."
    if git fetch origin 2>/dev/null; then
        print_success "Fetched from GitHub"
    else
        print_error "Failed to fetch from GitHub"
        return 1
    fi
    
    # Step 4: Set upstream for current branch
    print_info "Setting upstream branch..."
    local current_branch=$(git branch --show-current)
    if git branch --set-upstream-to=origin/${current_branch} ${current_branch} 2>/dev/null; then
        print_success "Set upstream: origin/${current_branch}"
    else
        print_warning "Could not set upstream (this might be okay)"
    fi
    
    # Verify
    print_info "Verifying remotes..."
    echo ""
    git remote -v
    echo ""
    
    print_success "Repository updated successfully!"
    echo ""
    
    return 0
}

main() {
    print_header
    
    if [[ "$DRY_RUN" == true ]]; then
        print_warning "Running in DRY-RUN mode - no changes will be made"
        echo ""
    fi
    
    print_section "Local Repositories to Update"
    for repo in "${LOCAL_REPOS[@]}"; do
        # New format: name|path
        IFS='|' read -r name path <<< "$repo"
        echo "  - $name"
        echo "    Path: $path"
    done
    echo ""
    
    # Confirmation
    if [[ "$DRY_RUN" == false ]]; then
        echo -e "${YELLOW}This will update your local repository remotes to point to GitHub.${NC}"
        echo -e "${YELLOW}The old GitLab remote will be preserved as 'gitlab-backup'.${NC}"
        echo ""
        read -p "Continue? (yes/no): " confirmation
        if [[ "$confirmation" != "yes" ]]; then
            print_warning "Cancelled by user"
            exit 0
        fi
        echo ""
    fi
    
    # Update each repository
    for repo in "${LOCAL_REPOS[@]}"; do
        # New format: name|path
        IFS='|' read -r name path <<< "$repo"
        
        if update_repository "$path" "$name"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
    done
    
    # Summary
    print_section "Summary"
    echo -e "${BOLD}Total repositories:${NC} ${#LOCAL_REPOS[@]}"
    echo -e "${GREEN}${BOLD}Successful:${NC} $SUCCESS_COUNT"
    echo -e "${RED}${BOLD}Failed:${NC} $FAILED_COUNT"
    echo ""
    
    if [[ $FAILED_COUNT -eq 0 ]]; then
        print_success "All repositories updated successfully!"
        echo ""
        echo -e "${BOLD}Next steps:${NC}"
        echo "  1. Test pulling/pushing from your local repos"
        echo "  2. If everything works, you can remove gitlab-backup remotes:"
        echo "     git remote remove gitlab-backup"
    else
        print_error "Some repositories failed to update"
        exit 1
    fi
}

main "$@"
