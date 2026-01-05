#!/bin/bash

#############################################################################
# Deploy Security Workflow to All Repositories
# 
# Purpose: Add GitHub Actions security scanning to all migrated repositories
# Features:
#   - Gitleaks secret scanning (full history)
#   - ShellCheck linting (if shell scripts present)
#   - Dependency review (for pull requests)
#   - Weekly scheduled scans
#
# Usage:
#   ./07-deploy-security-workflow.sh [--dry-run]
#
#############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load configuration library
source "${SCRIPT_DIR}/lib-config.sh"

# Load configuration
load_config

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Options
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Template file location
# NOTE: Templates have been moved to github-templates repository
# Download from: https://github.com/0xgruber/github-templates
GITHUB_TEMPLATES_REPO="${LOCAL_REPO_ROOT}/github-templates"
TEMPLATE_FILE="${GITHUB_TEMPLATES_REPO}/workflows/security.yml"

# Statistics
TOTAL_REPOS=0
SUCCESS_COUNT=0
SKIP_COUNT=0
FAILED_COUNT=0

print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║     Deploy Security Workflow to All Repositories                  ║"
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

check_template() {
    # Check if github-templates repo exists
    if [[ ! -d "$GITHUB_TEMPLATES_REPO" ]]; then
        print_error "github-templates repository not found: $GITHUB_TEMPLATES_REPO"
        print_info "Cloning from GitHub..."
        if git clone "git@github.com:${GITHUB_USER}/github-templates.git" "$GITHUB_TEMPLATES_REPO" &>/dev/null; then
            print_success "Cloned github-templates repository"
        else
            print_error "Failed to clone github-templates"
            echo ""
            echo "Please clone it manually:"
            echo "  git clone git@github.com:${GITHUB_USER}/github-templates.git $GITHUB_TEMPLATES_REPO"
            exit 1
        fi
    fi
    
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        print_error "Template file not found: $TEMPLATE_FILE"
        exit 1
    fi
    print_success "Template file found: $TEMPLATE_FILE"
}

deploy_to_repo() {
    local repo_name="$1"
    local repo_path="${LOCAL_REPO_ROOT}/${repo_name}"
    
    print_section "Processing: $repo_name"
    
    # Check if local repo exists
    if [[ ! -d "$repo_path" ]]; then
        print_warning "Repository not found locally: $repo_path"
        print_info "Cloning from GitHub..."
        
        if [[ "$DRY_RUN" == false ]]; then
            if git clone "git@github.com:${GITHUB_USER}/${repo_name}.git" "$repo_path" &>/dev/null; then
                print_success "Cloned successfully"
            else
                print_error "Failed to clone $repo_name"
                return 1
            fi
        else
            print_info "[DRY-RUN] Would clone from GitHub"
        fi
    fi
    
    # Check if it's a valid git repo
    if [[ ! -d "$repo_path/.git" ]]; then
        print_error "Not a valid git repository: $repo_path"
        return 1
    fi
    
    cd "$repo_path"
    
    # Ensure we're on the main branch and up to date
    if [[ "$DRY_RUN" == false ]]; then
        git fetch origin &>/dev/null || true
        git checkout main 2>/dev/null || git checkout master 2>/dev/null || {
            print_error "Could not checkout main/master branch"
            return 1
        }
        git pull origin HEAD &>/dev/null || true
    fi
    
    # Check if workflow already exists
    local workflow_path=".github/workflows/security.yml"
    if [[ -f "$workflow_path" ]]; then
        print_info "Security workflow already exists"
        
        # Check if it's different from template
        if diff -q "$TEMPLATE_FILE" "$workflow_path" &>/dev/null; then
            print_success "Workflow is up to date"
            return 2  # Return 2 to indicate "skip"
        else
            print_warning "Workflow exists but differs from template"
            echo -e "${YELLOW}Update existing workflow?${NC}"
            read -p "Continue? (yes/no): " response
            if [[ "$response" != "yes" ]]; then
                print_info "Skipped updating workflow"
                return 2
            fi
        fi
    fi
    
    # Create .github/workflows directory
    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p .github/workflows
    else
        print_info "[DRY-RUN] Would create .github/workflows/"
    fi
    
    # Copy workflow template
    if [[ "$DRY_RUN" == false ]]; then
        cp "$TEMPLATE_FILE" "$workflow_path"
        print_success "Security workflow added"
    else
        print_info "[DRY-RUN] Would copy security workflow"
    fi
    
    # Check for existing changes
    if [[ "$DRY_RUN" == false ]]; then
        if [[ -n $(git status --porcelain) ]]; then
            print_info "Changes detected, preparing commit..."
            
            git add .github/workflows/security.yml
            
            if git commit -m "Add GitHub Actions security workflow

- Gitleaks secret scanning (full git history)
- ShellCheck linting for shell scripts
- Dependency review for pull requests
- Weekly scheduled security scans

This ensures no secrets are accidentally committed and all
shell scripts follow security best practices." &>/dev/null; then
                print_success "Changes committed"
                
                # Push to GitHub
                echo -e "${YELLOW}Push changes to GitHub?${NC}"
                read -p "Push? (yes/no): " push_response
                if [[ "$push_response" == "yes" ]]; then
                    if git push origin HEAD &>/dev/null; then
                        print_success "Changes pushed to GitHub"
                        return 0
                    else
                        print_error "Failed to push changes"
                        return 1
                    fi
                else
                    print_info "Changes committed but not pushed"
                    return 0
                fi
            else
                print_warning "Nothing to commit or commit failed"
                return 2
            fi
        else
            print_info "No changes detected"
            return 2
        fi
    else
        print_info "[DRY-RUN] Would commit and push changes"
        return 0
    fi
}

main() {
    print_header
    
    if [[ "$DRY_RUN" == true ]]; then
        print_warning "Running in DRY-RUN mode - no changes will be made"
        echo ""
    fi
    
    # Check template exists
    check_template
    echo ""
    
    # Load repository list from repos.ini
    mapfile -t REPOS_RAW < <(load_repositories)
    declare -a REPOS=()
    for repo in "${REPOS_RAW[@]}"; do
        # Format: name|visibility|description|gitlab_ssh_url
        IFS='|' read -r name vis desc url <<< "$repo"
        REPOS+=("$name")
    done
    
    TOTAL_REPOS=${#REPOS[@]}
    
    print_section "Repositories to Process"
    for repo in "${REPOS[@]}"; do
        echo "  - $repo"
    done
    echo ""
    
    if [[ "$DRY_RUN" == false ]]; then
        echo -e "${YELLOW}This will add security scanning to all repositories.${NC}"
        echo -e "${YELLOW}Each repository will be processed interactively.${NC}"
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
        if deploy_to_repo "$repo"; then
            ((SUCCESS_COUNT++)) || true
        else
            local exit_code=$?
            if [[ $exit_code -eq 2 ]]; then
                ((SKIP_COUNT++)) || true
            else
                ((FAILED_COUNT++)) || true
            fi
        fi
        echo ""
    done
    
    # Summary
    print_section "Summary"
    echo -e "${BOLD}Total repositories:${NC} $TOTAL_REPOS"
    echo -e "${GREEN}${BOLD}Successfully updated:${NC} $SUCCESS_COUNT"
    echo -e "${YELLOW}${BOLD}Skipped:${NC} $SKIP_COUNT"
    echo -e "${RED}${BOLD}Failed:${NC} $FAILED_COUNT"
    echo ""
    
    if [[ $SUCCESS_COUNT -gt 0 ]]; then
        print_info "Security workflows have been deployed!"
        print_info "GitHub Actions will now scan for:"
        echo "  - Leaked secrets in git history"
        echo "  - Shell script security issues"
        echo "  - Vulnerable dependencies in PRs"
        echo "  - Weekly scheduled security scans"
    fi
    
    print_success "Deployment complete!"
}

main "$@"
