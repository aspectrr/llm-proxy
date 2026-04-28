#!/bin/sh
set -e

echo "Starting Qdrant..."
QDRANT_STORAGE=/var/lib/tailscale/qdrant /usr/local/bin/qdrant &
QDRANT_PID=$!
echo "Qdrant PID: $QDRANT_PID"

echo "Waiting for Qdrant to be ready..."
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if curl -s http://localhost:6333/ > /dev/null 2>&1; then
    echo "Qdrant is ready!"
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  echo "Attempt $RETRY_COUNT/$MAX_RETRIES: Qdrant not ready yet..."
  sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  echo "ERROR: Qdrant failed to start after $MAX_RETRIES attempts"
  exit 1
fi

echo "Starting Tailscale..."
/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
TAILSCALE_PID=$!
echo "Tailscaled PID: $TAILSCALE_PID"
sleep 2

if [ -n "$TAILSCALE_AUTHKEY" ]; then
  echo "Joining Tailnet..."
  /usr/local/bin/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=fly-bifrost || echo "Warning: Tailscale join failed, continuing..."
else
  echo "No TAILSCALE_AUTHKEY provided, skipping Tailscale setup"
fi

echo "Starting Bifrost..."
exec /usr/local/bin/bifrost --host 0.0.0.0 --port 8080
