# Changelog

## 0.2.2

- Replace the add-on `icon.png` with the official Honcho saluting-face mark on
  the brand-blue (`#B5DAFF`) background, sourced from upstream branding
  (`plastic-labs/honcho`). The previous icon was an off-brand, glitchy navy
  emoji that did not match the project's identity.
- Refresh `logo.png` from the upstream wordmark vector (`assets/honcho.svg`) for
  a crisp, higher-resolution rendering.

## 0.2.1

- Pin the base image to the dated tag `base-debian:trixie-2026.05.0` instead of
  the floating `trixie` codename, for reproducible builds.
- Remove the unused read-write `share` mount and its AppArmor grant (least
  privilege; `/data` is always mounted, so persistence is unaffected).
- Declare `hassio_api: true` to make the init script's Supervisor self-API calls
  (writing `jwt_secret`/`api_token`, `supervisor.ping`) explicit. Role stays at
  default.
- Use the `[PORT:8000]` watchdog placeholder so the health check follows a
  user-remapped port.
- Docs: clarify that dialectic thinking budgets are best-effort no-ops under the
  OpenRouter (`openai` transport) routing, and that the embedding model is fixed
  by the add-on (not by Honcho).

## 0.2.0

- Upgrade bundled Honcho to v3.0.7
- Rewrite LLM provider configuration to Honcho's new `MODEL_CONFIG` scheme; all models continue to route through OpenRouter with a single API key
- Embeddings now use OpenRouter's OpenAI-compatible `/embeddings` endpoint (`openai/text-embedding-3-small`)
- `dream_model` now configures both the deduction and induction dream specialists (Honcho removed the single dream orchestrator model)
- Use Honcho's native `/health` endpoint; remove the bundled health wrapper
- Modernize the add-on `map:` declaration to object form; drop the redundant `data` entry (`/data` is always mounted for add-ons, so persistence is unaffected)

## 0.1.7

- Add API token generation for JWT authentication
- Document OpenClaw plugin integration (baseUrl configuration)
- Add Docker integration tests for auth flows

## 0.1.0

- Initial release
