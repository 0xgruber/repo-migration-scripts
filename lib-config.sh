#!/bin/bash

#############################################################################
# Config Parser Library
# 
# Provides functions to read configuration from config.ini and repos.ini
#############################################################################

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.ini"
REPOS_FILE="${SCRIPT_DIR}/repos.ini"

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE" >&2
    exit 1
fi

# Function to read a config value
# Usage: config_get section key
config_get() {
    local section="$1"
    local key="$2"
    
    # Read the config file, find the section, then find the key
    awk -F '=' -v section="$section" -v key="$key" '
        /^\[/ { 
            gsub(/[\[\]]/, "", $0)
            in_section = ($0 == section)
            next
        }
        in_section {
            # Trim leading whitespace from key
            k = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k == key) {
                # Get everything after the =
                v = $2
                for (i=3; i<=NF; i++) v = v "=" $i
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                # Remove inline comments
                sub(/[[:space:]]*#.*$/, "", v)
                print v
                exit
            }
        }
    ' "$CONFIG_FILE"
}

# Function to read multi-line config value (like repos list)
# Usage: config_get_array section key
config_get_array() {
    local section="$1"
    local key="$2"
    
    awk -F '=' -v section="$section" -v key="$key" '
        /^\[/ { 
            gsub(/[\[\]]/, "", $0)
            in_section = ($0 == section)
            in_value = 0
            next
        }
        in_section {
            # Check if this is the key we want
            k = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            if (k == key) {
                in_value = 1
                # Check if there is a value on the same line
                if (NF >= 2) {
                    v = $2
                    for (i=3; i<=NF; i++) v = v "=" $i
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                    sub(/[[:space:]]*#.*$/, "", v)
                    if (length(v) > 0) print v
                }
                next
            }
            # If we hit another key, stop collecting values
            if (in_value && /^[[:alnum:]]/) {
                in_value = 0
            }
            # Collect continuation lines (indented)
            if (in_value && /^[[:space:]]+/) {
                line = $0
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                sub(/[[:space:]]*#.*$/, "", line)
                if (length(line) > 0) print line
            }
        }
    ' "$CONFIG_FILE"
}

# Load configuration into variables
load_config() {
    # Source
    GITLAB_HOST=$(config_get "source" "host")
    GITLAB_USER=$(config_get "source" "user")
    GITLAB_TOKEN=$(config_get "source" "api_token")
    
    # Destination
    GITHUB_HOST=$(config_get "destination" "host")
    GITHUB_USER=$(config_get "destination" "user")
    
    # Paths
    WORK_DIR=$(config_get "paths" "work_dir")
    DOC_UPDATE_DIR=$(config_get "paths" "doc_update_dir")
    LOCAL_REPO_ROOT=$(config_get "paths" "local_repo_root")
    
    # Options
    MIN_DISK_SPACE_MB=$(config_get "options" "min_disk_space_mb")
    SSH_TIMEOUT=$(config_get "options" "ssh_timeout")
    VERBOSE=$(config_get "options" "verbose")
    
    # Derived paths
    LOG_FILE="${WORK_DIR}/migration.log"
    REPORT_FILE="${WORK_DIR}/MIGRATION-REPORT.md"
    
    # Export for use in scripts
    export GITLAB_HOST GITLAB_USER GITLAB_TOKEN
    export GITHUB_HOST GITHUB_USER
    export WORK_DIR DOC_UPDATE_DIR LOCAL_REPO_ROOT LOG_FILE REPORT_FILE
    export MIN_DISK_SPACE_MB SSH_TIMEOUT VERBOSE
}

# Function to validate configuration
validate_config() {
    local errors=0
    
    if [[ -z "$GITLAB_HOST" ]]; then
        echo "ERROR: source.host not configured" >&2
        errors=1
    fi
    
    if [[ -z "$GITLAB_USER" ]]; then
        echo "ERROR: source.user not configured" >&2
        errors=1
    fi
    
    if [[ -z "$GITHUB_HOST" ]]; then
        echo "ERROR: destination.host not configured" >&2
        errors=1
    fi
    
    if [[ -z "$GITHUB_USER" ]]; then
        echo "ERROR: destination.user not configured" >&2
        errors=1
    fi
    
    if [[ -z "$WORK_DIR" ]]; then
        echo "ERROR: paths.work_dir not configured" >&2
        errors=1
    fi
    
    return $errors
}

# Function to load repository list from repos.ini
# Returns: name|visibility|description|gitlab_ssh_url
load_repositories() {
    if [[ ! -f "$REPOS_FILE" ]]; then
        echo "ERROR: repos.ini not found. Run ./generate-repos.sh first" >&2
        return 1
    fi
    
    local repos_array=()
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^\[ ]] && continue
        
        # Parse: name|visibility|description
        IFS='|' read -r name visibility description <<< "$line"
        
        # Skip if name is empty
        [[ -z "$name" ]] && continue
        
        # Derive SSH URLs from config settings
        local gitlab_ssh="git@${GITLAB_HOST}:${GITLAB_USER}/${name}.git"
        
        # Output format: name|visibility|description|gitlab_ssh_url
        repos_array+=("${name}|${visibility}|${description}|${gitlab_ssh}")
    done < "$REPOS_FILE"
    
    printf '%s\n' "${repos_array[@]}"
}

# Function to load local repositories list
# Returns: name|path (path derived from local_repo_root unless custom path specified)
load_local_repositories() {
    local repos_array=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        
        # Check if line has custom path: name|/custom/path
        if [[ "$line" == *"|"* ]]; then
            # Custom path specified
            IFS='|' read -r name custom_path <<< "$line"
            repos_array+=("${name}|${custom_path}")
        else
            # Use default path from local_repo_root
            local name="$line"
            local default_path="${LOCAL_REPO_ROOT}/${name}"
            repos_array+=("${name}|${default_path}")
        fi
    done < <(config_get_array "local_repos" "repos")
    
    printf '%s\n' "${repos_array[@]}"
}

# Helper function to get GitLab SSH URL for a repo name
get_gitlab_ssh_url() {
    local name="$1"
    echo "git@${GITLAB_HOST}:${GITLAB_USER}/${name}.git"
}

# Helper function to get GitHub SSH URL for a repo name
get_github_ssh_url() {
    local name="$1"
    echo "git@${GITHUB_HOST}:${GITHUB_USER}/${name}.git"
}

# Helper function to get local path for a repo name
get_local_repo_path() {
    local name="$1"
    echo "${LOCAL_REPO_ROOT}/${name}"
}
