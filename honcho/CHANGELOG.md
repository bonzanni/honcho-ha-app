# Changelog

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
