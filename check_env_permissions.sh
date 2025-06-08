#!/bin/bash
set -euo pipefail

# Define the root directory to search for .env files
ROOT_DIR="/opt"

# ANSI color codes (only enable colors if stdout is a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'
else
    RED='' GREEN='' NC=''
fi

echo "Checking .env files in ${ROOT_DIR} for permissions 660: Owner (user) and group can read and modify."

# Find all .env files in the specified directory and check their permissions
sudo find "${ROOT_DIR}" -type f -name "*.env" | while read -r file; do
    # Get the numeric permissions of the file
    perms=$(stat -c "%a" "$file")

    # Check if the permissions are not 660
    if [[ "$perms" != "660" ]]; then
        echo -e "${RED}ERROR:${NC} Incorrect permissions ($perms) for file: $file"
    else
        echo -e "${GREEN}OK:${NC} $file"
    fi
done
