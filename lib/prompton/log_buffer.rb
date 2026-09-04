# frozen_string_literal: true

require "json"
require_relative "errors"

module PromptOn
  # Batches monitoring logs and sends them to POST /generations.
  #
  # Nothing here ever blocks a provider call: #enqueue only appends and returns. A worker thread
  # sends on a size, byte or time trigger, at most 200 records and 4 MB per request (the server's
  # body limit is 5 MB), one batch per environment because the environment is forced on the whole
  # batch by the query parameter.
  #
  # Failure handling follows the contract: 429 and any 5xx retry the same batch with the same
  # ids (honouring Retry-After, otherwise backing off ×2 from 1 s up to 5 minutes) until the
  # attempt bound is reached, then the batch is dropped and counted; a 413 batch is split in
  # half; any other 4xx is dropped, counted and logged once. A 202 with `rejected` entries never
  # resends the accepted ids. The queue is bounded and drops the oldest records first.
  class LogBuffer
    MAX_RECORDS_PER_REQUEST = 200
    MAX_BATCH_BYTES = 4_000_000
    BACKOFF_START = 1.0
    BACKOFF_CAP = 300.0
    DROP_WARN_INTERVAL = 60.0

    # One queued record with the byte size and environment that decide how it is batched.
    Item = Struct.new(:record, :bytes, :environment, keyword_init: true)

    def initialize(config, http)
      @config = config
      @http = http
      @mutex = Mutex.new
      @send_mutex = Mutex.new
      @wake = ConditionVariable.new
      @queue = []
      @prebuilt = []
      @bytes = 0
      @oldest_at = nil
      @paused_until = 0.0
      @batch_attempts = 0
      @stopped = false
      @thread = nil
      @counters = Hash.new(0)
      @last_drop_warning = nil
    end

    def start
      return self if @thread&.alive?

      @stopped = false
      @thread = Thread.new { run }
      @thread.name = "prompton-logs"
      @thread.abort_on_exception = false
      self
    end

    # Appends one record. Returns immediately; the send happens on the worker thread.
    def enqueue(record, environment: @config.environment)
      json = JSON.generate(record)
      if json.bytesize > MAX_BATCH_BYTES
        count(:dropped_too_large)
        @config.logger.warn("[PromptOn] dropping monitoring log #{record["id"]}: " \
                            "#{json.bytesize} bytes exceeds the #{MAX_BATCH_BYTES}-byte request limit")
        return false
      end

      @mutex.synchronize do
        drop_oldest(@queue.length - @config.max_buffer + 1) if @queue.length >= @config.max_buffer
        @queue << Item.new(record: record, bytes: json.bytesize, environment: environment)
        @bytes += json.bytesize
        @oldest_at ||= now
        count(:enqueued)
        @wake.broadcast if trigger_reached?
      end
      true
    end

    # Sends everything queued now and waits for the result. This is what a script, a test or a
    # shutdown hook calls. Returns a summary hash.
    def flush(timeout: 5.0)
      deadline = now + timeout
      summary = Hash.new(0)

      loop do
        batch = @mutex.synchronize { now >= @paused_until ? take_batch : nil }
        break if batch.nil?

        merge_summary(summary, @send_mutex.synchronize { deliver(batch) })
        break if now >= deadline
      end

      summary
    end

    # Stops the worker thread after one last best-effort flush.
    def stop(timeout: 5.0)
      @mutex.synchronize do
        @stopped = true
        @wake.broadcast
      end
      @thread&.join(timeout)
      @thread = nil
      flush(timeout: timeout)
      self
    end

    def stats
      @mutex.synchronize do
        @counters.merge(queued: @queue.length, queued_bytes: @bytes,
                        pending_batches: @prebuilt.length,
                        paused_for: [@paused_until - now, 0.0].max.round(3))
      end
    end

    private

    def run
      loop do
        batch = @mutex.synchronize do
          loop do
            break nil if @stopped && (pending.zero? || now < @paused_until)
            break take_batch if ready?

            @wake.wait(@mutex, wait_time)
          end
        end
        break if batch.nil?

        @send_mutex.synchronize { deliver(batch) }
      end
    rescue StandardError => e
      @config.logger.error("[PromptOn] log buffer worker stopped: #{e.class}: #{e.message}")
    end

    def pending
      @queue.length + @prebuilt.sum(&:length)
    end

    def ready?
      return false if pending.zero?
      return false if now < @paused_until

      @stopped || !@prebuilt.empty? || trigger_reached?
    end

    def trigger_reached?
      return true if @queue.length >= @config.flush_size
      return true if @bytes >= @config.flush_bytes

      !@oldest_at.nil? && now - @oldest_at >= @config.flush_interval
    end

    def wait_time
      waits = [@config.flush_interval]
      waits << (@paused_until - now) if @paused_until > now
      waits << (@oldest_at + @config.flush_interval - now) if @oldest_at
      [waits.reject(&:negative?).min || @config.flush_interval, 0.05].max
    end

    # One request's worth: a batch left over from a 413 split first, otherwise as many queued
    # records of the same environment as fit the record and byte caps.
    def take_batch
      return nil if pending.zero?
      return @prebuilt.shift unless @prebuilt.empty?

      environment = @queue.first.environment
      batch = []
      bytes = 0

      while (item = @queue.first)
        break unless item.environment == environment
        break if batch.length >= MAX_RECORDS_PER_REQUEST
        break if !batch.empty? && bytes + item.bytes > MAX_BATCH_BYTES

        batch << @queue.shift
        bytes += item.bytes
        @bytes -= item.bytes
      end

      @oldest_at = @queue.empty? ? nil : now
      batch
    end

    def requeue(batch)
      @mutex.synchronize do
        @queue.unshift(*batch)
        @bytes += batch.sum(&:bytes)
        @oldest_at ||= now
        drop_oldest(@queue.length - @config.max_buffer) if @queue.length > @config.max_buffer
      end
    end

    def drop_oldest(amount)
      amount.times do
        item = @queue.shift or break

        @bytes -= item.bytes
        count(:dropped_buffer_full)
      end
      warn_dropped
    end

    def warn_dropped
      return if @last_drop_warning && now - @last_drop_warning < DROP_WARN_INTERVAL

      @last_drop_warning = now
      @config.logger.warn("[PromptOn] monitoring log buffer is full; dropped the oldest records " \
                          "(#{@counters[:dropped_buffer_full]} so far)")
    end

    def deliver(batch)
      response = @http.post_generations(batch.map(&:record), environment: batch.first.environment)
      handle(batch, response)
    rescue TransportError => e
      retry_later(batch, reason: e.message, retry_after: nil)
    end

    def handle(batch, response)
      status = response.status
      return accepted(batch, response) if status.between?(200, 299)
      return split(batch) if status == 413 && batch.length > 1
      return retry_later(batch, reason: "rate limited", retry_after: response.retry_after_seconds) if status == 429
      if status >= 500
        return retry_later(batch, reason: "server error #{status}",
                                  retry_after: response.retry_after_seconds)
      end

      drop(batch, "PromptOn rejected the batch with #{status}: #{summarize(response.body)}")
    end

    def accepted(batch, response)
      body = response.body.is_a?(Hash) ? response.body : {}
      rejected = body["rejected"] || []
      unless rejected.empty?
        count(:rejected, rejected.length)
        @config.logger.warn("[PromptOn] #{rejected.length} monitoring log(s) rejected: #{rejected.first(3).inspect}")
      end

      @mutex.synchronize do
        @batch_attempts = 0
        @paused_until = 0.0
      end
      count(:sent, batch.length)
      count(:accepted, body["accepted"].to_i)
      count(:duplicates, body["duplicates"].to_i)
      { sent: batch.length, accepted: body["accepted"].to_i, duplicates: body["duplicates"].to_i,
        rejected: rejected.length }
    end

    def split(batch)
      half = batch.length / 2
      @mutex.synchronize { @prebuilt.unshift(batch[0...half], batch[half..]) }
      count(:split)
      @config.logger.warn("[PromptOn] batch of #{batch.length} monitoring logs was too large; splitting in half")
      { split: 1 }
    end

    def retry_later(batch, reason:, retry_after:)
      attempts = @mutex.synchronize { @batch_attempts += 1 }
      if attempts >= @config.max_send_attempts
        @mutex.synchronize { @batch_attempts = 0 }
        return drop(batch, "giving up after #{attempts} attempts (#{reason})")
      end

      delay = retry_after || [BACKOFF_START * (2**(attempts - 1)), BACKOFF_CAP].min
      requeue(batch)
      @mutex.synchronize { @paused_until = now + delay }
      count(:retries)
      @config.logger.warn("[PromptOn] monitoring logs not sent (#{reason}); retrying " \
                          "#{batch.length} record(s) in #{delay.round(1)}s")
      { retried: batch.length }
    end

    def drop(batch, reason)
      count(:dropped_rejected, batch.length)
      @config.logger.error("[PromptOn] dropping #{batch.length} monitoring log(s): #{reason}")
      { dropped: batch.length }
    end

    def summarize(body)
      body.is_a?(String) ? body[0, 200] : JSON.generate(body)[0, 200]
    rescue StandardError
      body.class.to_s
    end

    def merge_summary(summary, result)
      result.each { |key, value| summary[key] += value } if result.is_a?(Hash)
      summary
    end

    def count(key, amount = 1)
      @counters[key] += amount
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
