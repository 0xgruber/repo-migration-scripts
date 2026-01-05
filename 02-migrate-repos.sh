#!/bin/bash

#############################################################################
# GitLab to GitHub Repository Migration Script
# 
# Purpose: Migrate repositories from GitLab to GitHub
# Method: Mirror clone (preserves all history, branches, tags)
# Configuration: Uses config.ini for all settings
#
# Usage:
#   ./gitlab-to-github-migration.sh [--dry-run] [--config FILE]
#
# Options:
#   --dry-run         Preview actions without making changes
#   --config FILE     Use alternative config file (default: config.ini)
#
#############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration library
source "${SCRIPT_DIR}/lib-config.sh"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Default configuration
DRY_RUN=false
CUSTOM_CONFIG=""

# Parse command line arguments
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

# Validate configuration
if ! validate_config; then
    echo "ERROR: Invalid configuration. Please check config.ini"
    exit 1
fi

# Load repository list
mapfile -t REPOS < <(load_repositories)
TOTAL_REPOS=${#REPOS[@]}

# Statistics
SUCCESS_COUNT=0
FAILED_COUNT=0
declare -a FAILED_REPOS=()
declare -a SUCCESS_REPOS=()

#############################################################################
# Utility Functions
#############################################################################

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║     GitLab → GitHub Repository Migration Tool                     ║"
    echo "║     Source: ${GITLAB_HOST}/${GITLAB_USER}"
    printf "║     %-66s ║\n" "Target: ${GITHUB_HOST}/${GITHUB_USER}"
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

#############################################################################
# Pre-flight Checks
#############################################################################

preflight_checks() {
    print_section "Pre-flight Checks"
    
    local all_passed=true
    
    # Check if running in dry-run mode
    if [[ "$DRY_RUN" == true ]]; then
        print_warning "Running in DRY-RUN mode - no changes will be made"
        log "INFO" "DRY-RUN mode enabled"
    fi
    
    # Check for required commands
    print_info "Checking required commands..."
    local required_commands=("git" "gh" "curl" "jq")
    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" &> /dev/null; then
            print_success "$cmd found"
        else
            print_error "$cmd not found"
            case "$cmd" in
                gh)
                    echo ""
                    echo -e "${YELLOW}GitHub CLI (gh) is required for this script.${NC}"
                    echo -e "${CYAN}Install instructions:${NC}"
                    echo "  Fedora/RHEL:  sudo dnf install gh"
                    echo "  Ubuntu/Debian: sudo apt install gh"
                    echo "  macOS:        brew install gh"
                    echo "  Other:        https://cli.github.com/manual/installation"
                    echo ""
                    echo -e "${CYAN}After installing, authenticate with:${NC}"
                    echo "  gh auth login"
                    echo ""
                    ;;
                jq)
                    echo -e "${YELLOW}Install jq: sudo dnf install jq (Fedora) or sudo apt install jq (Debian/Ubuntu)${NC}"
                    ;;
                curl)
                    echo -e "${YELLOW}Install curl: sudo dnf install curl (Fedora) or sudo apt install curl (Debian/Ubuntu)${NC}"
                    ;;
            esac
            all_passed=false
        fi
    done
    
    # Check GitHub authentication
    print_info "Verifying GitHub authentication..."
    local gh_user=$(gh api user --jq .login 2>/dev/null || echo "")
    if [[ -n "$gh_user" ]] && [[ "$gh_user" != "null" ]]; then
        if [[ "$gh_user" == "$GITHUB_USER" ]]; then
            print_success "Authenticated to GitHub as $gh_user"
            log "INFO" "GitHub authentication verified: $gh_user"
        else
            print_error "GitHub authenticated as $gh_user but expected $GITHUB_USER"
            print_warning "Please run: gh auth logout && gh auth login"
            all_passed=false
        fi
    else
        print_error "GitHub CLI not authenticated or token expired"
        print_warning "Please run: gh auth login"
        all_passed=false
    fi
    
    # Check SSH connectivity to GitLab
    print_info "Verifying GitLab SSH access..."
    if ssh -T git@${GITLAB_HOST} 2>&1 | grep -q "Welcome to GitLab"; then
        print_success "GitLab SSH access verified"
        log "INFO" "GitLab SSH connection successful"
    else
        print_error "Cannot connect to GitLab via SSH"
        all_passed=false
    fi
    
    # Check SSH connectivity to GitHub
    print_info "Verifying GitHub SSH access..."
    local gh_ssh_test=$(timeout ${SSH_TIMEOUT} ssh -T git@${GITHUB_HOST} 2>&1 || true)
    if echo "$gh_ssh_test" | grep -q "$GITHUB_USER"; then
        print_success "GitHub SSH access verified"
        log "INFO" "GitHub SSH connection successful"
    elif echo "$gh_ssh_test" | grep -qi "successfully authenticated"; then
        print_success "GitHub SSH access verified"
        log "INFO" "GitHub SSH connection successful"
    else
        print_warning "Could not verify GitHub SSH access in pre-flight"
        print_info "Will attempt to use SSH during migration"
        log "WARNING" "GitHub SSH verification inconclusive"
        # Don't fail pre-flight for this - we verified it works manually
    fi
    
    # Check disk space
    print_info "Checking available disk space..."
    local available_space=$(df /tmp | awk 'NR==2 {print $4}')
    local required_space=$((MIN_DISK_SPACE_MB * 1024))  # Convert MB to KB
    if [[ $available_space -gt $required_space ]]; then
        print_success "Sufficient disk space available: $(( available_space / 1024 / 1024 )) GB"
        log "INFO" "Disk space check passed: $(( available_space / 1024 / 1024 )) GB available"
    else
        print_warning "Low disk space: $(( available_space / 1024 / 1024 )) GB (recommended: ${MIN_DISK_SPACE_MB}MB+)"
    fi
    
    # Create working directory
    if [[ "$DRY_RUN" == false ]]; then
        print_info "Creating working directory..."
        mkdir -p "${WORK_DIR}"
        print_success "Working directory created: ${WORK_DIR}"
        log "INFO" "Working directory created: ${WORK_DIR}"
    else
        print_info "Would create working directory: ${WORK_DIR}"
    fi
    
    if [[ "$all_passed" == false ]]; then
        print_error "Pre-flight checks failed. Please fix the issues above and try again."
        log "ERROR" "Pre-flight checks failed"
        exit 1
    fi
    
    print_success "All pre-flight checks passed!"
    echo ""
}

#############################################################################
# Local Repository Check
#############################################################################

check_local_repos() {
    print_section "Checking Local Repositories"
    
    # Load local repositories from config
    local local_repos_raw
    mapfile -t local_repos_raw < <(load_local_repositories)
    
    if [[ ${#local_repos_raw[@]} -eq 0 ]]; then
        print_info "No local repositories configured - skipping local repo check"
        return 0
    fi
    
    print_info "Checking ${#local_repos_raw[@]} local repositories for uncommitted/unpushed changes..."
    echo ""
    
    local repos_with_issues=()
    local repos_uncommitted=()
    local repos_unpushed=()
    
    for repo_entry in "${local_repos_raw[@]}"; do
        # Format: name|path
        IFS='|' read -r repo_name repo_path <<< "$repo_entry"
        
        # Skip if directory doesn't exist
        if [[ ! -d "$repo_path" ]]; then
            print_warning "Directory not found: $repo_path (skipping)"
            continue
        fi
        
        # Skip if not a git repository
        if [[ ! -d "$repo_path/.git" ]]; then
            print_warning "Not a git repository: $repo_path (skipping)"
            continue
        fi
        
        local has_issues=false
        local uncommitted=false
        local unpushed=false
        
        # Check for uncommitted changes
        if [[ -n "$(git -C "$repo_path" status --porcelain 2>/dev/null)" ]]; then
            uncommitted=true
            has_issues=true
            repos_uncommitted+=("$repo_name|$repo_path")
        fi
        
        # Check for unpushed commits
        local unpushed_count=$(git -C "$repo_path" rev-list @{u}..HEAD --count 2>/dev/null || echo "0")
        if [[ "$unpushed_count" -gt 0 ]]; then
            unpushed=true
            has_issues=true
            repos_unpushed+=("$repo_name|$repo_path|$unpushed_count")
        fi
        
        if [[ "$has_issues" == true ]]; then
            repos_with_issues+=("$repo_name|$repo_path")
            print_error "$repo_name ($repo_path)"
            [[ "$uncommitted" == true ]] && echo -e "    ${YELLOW}└─ Has uncommitted changes${NC}"
            [[ "$unpushed" == true ]] && echo -e "    ${YELLOW}└─ Has $unpushed_count unpushed commit(s)${NC}"
        else
            print_success "$repo_name - clean"
        fi
    done
    
    echo ""
    
    # If there are issues, prompt user
    if [[ ${#repos_with_issues[@]} -gt 0 ]]; then
        print_warning "Found ${#repos_with_issues[@]} repository(ies) with uncommitted or unpushed changes"
        echo ""
        echo -e "${YELLOW}These changes will NOT be included in the migration unless pushed to GitLab first.${NC}"
        echo ""
        
        if [[ "$DRY_RUN" == true ]]; then
            print_info "[DRY-RUN] Would prompt to commit and push changes"
            return 0
        fi
        
        echo -e "${CYAN}Options:${NC}"
        echo "  1) Commit and push all changes to GitLab now"
        echo "  2) Continue migration without these changes (not recommended)"
        echo "  3) Abort migration and handle manually"
        echo ""
        read -p "Select option [1/2/3]: " choice
        
        case "$choice" in
            1)
                commit_and_push_local_repos "${repos_with_issues[@]}"
                ;;
            2)
                print_warning "Continuing without local changes - these will NOT be migrated!"
                log "WARNING" "User chose to continue without pushing local changes"
                echo ""
                ;;
            3|*)
                print_info "Migration aborted. Please commit and push your changes manually:"
                echo ""
                for repo_entry in "${repos_with_issues[@]}"; do
                    IFS='|' read -r name path <<< "$repo_entry"
                    echo "  cd $path"
                    echo "  git add -A && git commit -m 'Pre-migration commit' && git push"
                    echo ""
                done
                exit 0
                ;;
        esac
    else
        print_success "All local repositories are clean - ready for migration!"
    fi
    
    echo ""
}

commit_and_push_local_repos() {
    local repos=("$@")
    
    print_section "Committing and Pushing Local Changes"
    
    for repo_entry in "${repos[@]}"; do
        IFS='|' read -r repo_name repo_path <<< "$repo_entry"
        
        print_info "Processing: $repo_name"
        
        cd "$repo_path"
        
        # Check for uncommitted changes
        if [[ -n "$(git status --porcelain)" ]]; then
            print_info "  Staging changes..."
            git add -A
            
            # Prompt for commit message
            echo ""
            echo -e "${CYAN}Enter commit message for $repo_name${NC}"
            echo -e "${YELLOW}(or press Enter for default: 'Pre-migration commit')${NC}"
            read -p "> " commit_msg
            
            if [[ -z "$commit_msg" ]]; then
                commit_msg="Pre-migration commit"
            fi
            
            if git commit -m "$commit_msg"; then
                print_success "  Committed changes"
                log "INFO" "Committed changes in $repo_name: $commit_msg"
            else
                print_error "  Failed to commit changes"
                log "ERROR" "Failed to commit in $repo_name"
                continue
            fi
        fi
        
        # Push to origin (GitLab)
        print_info "  Pushing to GitLab..."
        if git push origin 2>/dev/null; then
            print_success "  Pushed to GitLab"
            log "INFO" "Pushed $repo_name to GitLab"
        else
            # Try pushing with upstream set
            local current_branch=$(git branch --show-current)
            if git push -u origin "$current_branch" 2>/dev/null; then
                print_success "  Pushed to GitLab (set upstream)"
                log "INFO" "Pushed $repo_name to GitLab with upstream"
            else
                print_error "  Failed to push to GitLab"
                log "ERROR" "Failed to push $repo_name to GitLab"
            fi
        fi
        
        echo ""
    done
    
    print_success "Finished processing local repositories"
    echo ""
}

#############################################################################
# Repository Migration Functions
#############################################################################

migrate_repository() {
    local display_name="$1"
    local slug="$2"
    local visibility="$3"
    local gitlab_url="$4"
    local description="$5"
    local repo_num="$6"
    local total="$7"
    
    print_section "[$repo_num/$total] Migrating: $slug"
    log "INFO" "Starting migration: $slug (display: $display_name, visibility: $visibility)"
    
    local temp_dir="${WORK_DIR}/${slug}"
    local github_url="git@${GITHUB_HOST}:${GITHUB_USER}/${slug}.git"
    
    # Step 1: Clone from GitLab
    print_info "Cloning from GitLab (mirror)..."
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[DRY-RUN] Would run: git clone --mirror ${gitlab_url} ${temp_dir}"
        log "INFO" "[DRY-RUN] Would clone: $gitlab_url"
    else
        if git clone --mirror "${gitlab_url}" "${temp_dir}" >> "${LOG_FILE}" 2>&1; then
            print_success "Cloned from GitLab"
            log "INFO" "Successfully cloned: $gitlab_url"
        else
            print_error "Failed to clone from GitLab"
            log "ERROR" "Failed to clone from GitLab: $gitlab_url"
            return 1
        fi
    fi
    
    # Step 2: Get repository metadata
    if [[ "$DRY_RUN" == false ]]; then
        cd "${temp_dir}"
        local branch_count=$(git branch -a | wc -l)
        local tag_count=$(git tag | wc -l)
        local commit_count=$(git rev-list --all --count 2>/dev/null || echo "0")
        print_info "Metadata: $branch_count branches, $tag_count tags, $commit_count commits"
        log "INFO" "Repository metadata: branches=$branch_count, tags=$tag_count, commits=$commit_count"
        cd - > /dev/null
    else
        print_info "[DRY-RUN] Would extract repository metadata"
    fi
    
    # Step 3: Check if repository exists on GitHub
    print_info "Checking if repository exists on GitHub..."
    if [[ "$DRY_RUN" == false ]]; then
        if gh repo view "${GITHUB_USER}/${slug}" &> /dev/null; then
            print_error "Repository already exists on GitHub: ${GITHUB_USER}/${slug}"
            log "ERROR" "Repository already exists: ${GITHUB_USER}/${slug}"
            rm -rf "${temp_dir}"
            return 1
        fi
    else
        print_info "[DRY-RUN] Would check if ${GITHUB_USER}/${slug} exists"
    fi
    
    # Step 4: Create repository on GitHub
    print_info "Creating repository on GitHub..."
    local gh_visibility="$visibility"
    [[ "$visibility" == "internal" ]] && gh_visibility="private"
    
    local create_cmd="gh repo create ${GITHUB_USER}/${slug} --${gh_visibility}"
    [[ -n "$description" ]] && create_cmd="$create_cmd --description=\"$description\""
    
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[DRY-RUN] Would run: $create_cmd --source=${temp_dir}"
        log "INFO" "[DRY-RUN] Would create repo: ${GITHUB_USER}/${slug}"
    else
        # Create the repo without --source first, then push manually
        if [[ -n "$description" ]]; then
            gh repo create "${GITHUB_USER}/${slug}" "--${gh_visibility}" --description="$description" >> "${LOG_FILE}" 2>&1
        else
            gh repo create "${GITHUB_USER}/${slug}" "--${gh_visibility}" >> "${LOG_FILE}" 2>&1
        fi
        
        if [[ $? -eq 0 ]]; then
            print_success "Created repository on GitHub"
            log "INFO" "Successfully created: ${GITHUB_USER}/${slug}"
        else
            print_error "Failed to create repository on GitHub"
            log "ERROR" "Failed to create repo: ${GITHUB_USER}/${slug}"
            rm -rf "${temp_dir}"
            return 1
        fi
    fi
    
    # Step 5: Push mirror to GitHub
    print_info "Pushing to GitHub (mirror)..."
    if [[ "$DRY_RUN" == true ]]; then
        print_info "[DRY-RUN] Would run: git push --mirror ${github_url}"
        log "INFO" "[DRY-RUN] Would push mirror to: $github_url"
    else
        cd "${temp_dir}"
        if git push --mirror "${github_url}" >> "${LOG_FILE}" 2>&1; then
            print_success "Pushed to GitHub"
            log "INFO" "Successfully pushed mirror to: $github_url"
        else
            print_error "Failed to push to GitHub"
            log "ERROR" "Failed to push to GitHub: $github_url"
            cd - > /dev/null
            rm -rf "${temp_dir}"
            return 1
        fi
        cd - > /dev/null
    fi
    
    # Step 6: Verify migration
    if [[ "$DRY_RUN" == false ]]; then
        print_info "Verifying migration..."
        sleep 2  # Give GitHub a moment to process
        
        if gh repo view "${GITHUB_USER}/${slug}" &> /dev/null; then
            print_success "Verification passed"
            log "INFO" "Migration verified successfully: ${GITHUB_USER}/${slug}"
        else
            print_warning "Could not verify repository on GitHub"
            log "WARNING" "Verification inconclusive: ${GITHUB_USER}/${slug}"
        fi
    else
        print_info "[DRY-RUN] Would verify migration"
    fi
    
    # Step 7: Cleanup
    if [[ "$DRY_RUN" == false ]]; then
        print_info "Cleaning up temporary files..."
        rm -rf "${temp_dir}"
        print_success "Cleanup complete"
        log "INFO" "Cleanup completed for: $slug"
    else
        print_info "[DRY-RUN] Would clean up: ${temp_dir}"
    fi
    
    print_success "Migration completed: $slug"
    echo ""
    return 0
}

#############################################################################
# Main Migration Process
#############################################################################

main() {
    print_header
    
    # Initialize log file
    mkdir -p "${WORK_DIR}"
    echo "GitLab to GitHub Migration Log" > "${LOG_FILE}"
    echo "Started: $(date)" >> "${LOG_FILE}"
    echo "Mode: ${DRY_RUN}" >> "${LOG_FILE}"
    echo "Config: ${CONFIG_FILE}" >> "${LOG_FILE}"
    echo "======================================" >> "${LOG_FILE}"
    
    log "INFO" "Migration started"
    log "INFO" "Total repositories to migrate: $TOTAL_REPOS"
    
    # Run pre-flight checks
    preflight_checks
    
    # Check local repositories for uncommitted/unpushed changes
    check_local_repos
    
    # Display migration plan
    print_section "Migration Plan"
    echo -e "${BOLD}Repositories to migrate:${NC}"
    local idx=1
    for repo in "${REPOS[@]}"; do
        IFS='|' read -r name vis desc url <<< "$repo"
        echo "  $idx. $name ($vis)"
        idx=$((idx + 1))
    done
    echo ""
    echo -e "${BOLD}Total:${NC} $TOTAL_REPOS repositories"
    echo -e "${BOLD}Mode:${NC} $([ "$DRY_RUN" == true ] && echo "DRY-RUN (no changes)" || echo "LIVE MIGRATION")"
    echo ""
    
    # Confirmation prompt (skip in dry-run)
    if [[ "$DRY_RUN" == false ]]; then
        echo -e "${YELLOW}This will migrate all repositories from GitLab to GitHub.${NC}"
        echo -e "${YELLOW}Are you sure you want to proceed?${NC}"
        read -p "Type 'yes' to continue: " confirmation
        if [[ "$confirmation" != "yes" ]]; then
            print_warning "Migration cancelled by user"
            log "INFO" "Migration cancelled by user"
            exit 0
        fi
        echo ""
    fi
    
    # Migrate each repository
    print_section "Starting Migration"
    
    local repo_num=1
    for repo in "${REPOS[@]}"; do
        # New format: name|visibility|description|gitlab_ssh_url
        IFS='|' read -r name vis desc url <<< "$repo"
        
        if migrate_repository "$name" "$name" "$vis" "$url" "$desc" "$repo_num" "$TOTAL_REPOS"; then
            SUCCESS_REPOS+=("$name")
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            FAILED_REPOS+=("$name")
            FAILED_COUNT=$((FAILED_COUNT + 1))
        fi
        
        repo_num=$((repo_num + 1))
    done
    
    # Generate summary report
    generate_report
    
    # Display final summary
    print_section "Migration Summary"
    echo -e "${BOLD}Total repositories:${NC} $TOTAL_REPOS"
    echo -e "${GREEN}${BOLD}Successful:${NC} $SUCCESS_COUNT"
    echo -e "${RED}${BOLD}Failed:${NC} $FAILED_COUNT"
    echo ""
    
    if [[ $FAILED_COUNT -gt 0 ]]; then
        echo -e "${RED}${BOLD}Failed repositories:${NC}"
        for repo in "${FAILED_REPOS[@]}"; do
            echo -e "  ${RED}✗${NC} $repo"
        done
        echo ""
    fi
    
    if [[ "$DRY_RUN" == false ]]; then
        echo -e "${BOLD}Log file:${NC} ${LOG_FILE}"
        echo -e "${BOLD}Report:${NC} ${REPORT_FILE}"
    fi
    
    log "INFO" "Migration completed: $SUCCESS_COUNT successful, $FAILED_COUNT failed"
    
    if [[ $FAILED_COUNT -gt 0 ]]; then
        exit 1
    else
        print_success "All repositories migrated successfully!"
        exit 0
    fi
}

#############################################################################
# Report Generation
#############################################################################

generate_report() {
    if [[ "$DRY_RUN" == true ]]; then
        print_info "Skipping report generation in dry-run mode"
        return
    fi
    
    cat > "${REPORT_FILE}" << EOF
# GitLab to GitHub Migration Report

**Date:** $(date '+%Y-%m-%d %H:%M:%S')  
**Source:** ${GITLAB_HOST}/${GITLAB_USER}  
**Target:** ${GITHUB_HOST}/${GITHUB_USER}  
**Total Repositories:** $TOTAL_REPOS  
**Successful:** $SUCCESS_COUNT  
**Failed:** $FAILED_COUNT

---

## Successfully Migrated Repositories

EOF
    
    for repo in "${SUCCESS_REPOS[@]}"; do
        echo "- ✓ [$repo](https://${GITHUB_HOST}/${GITHUB_USER}/${repo})" >> "${REPORT_FILE}"
    done
    
    if [[ $FAILED_COUNT -gt 0 ]]; then
        cat >> "${REPORT_FILE}" << EOF

---

## Failed Migrations

EOF
        for repo in "${FAILED_REPOS[@]}"; do
            echo "- ✗ $repo" >> "${REPORT_FILE}"
        done
    fi
    
    cat >> "${REPORT_FILE}" << EOF

---

## Next Steps

1. **Verify Repositories**: Check each migrated repository on GitHub
2. **Normalize Names**: Update display names to match URL slugs
3. **Update Documentation**: Update GitLab URLs to GitHub URLs in all documentation
4. **Update Local Repos**: Update local repository remotes to point to GitHub
5. **Archive GitLab Repos**: Archive the migrated repositories on GitLab

---

## Migration Log

See detailed log at: \`${LOG_FILE}\`

EOF
    
    log "INFO" "Report generated: ${REPORT_FILE}"
}

#############################################################################
# Execute Main Function
#############################################################################

main "$@"
