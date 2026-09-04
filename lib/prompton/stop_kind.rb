# frozen_string_literal: true

module PromptOn
  # Normalises each provider's raw finish_reason into a PromptOn stop_kind.
  #
  #   stop, end_turn, stop_sequence      -> "stop"
  #   length, max_tokens                 -> "length"
  #   tool_call, tool_calls, tool_use    -> "tool_call"
  #   content_filter                     -> "content_filter"
  #   anything else, empty or absent     -> "other"
  #
  # Comparison lowercases and trims, so Google's "STOP" and "MAX_TOKENS" map correctly.
  # Normalisation is idempotent: feeding a stop_kind back in returns itself, which matters
  # because the server re-normalises whatever the client sent.
  #
  # Two traps. Google's SAFETY and RECITATION map to "other", not "content_filter" — only the
  # literal string content_filter lands there. And tool_calls is not a truncation: only "length"
  # sets truncated, and the truncation rate, the evaluator and the alerts all depend on that.
  module StopKind
    ALL = %w[stop length tool_call content_filter other].freeze

    TABLE = {
      "stop" => "stop", "end_turn" => "stop", "stop_sequence" => "stop",
      "length" => "length", "max_tokens" => "length",
      "tool_call" => "tool_call", "tool_calls" => "tool_call", "tool_use" => "tool_call",
      "content_filter" => "content_filter"
    }.freeze

    module_function

    # Normalises a raw finish_reason (String, Symbol or nil) into one of ALL.
    def normalize(reason)
      return "other" if reason.nil?
      return "other" unless reason.is_a?(String) || reason.is_a?(Symbol)

      TABLE.fetch(reason.to_s.strip.downcase, "other")
    end

    # Whether the output was cut off. True only for "length".
    def truncated?(reason)
      normalize(reason) == "length"
    end
  end
end
