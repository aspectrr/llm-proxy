#!/bin/sh
set -e

echo "Starting Qdrant..."
QDRANT_STORAGE=/var/lib/qdrant /usr/local/bin/qdrant &
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

echo "Starting Bifrost..."
exec /usr/local/bin/bifrost --host 0.0.0.0 --port 8080
