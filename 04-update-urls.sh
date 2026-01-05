#!/bin/bash

#############################################################################
# Update Repository URLs Script
# 
# Purpose: Update GitLab URLs to GitHub URLs in all repository files
# Scans: All text files (code, config, documentation) for old URLs
# Method: Interactive review before committing changes
# Configuration: Uses config.ini for all settings
#
# Usage:
#   ./04-update-urls.sh [--dry-run] [--auto-commit] [--config FILE]
#
# Options:
#   --dry-run       Preview changes without modifying files
#   --auto-commit   Automatically commit changes without review
#   --config FILE   Use alternative config file
#
# Can be called from 02-migrate-repos.sh or run standalone
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
CALLED_FROM_MIGRATE=false

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
        --from-migrate)
            # Called from migration script - skip redundant prompts
            CALLED_FROM_MIGRATE=true
            shift
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

# Use WORK_DIR from config (same as migration script)
CLONE_DIR="${WORK_DIR}"

TOTAL_FILES_UPDATED=0
TOTAL_REPLACEMENTS=0
declare -a UPDATED_REPOS=()

# File extensions to scan (text files that might contain URLs)
# Excludes binary files, images, compiled files, etc.
TEXT_EXTENSIONS=(
    "md" "txt" "rst" "adoc"                    # Documentation
    "sh" "bash" "zsh" "fish"                   # Shell scripts
    "py" "rb" "pl" "php"                       # Scripting languages
    "js" "ts" "jsx" "tsx" "mjs" "cjs"          # JavaScript/TypeScript
    "java" "kt" "scala" "groovy"               # JVM languages
    "c" "cpp" "h" "hpp" "cc"                   # C/C++
    "go" "rs" "swift"                          # Go, Rust, Swift
    "cs" "fs" "vb"                             # .NET languages
    "json" "yaml" "yml" "toml" "ini" "conf"   # Config files
    "xml" "html" "htm" "css" "scss" "sass"    # Web files
    "sql" "graphql"                            # Query languages
    "Dockerfile" "docker-compose"              # Docker
    "tf" "hcl"                                 # Terraform
    "nix"                                      # Nix
    "vim" "lua"                                # Editor configs
    "gitignore" "gitattributes" "gitmodules"  # Git files
    "env" "env.example" "env.sample"          # Environment files
    "Makefile" "CMakeLists"                   # Build files
)

print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║     Update Repository URLs                                         ║"
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
    local repo_dir="${CLONE_DIR}/${repo_name}"
    
    # Check if already exists (from migration script 02)
    if [[ -d "$repo_dir/.git" ]]; then
        print_info "Using existing clone: $repo_name"
        # Make sure we're on the right branch
        cd "$repo_dir"
        git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
        cd - > /dev/null
        return 0
    fi
    
    # Check if bare/mirror repo exists (needs conversion)
    if [[ -d "$repo_dir" ]] && [[ -f "$repo_dir/HEAD" ]]; then
        print_info "Converting mirror clone to working copy: $repo_name"
        cd "$repo_dir"
        git config --bool core.bare false
        git checkout HEAD -- . 2>/dev/null || true
        cd - > /dev/null
        return 0
    fi
    
    # Clone fresh from GitHub
    print_info "Cloning $repo_name from GitHub..."
    mkdir -p "${CLONE_DIR}"
    if git clone "git@github.com:${GITHUB_USER}/${repo_name}.git" "$repo_dir" &>/dev/null; then
        print_success "Cloned successfully"
        return 0
    else
        print_error "Failed to clone $repo_name"
        return 1
    fi
}

find_text_files() {
    local repo_dir="$1"
    
    # Build find command with all text extensions
    local find_args=()
    for ext in "${TEXT_EXTENSIONS[@]}"; do
        if [[ ${#find_args[@]} -gt 0 ]]; then
            find_args+=("-o")
        fi
        find_args+=("-name" "*.${ext}")
    done
    
    # Also include files without extensions that might be scripts
    find_args+=("-o" "-name" "Makefile")
    find_args+=("-o" "-name" "Dockerfile")
    find_args+=("-o" "-name" "Jenkinsfile")
    find_args+=("-o" "-name" "Vagrantfile")
    find_args+=("-o" "-name" ".gitmodules")
    
    # Find files, excluding .git directory
    find "$repo_dir" -type f \( "${find_args[@]}" \) 2>/dev/null | grep -v "/.git/" || true
}

update_urls_in_file() {
    local file="$1"
    
    # Patterns to replace
    local gitlab_https="https://${GITLAB_HOST}/${GITLAB_USER}"
    local gitlab_ssh="git@${GITLAB_HOST}:${GITLAB_USER}"
    local github_https="https://github.com/${GITHUB_USER}"
    local github_ssh="git@github.com:${GITHUB_USER}"
    
    # Also handle bare host references (without protocol)
    local gitlab_bare="${GITLAB_HOST}/${GITLAB_USER}"
    local github_bare="github.com/${GITHUB_USER}"
    
    # Count matches first
    local https_count=$(grep -c "https://${GITLAB_HOST}/${GITLAB_USER}" "$file" 2>/dev/null || true)
    local ssh_count=$(grep -c "git@${GITLAB_HOST}:${GITLAB_USER}" "$file" 2>/dev/null || true)
    local bare_count=$(grep -c "${GITLAB_HOST}/${GITLAB_USER}" "$file" 2>/dev/null || true)
    
    # bare_count includes https matches, so subtract
    bare_count=$((${bare_count:-0} - ${https_count:-0}))
    [[ $bare_count -lt 0 ]] && bare_count=0
    
    local total_matches=$((${https_count:-0} + ${ssh_count:-0} + ${bare_count:-0}))
    
    if [[ "$DRY_RUN" == true ]]; then
        echo "$total_matches"
        return 0
    fi
    
    if [[ $total_matches -eq 0 ]]; then
        echo "0"
        return 0
    fi
    
    # Perform replacements
    local temp_file="${file}.tmp"
    
    # Replace HTTPS URLs first
    sed "s|https://${GITLAB_HOST}/${GITLAB_USER}/|${github_https}/|g" "$file" > "$temp_file"
    
    # Replace SSH URLs
    sed -i "s|git@${GITLAB_HOST}:${GITLAB_USER}/|${github_ssh}/|g" "$temp_file"
    
    # Replace bare host references (careful not to double-replace)
    # Only replace if not already github.com
    sed -i "s|${GITLAB_HOST}/${GITLAB_USER}/|${github_bare}/|g" "$temp_file"
    
    # Check if anything changed
    if ! diff -q "$file" "$temp_file" &>/dev/null; then
        mv "$temp_file" "$file"
        echo "$total_matches"
        return 0
    else
        rm -f "$temp_file"
        echo "0"
        return 0
    fi
}

process_repository() {
    local repo_name="$1"
    
    print_section "Processing: $repo_name"
    
    local repo_dir="${CLONE_DIR}/${repo_name}"
    
    # Clone repository
    if ! clone_repository "$repo_name"; then
        return 1
    fi
    
    cd "$repo_dir"
    
    # Find text files
    print_info "Scanning for files containing GitLab URLs..."
    local text_files=$(find_text_files "$repo_dir")
    
    if [[ -z "$text_files" ]]; then
        print_info "No text files found"
        return 0
    fi
    
    # Check each file for GitLab URLs
    local files_with_urls=()
    
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        if grep -q "${GITLAB_HOST}" "$file" 2>/dev/null; then
            files_with_urls+=("$file")
        fi
    done <<< "$text_files"
    
    if [[ ${#files_with_urls[@]} -eq 0 ]]; then
        print_success "No GitLab URLs found - repository is clean"
        return 0
    fi
    
    print_info "Found ${#files_with_urls[@]} file(s) with GitLab URLs"
    echo ""
    
    # Show files with URLs
    for file in "${files_with_urls[@]}"; do
        local rel_path="${file#$repo_dir/}"
        print_info "Found GitLab URLs in: $rel_path"
        
        # Show preview of lines with URLs
        if [[ "$DRY_RUN" == true ]] || [[ "$AUTO_COMMIT" == false ]]; then
            echo -e "${YELLOW}Preview:${NC}"
            grep -n "${GITLAB_HOST}" "$file" 2>/dev/null | head -5 | sed 's/^/  /'
            echo ""
        fi
    done
    
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
    local files_updated=0
    
    for file in "${files_with_urls[@]}"; do
        local rel_path="${file#$repo_dir/}"
        
        local changes=$(update_urls_in_file "$file")
        
        if [[ $changes -gt 0 ]]; then
            print_success "Updated: $rel_path ($changes replacement(s))"
            ((repo_changes += changes))
            ((files_updated++))
        fi
    done
    
    if [[ $repo_changes -eq 0 ]]; then
        print_info "No changes needed"
        return 0
    fi
    
    ((TOTAL_FILES_UPDATED += files_updated))
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
            print_warning "Changes not committed (review with: git diff)"
            return 0
        fi
    fi
    
    # Commit changes
    if [[ "$DRY_RUN" == false ]]; then
        git add -A
        
        if git commit -m "chore: update repository URLs after migration to GitHub

Replaced GitLab URLs with GitHub URLs across the codebase." &>/dev/null; then
            print_success "Changes committed"
            
            # Push changes
            if [[ "$AUTO_COMMIT" == true ]]; then
                push_response="yes"
            else
                echo -e "${YELLOW}Push changes to GitHub?${NC}"
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
    
    # Create working directory if needed
    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$CLONE_DIR"
        print_info "Working directory: $CLONE_DIR"
        echo ""
    fi
    
    print_section "Repositories to Process"
    for repo in "${REPOS[@]}"; do
        echo "  - $repo"
    done
    echo ""
    
    # Skip confirmation if called from migrate script or auto-commit
    if [[ "$DRY_RUN" == false ]] && [[ "$AUTO_COMMIT" == false ]] && [[ "$CALLED_FROM_MIGRATE" == false ]]; then
        echo -e "${YELLOW}This will scan all text files for GitLab URLs and update them.${NC}"
        echo -e "${YELLOW}File types: code, config, documentation, scripts, etc.${NC}"
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
    echo -e "${BOLD}Total URL replacements:${NC} $TOTAL_REPLACEMENTS"
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
        print_info "Working directory: $CLONE_DIR"
        print_info "Run ./06-cleanup.sh when done to remove temporary files"
        
        # Prompt to run next script
        echo ""
        echo -e "${BLUE}Next step: ./05-archive-gitlab-repos.sh${NC}"
        read -p "Archive migrated repositories on GitLab? [y/N]: " run_next
        if [[ "${run_next,,}" == "y" ]]; then
            exec "${SCRIPT_DIR}/05-archive-gitlab-repos.sh"
        fi
    fi
    
    print_success "URL update process complete!"
}

main "$@"
