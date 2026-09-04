# frozen_string_literal: true

require_relative "test_helper"

class GenerationTest < Minitest::Test
  def setup
    @resolution = PromptOn::Resolver.resolve(PromptOn::SnapshotData.from_hash(snapshot_document),
                                             "greeting", source: "remote")
  end

  def test_the_record_carries_the_resolution_evidence_and_the_outcome
    record = build(status: "ok", outcome: {
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
    assert_equal "remote", record["resolution_source"]
    assert_equal "stop", record["stop_kind"]
    assert_equal({ "temperature" => 0.2, "max_tokens" => 512 }, record["params"])
    assert_equal({ "name" => "prompton-ruby", "version" => PromptOn::VERSION }, record["sdk"])
    assert_equal({ "total_tokens" => 47 }, record.dig("usage", "raw"))
  end

  def test_a_top_level_nil_is_omitted_while_a_nested_usage_nil_is_sent
    record = build(status: "ok", outcome: { content: "hi" })

    refute record.key?("trace_id")
    refute record.key?("error")
    assert record["usage"].key?("cost_usd")
    assert_nil record.dig("usage", "cost_usd")
    assert_equal "unknown", record.dig("usage", "cost_source")
  end

  def test_stop_kind_is_derived_from_finish_reason_when_absent
    assert_equal "length", build(status: "ok", outcome: { finish_reason: "max_tokens" })["stop_kind"]
    assert_equal "tool_call", build(status: "ok", outcome: { stop_kind: "tool_calls" })["stop_kind"]
    assert_nil build(status: "ok", outcome: {})["stop_kind"]
  end

  def test_is_byok_is_recorded_in_the_metadata
    record = build(status: "ok", outcome: { is_byok: true }, meta: { metadata: { job: 1 } })

    assert_equal({ "job" => 1, "is_byok" => true }, record["metadata"])
  end

  def test_a_string_outcome_becomes_the_output_content
    assert_equal({ "content" => "hi" }, build(status: "ok", outcome: "hi")["output"])
  end

  def test_input_text_is_carried_for_a_text_use_case
    record = build(status: "ok", outcome: {}, meta: { input_text: "Summarize: a, b" })

    assert_equal({ "text" => "Summarize: a, b" }, record["input"])
  end

  def test_the_error_kinds_are_the_documented_set
    assert_equal ConformanceTest::ERROR_KINDS.sort, PromptOn::Generation::ERROR_KINDS.sort
  end

  private

  def build(status:, outcome:, meta: {})
    error = status == "error" ? PromptOn::Failure.new(kind: "app") : nil
    PromptOn::Generation.build(@resolution, meta, id: PromptOn::UuidV7.generate,
                                                  started_at: Time.now.utc, latency_ms: 12,
                                                  status: status, outcome: outcome, error: error)
  end
end
