# Changelog

## Unreleased

- Suppress the exact closed Req connection transport failure from generation logs and matching
  error completion trace events before they reach redaction, test capture, buffering, or HTTP.
- Retired message-slot expansion. A prompt message with `{"type" => "slot"}` now raises
  `Message slots are not supported; compose conversation history in app code.` even when variables
  include a matching list; `{{ history }}` remains an ordinary template variable.
- Updated examples and tests so apps compose PromptOn-managed messages, app-owned conversation
  history and the current user message before calling the provider, then pass those final messages
  to `track(input_messages:)`.

## 0.5.0

- Changed runtime config fetches to demand-driven prompt lookups. Client startup, readiness checks and idle periods no longer fetch remote config or start a config polling timer; a prompt is fetched only when `use_case(key)` needs that key.
- Added per-prompt caching and singleflight behavior for config fetches. Each SDK instance keeps separate cache state per project, environment and prompt key; fresh remote values live for 10 seconds, failed attempts are also rate-limited for 10 seconds, and concurrent callers for the same key share one in-flight request.
- Switched normal runtime config traffic to `GET /api/v1/prompts/:key?environment=...` with prompt-specific `If-None-Match`. Successful `200` and meaningful `304` responses refresh only that key, while other cached prompts retain their own ETags and timestamps.
- Added a fixed 1-second total config fetch budget with no HTTP retry. Transport errors, HTTP errors, invalid documents, scope mismatches and timeouts serve the last valid cached value, even when expired; cold failures raise `PromptOn::NotReadyError`. Legacy `cache_ttl:` and `config_fetch_timeout:` options are accepted for compatibility but do not change runtime config fetch timing.
- Kept disk and bundle fallbacks, but local documents no longer count as fresh remote validation after process startup. Disk sidecars preserve prompt-specific raw documents so restarts keep each prompt's immutable model/version view even when the merged document has shared ids. `poll:` is accepted for compatibility and ignored for config fetching.

## 0.4.1

- Fixed runtime compatibility with the current PromptOn prompt API: snapshot fetches now use `GET /api/v1/prompts`, remote render uses `POST /api/v1/prompts/{key}/render` with `template`, and monitoring logs use canonical `prompt_key`/`template` fields.
- Updated active conformance fixtures to the schema7 prompt contract with native tool messages while keeping existing public use-case aliases.

## 0.4.0

- Added schema-v7 use-case documents with chat tool definitions and message slots. Full provider chat messages, including `content: nil`, array content, `tool_calls`, `tool_call_id` and native extra fields, are preserved when slot histories are spliced.
- Runtime evidence now carries deployment `api`, `request_path` and prompt `tools` metadata for provider request construction by applications.
- Added `PromptOn.log_events` / `PromptOn::Client#log_events` for application-observed trace events. It posts `{"logs": [], "events": [...]}` to `/api/v1/logs?environment=...` and captures events in test mode.

## 0.2.0

Breaking vocabulary cleanup for the schema-v4 use-case document contract.

- Public call flow is `use_case` → `messages`/`text` → `track`; old resolution/snapshot aliases
  were removed.
- Test helpers and bundled files now use `use-cases.<environment>.json`.
- Monitoring records use log vocabulary, `log(use_case_evidence:)`, and `PromptOn::LogBuilder`.
- Prompt endpoint decoding follows `key`, `prompt_names`, `source`, `params` and
  `provider_options`.
- `PromptOn::Result.from_openai` and `PromptOn::Result.from_anthropic` normalize provider
  responses for logs.
- Use-case documents must carry exact integer `schema_version: 4`.
- `PromptOn::Failure` now carries partial provider data with `result:`.

## 0.1.0

Initial release.

- Use-case document store with the three fallback tiers: memory, an atomically written disk cache and a
  bundled use-case document, with ETag polling, a 10-second cache TTL, Retry-After handling on 429 and
  exponential backoff on 5xx, timeouts and transport errors. A refresh never blocks or fails a
  log, and a document from another environment or project is never used.
- Local use-case selection against a schema-v4 use-case document: deployment → prompt version → model, with
  `use_case.default_params <- deployment.params` and
  `model.provider_options <- deployment.provider_options`.
- A prompt renderer for the Liquid subset PromptOn allows (`for`, `if`/`elsif`/`else`, `unless`,
  `assign`, `break`, `continue`, and the `size`, `join` and `default` filters), plus the `raw`
  engine and a static whitelist lint.
- `POST /use-cases/:key/prompt` client with the same caching and failure rules, for smoke tests and
  low-traffic paths.
- Monitoring logs: `log`, `flush` and the `track` wrapper, with app-generated UUIDv7
  ids, the payload policy (sampling, `hash` and `none` modes, truncation), batching by size,
  bytes and time, one batch per environment, partial-acceptance handling, retries on 429 and
  5xx, 413 splitting, a bounded drop-oldest queue, a redaction hook and `hash_end_user`.
- `stop_kind` derivation from provider finish reasons.
- Test mode (no HTTP, records captured for assertions) and offline mode (disk and bundle only).
- The cross-language conformance suite runs in this SDK's test suite.

### Fixed before the release, after an adversarial review

- The first use-case document fetch is due immediately rather than `cache_ttl` seconds after the monotonic
  clock's zero. On a host whose uptime was below `cache_ttl` the SDK used to refuse to make its
  very first HTTP call and raise `NotReadyError` against a healthy server.
- `remote_use_case(..., variables:)` returns a use-case selection carrying the **rendered** prompt; the
  render used to be computed and discarded, so `messages` still held `{{ variables }}`.
- `log` no longer backfills `started_at` with the enqueue time: it is one of the four required
  fields and a missing one raises `PromptOn::InvalidRecordError`, because a hand-built record is
  usually written after the provider call it describes.
- `flush` reports `queued` and `paused_for` when a `Retry-After` window leaves records behind, and
  a shutdown waits out a pause that fits in its timeout, then counts and names anything still
  unsent (`dropped_on_shutdown`) instead of dropping it silently.
- `close` waits for an in-flight background refresh, so a short script's use-case document really does
  reach the disk cache before the process ends.
- One process-wide `at_exit` hook drains a registry of clients held weakly, and `close` takes a
  client out of it: building a client per request or per test no longer keeps every one of them,
  and its queued records, alive until the process exits.
- The log-buffer counters, the discarded-log counter and the module-level default client are
  guarded by mutexes, so the "safe to share between threads" promise holds off MRI too.
- Ruby 3.2 is the floor — the oldest runtime the suite is actually run on — and minitest and
  rubocop are pinned to one major each, so every CI job resolves the versions that were exercised.
