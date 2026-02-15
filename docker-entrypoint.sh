#!/bin/bash
set -e

# Create and fix ownership of data directories (volume mount may have wrong perms)
mkdir -p /data/tor/elektrine /data/tor/data /data/certs 2>/dev/null || true
chown -R nobody:nogroup /data 2>/dev/null || true
chmod 700 /data/tor/elektrine 2>/dev/null || true

# Drop to nobody and run the start script
exec su -s /bin/bash nobody -c "/app/start.sh"
