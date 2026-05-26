# PII pipeline uses OpenAI format as canonical

All incoming requests are normalized to the OpenAI chat-completion format before PII detection and sanitization. After sanitization, responses are converted back to the caller's original format. This avoids duplicating sanitization logic per provider and lets the pipeline treat every provider uniformly. The risk—format fidelity loss during round-trip conversion—is mitigated by explicit converter modules per provider.
