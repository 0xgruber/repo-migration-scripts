#!/bin/bash

#############################################################################
# Generate repos.ini from GitLab API
# 
# Purpose: Query GitLab API for all repositories and generate repos.ini
# Usage:   ./generate-repos.sh [--output FILE]
#
# Options:
#   --output FILE     Output file (default: repos.ini)
#   --include-forks   Include forked repositories
#   --archived        Include archived repositories
#   --no-interactive  Skip interactive selection
#
#############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config for GitLab credentials
source "${SCRIPT_DIR}/lib-config.sh"
load_config

# Defaults
OUTPUT_FILE="${SCRIPT_DIR}/repos.ini"
INCLUDE_FORKS=false
INCLUDE_ARCHIVED=false
INTERACTIVE=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --include-forks)
            INCLUDE_FORKS=true
            shift
            ;;
        --archived)
            INCLUDE_ARCHIVED=true
            shift
            ;;
        --no-interactive)
            INTERACTIVE=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--output FILE] [--include-forks] [--archived] [--no-interactive]"
            echo ""
            echo "Options:"
            echo "  --output FILE     Output file (default: repos.ini)"
            echo "  --include-forks   Include forked repositories"
            echo "  --archived        Include archived repositories"
            echo "  --no-interactive  Skip interactive repo selection"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Whiptail dark theme
export NEWT_COLORS='
root=white,black
window=white,black
border=white,black
shadow=white,black
title=white,black
button=black,gray
actbutton=black,white
checkbox=white,black
actcheckbox=black,gray
listbox=white,black
actlistbox=black,gray
textbox=white,black
entry=white,black
label=white,black
'

echo -e "${CYAN}Generating repos.ini from GitLab API${NC}"
echo -e "GitLab Host: ${GITLAB_HOST}"
echo -e "GitLab User: ${GITLAB_USER}"
echo ""

# Check for required tools
if ! command -v curl &> /dev/null; then
    echo "ERROR: curl is required but not installed"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required but not installed"
    exit 1
fi

# Check for API token
if [[ -z "${GITLAB_TOKEN:-}" ]]; then
    echo "ERROR: GitLab API token not configured in config.ini"
    echo "Add api_token under [source] section"
    exit 1
fi

# Build GitLab API URL
API_URL="https://${GITLAB_HOST}/api/v4/users/${GITLAB_USER}/projects"
API_PARAMS="?per_page=100&owned=true"

if [[ "$INCLUDE_ARCHIVED" == false ]]; then
    API_PARAMS="${API_PARAMS}&archived=false"
fi

echo -e "${BLUE}Querying GitLab API...${NC}"

# Query GitLab API
RESPONSE=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${API_URL}${API_PARAMS}")

# Check for API errors
if echo "$RESPONSE" | jq -e '.error' &>/dev/null; then
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error // .message // "Unknown error"')
    echo "ERROR: GitLab API error: $ERROR_MSG"
    exit 1
fi

# Count repos
REPO_COUNT=$(echo "$RESPONSE" | jq 'length')
echo -e "${GREEN}Found ${REPO_COUNT} repositories${NC}"
echo ""

# Parse repos into arrays
declare -a REPO_NAMES=()
declare -a REPO_VISIBILITIES=()
declare -a REPO_DESCRIPTIONS=()
declare -a REPO_SELECTED=()

while IFS= read -r repo; do
    NAME=$(echo "$repo" | jq -r '.path')
    VISIBILITY=$(echo "$repo" | jq -r '.visibility')
    DESCRIPTION=$(echo "$repo" | jq -r '.description // ""' | tr '|' '-' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    FORKED=$(echo "$repo" | jq -r '.forked_from_project // empty')
    
    # Skip forks if not requested
    if [[ -n "$FORKED" ]] && [[ "$INCLUDE_FORKS" == false ]]; then
        echo -e "  ${YELLOW}Skipping fork: ${NAME}${NC}"
        continue
    fi
    
    REPO_NAMES+=("$NAME")
    REPO_VISIBILITIES+=("$VISIBILITY")
    REPO_DESCRIPTIONS+=("$DESCRIPTION")
    REPO_SELECTED+=(1)  # 1 = selected (include), 0 = excluded
done < <(echo "$RESPONSE" | jq -c '.[]')

TOTAL_REPOS=${#REPO_NAMES[@]}

#############################################################################
# Interactive Selection Functions
#############################################################################

run_interactive_selection() {
    # Build whiptail checklist arguments
    local -a checklist_args=()
    
    for i in "${!REPO_NAMES[@]}"; do
        local name="${REPO_NAMES[$i]}"
        local vis="${REPO_VISIBILITIES[$i]}"
        # whiptail format: tag item status
        checklist_args+=("$name" "($vis)" "ON")
    done
    
    # Calculate dimensions
    local height=$((TOTAL_REPOS + 10))
    [[ $height -gt 25 ]] && height=25
    local width=60
    local list_height=$((height - 8))
    
    # Run whiptail and capture selected repos
    local selected
    selected=$(whiptail --title "Select Repositories to Migrate" \
        --checklist "Use SPACE to toggle, ENTER to confirm.\nSelected repos will be migrated:" \
        $height $width $list_height \
        "${checklist_args[@]}" \
        3>&1 1>&2 2>&3) || {
        echo -e "${YELLOW}Cancelled by user${NC}"
        exit 0
    }
    
    # Parse selected repos and update REPO_SELECTED array
    # whiptail returns quoted space-separated list: "repo1" "repo2" "repo3"
    for i in "${!REPO_NAMES[@]}"; do
        local name="${REPO_NAMES[$i]}"
        if echo "$selected" | grep -q "\"$name\""; then
            REPO_SELECTED[$i]=1
        else
            REPO_SELECTED[$i]=0
        fi
    done
}

#############################################################################
# Main Logic
#############################################################################

# Interactive selection
if [[ "$INTERACTIVE" == true ]] && [[ $TOTAL_REPOS -gt 0 ]]; then
    # Check if whiptail is available
    if command -v whiptail &>/dev/null; then
        run_interactive_selection
        
        # Count excluded
        excluded_count=0
        for s in "${REPO_SELECTED[@]}"; do
            [[ $s -eq 0 ]] && ((excluded_count++)) || true
        done
        
        if [[ $excluded_count -gt 0 ]]; then
            echo -e "${YELLOW}Excluded ${excluded_count} repository(ies)${NC}"
        fi
    else
        echo -e "${YELLOW}whiptail not found - including all repositories${NC}"
        echo -e "${DIM}Install whiptail for interactive selection: sudo apt install whiptail${NC}"
    fi
    echo ""
fi

# Generate repos.ini
echo -e "${BLUE}Generating ${OUTPUT_FILE}...${NC}"

cat > "${OUTPUT_FILE}" << 'EOF'
# Repository List Configuration
# Generated by generate-repos.sh
# 
# Format: name|visibility|description
# - name: Repository slug (used for both local path and remote URL)
# - visibility: public, private, or internal
# - description: Repository description (optional)
#
# Lines starting with "# EXCLUDED:" were deselected during generation
# To include an excluded repo, remove "# EXCLUDED: " prefix
#
# Local path is derived from: ${local_repo_root}/${name}
# GitLab SSH URL is derived from: git@${gitlab_host}:${gitlab_user}/${name}.git
# GitHub SSH URL is derived from: git@${github_host}:${github_user}/${name}.git
#

[repositories]
EOF

# Write selected repos
for i in "${!REPO_NAMES[@]}"; do
    NAME="${REPO_NAMES[$i]}"
    VISIBILITY="${REPO_VISIBILITIES[$i]}"
    DESCRIPTION="${REPO_DESCRIPTIONS[$i]}"
    
    if [[ ${REPO_SELECTED[$i]} -eq 1 ]]; then
        echo "  Adding: ${NAME} (${VISIBILITY})"
        echo "${NAME}|${VISIBILITY}|${DESCRIPTION}" >> "${OUTPUT_FILE}"
    else
        echo -e "  ${DIM}Excluded: ${NAME}${NC}"
        echo "# EXCLUDED: ${NAME}|${VISIBILITY}|${DESCRIPTION}" >> "${OUTPUT_FILE}"
    fi
done

echo ""
echo -e "${GREEN}Generated: ${OUTPUT_FILE}${NC}"
echo ""

# Show summary
echo -e "${CYAN}Summary:${NC}"
TOTAL=$(grep -c '^[^#\[]' "${OUTPUT_FILE}" 2>/dev/null || echo "0")
PUBLIC=$(grep '|public|' "${OUTPUT_FILE}" | wc -l || echo "0")
PRIVATE=$(grep '|private|' "${OUTPUT_FILE}" | wc -l || echo "0")
INTERNAL=$(grep '|internal|' "${OUTPUT_FILE}" | wc -l || echo "0")
EXCLUDED=$((TOTAL_REPOS - TOTAL))

echo "  Total repositories: ${TOTAL}"
echo "  Public: ${PUBLIC}"
echo "  Private: ${PRIVATE}"
echo "  Internal: ${INTERNAL}"
[[ $EXCLUDED -gt 0 ]] && echo -e "  ${DIM}Excluded: ${EXCLUDED}${NC}"
echo ""

# Prompt to run next script
echo -e "${BLUE}Next step: ./02-migrate-repos.sh${NC}"
read -p "Run migration script now? [y/N]: " run_next
if [[ "${run_next,,}" == "y" ]]; then
    exec "${SCRIPT_DIR}/02-migrate-repos.sh"
fi
