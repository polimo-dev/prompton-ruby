# frozen_string_literal: true

require_relative "test_helper"

class PayloadTest < Minitest::Test
  FULL = { mode: "full", sample_rate: 1.0, max_bytes: 262_144 }.freeze

  def test_sampling_drops_a_successful_record_and_keeps_errors_and_truncations
    policy = FULL.merge(sample_rate: 0.0)

    ok = PromptOn::Payload.apply(record(status: "ok"), policy)
    failed = PromptOn::Payload.apply(record(status: "error"), policy)
    truncated = PromptOn::Payload.apply(record(status: "ok", "stop_kind" => "length"), policy)

    refute ok.key?("input")
    assert failed.key?("input"), "an error you cannot see is worse than a storage bill"
    assert truncated.key?("input"), "a truncated answer is the one you most need the text of"
  end

  def test_the_sampling_decision_is_a_pure_function_of_the_id
    policy = FULL.merge(sample_rate: 0.5)
    kept = 500.times.count do |index|
      PromptOn::Payload.keep?({ "id" => "id-#{index}", "status" => "ok" }, 0.5)
    end

    assert_operator kept, :>, 200
    assert_operator kept, :<, 300
    assert_equal PromptOn::Payload.apply(record(id: "stable"), policy),
                 PromptOn::Payload.apply(record(id: "stable"), policy)
  end

  def test_hash_mode_digests_the_wrapped_value
    result = PromptOn::Payload.apply(record.merge("input" => "raw prompt text"),
                                     FULL.merge(mode: "hash"))

    assert_equal %w[bytes hashed sha256], result["input"].keys.sort
    assert_equal 26, result["input"]["bytes"], "the digest covers {\"text\":\"…\"}"
    refute_includes JSON.generate(result), "raw prompt text"
  end

  def test_none_mode_keeps_the_narrow_record
    result = PromptOn::Payload.apply(record, FULL.merge(mode: "none"))

    refute result.key?("input")
    refute result.key?("output")
    assert_equal "greeting", result["use_case"]
  end

  def test_error_messages_are_capped_at_2048_bytes_whatever_max_bytes_says
    long = "x" * 5_000
    result = PromptOn::Payload.apply(record.merge("error" => { "kind" => "app", "message" => long }),
                                     FULL.merge(max_bytes: 1_000_000))

    assert_operator result["error"]["message"].bytesize, :<=, 2048
    assert_includes result["error"]["message"], "truncated"
  end

  def test_end_user_ref_is_hashed_on_request
    result = PromptOn::Payload.apply(record.merge("end_user_ref" => "user-42"), FULL,
                                     hash_end_user: true)

    assert_equal Digest::SHA256.hexdigest("user-42"), result["end_user_ref"]
  end

  def test_the_redact_hook_runs_last_and_a_raising_hook_drops_the_payload
    hook = ->(generation) { generation.merge("context" => { "redacted" => true }) }
    result = PromptOn::Payload.apply(record, FULL, redact: hook)
    assert_equal({ "redacted" => true }, result["context"])

    logger = MemoryLogger.new
    exploding = ->(_generation) { raise "boom" }
    result = PromptOn::Payload.apply(record, FULL, redact: exploding, logger: logger)

    refute result.key?("input")
    refute result.key?("output")
    assert(logger.lines.any? { |line| line.include?("redact hook raised") })
  end

  def test_truncation_never_splits_a_multibyte_character
    content = "한" * 400
    result = PromptOn::Payload.apply(record.merge("output" => { "content" => content }),
                                     FULL.merge(max_bytes: 512))

    truncated = result["output"]["content"]
    assert_predicate truncated, :valid_encoding?
    assert_operator truncated.bytesize, :<=, 128
    assert result["output"]["truncated"]
  end

  def test_canonical_json_sorts_keys_so_a_digest_is_the_same_everywhere
    assert_equal "{\"a\":1,\"b\":[{\"x\":1,\"y\":2}]}",
                 PromptOn::Payload.canonical_json({ "b" => [{ "y" => 2, "x" => 1 }], "a" => 1 })
  end

  def test_truncate_string_keeps_the_head_and_the_tail
    truncated, cut = PromptOn::Payload.truncate_string("#{"a" * 100}#{"z" * 100}", 120)

    assert cut
    assert_operator truncated.bytesize, :<=, 120
    assert truncated.start_with?("aaa")
    assert truncated.end_with?("zzz")
    assert_includes truncated, "[truncated 80 bytes]"
  end

  private

  def record(id: "0198f2a1-0000-7000-8000-000000001001", status: "ok", **extra)
    { "id" => id, "use_case" => "greeting", "model" => "openai/gpt-4o-mini", "status" => status,
      "started_at" => "2026-09-04T09:00:00.000000Z",
      "input" => { "messages" => [{ "role" => "user", "content" => "hi" }] },
      "output" => { "content" => "hello" } }.merge(extra)
  end
end
