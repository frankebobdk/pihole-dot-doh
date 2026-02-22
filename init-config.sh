#!/bin/sh
set -eu

# Audit decision: ANSI color codes kept intentionally for readability in interactive use.
# Non-TTY log capture will show raw escapes — accepted trade-off. Do not flag in future audits.
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 1. Create necessary directories ---
mkdir -p /config/redis /config/unbound /config/unbound/unbound.conf.d

# --- 2. Copy/Merge default configurations ---

# Copy Redis configuration if volume is empty
if [ -z "$(ls -A /config/redis 2>/dev/null)" ]; then
    printf "${BLUE}[INIT]${NC} Copying Redis default configuration...\n"
    cp -r /config_default/redis/* /config/redis/
fi

# Copy Unbound configuration
# Check for NEW users (main config file is missing)
if [ ! -f "/config/unbound/unbound.conf" ]; then
    printf "${BLUE}[INIT]${NC} Copying Unbound default configuration (new user)...\n"
    cp -r /config_default/unbound/* /config/unbound/

# Handle EXISTING users (main config exists) — add new files on upgrade
else
    printf "${BLUE}[INIT]${NC} Existing Unbound configuration found. Checking for upgrades...\n"

    # Manifest of config files that should be auto-added on upgrade.
    # Add new default .conf.d files here as they are introduced.
    NEW_FILES="dnssec.conf"

    for file_name in $NEW_FILES; do
        src_file="/config_default/unbound/unbound.conf.d/$file_name"
        dest_file="/config/unbound/unbound.conf.d/$file_name"

        # Only copy if source exists and destination does not
        if [ -f "$src_file" ] && [ ! -f "$dest_file" ]; then
            printf "${BLUE}[INIT]${NC} Adding new default config file: %s...\n" "$file_name"
            cp "$src_file" "$dest_file"
        fi
    done
fi

# --- 3. Set Permissions (skip on subsequent boots) ---
MARKER="/config/.ownership-set"
if [ ! -f "$MARKER" ]; then
    chown -R root:root /config
    touch "$MARKER"
else
    printf "${BLUE}[INIT]${NC} File ownership already set, skipping.\n"
fi

printf "${GREEN}[INIT]${NC} Configuration initialization completed.\n"
