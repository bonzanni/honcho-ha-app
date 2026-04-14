#!/usr/bin/env bash
# ==============================================================================
# Integration test for Honcho HA add-on auth flows.
#
# Builds the Docker image and tests:
#   1. No-auth flow: API accepts requests without credentials
#   2. Auth flow: API rejects without token, accepts with admin JWT
#
# Usage: bash tests/test-auth.sh
# Requires: docker
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

log_pass() { echo "  PASS: $1"; ((PASS++)); }
log_fail() { echo "  FAIL: $1"; ((FAIL++)); }

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
    docker logs "${CONTAINER_NAME}" 2>&1 | tail -50
    return 1
}

http_status() {
    # Return just the HTTP status code for a request.
    # Do NOT use -f: curl must exit 0 on 4xx/5xx so we capture the code.
    local method="$1"; shift
    local url="$1"; shift
    curl -s -o /dev/null -w "%{http_code}" -X "${method}" "$@" "${url}" 2>/dev/null || echo "000"
}

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
    -e LOG_LEVEL=DEBUG \
    "${IMAGE_NAME}"

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
import jwt
token = jwt.encode({'t': '', 'ad': True}, '${JWT_SECRET}'.encode('utf-8'), algorithm='HS256')
print(token)
" 2>/dev/null || python -c "
import jwt
token = jwt.encode({'t': '', 'ad': True}, '${JWT_SECRET}'.encode('utf-8'), algorithm='HS256')
print(token)
")

echo "Generated test JWT secret and admin token."
echo "Starting container with AUTH_USE_AUTH=true..."

docker run -d \
    --name "${CONTAINER_NAME}" \
    -p "${HONCHO_PORT}:8000" \
    -e AUTH_USE_AUTH=true \
    -e AUTH_JWT_SECRET="${JWT_SECRET}" \
    -e LOG_LEVEL=DEBUG \
    "${IMAGE_NAME}"

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
