#!/bin/bash
set -euo pipefail

# Configuration
readonly TARGET_DIRS=("/opt/docker" "/opt/scripts")
readonly GROUP="admin"
readonly USERS=("user1" "user2" "user3")

# Process each target directory
for TARGET_DIR in "${TARGET_DIRS[@]}"; do
    # Skip if directory doesn't exist
    if [[ ! -d "$TARGET_DIR" ]]; then
        printf "Warning: Directory %s does not exist, skipping...\n" "$TARGET_DIR" >&2
        continue
    fi

    # Group Ownership Changes
    for user in "${USERS[@]}"; do
        # Use find with -exec instead of xargs to handle empty results
        sudo find "$TARGET_DIR" \( -user "$user" \) -exec chgrp -h "$GROUP" {} +
    done

    # Permission Settings
    sudo chmod -R g+rwX "$TARGET_DIR"

    # Setgid for directories
    sudo find "$TARGET_DIR" -type d -exec chmod g+s {} +

    # Output results for this directory
    printf "\nSuccessfully updated permissions in %s:\n" "$TARGET_DIR"
    printf " - Changed group ownership to %s\n" "$GROUP"
    printf " - Set recursive rwX permissions for group\n"
    printf " - Enabled setgid bit for directories\n"
done
