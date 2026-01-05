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

# Cursor control
CURSOR_UP='\033[A'
CURSOR_DOWN='\033[B'
CLEAR_LINE='\033[2K'

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

draw_checklist() {
    local current_index=$1
    local start_line=$2
    
    # Move cursor to start position
    tput cup $start_line 0
    
    echo -e "${BOLD}Select repositories to migrate:${NC}"
    echo -e "${DIM}Use arrow keys to navigate, SPACE to toggle, ENTER to confirm${NC}"
    echo -e "${DIM}Selected repos will be migrated, unselected will be excluded${NC}"
    echo ""
    
    for i in "${!REPO_NAMES[@]}"; do
        local name="${REPO_NAMES[$i]}"
        local vis="${REPO_VISIBILITIES[$i]}"
        local selected="${REPO_SELECTED[$i]}"
        
        # Highlight current line
        if [[ $i -eq $current_index ]]; then
            echo -ne "${BOLD}> "
        else
            echo -ne "  "
        fi
        
        # Checkbox
        if [[ $selected -eq 1 ]]; then
            echo -ne "${GREEN}[x]${NC} "
        else
            echo -ne "${RED}[ ]${NC} "
        fi
        
        # Repo name and visibility
        if [[ $i -eq $current_index ]]; then
            echo -e "${BOLD}${name}${NC} ${DIM}(${vis})${NC}${CLEAR_LINE}"
        else
            echo -e "${name} ${DIM}(${vis})${NC}${CLEAR_LINE}"
        fi
    done
    
    echo ""
    local selected_count=0
    for s in "${REPO_SELECTED[@]}"; do
        ((selected_count += s))
    done
    echo -e "${CYAN}Selected: ${selected_count}/${TOTAL_REPOS} repositories${NC}${CLEAR_LINE}"
    echo ""
    echo -e "${YELLOW}[ENTER] Confirm selection    [a] Select all    [n] Select none    [q] Quit${NC}${CLEAR_LINE}"
}

run_interactive_selection() {
    local current_index=0
    
    # Hide cursor
    tput civis
    
    # Save cursor position
    local start_line=$(tput lines)
    start_line=$((start_line - TOTAL_REPOS - 10))
    [[ $start_line -lt 0 ]] && start_line=0
    
    # Clear screen area and draw initial list
    tput cup $start_line 0
    for ((i=0; i<TOTAL_REPOS+10; i++)); do
        echo -e "${CLEAR_LINE}"
    done
    
    draw_checklist $current_index $start_line
    
    # Read input
    while true; do
        # Read single keypress
        IFS= read -rsn1 key
        
        case "$key" in
            $'\x1b')  # Escape sequence (arrow keys)
                read -rsn2 -t 0.1 key
                case "$key" in
                    '[A')  # Up arrow
                        ((current_index > 0)) && ((current_index--))
                        ;;
                    '[B')  # Down arrow
                        ((current_index < TOTAL_REPOS - 1)) && ((current_index++))
                        ;;
                esac
                ;;
            ' ')  # Space - toggle selection
                if [[ ${REPO_SELECTED[$current_index]} -eq 1 ]]; then
                    REPO_SELECTED[$current_index]=0
                else
                    REPO_SELECTED[$current_index]=1
                fi
                ;;
            'a'|'A')  # Select all
                for i in "${!REPO_SELECTED[@]}"; do
                    REPO_SELECTED[$i]=1
                done
                ;;
            'n'|'N')  # Select none
                for i in "${!REPO_SELECTED[@]}"; do
                    REPO_SELECTED[$i]=0
                done
                ;;
            'q'|'Q')  # Quit
                tput cnorm  # Show cursor
                echo ""
                echo -e "${YELLOW}Cancelled by user${NC}"
                exit 0
                ;;
            '')  # Enter - confirm
                tput cnorm  # Show cursor
                echo ""
                return 0
                ;;
        esac
        
        draw_checklist $current_index $start_line
    done
}

#############################################################################
# Main Logic
#############################################################################

# Interactive selection
if [[ "$INTERACTIVE" == true ]] && [[ $TOTAL_REPOS -gt 0 ]]; then
    echo -e "${YELLOW}Would you like to select which repositories to include?${NC}"
    echo "  1) Yes - choose interactively"
    echo "  2) No  - include all repositories"
    echo ""
    read -p "Select option [1/2]: " choice
    
    if [[ "$choice" == "1" ]]; then
        echo ""
        run_interactive_selection
        
        # Count excluded
        local excluded_count=0
        for s in "${REPO_SELECTED[@]}"; do
            [[ $s -eq 0 ]] && ((excluded_count++))
        done
        
        if [[ $excluded_count -gt 0 ]]; then
            echo ""
            echo -e "${YELLOW}Excluded ${excluded_count} repository(ies)${NC}"
        fi
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
# Local path is derived from: ${local_repo_root}/${name}
# GitLab SSH URL is derived from: git@${gitlab_host}:${gitlab_user}/${name}.git
# GitHub SSH URL is derived from: git@${github_host}:${github_user}/${name}.git
#

[repositories]
EOF

# Write selected repos
for i in "${!REPO_NAMES[@]}"; do
    if [[ ${REPO_SELECTED[$i]} -eq 1 ]]; then
        NAME="${REPO_NAMES[$i]}"
        VISIBILITY="${REPO_VISIBILITIES[$i]}"
        DESCRIPTION="${REPO_DESCRIPTIONS[$i]}"
        
        echo "  Adding: ${NAME} (${VISIBILITY})"
        echo "${NAME}|${VISIBILITY}|${DESCRIPTION}" >> "${OUTPUT_FILE}"
    else
        echo -e "  ${DIM}Excluded: ${REPO_NAMES[$i]}${NC}"
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

echo "  Total repositories: ${TOTAL}"
echo "  Public: ${PUBLIC}"
echo "  Private: ${PRIVATE}"
echo "  Internal: ${INTERNAL}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Run: ./02-migrate-repos.sh --dry-run"
echo "  2. Run: ./02-migrate-repos.sh"
