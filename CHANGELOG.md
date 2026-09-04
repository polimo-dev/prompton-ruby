# Changelog

## 0.1.0

Initial release.

- Snapshot store with the three fallback tiers: memory, an atomically written disk cache and a
  bundled snapshot, with ETag polling, a 10-second cache TTL, Retry-After handling on 429 and
  exponential backoff on 5xx, timeouts and transport errors. A refresh never blocks or fails a
  generation, and a document from another environment or project is never used.
- Local resolution against a schema-v3 snapshot: deployment → prompt version → model, with
  `use_case.default_params <- deployment.params` and
  `model.provider_options <- deployment.provider_options`.
- A prompt renderer for the Liquid subset PromptOn allows (`for`, `if`/`elsif`/`else`, `unless`,
  `assign`, `break`, `continue`, and the `size`, `join` and `default` filters), plus the `raw`
  engine and a static whitelist lint.
- `POST /resolve` client with the same caching and failure rules, for smoke tests and
  low-traffic paths.
- Monitoring logs: `log`, `flush` and the `with_generation` wrapper, with app-generated UUIDv7
  ids, the payload policy (sampling, `hash` and `none` modes, truncation), batching by size,
  bytes and time, one batch per environment, partial-acceptance handling, retries on 429 and
  5xx, 413 splitting, a bounded drop-oldest queue, a redaction hook and `hash_end_user`.
- `stop_kind` derivation from provider finish reasons.
- Test mode (no HTTP, records captured for assertions) and offline mode (disk and bundle only).
- The cross-language conformance suite runs in this SDK's test suite.
