# frozen_string_literal: true

require_relative "test_helper"

# The caching rules the SDK promises: a 10-second memory cache, ETag polling, Retry-After on 429,
# exponential backoff on everything else, and the last good document served through all of it.
class SnapshotCacheTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("prompton-cache")
    @logger = MemoryLogger.new
    @state = { body: snapshot_json, etag: "\"v1\"", status: 200, retry_after: nil, delay: nil }
    @server = PromptOnTest::StubServer.new { |request| respond(request) }
    @server_url = @server.url
    @clients = []
  end

  def teardown
    @clients.each(&:close)
    @server.stop
    FileUtils.remove_entry(@dir)
  end

  def test_within_the_ttl_every_resolve_is_served_from_memory_with_no_http_call
    client = build_client(cache_ttl: 30.0)

    10.times { assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model }

    assert_equal 1, @server.request_count, "one boot fetch, then nothing"
  end

  def test_after_the_ttl_the_document_is_refreshed_with_if_none_match
    client = build_client(cache_ttl: 0.05)
    client.use_case("greeting")

    sleep(0.1)
    client.use_case("greeting")

    wait_until { @server.request_count >= 2 }
    assert_equal "\"v1\"", @server.recorded.last.headers["if-none-match"]
    assert_equal "remote", client.use_case_document_info[:source]
  end

  def test_a_304_leaves_the_document_in_place
    client = build_client(cache_ttl: 0.05)
    client.use_case("greeting")
    sleep(0.1)

    assert client.refresh
    assert_equal 304, last_status
    assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model
  end

  def test_a_new_revision_is_picked_up_on_the_next_poll
    client = build_client(cache_ttl: 0.05)
    assert_in_delta 0.2, client.use_case("greeting").params["temperature"]

    @state[:body] = snapshot_json(temperature: 0.9)
    @state[:etag] = "\"v2\""
    sleep(0.1)
    client.refresh

    assert_in_delta 0.9, client.use_case("greeting").params["temperature"]
  end

  def test_a_burst_of_concurrent_resolves_costs_one_refresh_not_one_each
    client = build_client(cache_ttl: 0.05)
    client.use_case("greeting")
    @state[:delay] = 0.05
    sleep(0.1)

    threads = Array.new(20) { Thread.new { client.use_case("greeting").model } }
    assert_equal ["openai/gpt-4o-mini"], threads.map(&:value).uniq

    wait_until { @server.request_count >= 2 }
    sleep(0.2)
    assert_equal 2, @server.request_count
  end

  def test_resolved_evidence_is_frozen_so_it_can_be_shared_between_threads
    client = build_client
    use_case = client.use_case("greeting")

    assert_predicate use_case.__send__(:evidence), :frozen?
    assert_predicate client.use_case_document, :frozen?
  end

  def test_a_refresh_in_flight_never_blocks_a_provider_call
    client = build_client(cache_ttl: 0.05)
    client.use_case("greeting")

    @state[:delay] = 1.0
    sleep(0.1)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.use_case("greeting")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.3, "the stale-while-revalidate refresh must not block the caller"
  end

  def test_a_429_waits_out_retry_after_and_the_caller_never_sees_an_error
    client = build_client(cache_ttl: 0.01)
    client.use_case("greeting")

    @state[:status] = 429
    @state[:retry_after] = 30
    client.refresh
    after_429 = @server.request_count

    5.times do
      sleep(0.02)
      assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model
    end

    assert_equal after_429, @server.request_count, "no request before Retry-After has elapsed"
    assert(@logger.lines.any? { |line| line.include?("serving the cached snapshot") })
  end

  def test_retry_after_can_also_arrive_in_the_error_details
    client = build_client(cache_ttl: 0.01)
    client.use_case("greeting")

    @state[:status] = :rate_limited_with_details
    refute client.refresh
    after_429 = @server.request_count

    3.times do
      sleep(0.02)
      client.use_case("greeting")
    end

    assert_equal after_429, @server.request_count
    assert_operator client.use_case_document_status[:next_attempt_in], :>, 25
  end

  def test_a_5xx_backs_off_from_the_ttl_doubling_each_time
    client = build_client(cache_ttl: 1.0)
    client.use_case("greeting")
    @state[:status] = 503

    refute client.refresh
    assert_in_delta 1.0, client.use_case_document_status[:next_attempt_in], 0.2

    refute client.refresh
    assert_in_delta 2.0, client.use_case_document_status[:next_attempt_in], 0.2

    refute client.refresh
    assert_in_delta 4.0, client.use_case_document_status[:next_attempt_in], 0.2
  end

  def test_a_5xx_keeps_serving_the_previous_document
    client = build_client(cache_ttl: 1.0)
    client.use_case("greeting")

    @state[:status] = 503
    refute client.refresh
    after_failure = @server.request_count

    3.times { assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model }

    assert_equal after_failure, @server.request_count, "no request before the backoff has elapsed"
    assert client.use_case_document_info[:stale]
    assert_equal 1, client.use_case_document_status[:failures]
  end

  def test_when_prompton_is_down_the_previous_document_still_answers
    client = build_client(cache_ttl: 0.01)
    client.use_case("greeting")
    @server.stop

    3.times do
      sleep(0.02)
      assert_equal "openai/gpt-4o-mini", client.use_case("greeting").model
    end
  end

  def test_a_cold_start_with_nothing_cached_fails_with_a_clear_error
    client = build_client(host: PromptOnTest::StubServer.dead_url)

    error = assert_raises(PromptOn::NotReadyError) { client.use_case("greeting") }

    assert_includes error.message, "unreachable"
    assert_includes error.message, "nothing is cached"
  end

  def test_the_first_fetch_is_due_immediately_on_a_freshly_booted_host
    # CLOCK_MONOTONIC counts from boot, so on a host that has been up for less than cache_ttl
    # seconds a "never attempted" marker of 0.0 sits in the future: the first fetch would be held
    # back and a healthy server reported as unreachable for the whole TTL.
    config = PromptOn::Config.new(**client_options(logger: @logger, host: @server_url,
                                                   cache_ttl: 600.0))
    store = PromptOn::SnapshotStore.new(config)
    poller = PromptOn::SnapshotPoller.new(config, store, PromptOn::Http.new(config),
                                          clock: -> { 5.0 })

    assert poller.ensure_document, "the first fetch is due now, not cache_ttl seconds from now"
    assert_equal 1, @server.request_count
    assert_equal "openai/gpt-4o-mini", PromptOn::Resolver.resolve(store.data, "greeting").model
  end

  def test_a_fetch_that_has_just_happened_is_not_due_again_within_the_ttl
    config = PromptOn::Config.new(**client_options(logger: @logger, host: @server_url,
                                                   cache_ttl: 600.0))
    store = PromptOn::SnapshotStore.new(config)
    poller = PromptOn::SnapshotPoller.new(config, store, PromptOn::Http.new(config),
                                          clock: -> { 5.0 })
    poller.ensure_document

    store.clear
    refute poller.ensure_document, "the TTL still applies once an attempt has been made"
    assert_equal 1, @server.request_count
  end

  def test_close_waits_for_the_background_refresh_so_its_disk_write_lands
    File.write(bundle_path, snapshot_json)
    client = build_client(disk_cache: disk_path, bundle: bundle_path)
    @state[:delay] = 0.2

    assert_equal "bundle", client.use_case("greeting").source
    client.close

    assert_path_exists disk_path, "the in-flight refresh finishes before close returns"
    assert_path_exists "#{disk_path}.meta.json"
  end

  def test_the_disk_cache_survives_a_restart_with_prompton_down
    build_client(disk_cache: disk_path).use_case("greeting")
    @server.stop

    restarted = build_client(disk_cache: disk_path, host: PromptOnTest::StubServer.dead_url)

    assert_equal "openai/gpt-4o-mini", restarted.use_case("greeting").model
    assert_equal "disk", restarted.use_case_document_info[:source]
    assert_equal "disk", restarted.use_case("greeting").source
  end

  def test_the_bundle_answers_when_memory_and_disk_are_empty
    File.write(bundle_path, snapshot_json)
    client = build_client(disk_cache: File.join(@dir, "absent.json"), bundle: bundle_path,
                          host: PromptOnTest::StubServer.dead_url)

    assert_equal "bundle", client.use_case("greeting").source
  end

  def test_a_bundle_from_another_environment_is_refused
    File.write(bundle_path, snapshot_json(environment: "staging"))
    client = build_client(disk_cache: false, bundle: bundle_path,
                          host: PromptOnTest::StubServer.dead_url)

    assert_raises(PromptOn::NotReadyError) { client.use_case("greeting") }
  end

  def test_fetch_once_now_is_available_for_scripts
    client = build_client(cache_ttl: 300.0)
    assert client.refresh!
    assert_equal 1, @server.request_count

    assert client.refresh!, "refresh! ignores the cache window"
    assert_equal 2, @server.request_count
  end

  def test_refresh_raises_the_underlying_failure_while_refresh_reports_it
    client = build_client
    @state[:status] = 500

    refute client.refresh
    assert_raises(PromptOn::ApiError) { client.refresh! }
  end

  def test_the_current_document_can_be_exported_as_a_bundle
    client = build_client
    client.use_case("greeting")

    client.export_use_case_document(bundle_path)

    offline = build_client(mode: :offline, api_key: nil, disk_cache: false, bundle: bundle_path)
    assert_equal "bundle", offline.use_case("greeting").source
  end

  private

  def disk_path
    File.join(@dir, "snapshot.json")
  end

  def bundle_path
    File.join(@dir, "use-cases.production.json")
  end

  attr_reader :last_status

  def build_client(**overrides)
    options = client_options(logger: @logger, host: @server_url, **overrides)
    client = PromptOn::Client.new(**options)
    @clients << client
    client
  end

  def respond(request)
    sleep(@state[:delay]) if @state[:delay]

    case @state[:status]
    when 200
      if request.headers["if-none-match"] == @state[:etag]
        @last_status = 304
        [304, { "etag" => @state[:etag] }, nil]
      else
        @last_status = 200
        [200, { "etag" => @state[:etag], "content-type" => "application/json",
                "last-modified" => "Fri, 04 Sep 2026 00:21:48 GMT" }, @state[:body]]
      end
    when :rate_limited_with_details
      @last_status = 429
      [429, { "content-type" => "application/json" },
       { "error" => { "code" => "rate_limited", "message" => "slow down",
                      "details" => { "retry_after" => 30 } } }]
    else
      @last_status = @state[:status]
      headers = { "content-type" => "application/json" }
      headers["Retry-After"] = @state[:retry_after].to_s if @state[:retry_after]
      [@state[:status], headers, { "error" => { "code" => "unavailable", "details" => {} } }]
    end
  end
end
