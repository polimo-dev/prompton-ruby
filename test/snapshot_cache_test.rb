# frozen_string_literal: true

require_relative "test_helper"

class SnapshotCacheTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("prompton-cache")
    @logger = MemoryLogger.new
    @clock = FakeClock.new
    @state = {
      "greeting" => { body: prompt_json("greeting"), etag: "\"greeting-v1\"", status: 200 },
      "summarize" => { body: prompt_json("summarize"), etag: "\"summarize-v1\"", status: 200 }
    }
    @server = PromptOnTest::StubServer.new { |request| respond(request) }
    @server_url = @server.url
    @clients = []
  end

  def teardown
    @clients.each(&:close)
    @server.stop
    FileUtils.remove_entry(@dir)
  end

  def test_startup_and_idle_make_no_config_fetches
    build_client
    sleep(0.05)

    assert_equal 0, @server.request_count
  end

  def test_cold_lookup_fetches_only_the_requested_prompt_url
    client = build_client

    assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model

    assert_equal 1, @server.request_count
    request = @server.recorded.first
    assert_equal "/api/v1/prompts/greeting", request.path
    assert_equal({ "environment" => "production" }, request.query)
  end

  def test_fresh_cache_hit_makes_no_http_call
    client = build_client

    3.times { assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model }

    assert_equal 1, @server.request_count
  end

  def test_expired_cache_fetches_with_the_prompt_specific_etag
    client = build_client
    client.use_case("greeting")
    @state["greeting"][:etag] = "\"greeting-v2\""
    @state["greeting"][:body] = prompt_json("greeting", temperature: 0.9)

    @clock.advance(10.01)
    assert_in_delta 0.9, client.use_case("greeting").params["temperature"]

    assert_equal 2, @server.request_count
    assert_equal "\"greeting-v1\"", @server.recorded.last.headers["if-none-match"]
  end

  def test_failed_attempts_are_throttled_for_the_cache_ttl_and_serve_stale
    client = build_client
    assert_in_delta 0.2, client.use_case("greeting").params["temperature"]

    @state["greeting"][:status] = 503
    @clock.advance(10.01)

    3.times { assert_in_delta 0.2, client.use_case("greeting").params["temperature"] }

    assert_equal 2, @server.request_count
    assert_equal 1, client.use_case_document_status("greeting")[:failures]
  end

  def test_cold_failure_returns_a_normal_not_ready_error_and_is_rate_limited
    @state["greeting"][:status] = 503
    client = build_client

    assert_raises(PromptOn::NotReadyError) { client.use_case("greeting") }
    assert_raises(PromptOn::NotReadyError) { client.use_case("greeting") }

    assert_equal 1, @server.request_count
  end

  def test_304_revalidates_the_cached_prompt
    client = build_client
    client.use_case("greeting")
    @state["greeting"][:status] = 304

    @clock.advance(10.01)
    assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model

    assert_equal 2, @server.request_count
    assert_equal "\"greeting-v1\"", client.use_case("greeting").etag
    refute client.use_case_document_info[:stale]
  end

  def test_304_without_a_cached_value_is_a_failure
    @state["greeting"][:status] = 304
    client = build_client

    assert_raises(PromptOn::NotReadyError) { client.use_case("greeting") }

    assert_equal 1, @server.request_count
  end

  def test_http_errors_do_not_retry_inside_one_fetch
    @state["greeting"][:status] = 500
    client = build_client

    assert_raises(PromptOn::NotReadyError) { client.use_case("greeting") }

    assert_equal 1, @server.request_count
  end

  def test_transport_disconnect_does_not_use_net_http_automatic_retry
    @server.stop
    attempts = Queue.new
    closing_server = TCPServer.new("127.0.0.1", 0)
    closer =
      Thread.new do
        loop do
          connection = closing_server.accept
          attempts << :accepted
          connection.close
        end
      rescue IOError, Errno::EBADF
        nil
      end
    host = "http://127.0.0.1:#{closing_server.addr[1]}"
    client = build_client(host: host, config_fetch_timeout: 0.2)

    assert_raises(PromptOn::NotReadyError) { client.use_case("greeting") }

    assert_equal :accepted, attempts.pop(true)
    assert_raises(ThreadError) { attempts.pop(true) }
  ensure
    closing_server&.close
    closer&.join(1)
  end

  def test_unexpected_fetch_exception_clears_inflight_and_allows_later_retry
    client = build_client
    http = client.instance_variable_get(:@http)
    original_get_prompt = http.method(:get_prompt)
    attempts = 0
    http.define_singleton_method(:get_prompt) do |*args, **kwargs|
      attempts += 1
      raise "socket exploded" if attempts == 1

      original_get_prompt.call(*args, **kwargs)
    end

    assert_raises(PromptOn::NotReadyError) { client.use_case("greeting") }
    assert_raises(PromptOn::NotReadyError) { client.use_case("greeting") }
    assert_equal 1, attempts
    assert_equal 0, @server.request_count

    @clock.advance(10.01)
    assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model

    assert_equal 2, attempts
    assert_equal 1, @server.request_count
  end

  def test_one_second_total_timeout_serves_stale_and_discards_the_late_result
    client = build_client
    client.use_case("greeting")
    @state["greeting"][:delay] = 1.25
    @state["greeting"][:etag] = "\"greeting-v2\""
    @state["greeting"][:body] = prompt_json("greeting", temperature: 0.9)

    @clock.advance(10.01)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_in_delta 0.2, client.use_case("greeting").params["temperature"]
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 1.15
    sleep(0.3)
    assert_in_delta 0.2, client.use_case("greeting").params["temperature"]
  end

  def test_same_prompt_concurrent_cold_requests_share_one_fetch
    @state["greeting"][:delay] = 0.05
    client = build_client

    threads = Array.new(12) { Thread.new { client.use_case("greeting").model } }

    assert_equal ["openai/gpt-4o-mini"], threads.map(&:value).uniq
    assert_equal 1, @server.request_count
  end

  def test_different_prompt_keys_are_independent
    @state["greeting"][:delay] = 0.25
    client = build_client
    summary_elapsed = nil

    slow = Thread.new { client.use_case("greeting").model }
    fast = Thread.new do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      model = client.use_case("summarize").model
      summary_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      model
    end

    assert_equal "openai/gpt-4o-mini", fast.value
    assert_operator summary_elapsed, :<, 0.15
    assert_equal "openai/gpt-4o-mini", slow.value
    assert_equal ["/api/v1/prompts/greeting", "/api/v1/prompts/summarize"].sort,
                 @server.recorded.map(&:path).sort
  end

  def test_scope_mismatch_is_rejected_without_replacing_stale_cache
    client = build_client
    client.use_case("greeting")
    @state["greeting"][:body] = prompt_json("greeting", project: "other")
    @state["greeting"][:etag] = "\"bad\""

    @clock.advance(10.01)
    assert_in_delta 0.2, client.use_case("greeting").params["temperature"]

    assert_equal "\"greeting-v1\"", client.use_case("greeting").etag
  end

  def test_disk_and_bundle_are_fallbacks_but_do_not_count_as_fresh_remote_validation
    File.write(bundle_path, prompt_json("greeting", temperature: 0.4))
    client = build_client(bundle: bundle_path)

    assert_in_delta 0.2, client.use_case("greeting").params["temperature"]

    assert_equal 1, @server.request_count
    assert_equal "remote", client.use_case("greeting").source
  end

  def test_bundle_answers_when_prompton_is_unreachable
    File.write(bundle_path, prompt_json("greeting", temperature: 0.4))
    client = build_client(bundle: bundle_path, host: PromptOnTest::StubServer.dead_url)

    assert_in_delta 0.4, client.use_case("greeting").params["temperature"]
    assert_equal "bundle", client.use_case("greeting").source
  end

  def test_each_prompt_keeps_its_own_cache_and_etag
    client = build_client
    client.use_case("greeting")
    client.use_case("summarize")
    @state["greeting"][:etag] = "\"greeting-v2\""
    @state["greeting"][:body] = prompt_json("greeting", temperature: 0.8)

    @clock.advance(10.01)
    assert_in_delta 0.8, client.use_case("greeting").params["temperature"]

    paths = @server.recorded.map(&:path)
    assert_equal 2, paths.count("/api/v1/prompts/greeting")
    assert_equal 1, paths.count("/api/v1/prompts/summarize")
    assert_equal "\"summarize-v1\"", client.use_case("summarize").etag
  end

  def test_prompt_cache_keeps_an_immutable_document_per_key
    client = build_client

    assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model

    @state["summarize"][:etag] = "\"summarize-v2\""
    @state["summarize"][:body] = prompt_json_with_model("summarize", "openai/changed-model")

    assert_equal "openai/changed-model", client.use_case("summarize").model
    assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model

    paths = @server.recorded.map(&:path)
    assert_equal 1, paths.count("/api/v1/prompts/greeting")
    assert_equal 1, paths.count("/api/v1/prompts/summarize")
  end

  def test_disk_restore_keeps_immutable_prompt_documents_per_key
    disk_path = File.join(@dir, "cache.json")
    client = build_client(disk_cache: disk_path)

    assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model
    @state["summarize"][:etag] = "\"summarize-v2\""
    @state["summarize"][:body] = prompt_json_with_model("summarize", "openai/changed-model")
    assert_equal "openai/changed-model", client.use_case("summarize").model

    @state["greeting"][:status] = 503
    @state["summarize"][:status] = 503
    restarted = build_client(disk_cache: disk_path)

    assert_equal "openai/gpt-4o-mini", restarted.use_case("greeting").model
    assert_equal "openai/changed-model", restarted.use_case("summarize").model
  end

  def test_late_validation_result_does_not_install_after_the_deadline
    client = build_client
    assert_in_delta 0.2, client.use_case("greeting").params["temperature"]
    @state["greeting"][:etag] = "\"greeting-v2\""
    @state["greeting"][:body] = prompt_json("greeting", temperature: 0.9)
    @clock.advance(10.01)

    original_parse = PromptOn::UseCaseDocument.method(:parse)
    advance_during_next_parse = true
    clock = @clock
    PromptOn::UseCaseDocument.define_singleton_method(:parse) do |body|
      parsed = original_parse.call(body)
      if advance_during_next_parse
        advance_during_next_parse = false
        clock.advance(1.01)
      end
      parsed
    end

    assert_in_delta 0.2, client.use_case("greeting").params["temperature"]
    assert_equal "\"greeting-v1\"", client.use_case("greeting").etag
  ensure
    PromptOn::UseCaseDocument.define_singleton_method(:parse) { |body| original_parse.call(body) } if original_parse
  end

  def test_export_writes_the_cached_prompt_document_as_a_bundle
    client = build_client
    client.use_case("greeting")

    client.export_use_case_document(bundle_path)

    offline = build_client(mode: :offline, api_key: nil, disk_cache: false, bundle: bundle_path)
    assert_equal "bundle", offline.use_case("greeting").source
  end

  private

  def bundle_path
    File.join(@dir, "use-cases.production.json")
  end

  def build_client(**overrides)
    options = client_options(logger: @logger, host: @server_url, _clock: @clock, **overrides)
    client = PromptOn::Client.new(**options)
    @clients << client
    client
  end

  def prompt_json(key, **options)
    document = snapshot_document(**options)
    keep_prompt!(document, key)
    JSON.generate(document)
  end

  def prompt_json_with_model(key, model)
    document = snapshot_document
    model_id = document.dig("deployments", key, "model_id")
    document.fetch("models").fetch(model_id)["model_id"] = model
    keep_prompt!(document, key)
    JSON.generate(document)
  end

  def keep_prompt!(document, key)
    document["use_cases"].select! { |candidate, _| candidate == key }
    document["deployments"].select! { |candidate, _| candidate == key }
    version_ids = document.dig("deployments", key, "prompt_pins")&.values || []
    model_id = document.dig("deployments", key, "model_id")
    document["prompt_versions"].select! { |id, _| version_ids.include?(id) }
    document["models"].select! { |id, _| id == model_id }
  end

  def respond(request)
    key = File.basename(request.path)
    state = @state.fetch(key)
    sleep(state[:delay]) if state[:delay]

    case state[:status]
    when 200
      if request.headers["if-none-match"] == state[:etag]
        [304, { "etag" => state[:etag] }, nil]
      else
        [200, { "etag" => state[:etag], "content-type" => "application/json",
                "last-modified" => "Fri, 04 Sep 2026 00:21:48 GMT" }, state[:body]]
      end
    when 304
      [304, { "etag" => state[:etag] }, nil]
    else
      [state[:status], { "content-type" => "application/json" },
       { "error" => { "code" => "unavailable", "details" => {} } }]
    end
  end
end
