# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "config"
require_relative "errors"
require_relative "generation"
require_relative "http"
require_relative "log_buffer"
require_relative "params"
require_relative "payload"
require_relative "resolve_client"
require_relative "resolver"
require_relative "snapshot_poller"
require_relative "snapshot_store"
require_relative "uuid_v7"

module PromptOn
  # One configured PromptOn client: a snapshot store, a poller, a /resolve client and a
  # monitoring-log buffer.
  #
  #   prompton = PromptOn::Client.new(api_key: ENV["PTN_API_KEY"])
  #   resolution = prompton.resolve("greeting", prompt: "ko")
  #   messages = resolution.render(name: "Ada")
  #
  #   prompton.with_generation(resolution, variables: { name: "Ada" }, input_messages: messages) do
  #     call_your_provider(resolution.model, messages, resolution.params)
  #   end
  #
  # Clients are safe to share between threads and hold background threads of their own; call
  # #close when you are done with one.
  class Client
    REQUIRED_RECORD_FIELDS = %w[use_case model status started_at].freeze

    attr_reader :config

    def initialize(config = nil, **options)
      @config = config || Config.new(**options)
      @http = Http.new(@config)
      @store = SnapshotStore.new(@config)
      @poller = SnapshotPoller.new(@config, @store, @http)
      @resolve_client = ResolveClient.new(@config, @http)
      @buffer = LogBuffer.new(@config, @http)
      @captured = []
      @capture_mutex = Mutex.new
      @stub_document = nil
      @discarded_logs = 0

      announce_disk_only_mode
      unless @config.test?
        @store.load_local
        @poller.start
      end
      @buffer.start if @config.remote?
      install_exit_hook
    end

    # --- resolution ----------------------------------------------------------

    # Resolves a use case against the cached snapshot. Never makes an HTTP call within the cache
    # TTL, and never fails because PromptOn is unreachable while any tier holds a document.
    #
    # Raises PromptOn::UnknownUseCaseError, PromptOn::UnresolvedError,
    # PromptOn::UnknownPromptError, or PromptOn::NotReadyError when no tier has a document.
    def resolve(use_case, prompt: nil)
      entry = current_entry
      @poller.ensure_fresh
      Resolver.resolve(entry.data, use_case, prompt: prompt, source: entry.source, etag: entry.etag)
    end

    # The prompt names the live deployment pins for a use case, sorted.
    def prompt_names(use_case)
      Resolver.prompt_names(current_entry.data, use_case)
    end

    # Renders a resolution's prompt with this call's variables.
    def render(resolution, variables = {})
      resolution.render(variables)
    end

    # Resolves through POST /resolve instead of the snapshot. The simple path and the smoke test.
    def remote_resolve(use_case, prompt: nil, environment: nil, variables: nil)
      @resolve_client.resolve(use_case, prompt: prompt, environment: environment, variables: variables)
    end

    # The raw POST /resolve response. Passing +variables+ asks the server to render.
    def api_resolve(use_case, prompt: nil, environment: nil, variables: nil)
      @resolve_client.fetch(use_case, prompt: prompt, environment: environment, variables: variables)
    end

    # --- snapshot ------------------------------------------------------------

    # The document every resolve reads, or nil when no tier has produced one.
    def snapshot
      @store.data
    end

    # Where the current document came from and how old it is.
    def snapshot_info
      @store.info
    end

    # Poll state: the last attempt, the consecutive failure count and how long the backoff or
    # Retry-After window still has to run.
    def snapshot_status
      @poller.status
    end

    # Fetches once, now, in the calling thread. Returns true on success; never raises.
    def refresh
      @poller.refresh
    end

    # Fetches once, now, in the calling thread, and raises when it fails.
    def refresh!
      @poller.refresh!
    end

    # Writes the current document to +path+ (plus a sidecar with its ETag) so it can be committed
    # as the app's bundled snapshot.
    def export_snapshot(path)
      @store.export(path)
    end

    # --- monitoring logs -----------------------------------------------------

    # Enqueues one monitoring-log record the app built itself and returns immediately.
    #
    # The record can be a hash or inline fields:
    #
    #   client.log(record)
    #   client.log(use_case: "greeting", model: "openai/gpt-4o-mini", status: "ok",
    #              started_at: started_at, latency_ms: 842)
    #
    # Fills in id (UUIDv7), started_at and sdk, and — when a Resolution is passed — the
    # deployment, prompt and resolution_source evidence. Raises PromptOn::InvalidRecordError when
    # a field the server requires is missing.
    def log(record = nil, resolution: nil, environment: nil, **fields)
      prepared = prepare_record(Params.deep_stringify(record || {}).merge(Params.deep_stringify(fields)),
                                resolution)

      if @config.test?
        @capture_mutex.synchronize { @captured << prepared }
      elsif @config.remote?
        @buffer.enqueue(prepared, environment: environment || @config.environment)
      else
        discard_log
      end

      prepared
    end

    # Times a provider call, builds the record and enqueues it.
    #
    # The block's return value comes back unchanged. Return a PromptOn::Failure to record a
    # provider error without raising; an exception is logged as an error of kind "app" and then
    # re-raised as it was.
    def with_generation(resolution, **meta, &)
      sink = ->(record) { safe_log(record, resolution, meta[:environment]) }
      Generation.call(resolution, meta, sink, &)
    end

    # A UUIDv7 to use as a monitoring-log id, issued up front so the app can store it too.
    def generation_id
      UuidV7.generate
    end

    # Sends everything queued now and waits for the result.
    def flush(timeout: 5.0)
      return { captured: logged.length } if @config.test?
      return { discarded: @discarded_logs } unless @config.remote?

      @buffer.flush(timeout: timeout)
    end

    def log_stats
      return { captured: logged.length } if @config.test?
      return { discarded: @discarded_logs } unless @config.remote?

      @buffer.stats
    end

    # --- test mode -----------------------------------------------------------

    # The records captured in test mode, in order.
    def logged
      @capture_mutex.synchronize { @captured.dup }
    end

    def clear_logs
      @capture_mutex.synchronize { @captured.clear }
    end

    # Installs a snapshot document directly: a Hash, a JSON string, or a path to a JSON file.
    def put_snapshot(document, source: "manual")
      document = read_document(document) if document.is_a?(String)
      @stub_document = document.is_a?(Hash) ? Params.deep_stringify(document) : nil
      @store.install_document(document, source: source)
    end

    # Builds a minimal snapshot entry for one use case and merges it into the current one, so a
    # test can stub exactly the call site it exercises.
    def stub(use_case, model:, messages: nil, text: nil, kind: "chat", prompt: "default",
             params: {}, provider_options: {}, default_params: {}, provider: "openrouter",
             payload_policy: nil, engine: "liquid", revision: 1)
      key = use_case.to_s
      document = @stub_document || base_stub_document
      version_id = stub_id("version", key, prompt)
      model_id = stub_id("model", key)
      existing = document.dig("deployments", key) || {}
      pins = existing["prompt_pins"] || {}

      unless kind.to_s == "embedding"
        pins = pins.merge(prompt.to_s => version_id)
        document["prompt_versions"][version_id] = {
          "id" => version_id, "number" => 1, "engine" => engine,
          "messages" => messages ? Params.deep_stringify(messages) : [], "text_template" => text
        }
      end

      # Calling stub again for the same use case adds a pin rather than resetting the rest, so a
      # second call that only names another prompt keeps the params the first one set.
      document["use_cases"][key] = {
        "id" => stub_id("use_case", key), "kind" => kind.to_s, "input_schema" => [],
        "default_params" => merged(document.dig("use_cases", key, "default_params"), default_params),
        "payload_policy" => payload_policy || document.dig("use_cases", key, "payload_policy")
      }
      document["deployments"][key] = {
        "id" => stub_id("deployment", key), "revision" => revision, "model_id" => model_id,
        "params" => merged(existing["params"], params),
        "provider_options" => merged(existing["provider_options"], provider_options),
        "prompt_pins" => pins
      }
      document["models"][model_id] = {
        "id" => model_id, "provider" => provider.to_s, "model_id" => model.to_s,
        "display_name" => model.to_s, "metadata" => {}, "provider_options" => {}, "capabilities" => []
      }

      put_snapshot(document, source: "manual")
    end

    # --- lifecycle -----------------------------------------------------------

    # Stops the background threads after a last best-effort flush.
    def close(timeout: 5.0)
      @poller.stop
      @buffer.stop(timeout: timeout) unless @config.test?
      self
    end

    private

    # A deterministic UUIDv7-shaped id, so stubbed records pass the server's id validation and a
    # test that runs twice sees the same ids.
    def stub_id(*parts)
      hex = Digest::SHA256.hexdigest(parts.join(":"))
      "#{hex[0, 8]}-#{hex[8, 4]}-7#{hex[13, 3]}-8#{hex[17, 3]}-#{hex[20, 12]}"
    end

    def merged(existing, given)
      Params.merge(existing, given)
    end

    def read_document(value)
      value.lstrip.start_with?("{") ? JSON.parse(value) : JSON.parse(File.read(value))
    end

    def discard_log
      @discarded_logs += 1
      return unless @discarded_logs == 1

      @config.logger.warn("[PromptOn] monitoring logs are not being sent: " \
                          "#{@config.mode == :offline ? "offline mode" : "no API key configured"}")
    end

    def base_stub_document
      { "schema_version" => SnapshotData::SCHEMA_VERSION, "project" => @config.project,
        "environment" => @config.environment, "use_cases" => {}, "deployments" => {},
        "prompt_versions" => {}, "models" => {} }
    end

    # A monitoring log must never be the reason a generation fails, so the wrapper swallows what
    # log would raise and says so once per record instead.
    def safe_log(record, resolution, environment)
      log(record, resolution: resolution, environment: environment)
    rescue StandardError => e
      @config.logger.warn("[PromptOn] could not record the monitoring log: #{e.class}: #{e.message}")
      nil
    end

    def current_entry
      entry = @store.entry || @store.load_local
      entry ||= @store.entry if @poller.ensure_document
      raise NotReadyError if entry.nil?

      entry
    end

    def prepare_record(record, resolution)
      prepared = Params.deep_stringify(record)
      prepared["id"] ||= UuidV7.generate
      prepared["started_at"] ||= Time.now.utc.iso8601(6)
      prepared["sdk"] ||= { "name" => SDK_NAME, "version" => VERSION }
      merge_resolution(prepared, resolution) if resolution

      REQUIRED_RECORD_FIELDS.each do |field|
        raise InvalidRecordError, field if prepared[field].nil?
      end

      Payload.apply(prepared, policy_for(prepared, resolution), **payload_config)
    end

    def merge_resolution(record, resolution)
      { "use_case" => resolution.use_case, "kind" => resolution.kind, "model" => resolution.model,
        "model_id" => resolution.model_id, "provider" => resolution.provider,
        "deployment_id" => resolution.deployment_id,
        "deployment_revision" => resolution.deployment_revision, "prompt" => resolution.prompt,
        "prompt_version_id" => resolution.prompt_version_id,
        "resolution_source" => resolution.source }.each do |key, value|
        record[key] = value if record[key].nil? && !value.nil?
      end
      return unless record["params"] || !resolution.params.empty?

      record["params"] =
        Params.merge(resolution.params, record["params"])
    end

    def policy_for(record, resolution)
      return resolution.payload_policy if resolution&.payload_policy

      snapshot&.use_case(record["use_case"])&.payload_policy
    end

    def payload_config
      { payload_defaults: @config.payload_defaults, hash_end_user: @config.hash_end_user,
        redact: @config.redact, logger: @config.logger }
    end

    def announce_disk_only_mode
      return unless @config.mode == :live && @config.api_key.nil?

      @config.logger.warn(
        "[PromptOn] no API key configured (set PTN_API_KEY or pass api_key:); running on the " \
        "disk cache and the bundled snapshot only, with no remote calls and no monitoring logs"
      )
    end

    def install_exit_hook
      return unless @config.flush_on_exit && !@config.test?

      at_exit do
        close(timeout: 2.0)
      rescue StandardError
        nil
      end
    end
  end
end
