# Session store is ETS (default) or Redis

Sessions are ephemeral by design and do not require a relational database. ETS is the default backend because it is in-process, zero-config, and fast enough for a single-node deployment. Redis is supported via `SESSION_STORE_BACKEND=redis` for deployments that need session sharing across multiple nodes or persistence across restarts. No other backends are planned; if durable long-term session history becomes a requirement, that would be a new feature rather than an extension of the current session store.
