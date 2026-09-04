# frozen_string_literal: true

require "time"
require_relative "params"
require_relative "result"
require_relative "stop_kind"
require_relative "uuid_v7"
require_relative "version"

module PromptOn
  # Returned from a track block to record a provider failure without raising.
  #
  #   PromptOn::Failure.new(kind: "rate_limited", status: 429, message: body,
  #                         result: { usage: { input_tokens: 38 } })
  #
  # The usage and output carried in +result+ are kept, which is what makes a parse failure
  # still readable as a quality signal.
  Failure = Struct.new(:kind, :status, :message, :result, keyword_init: true)

  # Builds the monitoring-log record and times the provider call.
  module LogBuilder
    ERROR_KINDS = %w[http_4xx http_5xx rate_limited timeout transport parse app].freeze
    RESULT_KEYS = %i[content tool_calls finish_reason stop_kind usage cost_usd cost_source
                     is_byok model_used upstream_provider input_tokens output_tokens].freeze

    module_function

    # Runs +block+, measures it, builds the record and hands it to +sink+.
    #
    # The block's return value decides the status: a Failure means "error", anything else means
    # "ok". An exception is logged as an error of kind "app" and then re-raised unchanged. The
    # return value of this method is always the block's own.
    def call(evidence, meta, sink)
      id = meta[:id] || UuidV7.generate
      started_at = Time.now.utc
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        result = yield
      rescue StandardError => e
        sink.call(build(evidence, meta, id: id, started_at: started_at,
                                        latency_ms: elapsed_ms(started), status: "error",
                                        result: nil, error: exception_failure(e)))
        raise
      end

      failure = result.is_a?(Failure) ? result : nil
      sink.call(build(evidence, meta, id: id, started_at: started_at,
                                      latency_ms: elapsed_ms(started),
                                      status: failure ? "error" : "ok",
                                      result: failure ? failure.result : result,
                                      error: failure))
      result
    end

    # Assembles one monitoring-log record from use-case evidence, call metadata and the result.
    def build(evidence, meta, id:, started_at:, latency_ms:, status:, result:, error:)
      result = normalize_result(result)
      usage = result[:usage] || {}

      record = {
        "id" => id,
        "use_case" => evidence&.use_case || meta[:use_case],
        "kind" => evidence&.kind || meta[:kind],
        "model" => result[:model] || evidence&.model || meta[:model],
        "model_id" => evidence&.model_id,
        "model_used" => result[:model_used],
        "provider" => evidence&.provider,
        "upstream_provider" => result[:upstream_provider],
        "deployment_id" => evidence&.deployment_id,
        "deployment_revision" => evidence&.deployment_revision,
        "prompt" => evidence&.prompt,
        "prompt_version_id" => evidence&.prompt_version_id,
        "source" => evidence&.source,
        "status" => status,
        "started_at" => iso8601(started_at),
        "latency_ms" => latency_ms,
        "finish_reason" => result[:finish_reason]&.to_s,
        "stop_kind" => stop_kind(result),
        "params" => Params.merge(evidence&.params, meta[:params]),
        "input" => build_input(meta),
        "output" => build_output(result),
        "error" => build_error(error),
        "usage" => {
          "input_tokens" => usage[:input_tokens] || result[:input_tokens],
          "output_tokens" => usage[:output_tokens] || result[:output_tokens],
          "cost_usd" => result[:cost_usd],
          "cost_source" => (result[:cost_source] || "unknown").to_s,
          "raw" => usage[:raw]
        },
        "trace_id" => meta[:trace_id]&.to_s,
        "sequence" => meta[:sequence],
        "end_user_ref" => meta[:end_user_ref]&.to_s,
        "context" => Params.stringify_keys(meta[:context] || {}),
        "metadata" => metadata(meta, result),
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

    def build_output(result)
      output = {}
      output["content"] = result[:content] unless result[:content].nil?
      output["tool_calls"] = result[:tool_calls] unless result[:tool_calls].nil?
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

    def metadata(meta, result)
      metadata = Params.stringify_keys(meta[:metadata] || {})
      metadata["is_byok"] = result[:is_byok] unless result[:is_byok].nil?
      metadata
    end

    def stop_kind(result)
      raw = result[:stop_kind] || result[:finish_reason]
      raw.nil? ? nil : StopKind.normalize(raw)
    end

    def exception_failure(error)
      return error if error.is_a?(Failure)

      Failure.new(kind: "app", message: "#{error.class}: #{error.message}")
    end

    def normalize_result(result)
      case result
      when String then { content: result }
      when Hash then symbolize(result).tap { |o| o[:usage] = symbolize(o[:usage]) if o[:usage].is_a?(Hash) }
      when Result then result.to_h
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
