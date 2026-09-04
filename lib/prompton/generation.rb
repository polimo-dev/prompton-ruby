# frozen_string_literal: true

require "time"
require_relative "params"
require_relative "stop_kind"
require_relative "uuid_v7"
require_relative "version"

module PromptOn
  # Returned from a with_generation block to record a provider failure without raising.
  #
  #   PromptOn::Failure.new(kind: "rate_limited", status: 429, message: body,
  #                         outcome: { usage: { input_tokens: 38 } })
  #
  # The usage and output carried in +outcome+ are kept, which is what makes a parse failure
  # still readable as a quality signal.
  Failure = Struct.new(:kind, :status, :message, :outcome, keyword_init: true)

  # Builds the monitoring-log record and times the provider call.
  module Generation
    ERROR_KINDS = %w[http_4xx http_5xx rate_limited timeout transport parse app].freeze
    OUTCOME_KEYS = %i[content tool_calls finish_reason stop_kind usage cost_usd cost_source
                      is_byok model_used upstream_provider input_tokens output_tokens].freeze

    module_function

    # Runs +block+, measures it, builds the record and hands it to +sink+.
    #
    # The block's return value decides the status: a Failure means "error", anything else means
    # "ok". An exception is logged as an error of kind "app" and then re-raised unchanged. The
    # return value of this method is always the block's own.
    def call(resolution, meta, sink)
      id = meta[:id] || UuidV7.generate
      started_at = Time.now.utc
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        result = yield
      rescue StandardError => e
        sink.call(build(resolution, meta, id: id, started_at: started_at,
                                          latency_ms: elapsed_ms(started), status: "error",
                                          outcome: nil, error: exception_failure(e)))
        raise
      end

      failure = result.is_a?(Failure) ? result : nil
      sink.call(build(resolution, meta, id: id, started_at: started_at,
                                        latency_ms: elapsed_ms(started),
                                        status: failure ? "error" : "ok",
                                        outcome: failure ? failure.outcome : result,
                                        error: failure))
      result
    end

    # Assembles one monitoring-log record from a Resolution, the call metadata and the outcome.
    def build(resolution, meta, id:, started_at:, latency_ms:, status:, outcome:, error:)
      outcome = normalize_outcome(outcome)
      usage = outcome[:usage] || {}

      record = {
        "id" => id,
        "use_case" => resolution&.use_case || meta[:use_case],
        "kind" => resolution&.kind || meta[:kind],
        "model" => outcome[:model] || resolution&.model || meta[:model],
        "model_id" => resolution&.model_id,
        "model_used" => outcome[:model_used],
        "provider" => resolution&.provider,
        "upstream_provider" => outcome[:upstream_provider],
        "deployment_id" => resolution&.deployment_id,
        "deployment_revision" => resolution&.deployment_revision,
        "prompt" => resolution&.prompt,
        "prompt_version_id" => resolution&.prompt_version_id,
        "resolution_source" => resolution&.source,
        "status" => status,
        "started_at" => iso8601(started_at),
        "latency_ms" => latency_ms,
        "finish_reason" => outcome[:finish_reason]&.to_s,
        "stop_kind" => stop_kind(outcome),
        "params" => Params.merge(resolution&.params, meta[:params]),
        "input" => build_input(meta),
        "output" => build_output(outcome),
        "error" => build_error(error),
        "usage" => {
          "input_tokens" => usage[:input_tokens] || outcome[:input_tokens],
          "output_tokens" => usage[:output_tokens] || outcome[:output_tokens],
          "cost_usd" => outcome[:cost_usd],
          "cost_source" => (outcome[:cost_source] || "unknown").to_s,
          "raw" => usage[:raw]
        },
        "trace_id" => meta[:trace_id]&.to_s,
        "sequence" => meta[:sequence],
        "end_user_ref" => meta[:end_user_ref]&.to_s,
        "context" => Params.stringify_keys(meta[:context] || {}),
        "metadata" => metadata(meta, outcome),
        "sdk" => { "name" => SDK_NAME, "version" => VERSION }
      }

      record.compact
    end

    def build_input(meta)
      input = {}
      input["variables"] = Params.stringify_keys(meta[:variables]) if meta[:variables]
      input["messages"] = meta[:input_messages] if meta[:input_messages]
      input["text"] = meta[:input_text] if meta[:input_text]
      input.empty? ? nil : input
    end

    def build_output(outcome)
      output = {}
      output["content"] = outcome[:content] unless outcome[:content].nil?
      output["tool_calls"] = outcome[:tool_calls] unless outcome[:tool_calls].nil?
      output.empty? ? nil : output
    end

    def build_error(failure)
      return nil if failure.nil?

      kind = failure.kind.to_s
      error = { "kind" => ERROR_KINDS.include?(kind) ? kind : "app" }
      error["status"] = failure.status if failure.status.is_a?(Integer)
      error["message"] = failure.message.to_s unless failure.message.nil?
      error
    end

    def metadata(meta, outcome)
      metadata = Params.stringify_keys(meta[:metadata] || {})
      metadata["is_byok"] = outcome[:is_byok] unless outcome[:is_byok].nil?
      metadata
    end

    def stop_kind(outcome)
      raw = outcome[:stop_kind] || outcome[:finish_reason]
      raw.nil? ? nil : StopKind.normalize(raw)
    end

    def exception_failure(error)
      return error if error.is_a?(Failure)

      Failure.new(kind: "app", message: "#{error.class}: #{error.message}")
    end

    def normalize_outcome(outcome)
      case outcome
      when String then { content: outcome }
      when Hash then symbolize(outcome).tap { |o| o[:usage] = symbolize(o[:usage]) if o[:usage].is_a?(Hash) }
      else {}
      end
    end

    def symbolize(hash)
      hash.each_with_object({}) { |(key, value), acc| acc[key.to_sym] = value }
    end

    def iso8601(time)
      time.utc.iso8601(6)
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end
  end
end
