#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Initialize Honcho: wait for PG, run migrations, generate config
# ==============================================================================

# Detect if running under HA Supervisor
declare SUPERVISED=false
if bashio::supervisor.ping 2>/dev/null; then
    SUPERVISED=true
fi

# Wait for PostgreSQL to accept connections (up to 30s)
bashio::log.info "Waiting for PostgreSQL to be ready..."
for i in $(seq 1 30); do
    if pg_isready -U postgres -q 2>/dev/null; then
        bashio::log.info "PostgreSQL is ready."
        break
    fi
    if [ "${i}" -eq 30 ]; then
        bashio::log.fatal "PostgreSQL did not become ready within 30 seconds."
        exit 1
    fi
    sleep 1
done

# Create honcho database if it doesn't exist
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='honcho'\" | grep -q 1" \
    || su - postgres -c "createdb honcho"

# Enable pgvector extension
su - postgres -c "psql -d honcho -c 'CREATE EXTENSION IF NOT EXISTS vector;'"

# ==============================================================================
# Generate environment config
# ==============================================================================

declare CONFIG_DIR="/data/honcho"
mkdir -p "${CONFIG_DIR}"

# --------------------------------------------------------------------------
# OpenRouter routing (Honcho v3.0.7+):
# Honcho's provider config is nested under <MODULE>_MODEL_CONFIG__*. Valid
# transports are openai|anthropic|gemini only. OpenRouter is OpenAI-compatible,
# so every module uses transport=openai with a per-module base_url override.
# The openai backend reads its key from the global LLM_OPENAI_API_KEY.
#
# Because transport is set explicitly, Honcho's _normalize_model_transport does
# NOT strip the "provider/" prefix, so OpenRouter model IDs like
# "google/gemini-2.5-flash-lite" reach OpenRouter intact.
# --------------------------------------------------------------------------

OPENROUTER_BASE_URL="https://openrouter.ai/api/v1"

# write_dialectic_level ENV_FILE LEVEL MODEL THINK_BUDGET ITERS MAX_OUT TOOL_CHOICE
# MAX_OUT and TOOL_CHOICE are optional (pass "" to omit).
# Reads global: OPENROUTER_BASE_URL
write_dialectic_level() {
    local ENV_FILE="$1" LVL="$2" MODEL="$3" THINK="$4" ITERS="$5" MAXOUT="$6" TOOLCHOICE="$7"
    local P="DIALECTIC_LEVELS__${LVL}__"
    echo "${P}MODEL_CONFIG__TRANSPORT=openai" >> "${ENV_FILE}"
    echo "${P}MODEL_CONFIG__MODEL=${MODEL}" >> "${ENV_FILE}"
    echo "${P}MODEL_CONFIG__OVERRIDES__BASE_URL=${OPENROUTER_BASE_URL}" >> "${ENV_FILE}"
    echo "${P}MODEL_CONFIG__THINKING_BUDGET_TOKENS=${THINK}" >> "${ENV_FILE}"
    echo "${P}MAX_TOOL_ITERATIONS=${ITERS}" >> "${ENV_FILE}"
    [ -n "${MAXOUT}" ] && echo "${P}MAX_OUTPUT_TOKENS=${MAXOUT}" >> "${ENV_FILE}"
    [ -n "${TOOLCHOICE}" ] && echo "${P}TOOL_CHOICE=${TOOLCHOICE}" >> "${ENV_FILE}"
    return 0
}

# write_openrouter_env ENV_FILE API_KEY
# Writes all Honcho v3.0.7 provider env vars, routing every module through
# OpenRouter via transport=openai + base_url override.
write_openrouter_env() {
    local ENV_FILE="$1"
    local API_KEY="$2"

    # Single credential — used by the openai transport for every module.
    echo "LLM_OPENAI_API_KEY=${API_KEY}" >> "${ENV_FILE}"

    # Read model choices from HA config
    local DERIVER_MODEL SUMMARY_MODEL DREAM_MODEL
    DERIVER_MODEL=$(bashio::config 'deriver_model')
    SUMMARY_MODEL=$(bashio::config 'summary_model')
    DREAM_MODEL=$(bashio::config 'dream_model')

    # Deriver
    echo "DERIVER_MODEL_CONFIG__TRANSPORT=openai" >> "${ENV_FILE}"
    echo "DERIVER_MODEL_CONFIG__MODEL=${DERIVER_MODEL}" >> "${ENV_FILE}"
    echo "DERIVER_MODEL_CONFIG__OVERRIDES__BASE_URL=${OPENROUTER_BASE_URL}" >> "${ENV_FILE}"

    # Summary
    echo "SUMMARY_MODEL_CONFIG__TRANSPORT=openai" >> "${ENV_FILE}"
    echo "SUMMARY_MODEL_CONFIG__MODEL=${SUMMARY_MODEL}" >> "${ENV_FILE}"
    echo "SUMMARY_MODEL_CONFIG__OVERRIDES__BASE_URL=${OPENROUTER_BASE_URL}" >> "${ENV_FILE}"

    # Dream — v3.0.7 has no single dream model; the user's dream_model drives
    # both the deduction and induction specialists.
    echo "DREAM_DEDUCTION_MODEL_CONFIG__TRANSPORT=openai" >> "${ENV_FILE}"
    echo "DREAM_DEDUCTION_MODEL_CONFIG__MODEL=${DREAM_MODEL}" >> "${ENV_FILE}"
    echo "DREAM_DEDUCTION_MODEL_CONFIG__OVERRIDES__BASE_URL=${OPENROUTER_BASE_URL}" >> "${ENV_FILE}"
    echo "DREAM_INDUCTION_MODEL_CONFIG__TRANSPORT=openai" >> "${ENV_FILE}"
    echo "DREAM_INDUCTION_MODEL_CONFIG__MODEL=${DREAM_MODEL}" >> "${ENV_FILE}"
    echo "DREAM_INDUCTION_MODEL_CONFIG__OVERRIDES__BASE_URL=${OPENROUTER_BASE_URL}" >> "${ENV_FILE}"

    # Dialectic levels (lowercase keys). Fixed params match prior intent:
    #   level    think  iters  max_out  tool_choice
    #   minimal  0      1      250      any
    #   low      0      5      -        any
    #   medium   1024   2      -        -
    #   high     1024   4      -        -
    #   max      2048   10     -        -
    local MINIMAL_MODEL LOW_MODEL MEDIUM_MODEL HIGH_MODEL MAX_MODEL
    MINIMAL_MODEL=$(bashio::config 'dialectic_minimal_model')
    LOW_MODEL=$(bashio::config 'dialectic_low_model')
    MEDIUM_MODEL=$(bashio::config 'dialectic_medium_model')
    HIGH_MODEL=$(bashio::config 'dialectic_high_model')
    MAX_MODEL=$(bashio::config 'dialectic_max_model')

    write_dialectic_level "${ENV_FILE}" minimal "${MINIMAL_MODEL}" 0    1  250 any
    write_dialectic_level "${ENV_FILE}" low     "${LOW_MODEL}"     0    5  ""  any
    write_dialectic_level "${ENV_FILE}" medium  "${MEDIUM_MODEL}"  1024 2  ""  ""
    write_dialectic_level "${ENV_FILE}" high    "${HIGH_MODEL}"    1024 4  ""  ""
    write_dialectic_level "${ENV_FILE}" max     "${MAX_MODEL}"     2048 10 ""  ""

    # Embeddings — via OpenRouter's OpenAI-compatible /embeddings endpoint.
    # transport=openai is set explicitly so the "openai/" prefix is preserved.
    echo "EMBEDDING_MODEL_CONFIG__TRANSPORT=openai" >> "${ENV_FILE}"
    echo "EMBEDDING_MODEL_CONFIG__MODEL=openai/text-embedding-3-small" >> "${ENV_FILE}"
    echo "EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL=${OPENROUTER_BASE_URL}" >> "${ENV_FILE}"

    bashio::log.info "Provider: OpenRouter (transport=openai + base_url override)"
    bashio::log.info "  Deriver: ${DERIVER_MODEL}"
    bashio::log.info "  Summary: ${SUMMARY_MODEL}"
    bashio::log.info "  Dream:   ${DREAM_MODEL} (deduction + induction)"
    bashio::log.info "  Dialectic: ${MINIMAL_MODEL} -> ${LOW_MODEL} -> ${MEDIUM_MODEL} -> ${HIGH_MODEL} -> ${MAX_MODEL}"
    bashio::log.info "  Embedding: openai/text-embedding-3-small"
}

# Check for user-provided config.toml override
if [ -f "${CONFIG_DIR}/config.toml" ]; then
    bashio::log.info "Using config.toml override from ${CONFIG_DIR}/config.toml"
elif bashio::var.true "${SUPERVISED}"; then
    # Running under HA Supervisor — read config from Bashio API
    declare LOG_LEVEL
    LOG_LEVEL=$(bashio::config 'log_level' | tr '[:lower:]' '[:upper:]')

    declare AUTH_ENABLED
    AUTH_ENABLED=$(bashio::config 'auth_enabled')

    declare JWT_SECRET
    JWT_SECRET=$(bashio::config 'jwt_secret')

    declare DERIVER_ENABLED
    DERIVER_ENABLED=$(bashio::config 'deriver_enabled')

    declare OPENROUTER_KEY
    OPENROUTER_KEY=$(bashio::config 'openrouter_api_key')

    if [ -z "${OPENROUTER_KEY}" ]; then
        bashio::log.fatal "OpenRouter API key is required. Set it in the add-on configuration."
        exit 1
    fi

    # JWT secret validation / auto-generation
    if bashio::var.true "${AUTH_ENABLED}"; then
        if [ -z "${JWT_SECRET}" ]; then
            if [ -f "${CONFIG_DIR}/.jwt_secret" ]; then
                JWT_SECRET=$(cat "${CONFIG_DIR}/.jwt_secret")
                bashio::log.info "Using previously generated JWT secret."
            else
                JWT_SECRET=$(/app/.venv/bin/python -c "import secrets; print(secrets.token_urlsafe(48))")
                echo "${JWT_SECRET}" > "${CONFIG_DIR}/.jwt_secret"
                chmod 600 "${CONFIG_DIR}/.jwt_secret"
                bashio::log.info "Auto-generated JWT secret."
            fi
            bashio::addon.option 'jwt_secret' "${JWT_SECRET}"
        fi

        # Generate a non-expiring admin JWT token for API access.
        # This token can be used as the apiKey in the OpenClaw Honcho plugin.
        declare API_TOKEN
        API_TOKEN=$(/app/.venv/bin/python -c "
import jwt, sys
token = jwt.encode({'t': '', 'ad': True}, sys.stdin.read().encode('utf-8'), algorithm='HS256')
print(token)
" <<< "${JWT_SECRET}")

        echo "${API_TOKEN}" > "${CONFIG_DIR}/.api_token"
        chmod 600 "${CONFIG_DIR}/.api_token"
        bashio::addon.option 'api_token' "${API_TOKEN}"
        bashio::log.info "API token generated. Find it in the Configuration tab."
    fi

    # Write base env vars
    {
        echo "DB_CONNECTION_URI=postgresql+psycopg://postgres@localhost:5432/honcho"
        echo "CACHE_URL=redis://127.0.0.1:6379/0"
        echo "CACHE_ENABLED=true"
        echo "LOG_LEVEL=${LOG_LEVEL}"
        echo "AUTH_USE_AUTH=${AUTH_ENABLED}"
        [ -n "${JWT_SECRET}" ] && echo "AUTH_JWT_SECRET=${JWT_SECRET}"
        echo "DERIVER_ENABLED=${DERIVER_ENABLED}"
    } > "${CONFIG_DIR}/env"

    # Write OpenRouter provider config with user's model choices
    write_openrouter_env "${CONFIG_DIR}/env" "${OPENROUTER_KEY}"

    chmod 600 "${CONFIG_DIR}/env"
else
    # Standalone mode — use environment variables directly (for development/testing)
    bashio::log.info "Not running under HA Supervisor. Using environment variables."
    {
        echo "DB_CONNECTION_URI=${DB_CONNECTION_URI:-postgresql+psycopg://postgres@localhost:5432/honcho}"
        echo "CACHE_URL=${CACHE_URL:-redis://127.0.0.1:6379/0}"
        echo "CACHE_ENABLED=${CACHE_ENABLED:-true}"
        echo "LOG_LEVEL=${LOG_LEVEL:-INFO}"
        echo "AUTH_USE_AUTH=${AUTH_USE_AUTH:-false}"
        echo "DERIVER_ENABLED=${DERIVER_ENABLED:-false}"
    } > "${CONFIG_DIR}/env"
    chmod 600 "${CONFIG_DIR}/env"
fi

# Run database provisioning (creates tables and runs Alembic migrations)
bashio::log.info "Running database provisioning..."
cd /app
export DB_CONNECTION_URI="postgresql+psycopg://postgres@localhost:5432/honcho"
/app/.venv/bin/python scripts/provision_db.py

bashio::log.info "Honcho initialization complete."
