# frozen_string_literal: true

require_relative "test_helper"

class LogBuilderTest < Minitest::Test
  def setup
    @evidence = PromptOn::Resolver.resolve(PromptOn::UseCaseDocument.from_hash(snapshot_document),
                                           "greeting", source: "remote")
  end

  def test_the_record_carries_the_use_case_evidence_and_the_result
    record = build(status: "ok", result: {
                     content: "Hello, Ada!", finish_reason: "stop", model_used: "openai/gpt-4o-mini",
                     upstream_provider: "OpenAI", cost_usd: 0.000112, cost_source: "provider",
                     usage: { input_tokens: 38, output_tokens: 9, raw: { "total_tokens" => 47 } }
                   })

    assert_equal "greeting", record["use_case"]
    assert_equal "chat", record["kind"]
    assert_equal "openai/gpt-4o-mini", record["model"]
    assert_equal "0198f2a1-0000-7000-8000-00000000e001", record["model_id"]
    assert_equal "openrouter", record["provider"]
    assert_equal "OpenAI", record["upstream_provider"]
    assert_equal "0198f2a1-0000-7000-8000-00000000d001", record["deployment_id"]
    assert_equal 3, record["deployment_revision"]
    assert_equal "default", record["prompt"]
    assert_equal "0198f2a1-0000-7000-8000-00000000a001", record["prompt_version_id"]
    assert_equal "remote", record["source"]
    assert_equal "stop", record["stop_kind"]
    assert_equal({ "temperature" => 0.2, "max_tokens" => 512 }, record["params"])
    assert_equal({ "name" => "prompton-ruby", "version" => PromptOn::VERSION }, record["sdk"])
    assert_equal({ "total_tokens" => 47 }, record.dig("usage", "raw"))
  end

  def test_a_top_level_nil_is_omitted_while_a_nested_usage_nil_is_sent
    record = build(status: "ok", result: { content: "hi" })

    refute record.key?("trace_id")
    refute record.key?("error")
    assert record["usage"].key?("cost_usd")
    assert_nil record.dig("usage", "cost_usd")
    assert_equal "unknown", record.dig("usage", "cost_source")
  end

  def test_stop_kind_is_derived_from_finish_reason_when_absent
    assert_equal "length", build(status: "ok", result: { finish_reason: "max_tokens" })["stop_kind"]
    assert_equal "tool_call", build(status: "ok", result: { stop_kind: "tool_calls" })["stop_kind"]
    assert_nil build(status: "ok", result: {})["stop_kind"]
  end

  def test_is_byok_is_recorded_in_the_metadata
    record = build(status: "ok", result: { is_byok: true }, meta: { metadata: { job: 1 } })

    assert_equal({ "job" => 1, "is_byok" => true }, record["metadata"])
  end

  def test_a_string_result_becomes_the_output_content
    assert_equal({ "content" => "hi" }, build(status: "ok", result: "hi")["output"])
  end

  def test_result_helpers_normalize_provider_responses
    openai = PromptOn::Result.from_openai(
      "model" => "gpt-4o-mini",
      "choices" => [{ "finish_reason" => "stop", "message" => { "content" => "hi" } }],
      "usage" => { "prompt_tokens" => 3, "completion_tokens" => 2 }
    )
    anthropic = PromptOn::Result.from_anthropic(
      "model" => "claude-sonnet-4",
      "stop_reason" => "end_turn",
      "content" => [{ "type" => "text", "text" => "hello" }],
      "usage" => { "input_tokens" => 5, "output_tokens" => 4 }
    )

    assert_equal "hi", build(status: "ok", result: openai).dig("output", "content")
    assert_equal "openai", build(status: "ok", result: openai)["upstream_provider"]
    assert_equal "hello", build(status: "ok", result: anthropic).dig("output", "content")
    assert_equal 4, build(status: "ok", result: anthropic).dig("usage", "output_tokens")
  end

  def test_input_text_is_carried_for_a_text_use_case
    record = build(status: "ok", result: {}, meta: { input_text: "Summarize: a, b" })

    assert_equal({ "text" => "Summarize: a, b" }, record["input"])
  end

  def test_the_error_kinds_are_the_documented_set
    assert_equal ConformanceTest::ERROR_KINDS.sort, PromptOn::LogBuilder::ERROR_KINDS.sort
  end

  private

  def build(status:, result:, meta: {})
    error = status == "error" ? PromptOn::Failure.new(kind: "app") : nil
    PromptOn::LogBuilder.build(@evidence, meta, id: PromptOn::UuidV7.generate,
                                                started_at: Time.now.utc, latency_ms: 12,
                                                status: status, result: result, error: error)
  end
end
