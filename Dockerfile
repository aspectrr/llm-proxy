FROM maximhq/bifrost:latest AS bifrost
FROM qdrant/qdrant:latest AS qdrant

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y ca-certificates curl libunwind8 && rm -rf /var/lib/apt/lists/*

COPY --from=bifrost /app/main /usr/local/bin/bifrost
COPY --from=qdrant /qdrant/qdrant /usr/local/bin/qdrant

RUN mkdir -p /var/lib/bifrost /var/lib/qdrant /root/.config/bifrost

COPY start.sh /start.sh
COPY config.json /root/.config/bifrost/config.json
RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]
