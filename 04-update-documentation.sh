#!/bin/bash

#############################################################################
# Update Documentation URLs Script
# 
# Purpose: Update GitLab URLs to GitHub URLs in documentation files
# Scans: README, CHANGELOG, and all .md files in migrated repositories
# Method: Interactive review before committing changes
# Configuration: Uses config.ini for all settings
#
# Usage:
#   ./update-documentation.sh [--dry-run] [--auto-commit] [--config FILE]
#
# Options:
#   --dry-run       Preview changes without modifying files
#   --auto-commit   Automatically commit changes without review
#   --config FILE   Use alternative config file
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

# Default options
DRY_RUN=false
AUTO_COMMIT=false
CUSTOM_CONFIG=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --auto-commit)
            AUTO_COMMIT=true
            shift
            ;;
        --config)
            CUSTOM_CONFIG="$2"
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Load configuration
load_config

# Load repository list from repos.ini
mapfile -t REPOS_RAW < <(load_repositories)
declare -a REPOS=()
for repo in "${REPOS_RAW[@]}"; do
    # Format: name|visibility|description|gitlab_ssh_url
    IFS='|' read -r name vis desc url <<< "$repo"
    REPOS+=("$name")
done

# Use DOC_UPDATE_DIR from config instead of WORK_DIR
WORK_DIR="${DOC_UPDATE_DIR}"

TOTAL_FILES_UPDATED=0
TOTAL_REPLACEMENTS=0
declare -a UPDATED_REPOS=()

print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║     Update Documentation URLs                                      ║"
    echo "║     GitLab → GitHub URL Replacement                               ║"
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

clone_repository() {
    local repo_name="$1"
    local repo_dir="${WORK_DIR}/${repo_name}"
    
    if [[ -d "$repo_dir" ]]; then
        print_info "Repository already cloned: $repo_name"
        return 0
    fi
    
    print_info "Cloning $repo_name from GitHub..."
    if git clone "git@github.com:${GITHUB_USER}/${repo_name}.git" "$repo_dir" &>/dev/null; then
        print_success "Cloned successfully"
        return 0
    else
        print_error "Failed to clone $repo_name"
        return 1
    fi
}

find_documentation_files() {
    local repo_dir="$1"
    
    # Find all markdown files
    find "$repo_dir" -type f -name "*.md" 2>/dev/null | grep -v ".git" || true
}

update_urls_in_file() {
    local file="$1"
    local repo_name="$2"
    
    local changes=0
    
    # Patterns to replace
    # 1. HTTPS URLs: https://gitlab.vaultcloud.xyz/aarongruber/REPO
    # 2. SSH URLs: git@gitlab.vaultcloud.xyz:aarongruber/REPO.git
    # 3. General GitLab references
    
    local gitlab_https="https://${GITLAB_HOST}/${GITLAB_USER}"
    local gitlab_ssh="git@${GITLAB_HOST}:${GITLAB_USER}"
    local github_https="https://github.com/${GITHUB_USER}"
    local github_ssh="git@github.com:${GITHUB_USER}"
    
    if [[ "$DRY_RUN" == true ]]; then
        # Just count potential replacements
        changes=$(grep -c "${GITLAB_HOST}/${GITLAB_USER}" "$file" 2>/dev/null || echo "0")
        changes=$((changes + $(grep -c "${GITLAB_HOST}:${GITLAB_USER}" "$file" 2>/dev/null || echo "0")))
        return $changes
    else
        # Perform replacements
        local temp_file="${file}.tmp"
        
        # Replace HTTPS URLs
        sed "s|https://${GITLAB_HOST}/${GITLAB_USER}/|${github_https}/|g" "$file" > "$temp_file"
        
        # Replace SSH URLs
        sed -i "s|git@${GITLAB_HOST}:${GITLAB_USER}/|${github_ssh}/|g" "$temp_file"
        
        # Check if anything changed
        if ! diff -q "$file" "$temp_file" &>/dev/null; then
            mv "$temp_file" "$file"
            changes=$(diff -u "$file".orig "$file" 2>/dev/null | grep -c "^+" || echo "1")
            return $changes
        else
            rm "$temp_file"
            return 0
        fi
    fi
}

process_repository() {
    local repo_name="$1"
    
    print_section "Processing: $repo_name"
    
    local repo_dir="${WORK_DIR}/${repo_name}"
    
    # Clone repository
    if ! clone_repository "$repo_name"; then
        return 1
    fi
    
    cd "$repo_dir"
    
    # Find documentation files
    print_info "Scanning for documentation files..."
    local doc_files=$(find_documentation_files "$repo_dir")
    
    if [[ -z "$doc_files" ]]; then
        print_info "No documentation files found"
        return 0
    fi
    
    local file_count=$(echo "$doc_files" | wc -l)
    print_info "Found $file_count documentation file(s)"
    echo ""
    
    # Check each file for GitLab URLs
    local files_with_urls=()
    local files_need_update=()
    
    for file in $doc_files; do
        if grep -q "${GITLAB_HOST}" "$file" 2>/dev/null; then
            local rel_path="${file#$repo_dir/}"
            files_with_urls+=("$file")
            print_info "Found GitLab URLs in: $rel_path"
            
            # Show preview of lines with URLs
            if [[ "$DRY_RUN" == true ]] || [[ "$AUTO_COMMIT" == false ]]; then
                echo -e "${YELLOW}Preview:${NC}"
                grep -n "${GITLAB_HOST}" "$file" | head -5 | sed 's/^/  /'
                echo ""
            fi
        fi
    done
    
    if [[ ${#files_with_urls[@]} -eq 0 ]]; then
        print_success "No GitLab URLs found - repository is clean"
        return 0
    fi
    
    # Ask for confirmation unless auto-commit or dry-run
    if [[ "$DRY_RUN" == false ]] && [[ "$AUTO_COMMIT" == false ]]; then
        echo -e "${YELLOW}Update ${#files_with_urls[@]} file(s) in $repo_name?${NC}"
        read -p "Continue? (yes/no/skip): " response
        if [[ "$response" != "yes" ]]; then
            print_warning "Skipped $repo_name"
            return 0
        fi
        echo ""
    fi
    
    # Update files
    local repo_changes=0
    for file in "${files_with_urls[@]}"; do
        local rel_path="${file#$repo_dir/}"
        
        if [[ "$DRY_RUN" == false ]]; then
            # Backup original
            cp "$file" "$file.orig"
        fi
        
        update_urls_in_file "$file" "$repo_name"
        local changes=$?
        
        if [[ $changes -gt 0 ]]; then
            print_success "Updated: $rel_path ($changes replacement(s))"
            ((repo_changes += changes))
            ((TOTAL_FILES_UPDATED++))
            files_need_update+=("$file")
        fi
        
        # Clean up backup
        rm -f "$file.orig"
    done
    
    if [[ $repo_changes -eq 0 ]]; then
        print_info "No changes needed"
        return 0
    fi
    
    ((TOTAL_REPLACEMENTS += repo_changes))
    
    # Show diff if not auto-committing
    if [[ "$DRY_RUN" == false ]] && [[ "$AUTO_COMMIT" == false ]]; then
        echo ""
        print_info "Changes made:"
        git diff --color=always | head -50
        echo ""
        
        echo -e "${YELLOW}Commit these changes?${NC}"
        read -p "Commit? (yes/no): " commit_response
        if [[ "$commit_response" != "yes" ]]; then
            print_warning "Changes not committed (staged for review)"
            return 0
        fi
    fi
    
    # Commit changes
    if [[ "$DRY_RUN" == false ]]; then
        git add *.md **/*.md 2>/dev/null || true
        
        if git commit -m "docs: update repository URLs after migration to GitHub" &>/dev/null; then
            print_success "Changes committed"
            
            # Push changes
            echo -e "${YELLOW}Push changes to GitHub?${NC}"
            if [[ "$AUTO_COMMIT" == true ]]; then
                push_response="yes"
            else
                read -p "Push? (yes/no): " push_response
            fi
            
            if [[ "$push_response" == "yes" ]]; then
                if git push origin main &>/dev/null || git push origin master &>/dev/null; then
                    print_success "Changes pushed to GitHub"
                    UPDATED_REPOS+=("$repo_name")
                else
                    print_error "Failed to push changes"
                fi
            else
                print_info "Changes committed but not pushed"
            fi
        else
            print_warning "Nothing to commit (or commit failed)"
        fi
    else
        print_info "[DRY-RUN] Would commit and push changes"
    fi
    
    echo ""
    return 0
}

main() {
    print_header
    
    if [[ "$DRY_RUN" == true ]]; then
        print_warning "Running in DRY-RUN mode - no changes will be made"
        echo ""
    fi
    
    if [[ "$AUTO_COMMIT" == true ]]; then
        print_warning "AUTO-COMMIT enabled - changes will be committed automatically"
        echo ""
    fi
    
    # Create working directory
    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$WORK_DIR"
        print_info "Working directory: $WORK_DIR"
        echo ""
    fi
    
    print_section "Repositories to Process"
    for repo in "${REPOS[@]}"; do
        echo "  • $repo"
    done
    echo ""
    
    if [[ "$DRY_RUN" == false ]] && [[ "$AUTO_COMMIT" == false ]]; then
        echo -e "${YELLOW}This will scan and update documentation files in all repositories.${NC}"
        echo -e "${YELLOW}You will be prompted to review changes before committing.${NC}"
        echo ""
        read -p "Continue? (yes/no): " confirmation
        if [[ "$confirmation" != "yes" ]]; then
            print_warning "Cancelled by user"
            exit 0
        fi
        echo ""
    fi
    
    # Process each repository
    for repo in "${REPOS[@]}"; do
        process_repository "$repo" || true
    done
    
    # Summary
    print_section "Summary"
    echo -e "${BOLD}Total repositories processed:${NC} ${#REPOS[@]}"
    echo -e "${BOLD}Files updated:${NC} $TOTAL_FILES_UPDATED"
    echo -e "${BOLD}Total replacements:${NC} $TOTAL_REPLACEMENTS"
    echo -e "${BOLD}Repositories committed & pushed:${NC} ${#UPDATED_REPOS[@]}"
    echo ""
    
    if [[ ${#UPDATED_REPOS[@]} -gt 0 ]]; then
        echo -e "${GREEN}${BOLD}Updated repositories:${NC}"
        for repo in "${UPDATED_REPOS[@]}"; do
            echo -e "  ${GREEN}✓${NC} https://github.com/${GITHUB_USER}/$repo"
        done
        echo ""
    fi
    
    if [[ "$DRY_RUN" == false ]]; then
        print_info "Working directory: $WORK_DIR"
        print_info "You can review the cloned repositories there"
    fi
    
    print_success "Documentation update process complete!"
}

main "$@"
