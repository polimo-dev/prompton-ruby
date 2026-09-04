# frozen_string_literal: true

require_relative "test_helper"

# Batching, retries and the bounded queue. Nothing here may ever block or fail a provider call.
class LogBufferTest < Minitest::Test
  def setup
    @logger = MemoryLogger.new
    @behaviour = ->(_request) { [202, {}, { "accepted" => 1, "duplicates" => 0, "rejected" => [] }] }
    @server = PromptOnTest::StubServer.new { |request| @behaviour.call(request) }
    @server_url = @server.url
    @buffers = []
  end

  def teardown
    @buffers.each { |buffer| buffer.stop(timeout: 0.5) }
    @server.stop
  end

  def test_flush_sends_what_is_queued_and_reports_the_result
    buffer = build_buffer
    3.times { |index| buffer.enqueue(record(index)) }

    summary = buffer.flush

    assert_equal 1, @server.request_count
    assert_equal 3, summary[:sent]
    assert_equal 3, sent_batches.first.length
    assert_equal "production", @server.recorded.first.query["environment"]
  end

  def test_a_batch_never_exceeds_two_hundred_records
    buffer = build_buffer
    250.times { |index| buffer.enqueue(record(index)) }

    buffer.flush

    assert_equal [200, 50], sent_batches.map(&:length)
  end

  def test_one_batch_per_environment_because_the_query_parameter_forces_it
    buffer = build_buffer
    buffer.enqueue(record(1), environment: "production")
    buffer.enqueue(record(2), environment: "staging")
    buffer.enqueue(record(3), environment: "production")

    buffer.flush

    assert_equal(%w[production staging production], @server.recorded.map { |r| r.query["environment"] })
    assert_equal [1, 1, 1], sent_batches.map(&:length)
  end

  def test_partial_acceptance_never_resends_the_accepted_ids
    @behaviour = lambda do |_request|
      [202, {}, { "accepted" => 2, "duplicates" => 0,
                  "rejected" => [{ "index" => 1, "id" => "x", "code" => "invalid_request",
                                   "message" => "id must be a UUID" }] }]
    end
    buffer = build_buffer
    3.times { |index| buffer.enqueue(record(index)) }

    buffer.flush
    buffer.flush

    assert_equal 1, @server.request_count, "a 202 is final, rejected entries included"
    assert_equal 1, buffer.stats[:rejected]
    assert(@logger.lines.any? { |line| line.include?("rejected") })
  end

  def test_a_429_retries_the_same_batch_with_the_same_ids
    attempts = 0
    @behaviour = lambda do |_request|
      attempts += 1
      attempts == 1 ? [429, { "Retry-After" => "0" }, { "error" => { "code" => "rate_limited" } }] : ok
    end
    buffer = build_buffer
    2.times { |index| buffer.enqueue(record(index)) }

    buffer.flush

    assert_equal 2, @server.request_count
    assert_equal(sent_batches[0].map { |r| r["id"] }, sent_batches[1].map { |r| r["id"] })
    assert_equal 1, buffer.stats[:retries]
  end

  def test_a_429_honours_retry_after_before_trying_again
    @behaviour = ->(_request) { [429, { "Retry-After" => "30" }, { "error" => {} }] }
    buffer = build_buffer
    buffer.enqueue(record(1))

    buffer.flush
    second = buffer.flush

    assert_equal 1, @server.request_count
    assert_equal 1, buffer.stats[:queued], "the batch stays queued, later records queue behind it"
    assert_operator buffer.stats[:paused_for], :>, 25
    assert_equal 1, second[:queued], "a flush that sends nothing says what it left behind"
    assert_operator second[:paused_for], :>, 25
  end

  def test_a_flush_with_an_empty_queue_is_still_an_empty_summary
    assert_empty build_buffer.flush
  end

  def test_a_pause_shorter_than_the_shutdown_budget_is_waited_out
    attempts = 0
    @behaviour = lambda do |_request|
      attempts += 1
      attempts == 1 ? [429, { "Retry-After" => "1" }, { "error" => {} }] : ok
    end
    buffer = build_buffer
    buffer.enqueue(record(1))

    buffer.flush
    assert_equal 1, buffer.stats[:queued]

    buffer.stop(timeout: 3.0)

    assert_equal 2, @server.request_count
    assert_equal 0, buffer.stats[:queued]
    assert_equal 0, buffer.stats[:dropped_on_shutdown]
  end

  def test_a_pause_longer_than_the_shutdown_budget_drops_loudly_rather_than_silently
    @behaviour = ->(_request) { [429, { "Retry-After" => "60" }, { "error" => {} }] }
    buffer = build_buffer
    2.times { |index| buffer.enqueue(record(index)) }

    buffer.flush
    buffer.stop(timeout: 0.2)

    assert_equal 1, @server.request_count
    assert_equal 2, buffer.stats[:dropped_on_shutdown]
    assert_equal 0, buffer.stats[:queued]
    assert(@logger.lines.any? { |line| line.include?("dropping 2 unsent monitoring log") })
  end

  def test_a_5xx_retries_and_then_drops_the_batch_once_the_attempts_run_out
    @behaviour = ->(_request) { [503, { "Retry-After" => "0" }, { "error" => {} }] }
    buffer = build_buffer(max_send_attempts: 3)
    buffer.enqueue(record(1))

    buffer.flush

    assert_equal 3, @server.request_count
    assert_equal 1, buffer.stats[:dropped_rejected]
    assert_equal 0, buffer.stats[:queued]
  end

  def test_a_transport_failure_is_retried_like_a_5xx_and_backs_off
    @server.stop
    buffer = build_buffer(max_send_attempts: 4)
    buffer.enqueue(record(1))

    buffer.flush

    assert_equal 1, buffer.stats[:retries]
    assert_equal 1, buffer.stats[:queued], "the record is kept for the next attempt"
    assert_in_delta 1.0, buffer.stats[:paused_for], 0.2, "the backoff starts at one second"
    assert(@logger.lines.any? { |line| line.include?("not sent") })
  end

  def test_a_413_batch_is_split_in_half
    @behaviour = lambda do |request|
      JSON.parse(request.body)["generations"].length > 2 ? [413, {}, { "error" => {} }] : ok
    end
    buffer = build_buffer
    4.times { |index| buffer.enqueue(record(index)) }

    buffer.flush

    assert_equal [4, 2, 2], sent_batches.map(&:length)
    assert_equal 1, buffer.stats[:split]
  end

  def test_any_other_4xx_drops_the_batch_without_retrying
    @behaviour = ->(_request) { [400, {}, { "error" => { "code" => "invalid_request" } }] }
    buffer = build_buffer
    2.times { |index| buffer.enqueue(record(index)) }

    buffer.flush
    buffer.flush

    assert_equal 1, @server.request_count
    assert_equal 2, buffer.stats[:dropped_rejected]
    assert(@logger.lines.any? { |line| line.include?("dropping 2 monitoring log") })
  end

  def test_the_queue_is_bounded_and_drops_the_oldest_first
    buffer = build_buffer(max_buffer: 5)
    8.times { |index| buffer.enqueue(record(index)) }

    buffer.flush

    assert_equal 3, buffer.stats[:dropped_buffer_full]
    assert_equal(%w[3 4 5 6 7], sent_batches.first.map { |r| r["trace_id"] })
    assert(@logger.lines.any? { |line| line.include?("buffer is full") })
  end

  def test_a_single_record_larger_than_a_request_is_dropped_on_the_spot
    buffer = build_buffer
    refute buffer.enqueue(record(1).merge("output" => { "content" => "x" * 4_100_000 }))

    assert_equal 1, buffer.stats[:dropped_too_large]
    assert_equal 0, buffer.stats[:queued]
  end

  def test_the_worker_thread_flushes_on_the_time_trigger
    buffer = build_buffer(flush_interval: 0.05, flush_size: 1000).start
    buffer.enqueue(record(1))

    wait_until { @server.request_count == 1 }
    assert_equal 1, sent_batches.first.length
  end

  def test_stopping_drains_what_is_left
    buffer = build_buffer(flush_interval: 60.0, flush_size: 1000).start
    3.times { |index| buffer.enqueue(record(index)) }

    buffer.stop(timeout: 2.0)

    assert_equal 1, @server.request_count
    assert_equal 3, sent_batches.first.length
  end

  private

  def ok
    [202, {}, { "accepted" => 1, "duplicates" => 0, "rejected" => [] }]
  end

  def sent_batches
    @server.recorded.map { |request| JSON.parse(request.body)["generations"] }
  end

  def record(index)
    { "id" => PromptOn::UuidV7.generate, "use_case" => "greeting", "model" => "openai/gpt-4o-mini",
      "status" => "ok", "started_at" => Time.now.utc.iso8601(6), "trace_id" => index.to_s }
  end

  def build_buffer(**overrides)
    config = PromptOn::Config.new(**client_options(logger: @logger, host: @server_url, **overrides))
    buffer = PromptOn::LogBuffer.new(config, PromptOn::Http.new(config))
    @buffers << buffer
    buffer
  end
end
