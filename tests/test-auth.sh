#!/usr/bin/env bash
# ==============================================================================
# Integration test for Honcho HA add-on auth flows.
#
# Builds the Docker image, then uses a custom entrypoint that bypasses
# S6-overlay/bashio (which require the HA Supervisor) and starts PostgreSQL,
# Redis, and the Honcho API directly.
#
# Tests:
#   1. No-auth flow: API accepts requests without credentials
#   2. Auth flow: API rejects without token, accepts with admin JWT
#
# Usage: bash tests/test-auth.sh
# Requires: docker, python3 with PyJWT (pip install PyJWT)
# ==============================================================================

set -euo pipefail

IMAGE_NAME="honcho-ha-test"
CONTAINER_NAME="honcho-ha-test-$$"
HONCHO_PORT=8000
PASS=0
FAIL=0

# ---------- helpers ----------------------------------------------------------

cleanup() {
    echo ""
    echo "--- Cleaning up ---"
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
}
trap cleanup EXIT

log_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

wait_for_health() {
    local url="http://localhost:${HONCHO_PORT}/health"
    local max_wait=90
    local waited=0
    echo "Waiting for Honcho API to be healthy (up to ${max_wait}s)..."
    while [ $waited -lt $max_wait ]; do
        if curl -sf "${url}" >/dev/null 2>&1; then
            echo "API is healthy after ${waited}s."
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    echo "ERROR: API did not become healthy within ${max_wait}s."
    echo "--- Container logs ---"
    docker logs "${CONTAINER_NAME}" 2>&1 | tail -80
    return 1
}

http_status() {
    # Return just the HTTP status code for a request.
    # Do NOT use -f: curl must exit 0 on 4xx/5xx so we capture the code.
    local method="$1"; shift
    local url="$1"; shift
    curl -s -o /dev/null -w "%{http_code}" -X "${method}" "$@" "${url}" 2>/dev/null || echo "000"
}

# Entrypoint that bypasses S6/bashio (which require HA Supervisor) and starts
# PostgreSQL, Redis, runs migrations, then launches the Honcho API directly.
# Auth-related env vars (AUTH_USE_AUTH, AUTH_JWT_SECRET) are passed via docker -e.
ENTRYPOINT_SCRIPT='
set -e
PG_BIN=/usr/lib/postgresql/17/bin
PGDATA=/data/postgresql
mkdir -p /run/postgresql "${PGDATA}" /data/redis
chown -R postgres:postgres /run/postgresql "${PGDATA}"
if [ ! -f "${PGDATA}/PG_VERSION" ]; then
    su - postgres -c "${PG_BIN}/initdb -D ${PGDATA} --encoding=UTF8 --locale=C.UTF-8" 2>&1
    cat > "${PGDATA}/pg_hba.conf" <<PGEOF
local   all   all              trust
host    all   all   127.0.0.1/32 trust
host    all   all   ::1/128      trust
PGEOF
    chown postgres:postgres "${PGDATA}/pg_hba.conf"
fi
su - postgres -c "${PG_BIN}/pg_ctl start -D ${PGDATA} -l /tmp/pg.log" 2>&1
for i in $(seq 1 30); do
    if su - postgres -c "${PG_BIN}/pg_isready -q" 2>/dev/null; then break; fi
    sleep 1
done
su - postgres -c "${PG_BIN}/psql -tc \"SELECT 1 FROM pg_database WHERE datname='"'"'honcho'"'"'\" | grep -q 1" \
    || su - postgres -c "${PG_BIN}/createdb honcho"
su - postgres -c "${PG_BIN}/psql -d honcho -c \"CREATE EXTENSION IF NOT EXISTS vector;\""
redis-server --daemonize yes --dir /data/redis --appendonly yes --bind 127.0.0.1 --protected-mode yes 2>&1
cd /app
export DB_CONNECTION_URI="postgresql+psycopg://postgres@localhost:5432/honcho"
export CACHE_URL="redis://127.0.0.1:6379/0"
export CACHE_ENABLED=true
export PSYCOPG_IMPL=python
/app/.venv/bin/python scripts/provision_db.py 2>&1
echo "Starting Honcho API (AUTH_USE_AUTH=${AUTH_USE_AUTH:-false})..."
exec /app/.venv/bin/python -m uvicorn src.main:app --host 0.0.0.0 --port 8000 --app-dir /app
'

# Dummy LLM provider env vars (Honcho v3.0.7 scheme). No real LLM calls are made
# during auth testing; transport=openai + a fake LLM_OPENAI_API_KEY is enough for
# the server to start. Deriver and Dream are disabled.
LLM_ENV=(
    -e DERIVER_ENABLED=false
    -e DREAM_ENABLED=false
    -e LLM_OPENAI_API_KEY=test
    -e DERIVER_MODEL_CONFIG__TRANSPORT=openai -e DERIVER_MODEL_CONFIG__MODEL=test
    -e SUMMARY_MODEL_CONFIG__TRANSPORT=openai -e SUMMARY_MODEL_CONFIG__MODEL=test
    -e DREAM_DEDUCTION_MODEL_CONFIG__TRANSPORT=openai -e DREAM_DEDUCTION_MODEL_CONFIG__MODEL=test
    -e DREAM_INDUCTION_MODEL_CONFIG__TRANSPORT=openai -e DREAM_INDUCTION_MODEL_CONFIG__MODEL=test
    -e DIALECTIC_LEVELS__minimal__MODEL_CONFIG__TRANSPORT=openai -e DIALECTIC_LEVELS__minimal__MODEL_CONFIG__MODEL=test
    -e DIALECTIC_LEVELS__minimal__MODEL_CONFIG__THINKING_BUDGET_TOKENS=0
    -e DIALECTIC_LEVELS__minimal__MAX_TOOL_ITERATIONS=1 -e DIALECTIC_LEVELS__minimal__MAX_OUTPUT_TOKENS=250
    -e DIALECTIC_LEVELS__minimal__TOOL_CHOICE=any
    -e DIALECTIC_LEVELS__low__MODEL_CONFIG__TRANSPORT=openai -e DIALECTIC_LEVELS__low__MODEL_CONFIG__MODEL=test
    -e DIALECTIC_LEVELS__low__MODEL_CONFIG__THINKING_BUDGET_TOKENS=0
    -e DIALECTIC_LEVELS__low__MAX_TOOL_ITERATIONS=5 -e DIALECTIC_LEVELS__low__TOOL_CHOICE=any
    -e DIALECTIC_LEVELS__medium__MODEL_CONFIG__TRANSPORT=openai -e DIALECTIC_LEVELS__medium__MODEL_CONFIG__MODEL=test
    -e DIALECTIC_LEVELS__medium__MODEL_CONFIG__THINKING_BUDGET_TOKENS=1024
    -e DIALECTIC_LEVELS__medium__MAX_TOOL_ITERATIONS=2
    -e DIALECTIC_LEVELS__high__MODEL_CONFIG__TRANSPORT=openai -e DIALECTIC_LEVELS__high__MODEL_CONFIG__MODEL=test
    -e DIALECTIC_LEVELS__high__MODEL_CONFIG__THINKING_BUDGET_TOKENS=1024
    -e DIALECTIC_LEVELS__high__MAX_TOOL_ITERATIONS=4
    -e DIALECTIC_LEVELS__max__MODEL_CONFIG__TRANSPORT=openai -e DIALECTIC_LEVELS__max__MODEL_CONFIG__MODEL=test
    -e DIALECTIC_LEVELS__max__MODEL_CONFIG__THINKING_BUDGET_TOKENS=2048
    -e DIALECTIC_LEVELS__max__MAX_TOOL_ITERATIONS=10
    -e EMBEDDING_MODEL_CONFIG__TRANSPORT=openai -e EMBEDDING_MODEL_CONFIG__MODEL=test
)

# ---------- build ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Building Docker image ==="
docker build -t "${IMAGE_NAME}" "${REPO_ROOT}/honcho"

# =============================================================================
# TEST 1: No-auth flow
# =============================================================================

echo ""
echo "=== Test 1: No-auth flow ==="
echo "Starting container with AUTH_USE_AUTH=false..."

docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "${HONCHO_PORT}:8000" \
    -e AUTH_USE_AUTH=false \
    -e LOG_LEVEL=INFO \
    "${LLM_ENV[@]}" \
    --entrypoint //bin/bash \
    "${IMAGE_NAME}" \
    -c "${ENTRYPOINT_SCRIPT}"

wait_for_health

echo "Testing API without credentials..."

# Health endpoint (always open)
STATUS=$(http_status GET "http://localhost:${HONCHO_PORT}/health")
if [ "${STATUS}" = "200" ]; then
    log_pass "GET /health returns 200"
else
    log_fail "GET /health returns ${STATUS} (expected 200)"
fi

# Workspace endpoint (auth-gated, but auth is off)
STATUS=$(http_status POST "http://localhost:${HONCHO_PORT}/v3/workspaces" \
    -H "Content-Type: application/json" \
    -d '{"name": "test-workspace"}')
if [ "${STATUS}" = "200" ] || [ "${STATUS}" = "201" ]; then
    log_pass "POST /v3/workspaces returns ${STATUS} without auth (auth disabled)"
else
    log_fail "POST /v3/workspaces returns ${STATUS} without auth (expected 200 or 201)"
fi

# Same endpoint WITH a Bearer token should also work (token is ignored)
STATUS=$(http_status POST "http://localhost:${HONCHO_PORT}/v3/workspaces" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer some-random-token" \
    -d '{"name": "test-workspace"}')
if [ "${STATUS}" = "200" ] || [ "${STATUS}" = "201" ]; then
    log_pass "POST /v3/workspaces returns ${STATUS} with arbitrary token (auth disabled)"
else
    log_fail "POST /v3/workspaces returns ${STATUS} with arbitrary token (expected 200 or 201)"
fi

echo "Stopping no-auth container..."
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1

# =============================================================================
# TEST 2: Auth flow
# =============================================================================

echo ""
echo "=== Test 2: Auth flow ==="

# Generate a JWT secret and admin token locally for testing
JWT_SECRET="test-secret-for-integration-tests-$(date +%s)"
ADMIN_TOKEN=$(python3 -c "
import jwt, sys
token = jwt.encode({'t': '', 'ad': True}, sys.argv[1].encode('utf-8'), algorithm='HS256')
print(token)
" "${JWT_SECRET}" 2>/dev/null || python -c "
import jwt, sys
token = jwt.encode({'t': '', 'ad': True}, sys.argv[1].encode('utf-8'), algorithm='HS256')
print(token)
" "${JWT_SECRET}")

echo "Generated test JWT secret and admin token."
echo "Starting container with AUTH_USE_AUTH=true..."

docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "${HONCHO_PORT}:8000" \
    -e AUTH_USE_AUTH=true \
    -e AUTH_JWT_SECRET="${JWT_SECRET}" \
    -e LOG_LEVEL=INFO \
    "${LLM_ENV[@]}" \
    --entrypoint //bin/bash \
    "${IMAGE_NAME}" \
    -c "${ENTRYPOINT_SCRIPT}"

wait_for_health

echo "Testing API without credentials (should fail)..."

STATUS=$(http_status POST "http://localhost:${HONCHO_PORT}/v3/workspaces" \
    -H "Content-Type: application/json" \
    -d '{"name": "test-workspace"}')
if [ "${STATUS}" = "401" ]; then
    log_pass "POST /v3/workspaces returns 401 without token (auth enabled)"
else
    log_fail "POST /v3/workspaces returns ${STATUS} without token (expected 401)"
fi

echo "Testing API with wrong token (should fail)..."

STATUS=$(http_status POST "http://localhost:${HONCHO_PORT}/v3/workspaces" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer wrong-token" \
    -d '{"name": "test-workspace"}')
if [ "${STATUS}" = "401" ]; then
    log_pass "POST /v3/workspaces returns 401 with wrong token (auth enabled)"
else
    log_fail "POST /v3/workspaces returns ${STATUS} with wrong token (expected 401)"
fi

echo "Testing API with valid admin token (should succeed)..."

STATUS=$(http_status POST "http://localhost:${HONCHO_PORT}/v3/workspaces" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -d '{"name": "test-workspace"}')
if [ "${STATUS}" = "200" ] || [ "${STATUS}" = "201" ]; then
    log_pass "POST /v3/workspaces returns ${STATUS} with admin token (auth enabled)"
else
    log_fail "POST /v3/workspaces returns ${STATUS} with admin token (expected 200 or 201)"
fi

# Health endpoint should still work without auth
STATUS=$(http_status GET "http://localhost:${HONCHO_PORT}/health")
if [ "${STATUS}" = "200" ]; then
    log_pass "GET /health returns 200 (always open, even with auth enabled)"
else
    log_fail "GET /health returns ${STATUS} (expected 200)"
fi

# =============================================================================
# Results
# =============================================================================

echo ""
echo "=== Results ==="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo ""

if [ "${FAIL}" -gt 0 ]; then
    echo "SOME TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
    exit 0
fi
