# frozen_string_literal: true

require "digest"
require "json"
require "time"
require_relative "config"
require_relative "errors"
require_relative "log_builder"
require_relative "http"
require_relative "log_buffer"
require_relative "params"
require_relative "payload"
require_relative "use_case_prompt_client"
require_relative "resolver"
require_relative "snapshot_poller"
require_relative "snapshot_store"
require_relative "use_case"
require_relative "uuid_v7"

module PromptOn
  # One configured PromptOn client: a use-case document store, a poller, a prompt endpoint
  # client and a monitoring-log buffer.
  #
  #   prompton = PromptOn::Client.new(api_key: ENV["PTN_API_KEY"])
  #   use_case = prompton.use_case("greeting", prompt: "ko")
  #   messages = use_case.messages(name: "Ada")
  #
  #   use_case.track(variables: { name: "Ada" }, input_messages: messages) do
  #     call_your_provider(use_case.model, messages, use_case.params)
  #   end
  #
  # Clients are safe to share between threads and hold background threads of their own; call
  # #close when you are done with one.
  class Client
    REQUIRED_RECORD_FIELDS = %w[use_case model status started_at].freeze

    # Ruby cannot unregister an at_exit block, so there is exactly one for the whole process and
    # it drains a registry of clients held weakly: a client that goes out of scope is collected
    # with its queued records instead of living until exit. #close takes a client out of the
    # drain without needing the registry to support deletion (WeakMap#delete is Ruby 3.3+).
    @exit_registry = ObjectSpace::WeakMap.new
    @exit_registry_mutex = Mutex.new
    @exit_hook_installed = false

    class << self
      def register_for_exit(client)
        @exit_registry_mutex.synchronize do
          @exit_registry[client] = client
          next if @exit_hook_installed

          @exit_hook_installed = true
          at_exit { PromptOn::Client.drain_at_exit }
        end
        client
      end

      # The clients that would be drained if the process exited now.
      def open_at_exit
        @exit_registry_mutex.synchronize { @exit_registry.keys }.reject(&:closed?)
      end

      def drain_at_exit(timeout: 2.0)
        open_at_exit.each do |client|
          client.close(timeout: timeout)
        rescue StandardError
          nil
        end
      end
    end

    attr_reader :config

    def initialize(config = nil, **options)
      @config = config || Config.new(**options)
      @http = Http.new(@config)
      @store = SnapshotStore.new(@config)
      @poller = SnapshotPoller.new(@config, @store, @http)
      @use_case_prompt_client = UseCasePromptClient.new(@config, @http)
      @buffer = LogBuffer.new(@config, @http)
      @captured = []
      @capture_mutex = Mutex.new
      @stub_document = nil
      @discarded_logs = 0
      @closed = false

      announce_disk_only_mode
      unless @config.test?
        @store.load_local
        @poller.start
      end
      @buffer.start if @config.remote?
      install_exit_hook
    end

    # --- use cases ----------------------------------------------------------

    # Selects a use case against the cached document. Never makes an HTTP call within the cache
    # TTL, and never fails because PromptOn is unreachable while any tier holds a document.
    #
    # Raises PromptOn::UnknownUseCaseError, PromptOn::UnresolvedError,
    # PromptOn::UnknownPromptError, or PromptOn::NotReadyError when no tier has a document.
    def use_case(use_case, prompt: nil)
      entry = current_entry
      @poller.ensure_fresh
      UseCase.new(self, Resolver.resolve(entry.data, use_case, prompt: prompt, source: entry.source, etag: entry.etag))
    end

    # The prompt names the live deployment pins for a use case, sorted.
    def prompt_names(use_case)
      Resolver.prompt_names(current_entry.data, use_case)
    end

    # Selects through the prompt endpoint instead of the document. The simple path and the smoke test.
    #
    # Passing +variables+ renders them locally into the returned use case: #messages (chat) or
    # #text (text) come back rendered, not as the template.
    def remote_use_case(use_case, prompt: nil, environment: nil, variables: nil)
      evidence =
        @use_case_prompt_client.resolve(use_case, prompt: prompt, environment: environment,
                                                  variables: variables)
      UseCase.new(self, evidence)
    end

    # The raw prompt endpoint response. Passing +variables+ asks the server to render.
    def api_use_case(use_case, prompt: nil, environment: nil, variables: nil)
      @use_case_prompt_client.fetch(use_case, prompt: prompt, environment: environment, variables: variables)
    end

    # --- use-case document ---------------------------------------------------

    # The document every use-case selection reads, or nil when no tier has produced one.
    def use_case_document
      @store.data
    end

    # Where the current document came from and how old it is.
    def use_case_document_info
      @store.info
    end

    # Poll state: the last attempt, the consecutive failure count and how long the backoff or
    # Retry-After window still has to run.
    def use_case_document_status
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
    # as the app's bundled use-case document.
    def export_use_case_document(path)
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
    # Fills in id (UUIDv7) and sdk, and — when use-case evidence is passed — the deployment, prompt
    # and source evidence. The four fields the server requires (use_case, model,
    # status, started_at) are yours to supply: a missing one raises PromptOn::InvalidRecordError
    # rather than being guessed, because a record built after the fact — a stream that has just
    # finished, a background scorer, a replay — must carry the time the provider call really
    # started. #track measures started_at for you.
    def log(record = nil, use_case_evidence: nil, environment: nil, **fields)
      prepared = prepare_record(Params.deep_stringify(record || {}).merge(Params.deep_stringify(fields)),
                                unwrap_evidence(use_case_evidence))

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
    def track_use_case(evidence, **meta, &)
      sink = ->(record) { safe_log(record, evidence, meta[:environment]) }
      LogBuilder.call(evidence, meta, sink, &)
    end

    # A UUIDv7 to use as a monitoring-log id, issued up front so the app can store it too.
    def log_id
      UuidV7.generate
    end

    # Sends everything queued now and waits for the result.
    def flush(timeout: 5.0)
      return { captured: logged.length } if @config.test?
      return { discarded: discarded_logs } unless @config.remote?

      @buffer.flush(timeout: timeout)
    end

    def log_stats
      return { captured: logged.length } if @config.test?
      return { discarded: discarded_logs } unless @config.remote?

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

    # Installs a use-case document directly: a Hash, a JSON string, or a path to a JSON file.
    def put_use_case_document(document, source: "manual")
      document = read_document(document) if document.is_a?(String)
      @stub_document = document.is_a?(Hash) ? Params.deep_stringify(document) : nil
      @store.install_document(document, source: source)
    end

    # Builds a minimal document entry for one use case and merges it into the current one, so a
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

      put_use_case_document(document, source: "manual")
    end

    # --- lifecycle -----------------------------------------------------------

    # Stops the background threads after a last best-effort flush, and takes this client out of
    # the process-wide exit drain.
    def close(timeout: 5.0)
      @capture_mutex.synchronize { @closed = true }
      @poller.stop
      @buffer.stop(timeout: timeout) unless @config.test?
      self
    end

    def closed?
      @capture_mutex.synchronize { @closed }
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

    def discarded_logs
      @capture_mutex.synchronize { @discarded_logs }
    end

    def discard_log
      discarded = @capture_mutex.synchronize { @discarded_logs += 1 }
      return unless discarded == 1

      @config.logger.warn("[PromptOn] monitoring logs are not being sent: " \
                          "#{@config.mode == :offline ? "offline mode" : "no API key configured"}")
    end

    def base_stub_document
      { "schema_version" => UseCaseDocument::SCHEMA_VERSION, "project" => @config.project,
        "environment" => @config.environment, "use_cases" => {}, "deployments" => {},
        "prompt_versions" => {}, "models" => {} }
    end

    # A monitoring log must never be the reason a provider call fails, so the wrapper swallows what
    # log would raise and says so once per record instead.
    def safe_log(record, evidence, environment)
      log(record, use_case_evidence: evidence, environment: environment)
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

    def prepare_record(record, evidence)
      prepared = Params.deep_stringify(record)
      prepared["id"] ||= UuidV7.generate
      prepared["sdk"] ||= { "name" => SDK_NAME, "version" => VERSION }
      merge_use_case(prepared, evidence) if evidence

      REQUIRED_RECORD_FIELDS.each do |field|
        raise InvalidRecordError, field if prepared[field].nil?
      end

      Payload.apply(prepared, policy_for(prepared, evidence), **payload_config)
    end

    def merge_use_case(record, evidence)
      { "use_case" => evidence.use_case, "kind" => evidence.kind, "model" => evidence.model,
        "model_id" => evidence.model_id, "provider" => evidence.provider,
        "deployment_id" => evidence.deployment_id,
        "deployment_revision" => evidence.deployment_revision, "prompt" => evidence.prompt,
        "prompt_version_id" => evidence.prompt_version_id,
        "source" => evidence.source }.each do |key, value|
        record[key] = value if record[key].nil? && !value.nil?
      end
      return unless record["params"] || !evidence.params.empty?

      record["params"] =
        Params.merge(evidence.params, record["params"])
    end

    def policy_for(record, evidence)
      return evidence.payload_policy if evidence&.payload_policy

      use_case_document&.use_case(record["use_case"])&.payload_policy
    end

    def unwrap_evidence(value)
      value.is_a?(UseCase) ? value.__send__(:evidence) : value
    end

    def payload_config
      { payload_defaults: @config.payload_defaults, hash_end_user: @config.hash_end_user,
        redact: @config.redact, logger: @config.logger }
    end

    def announce_disk_only_mode
      return unless @config.mode == :live && @config.api_key.nil?

      @config.logger.warn(
        "[PromptOn] no API key configured (set PTN_API_KEY or pass api_key:); running on the " \
        "disk cache and the bundled use-case document only, with no remote calls and no monitoring logs"
      )
    end

    def install_exit_hook
      return unless @config.flush_on_exit && !@config.test?

      Client.register_for_exit(self)
    end
  end
end
