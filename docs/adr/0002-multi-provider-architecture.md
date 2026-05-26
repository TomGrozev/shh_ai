# Multi-provider architecture

The application supports multiple AI providers simultaneously (OpenAI, Anthropic, and others) rather than coupling to a single vendor. Providers are configured independently via environment variables (`PROVIDER_OPENAI_1_ENABLED`, `PROVIDER_ANTHROPIC_1_API_KEY`, etc.) with up to four instances per provider type. This insulates users from provider outages, enables A/B testing of models, and prevents vendor lock-in. The trade-off is a small abstraction layer over each provider's native API format.
