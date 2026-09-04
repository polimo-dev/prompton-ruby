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
    client.put_use_case_document(snapshot_document)

    resolution = client.use_case("greeting")
    resolution.track(variables: { name: "Ada" }) { "hello" }

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
                 client.use_case("greeting", prompt: "ko").messages(name: "Ada")
    assert_equal({ "temperature" => 0.3 }, client.use_case("greeting").params)
    assert_equal "Sum 2", client.use_case("summarize").text(n: 2)
  end

  def test_clear_logs_empties_the_capture
    client = build_client(mode: :test)
    client.stub("greeting", model: "m", messages: [{ "role" => "user", "content" => "hi" }])
    client.use_case("greeting").track { "x" }

    client.clear_logs

    assert_empty client.logged
  end

  # --- offline mode --------------------------------------------------------

  def test_offline_mode_reads_the_bundle_and_never_calls_out
    bundle = File.join(@dir, "use-cases.production.json")
    File.write(bundle, snapshot_json)
    client = build_client(mode: :offline, bundle: bundle, host: PromptOnTest::StubServer.dead_url)

    assert_equal "bundle", client.use_case("greeting").source
    assert_equal({ discarded: 0 }, client.flush)
  end

  def test_without_an_api_key_the_sdk_says_so_once_and_works_from_the_bundle
    bundle = File.join(@dir, "use-cases.production.json")
    File.write(bundle, snapshot_json)
    client = build_client(api_key: nil, project: "sdkfixture", bundle: bundle)

    assert_equal "bundle", client.use_case("greeting").source
    announcements = @logger.lines.count { |line| line.include?("no API key configured") }
    assert_equal 1, announcements

    client.log(record)
    client.log(record)
    assert_equal(1, @logger.lines.count { |line| line.include?("monitoring logs are not being sent") })
    assert_equal({ discarded: 2 }, client.log_stats)
  end

  # --- log -----------------------------------------------------------------

  def test_log_fills_the_id_and_sdk_fields_and_keeps_the_started_at_it_was_given
    client = build_client(mode: :test)
    started_at = (Time.now.utc - 300).iso8601(6)
    logged = client.log("use_case" => "greeting", "model" => "m", "status" => "ok",
                        "started_at" => started_at)

    assert_match(/\A\h{8}-\h{4}-7\h{3}-/, logged["id"])
    assert_equal started_at, logged["started_at"], "a record built after the fact keeps its own clock"
    assert_equal({ "name" => "prompton-ruby", "version" => PromptOn::VERSION }, logged["sdk"])
  end

  def test_log_validates_the_fields_the_server_requires
    client = build_client(mode: :test)

    error = assert_raises(PromptOn::InvalidRecordError) { client.log("model" => "m", "status" => "ok") }
    assert_equal "use_case", error.field
    assert_raises(PromptOn::InvalidRecordError) { client.log("use_case" => "greeting", "status" => "ok") }

    # started_at is never guessed: a record for a provider call that ran minutes ago would otherwise
    # be stamped with the enqueue time and quietly corrupt every latency and time series.
    missing = assert_raises(PromptOn::InvalidRecordError) do
      client.log("use_case" => "greeting", "model" => "m", "status" => "ok")
    end
    assert_equal "started_at", missing.field
  end

  def test_log_takes_the_use_case_evidence_from_a_use_case
    client = build_client(mode: :test)
    client.put_use_case_document(snapshot_document)
    resolution = client.use_case("greeting", prompt: "ko")

    logged = client.log({ "status" => "ok", "started_at" => Time.now.utc.iso8601(6) },
                        use_case_evidence: resolution)

    assert_equal "greeting", logged["use_case"]
    assert_equal "ko", logged["prompt"]
    assert_equal 3, logged["deployment_revision"]
    assert_equal "0198f2a1-0000-7000-8000-00000000a002", logged["prompt_version_id"]
    assert_equal "manual", logged["source"]
    assert_equal({ "temperature" => 0.2, "max_tokens" => 512 }, logged["params"])
  end

  def test_symbol_keys_are_accepted_and_normalised
    client = build_client(mode: :test)
    logged = client.log(use_case: "greeting", model: "m", status: "ok",
                        started_at: Time.now.utc.iso8601(6), context: { language: "ko" })

    assert_equal({ "language" => "ko" }, logged["context"])
  end

  def test_the_payload_policy_from_the_snapshot_is_applied_before_the_record_is_queued
    document = snapshot_document
    document["use_cases"]["greeting"]["payload_policy"] =
      { "mode" => "hash", "sample_rate" => 1.0, "max_bytes" => 262_144 }
    client = build_client(mode: :test)
    client.put_use_case_document(document)

    logged = client.log({ "status" => "ok", "input" => "secret prompt",
                          "started_at" => Time.now.utc.iso8601(6) },
                        use_case_evidence: client.use_case("greeting"))

    assert_equal %w[bytes hashed sha256], logged["input"].keys.sort
    refute_includes JSON.generate(logged), "secret prompt"
  end

  def test_the_redact_hook_and_hash_end_user_reach_the_record
    client = build_client(mode: :test, hash_end_user: true,
                          redact: ->(gen) { gen.merge("metadata" => { "redacted" => true }) })

    logged = client.log("use_case" => "greeting", "model" => "m", "status" => "ok",
                        "started_at" => Time.now.utc.iso8601(6), "end_user_ref" => "user-42")

    assert_equal Digest::SHA256.hexdigest("user-42"), logged["end_user_ref"]
    assert_equal({ "redacted" => true }, logged["metadata"])
  end

  # --- track -----------------------------------------------------

  def test_track_times_the_call_and_returns_the_block_value_unchanged
    client = build_client(mode: :test)
    client.put_use_case_document(snapshot_document)
    resolution = client.use_case("greeting")
    result = { content: "Hello", finish_reason: "stop", usage: { input_tokens: 38, output_tokens: 9 },
               cost_usd: 0.000112, cost_source: "provider", model_used: "openai/gpt-4o-mini" }

    returned = resolution.track(variables: { name: "Ada" },
                                input_messages: resolution.messages(name: "Ada"),
                                end_user_ref: "u1", trace_id: "job:1", sequence: 2,
                                context: { plan: "pro" }, metadata: { job: 7 }) do
      result
    end

    assert_same result, returned
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

  def test_messages_prompt_selection_is_used_by_later_track_evidence
    client = build_client(mode: :test)
    client.put_use_case_document(snapshot_document)
    use_case = client.use_case("greeting")

    messages = use_case.messages({ name: "Ada" }, prompt: "ko")
    use_case.track(variables: { name: "Ada" }, input_messages: messages) { { content: "안녕" } }

    logged = client.logged.first
    assert_equal "ko", logged["prompt"]
    assert_equal "0198f2a1-0000-7000-8000-00000000a002", logged["prompt_version_id"]
    assert_equal "Ada님에게 인사해줘.", logged.dig("input", "messages").last["content"]
  end

  def test_a_failure_is_logged_with_its_kind_and_status_without_raising
    client = build_client(mode: :test)
    client.put_use_case_document(snapshot_document)
    failure = PromptOn::Failure.new(kind: "rate_limited", status: 429, message: "slow down")

    returned = client.use_case("greeting").track { failure }

    assert_same failure, returned
    logged = client.logged.first
    assert_equal "error", logged["status"]
    assert_equal({ "kind" => "rate_limited", "status" => 429, "message" => "slow down" }, logged["error"])
  end

  def test_a_failure_can_keep_the_usage_and_output_it_carries
    client = build_client(mode: :test)
    client.put_use_case_document(snapshot_document)
    failure = PromptOn::Failure.new(kind: "parse", message: "unexpected end of JSON input",
                                    result: { content: "{\"greeting\":", finish_reason: "length",
                                              usage: { input_tokens: 38, output_tokens: 512 } })

    client.use_case("greeting").track { failure }

    logged = client.logged.first
    assert_equal "error", logged["status"]
    assert_equal "length", logged["stop_kind"]
    assert_equal 512, logged.dig("usage", "output_tokens")
    assert_equal "{\"greeting\":", logged.dig("output", "content")
  end

  def test_an_exception_is_logged_as_an_app_error_and_re_raised_unchanged
    client = build_client(mode: :test)
    client.put_use_case_document(snapshot_document)
    raised = ArgumentError.new("provider client blew up")

    error = assert_raises(ArgumentError) { client.use_case("greeting").track { raise raised } }

    assert_same raised, error
    logged = client.logged.first
    assert_equal "error", logged["status"]
    assert_equal "app", logged.dig("error", "kind")
    assert_includes logged.dig("error", "message"), "provider client blew up"
  end

  def test_an_unknown_error_kind_falls_back_to_app
    client = build_client(mode: :test)
    client.put_use_case_document(snapshot_document)

    client.use_case("greeting").track { PromptOn::Failure.new(kind: "weird") }

    assert_equal "app", client.logged.first.dig("error", "kind")
  end

  def test_a_log_that_cannot_be_built_never_breaks_the_provider_call
    client = build_client(mode: :test)
    document = snapshot_document
    document["models"] = {}
    client.put_use_case_document(document)
    resolution = client.use_case("greeting")

    assert_equal("fine", resolution.track { "fine" })
    assert_empty client.logged
    assert(@logger.lines.any? { |line| line.include?("could not record the monitoring log") })
  end

  # --- lifecycle -----------------------------------------------------------

  def test_the_exit_drain_forgets_a_closed_client_and_holds_the_rest_weakly
    before = PromptOn::Client.open_at_exit.length
    client = build_client(mode: :offline, flush_on_exit: true)

    assert_equal before + 1, PromptOn::Client.open_at_exit.length

    client.close

    assert_equal before, PromptOn::Client.open_at_exit.length, "a closed client leaves the drain"

    # Ruby cannot unregister an at_exit block, so a client per request or per test would pile up
    # for the life of the process if the drain held them strongly.
    60.times { PromptOn::Client.new(**client_options(logger: @logger, mode: :offline, flush_on_exit: true)) }
    3.times { GC.start }

    assert_operator PromptOn::Client.open_at_exit.length, :<, before + 60,
                    "clients that went out of scope are collected, not kept alive until exit"
  end

  # --- module-level default client -----------------------------------------

  def test_the_module_delegates_to_a_replaceable_default_client
    PromptOn.configure(**client_options(mode: :test, logger: @logger))
    PromptOn.stub("greeting", model: "m", messages: [{ "role" => "user", "content" => "Hi {{ n }}" }])

    assert_equal [{ "role" => "user", "content" => "Hi 1" }], PromptOn.use_case("greeting").messages(n: 1)

    PromptOn.reset!
    assert_nil PromptOn.instance_variable_get(:@client)
  end

  private

  def record
    { "use_case" => "greeting", "model" => "openai/gpt-4o-mini", "status" => "ok",
      "started_at" => Time.now.utc.iso8601(6) }
  end

  def build_client(**overrides)
    client = PromptOn::Client.new(**client_options(logger: @logger, **overrides))
    @clients << client
    client
  end
end
