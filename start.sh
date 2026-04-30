#!/bin/sh
set -e

echo "Starting Redis Stack Server..."
REDIS_DATADIR=/var/lib/redis /opt/redis-stack/bin/redis-stack-server --daemonize no &
REDIS_PID=$!
echo "Redis PID: $REDIS_PID"

echo "Waiting for Redis to be ready..."
MAX_RETRIES=30
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
	if redis-cli ping >/dev/null 2>&1; then
		echo "Redis is ready!"
		break
	fi
	RETRY_COUNT=$((RETRY_COUNT + 1))
	echo "Attempt $RETRY_COUNT/$MAX_RETRIES: Redis not ready yet..."
	sleep 2
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
	echo "ERROR: Redis failed to start after $MAX_RETRIES attempts"
	exit 1
fi

echo "Starting Bifrost..."
exec /usr/local/bin/bifrost --host 0.0.0.0 --port 8080
