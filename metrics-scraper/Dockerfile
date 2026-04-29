FROM ghcr.io/astral-sh/uv:latest AS uv
FROM python:3.12-slim

COPY --from=uv /uv /usr/local/bin/uv

ENV PYTHONUNBUFFERED=1

WORKDIR /app
COPY pyproject.toml uv.lock .
COPY scraper.py .

RUN uv sync --no-dev --frozen

CMD ["uv", "run", "scraper.py"]
