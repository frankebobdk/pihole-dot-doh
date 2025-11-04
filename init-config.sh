#!/bin/sh
set -e

echo "Initializing configuration..."

# Copy default configs if they don't exist
if [ ! -f /config/redis/redis.conf ]; then
    echo "Creating Redis config..."
    cp -r /config_default/redis /config/
fi

if [ ! -f /config/unbound/unbound.conf ]; then
    echo "Creating Unbound config..."
    cp -r /config_default/unbound /config/
fi

echo "Configuration initialized successfully"
