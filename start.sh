#!/bin/sh
set -e

echo "Starting Redis Stack Server..."
# ponytail: wrapper hardcodes --dir /var/lib/redis-stack (writable layer, lost on
# recreate). Passing --dir again as a trailing arg overrides it — redis-server
# later args win — so the dump lands on the redis-data volume.
/opt/redis-stack/bin/redis-stack-server --dir /var/lib/redis --daemonize no &
REDIS_PID=$!
echo "Redis PID: $REDIS_PID"

echo "Waiting for Redis to be ready..."
MAX_RETRIES=60
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
	# ponytail: don't test the exit code — redis-cli exits 0 even on server
	# errors like LOADING, which made this gate pass mid-load and crash-loop
	# bifrost once the RDB grew. Compare the reply instead: only a literal OK
	# means the server accepts writes.
	if [ "$(redis-cli SET __ready_check 1 EX 5 2>/dev/null)" = "OK" ]; then
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
