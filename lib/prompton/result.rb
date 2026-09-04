# frozen_string_literal: true

require "json"

module PromptOn
  # Normalized provider result metadata for monitoring logs.
  class Result
    attr_reader :content, :tool_calls, :finish_reason, :stop_kind, :usage, :cost_usd,
                :cost_source, :is_byok, :model_used, :upstream_provider

    def initialize(content: nil, tool_calls: nil, finish_reason: nil, stop_kind: nil, usage: nil,
                   cost_usd: nil, cost_source: nil, is_byok: nil, model_used: nil,
                   upstream_provider: nil)
      @content = content
      @tool_calls = tool_calls
      @finish_reason = finish_reason
      @stop_kind = stop_kind
      @usage = usage || {}
      @cost_usd = cost_usd
      @cost_source = cost_source
      @is_byok = is_byok
      @model_used = model_used
      @upstream_provider = upstream_provider
    end

    def self.from_openai(response)
      data = normalize(response)
      choice = Array(data["choices"]).first || {}
      message = choice["message"] || {}
      usage = normalize_usage(data["usage"], input: "prompt_tokens", output: "completion_tokens")

      new(content: message["content"] || data.dig("output", 0, "content", 0, "text"),
          tool_calls: message["tool_calls"],
          finish_reason: choice["finish_reason"] || data["finish_reason"],
          usage: usage,
          model_used: data["model"],
          upstream_provider: "openai")
    end

    def self.from_anthropic(response)
      data = normalize(response)
      content = Array(data["content"]).filter_map do |part|
        part.is_a?(Hash) && part["type"] == "text" ? part["text"] : nil
      end.join
      usage = normalize_usage(data["usage"], input: "input_tokens", output: "output_tokens")

      new(content: content.empty? ? nil : content,
          finish_reason: data["stop_reason"],
          usage: usage,
          model_used: data["model"],
          upstream_provider: "anthropic")
    end

    def to_h
      { content: content, tool_calls: tool_calls, finish_reason: finish_reason, stop_kind: stop_kind,
        usage: usage, cost_usd: cost_usd, cost_source: cost_source, is_byok: is_byok,
        model_used: model_used, upstream_provider: upstream_provider }.compact
    end

    class << self
      private

      def normalize(value)
        return value.transform_keys(&:to_s) if value.is_a?(Hash)
        return JSON.parse(value) if value.is_a?(String)

        if value.respond_to?(:to_h)
          value.to_h.transform_keys(&:to_s)
        else
          {}
        end
      end

      def normalize_usage(raw, input:, output:)
        usage = raw.is_a?(Hash) ? raw.transform_keys(&:to_s) : {}
        {
          input_tokens: usage[input],
          output_tokens: usage[output],
          raw: raw
        }.compact
      end
    end
  end
end
