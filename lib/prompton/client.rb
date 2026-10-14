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
require_relative "prompt_render_client"
require_relative "resolver"
require_relative "snapshot_poller"
require_relative "snapshot_store"
require_relative "prompt"
require_relative "uuid_v7"

module PromptOn
  # One configured PromptOn client: a prompt document store, a poller, a prompt endpoint
  # client and a monitoring-log buffer.
  #
  #   prompton = PromptOn::Client.new(api_key: ENV["PTN_API_KEY"])
  #   prompt = prompton.prompt("greeting", template: "ko")
  #   messages = prompt.messages(name: "Ada")
  #
  #   prompt.track(variables: { name: "Ada" }, input_messages: messages) do
  #     call_your_provider(prompt.model, messages, prompt.params)
  #   end
  #
  # Clients are safe to share between threads and hold background threads of their own; call
  # #close when you are done with one.
  class Client
    REQUIRED_RECORD_FIELDS = %w[prompt_key model status started_at].freeze
    CLOSED_TRANSPORT_MESSAGES = [
      "%Req.TransportError{reason: :closed}",
      "failed to send request: %Req.TransportError{reason: :closed}"
    ].freeze
    CLOSED_TRANSPORT_COMPLETION_OUTPUTS =
      (CLOSED_TRANSPORT_MESSAGES +
       ["failed to call LLM: failed to send request: %Req.TransportError{reason: :closed}"]).freeze

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
      clock = options.delete(:_clock)
      @config = config || Config.new(**options)
      @http = Http.new(@config)
      @store = SnapshotStore.new(@config)
      @poller = SnapshotPoller.new(@config, @store, @http, clock: clock)
      @prompt_render_client = PromptRenderClient.new(@config, @http)
      @buffer = LogBuffer.new(@config, @http)
      @captured = []
      @captured_events = []
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

    # --- prompts ----------------------------------------------------------

    # Selects a prompt against the cached document. Never makes an HTTP call within the cache
    # TTL, and never fails because PromptOn is unreachable while any tier holds a document.
    #
    # Raises PromptOn::UnknownPromptError, PromptOn::UnresolvedError,
    # PromptOn::UnknownPromptError, or PromptOn::NotReadyError when no tier has a document.
    def prompt(prompt_key, template: nil)
      entry = current_entry(prompt_key)
      evidence = Resolver.resolve(entry.data, prompt_key, template: template, source: entry.source, etag: entry.etag)
      Prompt.new(self, evidence)
    end

    # The template names the live deployment pins for a prompt, sorted.
    def template_names(prompt_key)
      Resolver.template_names(current_entry(prompt_key).data, prompt_key)
    end

    # Selects through the prompt endpoint instead of the document. The simple path and the smoke test.
    #
    # Passing +variables+ renders them locally into the returned prompt: #messages (chat) or
    # #text (text) come back rendered, not as the template.
    def remote_prompt(prompt_key, template: nil, environment: nil, variables: nil)
      evidence =
        @prompt_render_client.resolve(prompt_key, template: template, environment: environment,
                                                  variables: variables)
      Prompt.new(self, evidence)
    end

    # The raw prompt endpoint response. Passing +variables+ asks the server to render.
    def api_prompt(prompt_key, template: nil, environment: nil, variables: nil)
      @prompt_render_client.fetch(prompt_key, template: template, environment: environment, variables: variables)
    end

    # --- prompt document ---------------------------------------------------

    # The document every prompt selection reads, or nil when no tier has produced one.
    def prompt_document
      @store.data
    end

    # Where the current document came from and how old it is.
    def prompt_document_info
      @store.info
    end

    # Poll state: the last attempt, the consecutive failure count and how long the backoff or
    # Retry-After window still has to run.
    def prompt_document_status(prompt = nil)
      @poller.status(prompt)
    end

    # Fetches once, now, in the calling thread. Returns true on success; never raises.
    def refresh(prompt = nil)
      @poller.refresh(prompt)
    end

    # Fetches once, now, in the calling thread, and raises when it fails.
    def refresh!(prompt = nil)
      @poller.refresh!(prompt)
    end

    # Writes the current document to +path+ (plus a sidecar with its ETag) so it can be committed
    # as the app's bundled prompt document.
    def export_prompt_document(path)
      @store.export(path)
    end

    # --- monitoring logs -----------------------------------------------------

    # Enqueues one monitoring-log record the app built itself and returns immediately.
    #
    # The record can be a hash or inline fields:
    #
    #   client.log(record)
    #   client.log(prompt: "greeting", model: "openai/gpt-4o-mini", status: "ok",
    #              started_at: started_at, latency_ms: 842)
    #
    # Fills in id (UUIDv7) and sdk, and — when prompt evidence is passed — the deployment, prompt
    # and source evidence. The four fields the server requires (prompt, model,
    # status, started_at) are yours to supply: a missing one raises PromptOn::InvalidRecordError
    # rather than being guessed, because a record built after the fact — a stream that has just
    # finished, a background scorer, a replay — must carry the time the provider call really
    # started. #track measures started_at for you.
    def log(record = nil, prompt_evidence: nil, environment: nil, **fields)
      prepared = prepare_record(Params.deep_stringify(record || {}).merge(Params.deep_stringify(fields)),
                                unwrap_evidence(prompt_evidence))
      return nil if prepared.nil?

      if @config.test?
        @capture_mutex.synchronize { @captured << prepared }
      elsif @config.remote?
        @buffer.enqueue(prepared, environment: environment || @config.environment)
      else
        discard_log
      end

      prepared
    end

    # Submits application-observed trace events immediately.
    #
    # The SDK never infers tool execution from model requests. Pass the tool/completion events
    # your app observed; each event must already carry its stable event_id and trace_id.
    def log_events(events, environment: nil)
      prepared = prepare_trace_events(events).reject { |event| closed_transport_completion?(event) }
      if @config.test?
        @capture_mutex.synchronize { @captured_events.concat(prepared) }
        return { accepted: prepared.length, duplicates: 0, rejected: [] }
      end
      return { accepted: 0, duplicates: 0, rejected: [] } if prepared.empty?
      return { accepted: 0, duplicates: 0, rejected: [] } unless @config.remote?

      response = @http.post_trace_events(prepared, environment: environment || @config.environment)
      unless response.success?
        raise ApiError.new(response.status, response.body,
                           retry_after: response.retry_after_seconds)
      end

      counters = if response.body.is_a?(Hash) && response.body["events"].is_a?(Hash)
                   response.body["events"]
                 else
                   response.body
                 end
      { accepted: counters.is_a?(Hash) ? counters.fetch("accepted", 0).to_i : 0,
        duplicates: counters.is_a?(Hash) ? counters.fetch("duplicates", 0).to_i : 0,
        rejected: counters.is_a?(Hash) && counters["rejected"].is_a?(Array) ? counters["rejected"] : [] }
    end

    # Times a provider call, builds the record and enqueues it.
    #
    # The block's return value comes back unchanged. Return a PromptOn::Failure to record a
    # provider error without raising; an exception is logged as an error of kind "app" and then
    # re-raised as it was.
    def track_prompt(evidence, **meta, &)
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

    # The trace events captured in test mode, in order.
    def logged_events
      @capture_mutex.synchronize { @captured_events.dup }
    end

    def clear_logs
      @capture_mutex.synchronize do
        @captured.clear
        @captured_events.clear
      end
    end

    # Installs a prompt document directly: a Hash, a JSON string, or a path to a JSON file.
    def put_prompt_document(document, source: "manual")
      document = read_document(document) if document.is_a?(String)
      @stub_document = document.is_a?(Hash) ? Params.deep_stringify(document) : nil
      @store.install_document(document, source: source)
    end

    # Builds a minimal document entry for one prompt and merges it into the current one, so a
    # test can stub exactly the call site it exercises.
    def stub(prompt_key, model:, messages: nil, text: nil, kind: "chat", template: "default",
             params: {}, provider_options: {}, default_params: {}, provider: "openrouter",
             payload_policy: nil, engine: "liquid", revision: "v2026.09.30-1")
      key = prompt_key.to_s
      raise ArgumentError, "stub only supports the default template" unless template.to_s == "default"

      document = @stub_document || base_stub_document
      version_number = 1
      version_id = "#{key}@#{version_number}"
      model_key = "#{provider}:#{model}"
      existing = document.dig("deployments", key) || {}

      unless kind.to_s == "embedding"
        document["prompt_versions"][version_id] = {
          "prompt" => key, "number" => version_number, "kind" => kind.to_s, "engine" => engine,
          "messages" => messages ? Params.deep_stringify(messages) : [], "text_template" => text
        }
      end

      # Calling stub again for the same prompt replaces the current prompt version while keeping
      # merged params/provider options from earlier stubs.
      document["prompts"][key] = {
        "kind" => kind.to_s, "variables" => [],
        "default_params" => merged(document.dig("prompts", key, "default_params"), default_params),
        "payload_policy" => payload_policy || document.dig("prompts", key, "payload_policy")
      }
      deployment = {
        "revision" => revision, "provider" => provider.to_s, "model" => model.to_s,
        "params" => merged(existing["params"], params),
        "provider_options" => merged(existing["provider_options"], provider_options)
      }
      deployment["prompt_version"] = version_number unless kind.to_s == "embedding"
      document["deployments"][key] = deployment
      document["models"][model_key] = {
        "provider" => provider.to_s, "model" => model.to_s,
        "display_name" => model.to_s, "metadata" => {}, "provider_options" => {}, "capabilities" => []
      }

      put_prompt_document(document, source: "manual")
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
      { "schema_version" => 1, "project" => @config.project,
        "environment" => @config.environment, "prompts" => {}, "deployments" => {},
        "prompt_versions" => {}, "models" => {} }
    end

    # A monitoring log must never be the reason a provider call fails, so the wrapper swallows what
    # log would raise and says so once per record instead.
    def safe_log(record, evidence, environment)
      log(record, prompt_evidence: evidence, environment: environment)
    rescue StandardError => e
      @config.logger.warn("[PromptOn] could not record the monitoring log: #{e.class}: #{e.message}")
      nil
    end

    def current_entry(prompt_key)
      @store.load_local if @store.entry.nil?
      @poller.ensure_prompt(prompt_key)
      prompt_entry = @store.prompt_entry(prompt_key)
      raise NotReadyError if prompt_entry.nil?

      prompt_entry
    end

    def prepare_trace_events(events)
      raise InvalidRecordError, "events" unless events.is_a?(Array)
      raise InvalidRecordError, "events" if events.length > 500

      events.map do |event|
        raise InvalidRecordError, "event" unless event.is_a?(Hash)

        prepared = Params.deep_stringify(event)
        prepared["sdk"] =
          { "name" => SDK_NAME, "version" => VERSION }.merge(prepared["sdk"].is_a?(Hash) ? prepared["sdk"] : {})
        prepared
      end
    end

    def prepare_record(record, evidence)
      prepared = Params.deep_stringify(record)
      prepared["prompt_key"] ||= prepared["prompt"] if prepared["prompt"]
      prepared["id"] ||= UuidV7.generate
      prepared["sdk"] ||= { "name" => SDK_NAME, "version" => VERSION }
      merge_prompt(prepared, evidence) if evidence

      REQUIRED_RECORD_FIELDS.each do |field|
        raise InvalidRecordError, field if prepared[field].nil?
      end

      return nil if closed_transport_log?(prepared)

      Payload.strip_retired_resource_fields(
        Payload.apply(prepared, policy_for(prepared, evidence), **payload_config)
      )
    end

    def closed_transport_log?(record)
      error = record["error"]
      error.is_a?(Hash) &&
        record["status"] == "error" &&
        error["kind"] == "transport" &&
        CLOSED_TRANSPORT_MESSAGES.include?(error["message"])
    end

    def closed_transport_completion?(event)
      event["event_kind"] == "completion" &&
        event["status"] == "error" &&
        CLOSED_TRANSPORT_COMPLETION_OUTPUTS.include?(event["completion_output"])
    end

    def merge_prompt(record, evidence)
      { "prompt_key" => evidence.prompt, "kind" => evidence.kind, "model" => evidence.model,
        "provider" => evidence.provider,
        "deployment_revision" => evidence.deployment_revision, "template" => evidence.template,
        "prompt_version_number" => evidence.prompt_version_number,
        "source" => evidence.source }.each do |key, value|
        record[key] = value if record[key].nil? && !value.nil?
      end
      return unless record["params"] || !evidence.params.empty?

      record["params"] =
        Params.merge(evidence.params, record["params"])
    end

    def policy_for(record, evidence)
      return evidence.payload_policy if evidence&.payload_policy

      prompt_document&.prompt(record["prompt_key"] || record["prompt"])&.payload_policy
    end

    def unwrap_evidence(value)
      value.is_a?(Prompt) ? value.__send__(:evidence) : value
    end

    def payload_config
      { payload_defaults: @config.payload_defaults, hash_end_user: @config.hash_end_user,
        redact: @config.redact, logger: @config.logger }
    end

    def announce_disk_only_mode
      return unless @config.mode == :live && @config.api_key.nil?

      @config.logger.warn(
        "[PromptOn] no API key configured (set PTN_API_KEY or pass api_key:); running on the " \
        "disk cache and the bundled prompt document only, with no remote calls and no monitoring logs"
      )
    end

    def install_exit_hook
      return unless @config.flush_on_exit && !@config.test?

      Client.register_for_exit(self)
    end
  end
end
