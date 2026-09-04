# frozen_string_literal: true

require "json"
require "digest"

module PromptOn
  # The payload policy the SDK applies to a monitoring log before it leaves the process.
  #
  # The server re-validates with the same rules, but the SDK applies them first so the raw text
  # never travels further than it has to. The order matters, because the steps interact:
  #
  #   1. keep decision (sampling; errors and stop_kind "length" are always kept)
  #   2. wrap a string input as {"text" => …} and a string output as {"content" => …}
  #   3. apply the mode: none drops input/output, hash digests them, full truncates
  #   4. cap error.message at 2048 bytes
  #   5. hash end_user_ref when hash_end_user is set
  #   6. run the app's redact hook last
  module Payload
    ERROR_MESSAGE_MAX = 2048
    SAMPLE_SCALE = 10_000
    DEFAULT_MAX_BYTES = 262_144
    DEFAULTS = { mode: "full", sample_rate: 1.0, max_bytes: DEFAULT_MAX_BYTES }.freeze
    MIN_TOOL_ARGUMENT_BUDGET = 32

    module_function

    # Returns the record with the policy applied.
    def apply(log, policy, payload_defaults: nil, hash_end_user: false, redact: nil, logger: nil)
      policy = normalize_policy(policy, payload_defaults)
      result = apply_mode(log, policy)
      result = cap_error_message(result)
      result = hash_end_user_ref(result, hash_end_user)
      run_redact(result, redact, logger)
    end

    # Normalises a use-case document payload_policy over the SDK defaults. sample_rate is clamped to 0..1.
    def normalize_policy(policy, defaults = nil)
      defaults = DEFAULTS.merge(defaults || {})
      policy = policy.is_a?(Hash) ? symbolize(policy) : {}
      pick = ->(key) { policy[key].nil? ? defaults[key] : policy[key] }

      mode = pick.call(:mode).to_s
      rate = pick.call(:sample_rate)
      bytes = pick.call(:max_bytes)

      { mode: %w[full hash none].include?(mode) ? mode : "full",
        sample_rate: rate.is_a?(Numeric) ? rate.to_f.clamp(0.0, 1.0) : 1.0,
        max_bytes: bytes.is_a?(Integer) && bytes.positive? ? bytes : DEFAULT_MAX_BYTES }
    end

    # Whether to keep this record's raw text. Errors and truncations always; otherwise
    # bucket(id) < round(rate * 10_000).
    def keep?(log, rate)
      return true if log["status"].to_s == "error"
      return true if log["stop_kind"].to_s == "length"
      return true if rate >= 1.0
      return false if rate <= 0.0

      bucket(log["id"]) < (rate * SAMPLE_SCALE).round
    end

    # Sampling bucket 0..9999: the first 4 bytes of sha256(id) read as an unsigned big-endian
    # 32-bit integer, mod 10000. The server computes the same number, so a resend makes the same
    # decision on both sides.
    def bucket(id)
      Digest::SHA256.digest(id.to_s).unpack1("N") % SAMPLE_SCALE
    end

    # JSON with no whitespace and hash keys sorted, so a digest of the same value is the same
    # digest in every language.
    def canonical_json(value)
      JSON.generate(canonicalize(value))
    end

    def canonicalize(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), acc| acc[key.to_s] = canonicalize(item) }.sort.to_h
      when Array then value.map { |item| canonicalize(item) }
      else value
      end
    end

    def json_size(value)
      canonical_json(value).bytesize
    end

    def sha256_hex(string)
      Digest::SHA256.hexdigest(string)
    end

    # UTF-8 safe truncation that keeps the head and the tail. Returns [string, truncated?] and
    # never exceeds +limit+ bytes.
    def truncate_string(string, limit)
      size = string.bytesize
      return [string, false] if size <= limit

      marker = "\n…[truncated #{size - limit} bytes]…\n"
      return [trim_trailing_partial(string.byteslice(0, limit)), true] if marker.bytesize > limit

      budget = limit - marker.bytesize
      head_bytes = budget * 6 / 10
      head = trim_trailing_partial(string.byteslice(0, head_bytes))
      tail = trim_leading_partial(string.byteslice(size - (budget - head_bytes), budget - head_bytes))
      [head + marker + tail, true]
    end

    # --- mode ----------------------------------------------------------------

    def apply_mode(log, policy)
      return drop_payload(log) if policy[:mode] == "none"
      return drop_payload(log) unless keep?(log, policy[:sample_rate])

      wrapped = wrap_payload(log)
      policy[:mode] == "hash" ? hash_payload(wrapped) : truncate_payload(wrapped, policy[:max_bytes])
    end

    def drop_payload(log)
      log.except("input", "output")
    end

    def wrap_payload(log)
      result = log.dup
      result["input"] = { "text" => result["input"] } if result["input"].is_a?(String)
      result["output"] = { "content" => result["output"] } if result["output"].is_a?(String)
      result
    end

    def hash_payload(log)
      result = log.dup
      %w[input output].each do |key|
        next if result[key].nil?

        json = canonical_json(result[key])
        result[key] = { "sha256" => sha256_hex(json), "bytes" => json.bytesize, "hashed" => true }
      end
      result
    end

    # --- full truncation -----------------------------------------------------

    def truncate_payload(log, max_bytes)
      result = log.dup
      { "input" => method(:truncate_input), "output" => method(:truncate_output) }.each do |key, fn|
        next unless result.key?(key)

        value = fn.call(result[key], max_bytes)
        value.nil? ? result.delete(key) : result[key] = value
      end
      result
    end

    def truncate_input(input, max_bytes)
      return input unless input.is_a?(Hash)

      per_message = [max_bytes / 8, 64].max
      variable_limit = [max_bytes / 4, 64].max

      messages, messages_cut = truncate_messages(input["messages"], per_message, max_bytes)
      text, text_cut = input["text"].is_a?(String) ? truncate_string(input["text"], max_bytes) : [input["text"], false]
      variables, variables_cut = truncate_variables(input["variables"], variable_limit)

      result = input.dup
      result["messages"] = messages unless messages.nil?
      result["text"] = text unless text.nil?
      result["variables"] = variables unless variables.nil?
      result["truncated"] = true if messages_cut || text_cut || variables_cut
      result
    end

    def truncate_output(output, max_bytes)
      return output unless output.is_a?(Hash)

      limit = [max_bytes / 4, 64].max
      content, content_cut =
        output["content"].is_a?(String) ? truncate_string(output["content"], limit) : [output["content"], false]
      tool_calls, tool_calls_cut = truncate_tool_calls(output["tool_calls"], limit)

      result = output.dup
      result["content"] = content unless content.nil?
      result["tool_calls"] = tool_calls unless tool_calls.nil?
      result["truncated"] = true if content_cut || tool_calls_cut
      result
    end

    def truncate_messages(messages, per_message, total_limit)
      return [nil, false] if messages.nil?
      return [messages, false] unless messages.is_a?(Array)

      cut = false
      capped = messages.map do |message|
        truncated, message_cut = truncate_message(message, per_message)
        cut ||= message_cut
        truncated
      end

      return [capped, cut] if list_json_size(capped) <= total_limit

      [fit_messages(capped, total_limit), true]
    end

    def truncate_message(message, limit)
      return [message, false] unless message.is_a?(Hash)

      content = message["content"]
      return [message, false] if content.nil?

      # A non-string content is measured on its JSON encoding and replaced by the truncated
      # encoding, so the cap holds whatever shape the app sent.
      measured = content.is_a?(String) ? content : canonical_json(content)
      return [message, false] if measured.bytesize <= limit

      truncated, = truncate_string(measured, limit)
      [message.merge("content" => truncated, "truncated" => true), true]
    end

    # The total is over budget: first empty the middle messages into byte-count stubs from the
    # front (the system prompt and the newest turn are always preserved, so a later middle
    # message can survive intact); if that is still not enough, drop the middle entirely.
    def fit_messages(messages, limit)
      stubbed = stub_middle(messages, limit)
      list_json_size(stubbed) <= limit ? stubbed : drop_middle(messages, limit)
    end

    def stub_middle(messages, limit)
      count = messages.length
      running = list_json_size(messages)

      messages.each_with_index.map do |message, index|
        next message unless index.positive? && index < count - 1 && running > limit

        stub = message.merge("content" => "…[truncated #{message_content_bytes(message)} bytes]…",
                             "truncated" => true)
        running = running - json_size(message) + json_size(stub)
        stub
      end
    end

    def drop_middle(messages, limit)
      return [] if messages.empty?

      first, *rest = messages
      marker = { "role" => "system", "content" => marker_text(rest.length), "truncated" => true }
      base = list_json_size([first, marker])

      if base <= limit
        kept = tail_within(rest, limit - base)
        [first, marker.merge("content" => marker_text(rest.length - kept.length))] + kept
      else
        smaller = shrink_first(first)
        if smaller == first
          only_marker = marker.merge("content" => marker_text(rest.length + 1))
          list_json_size([only_marker]) <= limit ? [only_marker] : []
        else
          drop_middle([smaller] + rest, limit)
        end
      end
    end

    # Halve the content if there is any, otherwise keep only the role. Returns the message
    # unchanged when there is nothing left to shrink, which is the caller's stop condition.
    def shrink_first(message)
      bytes = message_content_bytes(message)
      return minimal_message(message) if bytes.zero?

      truncate_message(message, bytes / 2).first
    end

    def minimal_message(message)
      role = message["role"]
      (role.nil? ? {} : { "role" => role }).merge("truncated" => true)
    end

    def tail_within(messages, budget)
      kept = []
      left = budget
      messages.reverse_each do |message|
        size = json_size(message) + 1
        break if size > left

        kept.unshift(message)
        left -= size
      end
      kept
    end

    def marker_text(dropped)
      "…[#{dropped} messages truncated]…"
    end

    def truncate_variables(variables, limit)
      return [nil, false] if variables.nil?

      json = canonical_json(variables)
      return [variables, false] if json.bytesize <= limit

      [{ "truncated" => true, "sha256" => sha256_hex(json), "bytes" => json.bytesize }, true]
    end

    def truncate_tool_calls(calls, limit)
      return [nil, false] if calls.nil?
      return [calls, false] unless calls.is_a?(Array)
      return [calls, false] if json_size(calls) <= limit

      overhead = json_size(calls.map { |call| put_arguments(call, "") })
      budget = [limit - overhead, 0].max / [calls.length, 1].max
      [shrink_tool_calls(calls, budget, limit), true]
    end

    def shrink_tool_calls(calls, budget, limit)
      while budget >= MIN_TOOL_ARGUMENT_BUDGET
        shrunk = calls.map do |call|
          arguments = call.dig("function", "arguments")
          next call unless arguments.is_a?(String)

          put_arguments(call, truncate_string(arguments, budget).first)
        end
        return shrunk if json_size(shrunk) <= limit

        budget /= 2
      end

      [{ "truncated" => true, "bytes" => json_size(calls) }]
    end

    def put_arguments(call, arguments)
      return call unless call.is_a?(Hash) && call["function"].is_a?(Hash) && call["function"]["arguments"].is_a?(String)

      call.merge("function" => call["function"].merge("arguments" => arguments))
    end

    def message_content_bytes(message)
      content = message["content"]
      case content
      when nil then 0
      when String then content.bytesize
      else json_size(content)
      end
    end

    def list_json_size(list)
      return 2 if list.empty?

      list.sum { |element| json_size(element) + 1 } + 1
    end

    # --- tail steps ----------------------------------------------------------

    def cap_error_message(log)
      error = log["error"]
      return log unless error.is_a?(Hash)

      message = error["message"]
      return log unless message.is_a?(String) && message.bytesize > ERROR_MESSAGE_MAX

      log.merge("error" => error.merge("message" => truncate_string(message, ERROR_MESSAGE_MAX).first))
    end

    def hash_end_user_ref(log, enabled)
      return log unless enabled
      return log if log["end_user_ref"].nil?

      log.merge("end_user_ref" => sha256_hex(log["end_user_ref"].to_s))
    end

    def run_redact(log, hook, logger)
      return log if hook.nil?

      result = hook.call(log)
      return result if result.is_a?(Hash)

      logger&.warn("[PromptOn] redact hook returned #{result.class}; dropping the payload")
      drop_payload(log)
    rescue StandardError => e
      logger&.warn("[PromptOn] redact hook raised #{e.class}: #{e.message}; dropping the payload")
      drop_payload(log)
    end

    # --- string helpers ------------------------------------------------------

    def trim_trailing_partial(string, tries = 3)
      return string if string.empty? || string.valid_encoding?
      return +"" if tries.zero?

      trim_trailing_partial(string.byteslice(0, string.bytesize - 1), tries - 1)
    end

    def trim_leading_partial(string)
      offset = 0
      bytes = string.bytes
      offset += 1 while offset < bytes.length && bytes[offset] >= 0x80 && bytes[offset] < 0xC0
      string.byteslice(offset, string.bytesize - offset)
    end

    def symbolize(hash)
      hash.each_with_object({}) { |(key, value), acc| acc[key.to_sym] = value }
    end
  end
end
