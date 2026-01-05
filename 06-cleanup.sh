#!/bin/bash

#############################################################################
# Cleanup Script
# 
# Purpose: Remove temporary directories created during migration
# Cleans: work_dir and doc_update_dir from config.ini
#
# Usage:
#   ./06-cleanup.sh [--force]
#
# Options:
#   --force     Skip confirmation prompt
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
FORCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--force]"
            exit 1
            ;;
    esac
done

# Load configuration
load_config

print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║     Migration Cleanup                                              ║"
    echo "║     Remove temporary directories                                   ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
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

get_dir_size() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        du -sh "$dir" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

count_repos() {
    local dir="$1"
    if [[ -d "$dir" ]]; then
        find "$dir" -maxdepth 1 -type d | wc -l
    else
        echo "0"
    fi
}

main() {
    print_header
    
    local dirs_to_clean=()
    local total_size=0
    
    # Check work_dir
    if [[ -d "${WORK_DIR}" ]]; then
        local size=$(get_dir_size "${WORK_DIR}")
        local count=$(($(count_repos "${WORK_DIR}") - 1))
        dirs_to_clean+=("${WORK_DIR}")
        echo -e "${BOLD}Migration work directory:${NC}"
        echo "  Path: ${WORK_DIR}"
        echo "  Size: ${size}"
        echo "  Repos: ${count}"
        echo ""
    fi
    
    # Check for log files
    if [[ -f "${LOG_FILE}" ]] || [[ -f "${REPORT_FILE}" ]]; then
        echo -e "${BOLD}Log files:${NC}"
        [[ -f "${LOG_FILE}" ]] && echo "  - ${LOG_FILE}"
        [[ -f "${REPORT_FILE}" ]] && echo "  - ${REPORT_FILE}"
        echo ""
    fi
    
    if [[ ${#dirs_to_clean[@]} -eq 0 ]]; then
        print_info "No temporary directories found to clean up"
        exit 0
    fi
    
    # Confirmation
    if [[ "$FORCE" == false ]]; then
        echo -e "${YELLOW}${BOLD}This will permanently delete the above directories.${NC}"
        echo ""
        read -p "Are you sure? (yes/no): " confirmation
        if [[ "$confirmation" != "yes" ]]; then
            print_warning "Cleanup cancelled"
            exit 0
        fi
        echo ""
    fi
    
    # Perform cleanup
    for dir in "${dirs_to_clean[@]}"; do
        print_info "Removing: $dir"
        if rm -rf "$dir"; then
            print_success "Removed: $dir"
        else
            print_error "Failed to remove: $dir"
        fi
    done
    
    # Optionally clean log files
    if [[ "$FORCE" == false ]]; then
        echo ""
        read -p "Also remove log files? (yes/no): " remove_logs
    else
        remove_logs="yes"
    fi
    
    if [[ "$remove_logs" == "yes" ]]; then
        [[ -f "${LOG_FILE}" ]] && rm -f "${LOG_FILE}" && print_success "Removed: ${LOG_FILE}"
        [[ -f "${REPORT_FILE}" ]] && rm -f "${REPORT_FILE}" && print_success "Removed: ${REPORT_FILE}"
    fi
    
    echo ""
    print_success "Cleanup complete!"
}

main "$@"
