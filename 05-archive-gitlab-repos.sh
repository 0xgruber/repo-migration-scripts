#!/bin/bash

#############################################################################
# Archive GitLab Repositories Script
# 
# Purpose: Archive migrated repositories on GitLab and update descriptions
# Updates: Marks repositories as archived and adds migration notice
# Configuration: Uses config.ini and repos.ini for all settings
#
# Usage:
#   ./archive-gitlab-repos.sh [--dry-run] [--config FILE]
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

# Load repositories from repos.ini
mapfile -t REPOS < <(load_repositories)

SUCCESS_COUNT=0
FAILED_COUNT=0

print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║     Archive GitLab Repositories                                    ║"
    echo "║     Mark migrated repositories as archived                        ║"
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

get_project_id() {
    local repo_name="$1"
    
    # URL encode the project path
    local project_path="${GITLAB_USER}/${repo_name}"
    local encoded_path=$(echo -n "$project_path" | jq -sRr @uri)
    
    # Get project details
    local response=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "https://${GITLAB_HOST}/api/v4/projects/${encoded_path}")
    
    # Extract project ID
    local project_id=$(echo "$response" | jq -r '.id // empty')
    
    if [[ -n "$project_id" ]] && [[ "$project_id" != "null" ]]; then
        echo "$project_id"
        return 0
    else
        return 1
    fi
}

archive_repository() {
    local repo_name="$1"
    
    print_section "Archiving: $repo_name"
    
    # Get project ID
    print_info "Getting project ID..."
    local project_id=$(get_project_id "$repo_name")
    
    if [[ -z "$project_id" ]]; then
        print_error "Could not find project ID for $repo_name"
        return 1
    fi
    
    print_success "Project ID: $project_id"
    
    # Get current project details
    print_info "Fetching current project details..."
    local project_info=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "https://${GITLAB_HOST}/api/v4/projects/${project_id}")
    
    local current_desc=$(echo "$project_info" | jq -r '.description // ""')
    local is_archived=$(echo "$project_info" | jq -r '.archived')
    
    print_info "Current status: archived=$is_archived"
    
    if [[ "$is_archived" == "true" ]]; then
        print_warning "Repository is already archived"
    fi
    
    # Prepare new description
    local new_desc="⚠️ MIGRATED TO GITHUB → https://github.com/${GITHUB_USER}/${repo_name}"
    if [[ -n "$current_desc" ]]; then
        new_desc="${new_desc}\n\nOriginal description: ${current_desc}"
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[DRY-RUN] Would archive repository"
        print_info "[DRY-RUN] New description: $new_desc"
        return 0
    fi
    
    # Archive the repository
    print_info "Archiving repository..."
    local archive_response=$(curl -s -X POST \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "https://${GITLAB_HOST}/api/v4/projects/${project_id}/archive")
    
    if echo "$archive_response" | jq -e '.archived == true' &>/dev/null; then
        print_success "Repository archived"
    else
        print_error "Failed to archive repository"
        echo "$archive_response" | jq -r '.message // .error // "Unknown error"'
        return 1
    fi
    
    # Update description
    print_info "Updating description..."
    local desc_response=$(curl -s -X PUT \
        --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "{\"description\": \"$new_desc\"}" \
        "https://${GITLAB_HOST}/api/v4/projects/${project_id}")
    
    if echo "$desc_response" | jq -e '.id' &>/dev/null; then
        print_success "Description updated"
    else
        print_warning "Failed to update description (repository is still archived)"
    fi
    
    print_success "Repository archived successfully!"
    echo ""
    
    return 0
}

main() {
    print_header
    
    if [[ "$DRY_RUN" == true ]]; then
        print_warning "Running in DRY-RUN mode - no changes will be made"
        echo ""
    fi
    
    # Verify GitLab API access
    print_section "Pre-flight Checks"
    print_info "Verifying GitLab API access..."
    
    local user_check=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "https://${GITLAB_HOST}/api/v4/user" | jq -r '.username // empty')
    
    if [[ -n "$user_check" ]]; then
        print_success "GitLab API access verified (user: $user_check)"
    else
        print_error "Failed to authenticate with GitLab API"
        exit 1
    fi
    echo ""
    
    print_section "Repositories to Archive"
    for repo in "${REPOS[@]}"; do
        # Format: name|visibility|description|gitlab_ssh_url
        IFS='|' read -r name vis desc url <<< "$repo"
        echo "  - $name"
    done
    echo ""
    
    if [[ "$DRY_RUN" == false ]]; then
        echo -e "${RED}${BOLD}WARNING: This will archive repositories on GitLab!${NC}"
        echo -e "${YELLOW}Archived repositories are read-only and cannot be modified.${NC}"
        echo -e "${YELLOW}This action can be reversed, but it's recommended to verify${NC}"
        echo -e "${YELLOW}the GitHub migration is successful before proceeding.${NC}"
        echo ""
        read -p "Type 'ARCHIVE' to confirm: " confirmation
        if [[ "$confirmation" != "ARCHIVE" ]]; then
            print_warning "Cancelled by user"
            exit 0
        fi
        echo ""
    fi
    
    # Archive each repository
    for repo in "${REPOS[@]}"; do
        # Format: name|visibility|description|gitlab_ssh_url
        IFS='|' read -r name vis desc url <<< "$repo"
        if archive_repository "$name"; then
            ((SUCCESS_COUNT++)) || true
        else
            ((FAILED_COUNT++)) || true
        fi
    done
    
    # Summary
    print_section "Summary"
    echo -e "${BOLD}Total repositories:${NC} ${#REPOS[@]}"
    echo -e "${GREEN}${BOLD}Successfully archived:${NC} $SUCCESS_COUNT"
    echo -e "${RED}${BOLD}Failed:${NC} $FAILED_COUNT"
    echo ""
    
    if [[ $FAILED_COUNT -eq 0 ]]; then
        print_success "All repositories archived successfully!"
        echo ""
        echo -e "${BOLD}Info:${NC}"
        echo "  • All repositories now show migration notice"
        echo "  • Repositories are read-only on GitLab"
        echo ""
        echo -e "${CYAN}To unarchive a repository (if needed):${NC}"
        echo "  Visit: https://${GITLAB_HOST}/${GITLAB_USER}/[repo]/edit"
        echo "  Or use: curl -X POST --header \"PRIVATE-TOKEN: \$TOKEN\" \\"
        echo "          \"https://${GITLAB_HOST}/api/v4/projects/[ID]/unarchive\""
        
        # Prompt to run next script
        echo ""
        echo -e "${BLUE}Next step: ./06-cleanup.sh${NC}"
        read -p "Clean up temporary files? [y/N]: " run_next
        if [[ "${run_next,,}" == "y" ]]; then
            exec "${SCRIPT_DIR}/06-cleanup.sh"
        fi
    else
        print_error "Some repositories failed to archive"
        exit 1
    fi
}

main "$@"
