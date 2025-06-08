#!/bin/bash
set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Constants
CONF_FILE="serv1.yml"
SERVICE_NAME="serv1"
CONFIG_DIR="./data/custom"
DOMAINS_CSV="domains.csv"  # Input CSV file with domains

# Ensure the directory exists
if [[ ! -d "$CONFIG_DIR" ]]; then
  echo "Directory $CONFIG_DIR does not exist. Creating it..."
  mkdir -p "$CONFIG_DIR"
fi

# Check if the CSV file exists
if [[ ! -f "$DOMAINS_CSV" ]]; then
  echo "Error: CSV file $DOMAINS_CSV does not exist."
  exit 1
fi

# Clear the old configuration file
> "$CONFIG_DIR/$CONF_FILE"

# Template for the configuration header
cat > "$CONFIG_DIR/$CONF_FILE" <<EOF
http:
  routers:
EOF

# Function to generate a single router configuration
generate_router_config() {
  local ROUTER_NAME="$1"
  local DOMAIN_RULE="$2"

  cat >> "$CONFIG_DIR/$CONF_FILE" <<EOF

    $ROUTER_NAME:
      entryPoints:
        - https
      service: $SERVICE_NAME
      rule: Host($DOMAIN_RULE)
      middlewares:
        - changeHeaders
      tls:
        certResolver: letsEncrypt
EOF
}

# Read domains from the CSV file and generate configurations
while IFS=',' read -ra DOMAINS; do
  # Skip empty lines
  if [[ ${#DOMAINS[@]} -eq 0 ]]; then
    continue
  fi

  # The first domain is used as the router name
  ROUTER_NAME="${DOMAINS[0]}"

  # Build the domain rule string
  DOMAIN_RULE=""
  for ((i = 0; i < ${#DOMAINS[@]}; i++)); do
    if [[ $i -gt 0 ]]; then
      DOMAIN_RULE+=", "
    fi
    DOMAIN_RULE+="\"${DOMAINS[$i]}\""
  done

  printf "Generating configuration for router: %s\n" "$ROUTER_NAME"

  # Call the function to generate the router configuration
  generate_router_config "$ROUTER_NAME" "$DOMAIN_RULE"
done < "$DOMAINS_CSV"

echo "Configuration file generated successfully at $CONFIG_DIR/$CONF_FILE"
