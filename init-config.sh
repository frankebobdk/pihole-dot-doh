#!/bin/sh
# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Create necessary directories if they do not exist
mkdir -p /config/redis /config/unbound

# Copy default configuration files if the target directory is empty (first run)
if [ -z "$(ls -A /config/redis)" ]; then
    echo -e "${BLUE}[INIT]${NC} Copying Redis default configuration..."
    cp -r /config_default/redis/* /config/redis/
fi

if [ -z "$(ls -A /config/unbound)" ]; then
    echo -e "${BLUE}[INIT]${NC} Copying Unbound default configuration..."
    cp -r /config_default/unbound/* /config/unbound/
fi

echo -e "${GREEN}[INIT]${NC} Configuration initialization completed"
