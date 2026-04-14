# Honcho for Home Assistant

Honcho is an AI memory infrastructure that provides persistent, contextualized memory for AI agents. This add-on runs the full Honcho stack in a single container.

## Requirements

- **Minimum RAM**: 2 GB (API only, deriver disabled) / 4 GB+ recommended (with deriver)
- **Storage**: 1 GB base + data growth
- **Architecture**: amd64 or aarch64
- **Not supported**: Raspberry Pi 3 or devices with 1 GB RAM
- **OpenRouter account**: Required - get a key at https://openrouter.ai

## Configuration

### OpenRouter API Key (required)

- **openrouter_api_key**: Your OpenRouter API key. All LLM calls go through OpenRouter.

### Model Selection

Each Honcho subsystem can use a different OpenRouter model. Defaults match Honcho's upstream choices (using latest model versions). Change them to control cost vs quality.

Embedding uses `openai/text-embedding-3-small` (hardcoded by Honcho, not configurable).

#### Task Models

| Option | Default | $/M in | $/M out | Purpose |
|--------|---------|--------|---------|---------|
| **deriver_model** | `google/gemini-2.5-flash-lite` | $0.10 | $0.40 | Processes conversation memory into observations |
| **summary_model** | `google/gemini-2.5-flash` | $0.30 | $2.50 | Generates session summaries |
| **dream_model** | `anthropic/claude-sonnet-4.6` | $3.00 | $15.00 | Deep memory consolidation (runs every 8+ hours) |

#### Dialectic Reasoning Levels

The Dialectic system uses escalating model tiers. Cheaper models handle simple queries; expensive ones handle complex reasoning.

| Option | Default | $/M in | $/M out | Thinking | Tool iterations |
|--------|---------|--------|---------|----------|-----------------|
| **dialectic_minimal_model** | `google/gemini-2.5-flash-lite` | $0.10 | $0.40 | None | 1 |
| **dialectic_low_model** | `google/gemini-2.5-flash-lite` | $0.10 | $0.40 | None | 5 |
| **dialectic_medium_model** | `anthropic/claude-haiku-4.5` | $1.00 | $5.00 | 1024 tokens | 2 |
| **dialectic_high_model** | `anthropic/claude-haiku-4.5` | $1.00 | $5.00 | 1024 tokens | 4 |
| **dialectic_max_model** | `anthropic/claude-haiku-4.5` | $1.00 | $5.00 | 2048 tokens | 10 |

> **Cost tip**: For cheaper operation, set all dialectic levels to `google/gemini-2.5-flash-lite`. For best quality, set high/max to `anthropic/claude-sonnet-4.6`.

*Prices from OpenRouter as of April 2026. Check https://openrouter.ai/models for current pricing.*

### Core Settings

- **log_level**: `debug`, `info`, `warning`, `error`, or `critical` (default: `info`)
- **auth_enabled**: Enable JWT authentication (default: `false`)
- **jwt_secret**: JWT signing secret (required when auth is enabled, auto-generated if empty)
- **deriver_enabled**: Enable the background deriver worker (default: `true`)

### Advanced: config.toml Override

Power users can place a full Honcho `config.toml` at `/data/honcho/config.toml` to override all settings.

## Network Access

Other Home Assistant add-ons can reach the Honcho API on the internal Docker network. The hostname depends on your installation method:

| Install method | Hostname |
|----------------|----------|
| Local add-on | `local-honcho:8000` |
| Repository add-on | `{repo_hash}-honcho:8000` |

**Do not hardcode the hostname** in dependent add-ons. Use the Supervisor API to discover the address dynamically.

Optionally, enable the host port mapping in the add-on configuration to expose the API at `http://<ha-ip>:<port>`.

## OpenClaw Plugin Integration

The [OpenClaw Honcho plugin](https://github.com/plastic-labs/openclaw-honcho) defaults to the managed cloud API (`api.honcho.dev`). To use your local add-on instead, you **must** configure the `baseUrl` in your `openclaw.json`:

### Without authentication (default)

```json
{
  "plugins": {
    "entries": {
      "openclaw-honcho": {
        "enabled": true,
        "config": {
          "baseUrl": "http://local-honcho:8000"
        }
      }
    }
  }
}
```

Replace `local-honcho` with the correct hostname for your setup (see Network Access above).

### With authentication

1. Enable `auth_enabled` in the add-on configuration and restart.
2. Copy the `api_token` value from the add-on's Configuration tab.
3. Configure the plugin:

```json
{
  "plugins": {
    "entries": {
      "openclaw-honcho": {
        "enabled": true,
        "config": {
          "baseUrl": "http://local-honcho:8000",
          "apiKey": "<paste api_token here>"
        }
      }
    }
  }
}
```

> **Important:** If you omit `baseUrl`, the plugin sends all requests to `api.honcho.dev` (the managed cloud API), which will fail with a 401 error unless you have a cloud API key.
