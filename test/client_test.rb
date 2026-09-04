# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  def setup
    @logger = MemoryLogger.new
    @dir = Dir.mktmpdir("prompton-client")
    @clients = []
  end

  def teardown
    @clients.each(&:close)
    FileUtils.remove_entry(@dir)
  end

  # --- test mode -----------------------------------------------------------

  def test_test_mode_makes_no_http_calls_and_captures_the_records
    client = build_client(mode: :test, host: PromptOnTest::StubServer.dead_url)
    client.put_snapshot(snapshot_document)

    resolution = client.resolve("greeting")
    client.with_generation(resolution, variables: { name: "Ada" }) { "hello" }

    assert_equal 1, client.logged.length
    assert_equal "greeting", client.logged.first["use_case"]
    assert_equal "hello", client.logged.first.dig("output", "content")
    assert_equal({ captured: 1 }, client.flush)
  end

  def test_stub_builds_a_snapshot_for_one_use_case_and_accumulates
    client = build_client(mode: :test)
    client.stub("greeting", model: "openai/gpt-4o-mini",
                            messages: [{ "role" => "user", "content" => "Hi {{ name }}" }],
                            params: { "temperature" => 0.3 })
    client.stub("greeting", model: "openai/gpt-4o-mini", prompt: "ko",
                            messages: [{ "role" => "user", "content" => "{{ name }}님" }])
    client.stub("summarize", model: "openai/gpt-4o-mini", kind: "text", text: "Sum {{ n }}")

    assert_equal %w[default ko], client.prompt_names("greeting")
    assert_equal [{ "role" => "user", "content" => "Ada님" }],
                 client.resolve("greeting", prompt: "ko").render(name: "Ada")
    assert_equal({ "temperature" => 0.3 }, client.resolve("greeting").params)
    assert_equal "Sum 2", client.resolve("summarize").render(n: 2)
  end

  def test_clear_logs_empties_the_capture
    client = build_client(mode: :test)
    client.stub("greeting", model: "m", messages: [{ "role" => "user", "content" => "hi" }])
    client.with_generation(client.resolve("greeting")) { "x" }

    client.clear_logs

    assert_empty client.logged
  end

  # --- offline mode --------------------------------------------------------

  def test_offline_mode_reads_the_bundle_and_never_calls_out
    bundle = File.join(@dir, "snapshot.production.json")
    File.write(bundle, snapshot_json)
    client = build_client(mode: :offline, bundle: bundle, host: PromptOnTest::StubServer.dead_url)

    assert_equal "bundle", client.resolve("greeting").source
    assert_equal({ discarded: 0 }, client.flush)
  end

  def test_without_an_api_key_the_sdk_says_so_once_and_works_from_the_bundle
    bundle = File.join(@dir, "snapshot.production.json")
    File.write(bundle, snapshot_json)
    client = build_client(api_key: nil, project: "sdkfixture", bundle: bundle)

    assert_equal "bundle", client.resolve("greeting").source
    announcements = @logger.lines.count { |line| line.include?("no API key configured") }
    assert_equal 1, announcements

    client.log(record)
    client.log(record)
    assert_equal(1, @logger.lines.count { |line| line.include?("monitoring logs are not being sent") })
    assert_equal({ discarded: 2 }, client.log_stats)
  end

  # --- log -----------------------------------------------------------------

  def test_log_fills_the_id_started_at_and_sdk_fields
    client = build_client(mode: :test)
    logged = client.log("use_case" => "greeting", "model" => "m", "status" => "ok")

    assert_match(/\A\h{8}-\h{4}-7\h{3}-/, logged["id"])
    assert Time.iso8601(logged["started_at"])
    assert_equal({ "name" => "prompton-ruby", "version" => PromptOn::VERSION }, logged["sdk"])
  end

  def test_log_validates_the_fields_the_server_requires
    client = build_client(mode: :test)

    error = assert_raises(PromptOn::InvalidRecordError) { client.log("model" => "m", "status" => "ok") }
    assert_equal "use_case", error.field
    assert_raises(PromptOn::InvalidRecordError) { client.log("use_case" => "greeting", "status" => "ok") }
  end

  def test_log_takes_the_resolution_evidence_from_a_resolution
    client = build_client(mode: :test)
    client.put_snapshot(snapshot_document)
    resolution = client.resolve("greeting", prompt: "ko")

    logged = client.log({ "status" => "ok" }, resolution: resolution)

    assert_equal "greeting", logged["use_case"]
    assert_equal "ko", logged["prompt"]
    assert_equal 3, logged["deployment_revision"]
    assert_equal "0198f2a1-0000-7000-8000-00000000a002", logged["prompt_version_id"]
    assert_equal "manual", logged["resolution_source"]
    assert_equal({ "temperature" => 0.2, "max_tokens" => 512 }, logged["params"])
  end

  def test_symbol_keys_are_accepted_and_normalised
    client = build_client(mode: :test)
    logged = client.log(use_case: "greeting", model: "m", status: "ok",
                        context: { language: "ko" })

    assert_equal({ "language" => "ko" }, logged["context"])
  end

  def test_the_payload_policy_from_the_snapshot_is_applied_before_the_record_is_queued
    document = snapshot_document
    document["use_cases"]["greeting"]["payload_policy"] =
      { "mode" => "hash", "sample_rate" => 1.0, "max_bytes" => 262_144 }
    client = build_client(mode: :test)
    client.put_snapshot(document)

    logged = client.log({ "status" => "ok", "input" => "secret prompt" },
                        resolution: client.resolve("greeting"))

    assert_equal %w[bytes hashed sha256], logged["input"].keys.sort
    refute_includes JSON.generate(logged), "secret prompt"
  end

  def test_the_redact_hook_and_hash_end_user_reach_the_record
    client = build_client(mode: :test, hash_end_user: true,
                          redact: ->(gen) { gen.merge("metadata" => { "redacted" => true }) })

    logged = client.log("use_case" => "greeting", "model" => "m", "status" => "ok",
                        "end_user_ref" => "user-42")

    assert_equal Digest::SHA256.hexdigest("user-42"), logged["end_user_ref"]
    assert_equal({ "redacted" => true }, logged["metadata"])
  end

  # --- with_generation -----------------------------------------------------

  def test_with_generation_times_the_call_and_returns_the_block_value_unchanged
    client = build_client(mode: :test)
    client.put_snapshot(snapshot_document)
    resolution = client.resolve("greeting")
    outcome = { content: "Hello", finish_reason: "stop", usage: { input_tokens: 38, output_tokens: 9 },
                cost_usd: 0.000112, cost_source: "provider", model_used: "openai/gpt-4o-mini" }

    returned = client.with_generation(resolution, variables: { name: "Ada" },
                                                  input_messages: resolution.render(name: "Ada"),
                                                  end_user_ref: "u1", trace_id: "job:1", sequence: 2,
                                                  context: { plan: "pro" }, metadata: { job: 7 }) do
      outcome
    end

    assert_same outcome, returned
    logged = client.logged.first
    assert_equal "ok", logged["status"]
    assert_equal "stop", logged["stop_kind"]
    assert_equal 38, logged.dig("usage", "input_tokens")
    assert_equal "provider", logged.dig("usage", "cost_source")
    assert_operator logged["latency_ms"], :>=, 0
    assert_equal "job:1", logged["trace_id"]
    assert_equal({ "plan" => "pro" }, logged["context"])
    assert_equal({ "job" => 7 }, logged["metadata"])
    assert_equal "Say hello to Ada.", logged.dig("input", "messages").last["content"]
  end

  def test_a_failure_is_logged_with_its_kind_and_status_without_raising
    client = build_client(mode: :test)
    client.put_snapshot(snapshot_document)
    failure = PromptOn::Failure.new(kind: "rate_limited", status: 429, message: "slow down")

    returned = client.with_generation(client.resolve("greeting")) { failure }

    assert_same failure, returned
    logged = client.logged.first
    assert_equal "error", logged["status"]
    assert_equal({ "kind" => "rate_limited", "status" => 429, "message" => "slow down" }, logged["error"])
  end

  def test_a_failure_can_keep_the_usage_and_output_it_carries
    client = build_client(mode: :test)
    client.put_snapshot(snapshot_document)
    failure = PromptOn::Failure.new(kind: "parse", message: "unexpected end of JSON input",
                                    outcome: { content: "{\"greeting\":", finish_reason: "length",
                                               usage: { input_tokens: 38, output_tokens: 512 } })

    client.with_generation(client.resolve("greeting")) { failure }

    logged = client.logged.first
    assert_equal "error", logged["status"]
    assert_equal "length", logged["stop_kind"]
    assert_equal 512, logged.dig("usage", "output_tokens")
    assert_equal "{\"greeting\":", logged.dig("output", "content")
  end

  def test_an_exception_is_logged_as_an_app_error_and_re_raised_unchanged
    client = build_client(mode: :test)
    client.put_snapshot(snapshot_document)
    raised = ArgumentError.new("provider client blew up")

    error = assert_raises(ArgumentError) { client.with_generation(client.resolve("greeting")) { raise raised } }

    assert_same raised, error
    logged = client.logged.first
    assert_equal "error", logged["status"]
    assert_equal "app", logged.dig("error", "kind")
    assert_includes logged.dig("error", "message"), "provider client blew up"
  end

  def test_an_unknown_error_kind_falls_back_to_app
    client = build_client(mode: :test)
    client.put_snapshot(snapshot_document)

    client.with_generation(client.resolve("greeting")) { PromptOn::Failure.new(kind: "weird") }

    assert_equal "app", client.logged.first.dig("error", "kind")
  end

  def test_a_log_that_cannot_be_built_never_breaks_the_generation
    client = build_client(mode: :test)
    document = snapshot_document
    document["models"] = {}
    client.put_snapshot(document)
    resolution = client.resolve("greeting")

    assert_equal "fine", client.with_generation(resolution) { "fine" }
    assert_empty client.logged
    assert(@logger.lines.any? { |line| line.include?("could not record the monitoring log") })
  end

  # --- module-level default client -----------------------------------------

  def test_the_module_delegates_to_a_replaceable_default_client
    PromptOn.configure(**client_options(mode: :test, logger: @logger))
    PromptOn.stub("greeting", model: "m", messages: [{ "role" => "user", "content" => "Hi {{ n }}" }])

    assert_equal [{ "role" => "user", "content" => "Hi 1" }], PromptOn.resolve("greeting").render(n: 1)

    PromptOn.reset!
    assert_nil PromptOn.instance_variable_get(:@client)
  end

  private

  def record
    { "use_case" => "greeting", "model" => "openai/gpt-4o-mini", "status" => "ok" }
  end

  def build_client(**overrides)
    client = PromptOn::Client.new(**client_options(logger: @logger, **overrides))
    @clients << client
    client
  end
end
