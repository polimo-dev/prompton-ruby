# prompton-sdk (Ruby)

The official Ruby SDK for [PromptOn](https://app.prompton.ai), the control plane for your app's
LLM prompts.

PromptOn holds one **pin** per use case and environment: a prompt version, one model, and its
params. Your app fetches a **use-case document** of those pins, renders the pinned prompt with this call's
variables, and calls the provider **itself, with its own key and its own HTTP client**. After each
call it sends a **monitoring log** back in a batch.

PromptOn is config-fetch, **not a proxy**. It is never in the request path, so a PromptOn outage
costs you nothing but fresher config: your app keeps running on the last use-case document it received.
This SDK is thin by design — no runtime dependencies, `Net::HTTP` and the standard library only.

```
use_case("greeting", prompt: "ko") ──▶ UseCase{model, params, provider_options, …}
use_case.messages(name: "Ada")     ──▶ the messages you send to your provider
use_case.track { … }               ──▶ the provider call, timed and logged in the background
```

## Install

Not published to RubyGems yet, so depend on the repository:

```ruby
# Gemfile
gem "prompton-sdk", github: "polimo-dev/prompton-ruby"
```

Once published, the line becomes `gem "prompton-sdk", "~> 0.2"`. Requires Ruby 3.2 or newer.

## Quick start

```ruby
require "prompton"

PromptOn.configure(api_key: ENV.fetch("PTN_API_KEY"))            # ptn_<project>_… , a project key

use_case = PromptOn.use_case("greeting", prompt: "ko")            # from the cached use-case document
messages = use_case.messages(name: "Ada")                         # your variables, rendered locally

use_case.track(variables: { name: "Ada" }, input_messages: messages) do
  openai.chat(model: use_case.model, messages: messages, **use_case.params)       # your key, your client
end
```

`use_case` reads memory, not the network. `track` times the block, builds the monitoring
log and queues it; it returns whatever your block returned, and re-raises whatever your block
raised. There is a runnable version in [`examples/greeting.rb`](examples/greeting.rb), which works
with no server at all because it ships a bundled use-case document.

Prefer an explicit object over the module-level default? `PromptOn::Client.new(...)` gives you one,
and you can hold as many as you like.

## Configuration

Every option follows the same precedence: **explicit option > environment variable > default**.
Passing `api_key: nil` explicitly means "no remote calls", even on a machine where `PTN_API_KEY` is
set.

| Option | Env | Default | What it does |
|---|---|---|---|
| `host` | `PTN_HOST` | `https://app.prompton.ai` | The SDK appends `/api/v1` itself |
| `api_key` | `PTN_API_KEY` | none | `ptn_<project_slug>_…`. Without it, no remote calls at all |
| `environment` | `PTN_ENVIRONMENT` | `production` | Which environment's pins this process reads |
| `project` | `PTN_PROJECT` | read from the API key | Guards the disk cache and the bundle |
| `cache_ttl` | | `10.0` | Seconds a use-case document is served from memory before a refresh |
| `max_backoff` | | `300.0` | Cap of the ×2 backoff after a failed refresh |
| `timeout` | | `5.0` | Seconds; `open_timeout` and `read_timeout` override it separately |
| `poll` | | `true` | Background poll loop. With `false` the next call revalidates instead |
| `disk_cache` | | `true` | `true` for the OS cache directory, a path, or `false` |
| `bundle` | `PTN_BUNDLE` | none | Path to a use-case document committed into the app |
| `mode` | | `:live` | `:live`, `:test` (no HTTP, logs captured) or `:offline` (disk/bundle only) |
| `hash_end_user` | | `false` | Send `sha256(end_user_ref)` instead of the raw reference |
| `redact` | | none | `->(record) { record }`, applied to every log record last |
| `flush_interval` | | `2.0` | Seconds before a partial batch of logs is sent |
| `flush_size` | | `100` | Records that trigger a send (a request carries at most 200) |
| `flush_bytes` | | `1_000_000` | Queued bytes that trigger a send |
| `max_buffer` | | `10_000` | Queue cap; over it the oldest records are dropped and counted |
| `max_send_attempts` | | `8` | Retries of one batch before it is dropped and counted |
| `flush_on_exit` | | `true` | Best-effort drain at process exit |
| `logger` | | warnings on `$stderr` | Anything responding to `info`, `warn` and `error` |
| `payload_defaults` | | `full`, `1.0`, `262144` | Used when the use-case document names no payload policy |

The default disk cache path is named by project and environment, for example
`~/.cache/prompton/use-case document-heydiary-production.json` (`~/Library/Caches/…` on macOS).

## Resilience: how config reaches your process

```
start:   memory ──▶ disk cache ──▶ bundled use-case document ──▶ remote
serve:   every use-case selection reads memory, with no HTTP call inside the cache TTL
refresh: GET /use-cases?environment=… with If-None-Match, in the background
         200 ─▶ swap in memory + write the disk cache atomically   source: remote
         304 ─▶ nothing to parse, nothing to write
         fail ─▶ keep serving the previous document, back off       source: disk | bundle
```

- **Ten-second cache.** Within `cache_ttl` every use-case selection is served from memory. When it has
  passed, the SDK refreshes with `If-None-Match` — a `304` costs nothing, so a short interval is
  cheap.
- **A refresh never blocks or fails a provider call.** It runs on a poll thread (or, with
  `poll: false`, as a stale-while-revalidate refresh the next call triggers). While it is in
  flight, and if it fails, the previous document is what every use-case selection reads.
- **Rate limits.** On `429` the SDK reads `Retry-After` (falling back to
  `error.details.retry_after`, then to the backoff) and does not contact the server again before
  it has elapsed. `5xx`, timeouts and transport errors back off ×2 from the cache TTL up to five
  minutes. The caller never sees any of it.
- **Three tiers, no external services.** Memory, one local file, and a file bundled into the app.
  No database, no Redis, nothing shared: instances never coordinate, which ETag polling makes
  cheap. Several processes on one host may share the disk file — writes are a temp file plus a
  rename, readers tolerate a concurrent rename, and a corrupt or partial file is ignored rather
  than raised.
- **A document from the wrong environment or project is never used.** A `staging` process cannot
  boot on a `production` bundle; the file records both and a mismatch is ignored with a warning.
- **Never fall back to a hard-coded prompt.** `PromptOn::UnresolvedError` and
  `PromptOn::UnknownPromptError` are bugs in the deployment or in the call. Fail that call loudly.

Build the bundle at release time and commit it:

```ruby
client = PromptOn::Client.new(api_key: ENV.fetch("PTN_API_KEY"))
client.refresh!                                             # fetch once, now
client.export_use_case_document("config/prompton/use-cases.production.json")
```

Then ship it with `bundle: Rails.root.join("config/prompton/use-cases.production.json").to_s`. One
file per environment: a single shared bundle is refused by the environment guard in whichever
environment it was not exported from.

`client.use_case_document_info` tells you where the current document came from and how old it is;
`client.use_case_document_status` tells you when the next fetch is due.

## How it fails

| Situation | What the SDK does | What your app sees |
|---|---|---|
| Inside the cache TTL | serves memory | no HTTP call at all |
| `304 Not Modified` | keeps the document | nothing |
| `429` with `Retry-After` | waits it out, serves the previous document | nothing; one warning line |
| `5xx`, timeout, DNS, connection refused | backs off ×2 from the TTL to 5 min, serves the previous document | nothing; one warning line |
| PromptOn down, disk cache present | serves the disk document | `use_case.source == "disk"` |
| PromptOn down, only a bundle present | serves the bundled document | `use_case.source == "bundle"` |
| PromptOn down, nothing cached anywhere | cannot select a use case | `PromptOn::NotReadyError` |
| Use-case document from another environment or project | ignores the file | one warning line; keeps looking |
| Use-case document with an unreadable `schema_version` | refuses it, keeps polling | `PromptOn::UnsupportedSchemaVersionError` on an explicit refresh |
| Use case key not in the use-case document | — | `PromptOn::UnknownUseCaseError` |
| Use case with no live deployment here | — | `PromptOn::UnresolvedError` |
| Prompt name the pin does not carry | never falls back to `default` | `PromptOn::UnknownPromptError` with `prompt_names` |
| Template reads a variable you did not pass | — | `PromptOn::MissingVariableError` with `variable` |
| Log batch gets `429` or `5xx` | retries the same ids, honouring `Retry-After` | nothing; dropped and counted after `max_send_attempts` |
| Log batch gets `413` | splits it in half and resends | nothing |
| Log batch gets any other `4xx` | drops it, counts it, logs once | nothing |
| Log queue full | drops the oldest, counts them | nothing; one warning per minute |
| Shutdown while a retry pause is running | waits the pause out when it fits in the timeout, otherwise drops what is left and counts it | `flush` reports `queued` and `paused_for`; one warning line naming the count |
| Log record missing `use_case`, `model`, `status` or `started_at` | refuses to guess the field | `PromptOn::InvalidRecordError` with `field` |
| No API key configured | no remote calls; disk and bundle only | one warning line at startup |

A log must never fail because PromptOn did. Config is stale in the worst case, not absent.

## Resolving and rendering

```ruby
use_case = PromptOn.use_case("diary_generation", prompt: "ko")

use_case.model               # "anthropic/claude-sonnet-4" — the provider model string
use_case.model_id            # the catalog UUID
use_case.provider            # "openrouter"
use_case.params              # use_case.default_params <- deployment.params
use_case.provider_options    # model.provider_options   <- deployment.provider_options
use_case.kind                # "chat" | "text" | "embedding"
use_case.prompt              # "ko"
use_case.prompt_names        # ["default", "ko"]
use_case.deployment_id       # the pin this call came from …
use_case.deployment_revision # … and its revision
use_case.prompt_version_id   # the immutable version …
use_case.prompt_version_number
use_case.source              # "remote" | "disk" | "bundle" | "manual"
use_case.messages_template   # the raw chat templates (nil for text/embedding)
use_case.text_template       # the raw text template (nil for chat/embedding)

use_case.messages(name: "Ada") # chat: the rendered message list
use_case.text(name: "Ada")     # text: the rendered string
use_case.detected_variables    # ["name"]
PromptOn.prompt_names("diary_generation")   # ["default", "ko"]
```

Both merges are **shallow** and the right side wins; an override of `nil` is kept as `nil`, not
deleted, because apps rely on sending `"only" => nil` to clear a provider restriction.

Templates are a small Liquid subset: `{{ var }}`, `for` (with `else`, `break`, `continue` and
`forloop.*`), `if`/`elsif`/`else`, `unless`, `assign`, and the `size`, `join` and `default`
filters. Nothing else parses. A variable that is absent from your hash is a
`PromptOn::MissingVariableError`; a key present with a `nil` value is not missing — it renders
empty and `default` replaces it. There is no HTML escaping. A prompt version whose engine is `raw`
comes back verbatim.

For a smoke test or a genuinely low-traffic path, `PromptOn.remote_use_case("greeting")` asks the
server instead (`POST /use-cases/{key}/prompt`) and caches the answer for the same TTL. Pass `variables:` and the
rendering still happens locally, in the returned use case: `remote_use_case("greeting", variables:
{ name: "Ada" }).messages` are the rendered messages, not the template. `PromptOn.api_use_case` returns
the server's raw JSON. Neither belongs in a hot loop.

## Monitoring logs

Three ways in.

```ruby
# 1. the wrapper: times the provider call and logs it
use_case.track(variables: vars, input_messages: messages,
               end_user_ref: user.id, trace_id: "job:#{job.id}", sequence: attempt,
               context: { language: "ko", plan: "pro" }, metadata: { job_id: job.id }) do
  response = openai.chat(model: use_case.model, messages: messages, **use_case.params)

  { content: response.dig("choices", 0, "message", "content"),
    finish_reason: response.dig("choices", 0, "finish_reason"),
    usage: { input_tokens: response.dig("usage", "prompt_tokens"),
             output_tokens: response.dig("usage", "completion_tokens"), raw: response["usage"] },
    cost_usd: 0.000112, cost_source: "provider", model_used: response["model"] }
end

# 2. one record you built yourself (streaming, a background scorer, a replay)
PromptOn.log({ "status" => "ok", "started_at" => started_at, "latency_ms" => 4180,
               "output" => { "content" => text } }, use_case_evidence: use_case)

# 3. send what is queued and wait — shutdown, scripts, tests
PromptOn.flush(timeout: 5)   # => {sent: 12, accepted: 12, duplicates: 0, rejected: 0}
```

`flush` returns what it did: `sent`, `accepted`, `duplicates`, `rejected`, plus `queued` and
`paused_for` whenever a `Retry-After` window it could not wait out left records behind — so an
empty hash means "nothing was queued" and never "the queue was skipped". `close` (and the process
exit hook) flushes once, waits out a retry pause short enough to fit in its timeout, and counts
anything still unsent as `dropped_on_shutdown` with one warning line rather than losing it
quietly.

Return a `PromptOn::Failure` from the block to record a provider error without raising; anything
it carries in `result:` (usage, partial output) is kept, which is what makes a parse failure
still readable as a quality signal. An exception is logged as an error of kind `app` and then
re-raised unchanged.

```ruby
PromptOn::Failure.new(kind: "rate_limited", status: 429, message: body)
PromptOn::Failure.new(kind: "parse", message: e.message,
                      result: { content: partial, finish_reason: "length", usage: usage })
```

### The record

`log` fills in `id` (a **UUIDv7** — the column is a UUIDv7 type and a v4 fails on write), `sdk`,
and the use-case evidence when you pass a `use-case evidence`. A top-level key whose value is `nil` is
omitted.

The four fields the server requires — `use_case`, `model`, `status`, `started_at` — are yours:
a missing one raises `PromptOn::InvalidRecordError` naming the field. `started_at` in particular is
never guessed, because the records you build by hand are exactly the ones whose provider call started
earlier than the call to `log` (a stream that has just finished, a background scorer, a replay).
`track` measures it for you.

| Field | Meaning |
|---|---|
| `id` | UUIDv7, generated by the app; the idempotency key, so a resend is a duplicate, never a second row |
| `use_case`, `kind` | which call site, and `chat` / `text` / `embedding` |
| `model`, `model_id`, `provider`, `model_used`, `upstream_provider` | what was requested and what actually answered |
| `deployment_id`, `deployment_revision`, `prompt`, `prompt_version_id` | the pin this call selected |
| `source` | `remote`, `disk`, `bundle` or `manual` — where the config came from |
| `status`, `error` | `ok` or `error`; `error.kind` is one of `http_4xx`, `http_5xx`, `rate_limited`, `timeout`, `transport`, `parse`, `app` |
| `started_at`, `latency_ms` | ISO 8601 with an offset; rejected if more than 5 minutes in the future or 7 days in the past |
| `params` | the params actually sent |
| `input` | `{variables, messages}` or `{text}` |
| `output` | `{content, tool_calls}` |
| `finish_reason`, `stop_kind` | the raw provider reason, and `stop` / `length` / `tool_call` / `content_filter` / `other` |
| `usage` | `{input_tokens, output_tokens, cost_usd, cost_source, raw}` |
| `trace_id`, `sequence`, `end_user_ref` | your correlation ids |
| `context`, `metadata` | free-form tags; keep them under 2 KB and 4 KB or the record is rejected |
| `sdk` | `{"name" => "prompton-ruby", "version" => "0.2.0"}` |

`PromptOn::StopKind.normalize(finish_reason)` is the same table the server uses. Only `length`
counts as truncated — `tool_calls` is not a truncation.

### Payload policy

Before a record leaves the process the SDK applies the use case's `payload_policy` from the
use-case document: the sampling decision (a pure function of the id, so a resend decides the same way, and
errors and `stop_kind: "length"` are always kept), then `none` / `hash` / `full`, then the 2 KB
cap on `error.message`, then `hash_end_user`, then your `redact` hook last. In `full` mode strings
are truncated head-and-tail on a UTF-8 boundary with a `…[truncated N bytes]…` marker, and every
map that lost bytes is flagged `"truncated" => true`.

**Do not log secrets**: no provider keys, no `PTN_API_KEY`, no user PII beyond `end_user_ref`.

## Testing your app

```ruby
# test setup
PromptOn.configure(mode: :test)
PromptOn.stub("diary_generation", model: "openai/gpt-4o-mini",
              messages: [{ "role" => "system", "content" => "You write diaries." },
                         { "role" => "user", "content" => "{{ text }}" }],
              params: { "temperature" => 0.5 })

# in a test
run_the_thing

record = PromptOn.logged.first
assert_equal "diary_generation", record["use_case"]
assert_equal "ok", record["status"]
```

In `mode: :test` there is no HTTP at all and every record is captured in `PromptOn.logged`
(`PromptOn.clear_logs` empties it). `PromptOn.put_use_case_document(hash_or_path)` installs a whole
document; `stub` builds a minimal one for a single use case and accumulates across calls.
In `mode: :offline` the SDK reads the disk cache and the bundle and never calls out, which is what
you want in CI.

## Errors

All of them are `PromptOn::Error`, each with a `code`:

`NotReadyError`, `UnknownUseCaseError`, `UnresolvedError`, `UnknownPromptError` (carries `prompt`
and `prompt_names`), `MissingVariableError` (carries `variable`), `TemplateSyntaxError`,
`TemplateRenderError`, `InvalidSnapshotError`, `UnsupportedSchemaVersionError`, `ApiError`
(carries `status`, `code` and `details`), `TransportError`, `InvalidRecordError`,
`ConfigurationError`.

## Development

```
bundle install
bundle exec rake test          # unit tests, the conformance suite, and the live test when PTN_API_KEY is set
bundle exec rubocop            # lint
```

`test/conformance/` is the cross-language contract every PromptOn SDK ships: template rendering,
use-case selection, monitoring-log truncation, `stop_kind` and golden records, with expected values. This
SDK reproduces every normative case. Two non-normative cases differ on purpose: this renderer
implements only the whitelisted filters (so `upcase` raises instead of being applied), and it
renders a hash in an output position with Ruby's `inspect` rather than Elixir's.

Point the live test at a running PromptOn:

```
PTN_HOST=http://localhost:4000 PTN_API_KEY=ptn_yourproject_… bundle exec rake test
```

## License

Copyright 2026 Polimo. Licensed under the Apache License, Version 2.0 — see [LICENSE](LICENSE).

PromptOn is a trademark of Polimo. The license does not grant permission to use the PromptOn name
or logo; forks and derived services must use a different name.
