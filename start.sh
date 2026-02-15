#!/bin/bash
set -e

# Start Tor in background (it will run as the current user - nobody)
echo "Starting Tor..."
tor -f /etc/tor/torrc &
TOR_PID=$!

# Wait for Tor to generate the onion address
for i in {1..60}; do
  if [ -f /data/tor/elektrine/hostname ]; then
    echo "Onion address: $(cat /data/tor/elektrine/hostname)"
    break
  fi
  # Check if Tor is still running
  if ! kill -0 $TOR_PID 2>/dev/null; then
    echo "Tor process exited, continuing without onion service"
    break
  fi
  echo "Waiting for Tor to initialize... ($i/60)"
  sleep 1
done

# Start Phoenix app
echo "Starting Phoenix..."
exec /app/bin/server
