#!/bin/bash
set -euo pipefail

# Configuration
readonly VERSION="1.1.0"
readonly CONF_FILE="serv1.yml"
readonly SERVICE_NAME="serv1"
readonly CONFIG_DIR="./data/custom"
readonly BACKUP_DIR="$CONFIG_DIR/bak"
readonly DOMAINS_CSV="domains.csv"
readonly LOCK_FILE="/tmp/traefik_config.lock"
declare -A existing_domains

# Functions
show_help() {
    echo "Usage: $0 [options]"
    echo "Generate Traefik configuration from CSV by github.com/haeniken"
    echo "Options:"
    echo "  -v, --version  Show version"
    echo "  -h, --help     Show this help"
}

validate_domain() {
    local domain="${1%%[[:space:]]*}"
    [[ "$domain" =~ ^# ]] || [[ -z "$domain" ]] && return 1

    # Domain validation regex (allows standard domains and IDN/Punycode)
    if [[ ! "$domain" =~ ^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])\.)+([A-Za-z]{2,}|xn--[A-Za-z0-9]+)$ ]]; then
        echo "Warning: Invalid domain format: $domain" >&2
        return 1
    fi
    return 0
}

create_backup() {
    local timestamp=$(date +%Y%m%d%H%M%S)
    local backup_file="$BACKUP_DIR/${CONF_FILE}.${timestamp}.bak"

    # Only create backup if config file exists
    if [ -f "$CONFIG_DIR/$CONF_FILE" ]; then
        if cp "$CONFIG_DIR/$CONF_FILE" "$backup_file"; then
            echo "Backup successfully created:"
            echo "  Location:    $backup_file"
            echo "  Backup time: $(date)"
            echo "  Original:    $CONFIG_DIR/$CONF_FILE"
            return 0
        else
            echo "Error: Failed to create backup" >&2
            return 1
        fi
    else
        echo "Notice: No existing config file found to backup ($CONFIG_DIR/$CONF_FILE)"
        return 0
    fi
}

generate_config() {
    echo "$(date) - Starting configuration generation"

    # Create backup with verbose output
    echo "Creating backup of current configuration..."
    if ! create_backup; then
        echo "Warning: Continuing without backup" >&2
    fi

    # Generate new config file
    cat > "$CONFIG_DIR/$CONF_FILE" <<EOF
# Auto-generated Traefik configuration
# Generated at: $(date)
# Version: $VERSION

http:
  routers:
EOF

    # Process each line in CSV file
    while IFS=',' read -ra domains || [[ -n "${domains[*]}" ]]; do
        # Skip empty lines and comments
        [[ ${#domains[@]} -eq 0 ]] && continue
        [[ "${domains[0]}" =~ ^# ]] && continue

        local router_name="${domains[0]%%[[:space:]]*}"
        local domain_rule="" valid_domains=()

        # Validate and collect domains
        for domain in "${domains[@]}"; do
            domain="${domain%%[[:space:]]*}"
            validate_domain "$domain" || continue

            # Check for duplicate domains
            if [[ -v existing_domains["$domain"] ]]; then
                echo "Warning: Duplicate domain '$domain' in $router_name" >&2
                continue 2
            fi

            existing_domains["$domain"]=1
            valid_domains+=("$domain")
        done

        [[ ${#valid_domains[@]} -eq 0 ]] && continue

        # Build domain rule string
        for ((i = 0; i < ${#valid_domains[@]}; i++)); do
            [[ $i -gt 0 ]] && domain_rule+=", "
            domain_rule+="\"${valid_domains[$i]}\""
        done

        echo "Processing: $router_name (domains: ${valid_domains[*]})"

        # Append router configuration
        cat >> "$CONFIG_DIR/$CONF_FILE" <<EOF
    $router_name:
      entryPoints:
        - https
      service: $SERVICE_NAME
      rule: Host($domain_rule)
      middlewares:
        - changeHeaders
      tls:
        certResolver: letsEncrypt
EOF
    done < "$DOMAINS_CSV"

    echo "$(date) - Configuration successfully generated: $CONFIG_DIR/$CONF_FILE"
    echo "Total domains processed: ${#existing_domains[@]}"
}

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -v|--version) echo "$0 version $VERSION"; exit 0 ;;
            *) echo "Invalid option: $1" >&2; exit 1 ;;
        esac
    done

    # Check required commands are available
    local deps=("bash" "mkdir" "touch" "cp" "date")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null; then
            echo "Error: Required command '$dep' not found" >&2
            exit 1
        fi
    done

    # Validate environment and setup directories
    [[ -f "$DOMAINS_CSV" ]] || { echo "Error: Missing $DOMAINS_CSV" >&2; exit 1; }
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" || { 
        echo "Error: Cannot create required directories" >&2
        exit 1
    }
    [ -w "$CONFIG_DIR" ] && [ -w "$BACKUP_DIR" ] || {
        echo "Error: Missing write permissions for config or backup directories" >&2
        exit 1
    }

    # Prevent concurrent execution using file lock
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        echo "Error: Script is already running (PID $(cat "$LOCK_FILE" 2>/dev/null))" >&2
        exit 1
    fi
    echo $$ > "$LOCK_FILE"

    # Generate configuration
    generate_config

    # Cleanup lock file
    flock -u 9
    exec 9>&-
    rm -f "$LOCK_FILE"
}

main "$@"
