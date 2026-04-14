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
# write_openrouter_env: Reads model choices from HA config and writes all
# Honcho env vars. OpenRouter is OpenAI-compatible, so we use the "openai"
# provider type with OpenRouter's base URL.
#
# Honcho's SupportedProviders = "anthropic"|"openai"|"google"|"groq"|"custom"|"vllm"
# OpenRouter works as "openai" with a custom base URL.
# --------------------------------------------------------------------------
write_openrouter_env() {
    local ENV_FILE="$1"
    local API_KEY="$2"

    # OpenRouter credentials
    # LLM calls use the "custom" provider (OPENAI_COMPATIBLE_*) which routes
    # through OpenRouter's OpenAI-compatible API. The "openai" provider would
    # go to api.openai.com directly and reject the OpenRouter key.
    # Embeddings use the "openrouter" provider (separate code path).
    echo "LLM_OPENAI_COMPATIBLE_API_KEY=${API_KEY}" >> "${ENV_FILE}"
    echo "LLM_OPENAI_COMPATIBLE_BASE_URL=https://openrouter.ai/api/v1" >> "${ENV_FILE}"
    echo "LLM_OPENROUTER_API_KEY=${API_KEY}" >> "${ENV_FILE}"
    echo "LLM_EMBEDDING_PROVIDER=openrouter" >> "${ENV_FILE}"

    # Read model choices from HA config (with defaults matching Honcho's upstream)
    local DERIVER_MODEL SUMMARY_MODEL DREAM_MODEL
    DERIVER_MODEL=$(bashio::config 'deriver_model')
    SUMMARY_MODEL=$(bashio::config 'summary_model')
    DREAM_MODEL=$(bashio::config 'dream_model')

    # Task-type providers — all use "custom" (OpenRouter via OPENAI_COMPATIBLE_*)
    echo "DERIVER_PROVIDER=custom" >> "${ENV_FILE}"
    echo "DERIVER_MODEL=${DERIVER_MODEL}" >> "${ENV_FILE}"

    echo "SUMMARY_PROVIDER=custom" >> "${ENV_FILE}"
    echo "SUMMARY_MODEL=${SUMMARY_MODEL}" >> "${ENV_FILE}"

    echo "DREAM_PROVIDER=custom" >> "${ENV_FILE}"
    echo "DREAM_MODEL=${DREAM_MODEL}" >> "${ENV_FILE}"
    # Dream specialist models (deduction/induction) use haiku-class
    echo "DREAM_DEDUCTION_MODEL=anthropic/claude-haiku-4.5" >> "${ENV_FILE}"
    echo "DREAM_INDUCTION_MODEL=anthropic/claude-haiku-4.5" >> "${ENV_FILE}"

    # Dialectic levels — each has a user-configurable model plus fixed parameters
    # that match Honcho's upstream defaults (thinking tokens, iterations, etc.)
    local MINIMAL_MODEL LOW_MODEL MEDIUM_MODEL HIGH_MODEL MAX_MODEL
    MINIMAL_MODEL=$(bashio::config 'dialectic_minimal_model')
    LOW_MODEL=$(bashio::config 'dialectic_low_model')
    MEDIUM_MODEL=$(bashio::config 'dialectic_medium_model')
    HIGH_MODEL=$(bashio::config 'dialectic_high_model')
    MAX_MODEL=$(bashio::config 'dialectic_max_model')

    # minimal: cheapest, one-shot, capped output
    echo "DIALECTIC_LEVELS__MINIMAL__PROVIDER=custom" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MINIMAL__MODEL=${MINIMAL_MODEL}" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MINIMAL__THINKING_BUDGET_TOKENS=0" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MINIMAL__MAX_TOOL_ITERATIONS=1" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MINIMAL__MAX_OUTPUT_TOKENS=250" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MINIMAL__TOOL_CHOICE=any" >> "${ENV_FILE}"

    # low: simple reasoning, limited tools
    echo "DIALECTIC_LEVELS__LOW__PROVIDER=custom" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__LOW__MODEL=${LOW_MODEL}" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__LOW__THINKING_BUDGET_TOKENS=0" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__LOW__MAX_TOOL_ITERATIONS=5" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__LOW__TOOL_CHOICE=any" >> "${ENV_FILE}"

    # medium: balanced, thinking enabled
    echo "DIALECTIC_LEVELS__MEDIUM__PROVIDER=custom" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MEDIUM__MODEL=${MEDIUM_MODEL}" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MEDIUM__THINKING_BUDGET_TOKENS=1024" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MEDIUM__MAX_TOOL_ITERATIONS=2" >> "${ENV_FILE}"

    # high: deep reasoning, extended tools
    echo "DIALECTIC_LEVELS__HIGH__PROVIDER=custom" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__HIGH__MODEL=${HIGH_MODEL}" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__HIGH__THINKING_BUDGET_TOKENS=1024" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__HIGH__MAX_TOOL_ITERATIONS=4" >> "${ENV_FILE}"

    # max: full capability
    echo "DIALECTIC_LEVELS__MAX__PROVIDER=custom" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MAX__MODEL=${MAX_MODEL}" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MAX__THINKING_BUDGET_TOKENS=2048" >> "${ENV_FILE}"
    echo "DIALECTIC_LEVELS__MAX__MAX_TOOL_ITERATIONS=10" >> "${ENV_FILE}"

    bashio::log.info "Provider: OpenRouter"
    bashio::log.info "  Deriver: ${DERIVER_MODEL}"
    bashio::log.info "  Summary: ${SUMMARY_MODEL}"
    bashio::log.info "  Dream:   ${DREAM_MODEL}"
    bashio::log.info "  Dialectic: ${MINIMAL_MODEL} → ${LOW_MODEL} → ${MEDIUM_MODEL} → ${HIGH_MODEL} → ${MAX_MODEL}"
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
