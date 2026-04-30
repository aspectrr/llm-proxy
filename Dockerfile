FROM maximhq/bifrost:latest AS bifrost
FROM redis/redis-stack-server:latest AS redis

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y ca-certificates curl libunwind8 && rm -rf /var/lib/apt/lists/*

COPY --from=bifrost /app/main /usr/local/bin/bifrost
COPY --from=redis /opt/redis-stack /opt/redis-stack
COPY --from=redis /usr/bin/redis-cli /usr/local/bin/redis-cli

RUN mkdir -p /var/lib/bifrost /var/lib/redis /root/.config/bifrost

COPY start.sh /start.sh
COPY config.json /root/.config/bifrost/config.json
RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]
