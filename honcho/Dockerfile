# Stage 1: Build Honcho Python application
# Uses Docker Hub Python image (independent of HA base)
ARG HONCHO_VERSION=v3.0.7

FROM python:3.13-slim-bookworm AS honcho-builder

ARG HONCHO_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

RUN git clone --depth 1 --branch "${HONCHO_VERSION}" \
    https://github.com/plastic-labs/honcho.git /build

WORKDIR /build

# Force uv to use the system Python 3.13 (Honcho's .python-version says 3.11,
# but we want 3.13 to match the runtime stage)
# Two-step sync matching upstream Dockerfile pattern
RUN rm -f .python-version \
    && uv sync --frozen --no-install-project --no-group dev --python 3.13 \
    && uv sync --frozen --no-group dev --python 3.13

# Stage 2: Runtime container
# Must use trixie for python3.13, postgresql-17, postgresql-17-pgvector.
# Pin the dated base tag (not the floating `trixie` codename) for reproducible
# builds; bump deliberately. Ships S6-overlay v3 (so config.yaml sets init: false).
FROM ghcr.io/home-assistant/base-debian:trixie-2026.05.0

# Install runtime dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        python3.13 \
        python3.13-venv \
        postgresql-17 \
        postgresql-17-pgvector \
        redis-server \
    && rm -rf /var/lib/apt/lists/*

# Copy built application from stage 1
COPY --from=honcho-builder /build /app

# Fix venv Python symlinks: builder has Python at /usr/local/bin/python3.13,
# runtime stage has it at /usr/bin/python3.13
RUN ln -sf /usr/bin/python3.13 /app/.venv/bin/python \
    && ln -sf python /app/.venv/bin/python3 \
    && ln -sf python /app/.venv/bin/python3.13

# Remove psycopg-binary: its bundled libpq returns bytes for text fields due to
# ABI mismatch between builder and runtime Python. Force psycopg to use the
# system libpq (installed with postgresql-17) via ctypes.
RUN /app/.venv/bin/pip uninstall -y psycopg-binary 2>/dev/null || true \
    && rm -rf /app/.venv/lib/python3.13/site-packages/psycopg_binary* \
    && rm -rf /app/.venv/lib/python3.13/site-packages/psycopg_binary.libs

ENV PSYCOPG_IMPL=python

# Create persistent data directories
RUN mkdir -p /data/postgresql /data/redis

# Copy S6 service definitions and rootfs
COPY rootfs /

# Ensure python3 is available in PATH (trixie only has python3.13)
RUN ln -sf /usr/bin/python3.13 /usr/bin/python3

# Ensure all S6 scripts are executable (Windows builds lose execute bits)
RUN chmod +x /etc/s6-overlay/scripts/*.sh \
    && find /etc/s6-overlay/s6-rc.d -name "run" -o -name "finish" -o -name "up" | xargs chmod +x
