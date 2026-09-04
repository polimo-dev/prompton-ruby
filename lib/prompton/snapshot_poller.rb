# frozen_string_literal: true

require_relative "errors"

module PromptOn
  # Keeps the snapshot fresh without ever standing between the app and its provider call.
  #
  # Within the cache TTL (10 s by default) every resolve is served from memory with no HTTP call.
  # Once the TTL has passed the document is refreshed with `If-None-Match` — in a background poll
  # loop, or, when polling is off, by a stale-while-revalidate refresh the next call triggers.
  # A refresh never blocks and never fails a log: while one is in flight, and if it fails,
  # the previous document is what every resolve reads.
  #
  # On 429 the Retry-After header (then error.details.retry_after, then the backoff) decides when
  # the server may be contacted again. 5xx, timeouts and transport errors back off ×2 from the
  # TTL up to five minutes. In every case the caller keeps the previous document, never an error.
  #
  # The one time a caller does wait is the cold start: nothing in memory, nothing on disk, no
  # bundle. Then #ensure_document fetches once in the calling thread, because there is nothing
  # else to serve.
  class SnapshotPoller
    # +clock+ is the monotonic clock, injectable so a test can pretend the host booted a moment
    # ago — the reading a cold start used to get wrong.
    def initialize(config, store, http, clock: nil)
      @config = config
      @store = store
      @http = http
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @mutex = Mutex.new
      @attempt_mutex = Mutex.new
      @wake = ConditionVariable.new
      @last_attempt = nil
      @next_allowed_at = 0.0
      @failures = 0
      @refreshing = false
      @stopped = false
      @thread = nil
      @refresh_thread = nil
    end

    # Starts the background poll loop. A no-op unless polling is enabled and remote calls are
    # possible at all.
    def start
      return self unless @config.remote? && @config.poll
      return self if @thread&.alive?

      @mutex.synchronize { @stopped = false }
      @thread = Thread.new { poll_loop }
      @thread.name = "prompton-snapshot"
      @thread.abort_on_exception = false
      self
    end

    # Stops the poll loop and waits briefly for an in-flight background refresh, so a script that
    # resolves once and exits still gets that refresh's disk write.
    def stop
      @mutex.synchronize do
        @stopped = true
        @wake.broadcast
      end
      @thread&.join(2)
      @thread = nil
      @mutex.synchronize { @refresh_thread }&.join(2)
      @mutex.synchronize { @refresh_thread = nil }
      self
    end

    # Called by every resolve once a document is in hand. Triggers a background refresh when the
    # TTL has passed and no poll loop is covering it. Returns immediately either way.
    def ensure_fresh
      return if !@config.remote? || @thread&.alive?
      return unless claim_refresh

      thread = Thread.new do
        attempt(only_if_due: true)
      ensure
        @mutex.synchronize { @refreshing = false }
      end
      thread.name = "prompton-snapshot-refresh"
      thread.abort_on_exception = false
      @mutex.synchronize { @refresh_thread = thread }
      nil
    end

    # Makes sure some document is available, waiting for one fetch if there is nothing at all to
    # serve. Returns true when the store holds a document afterwards.
    def ensure_document
      return true unless @store.entry.nil?
      return false unless @config.remote?

      @attempt_mutex.synchronize do
        # Another thread may have installed one while we waited for this lock.
        next true unless @store.entry.nil?
        next false if due_in.positive?

        perform
      end

      !@store.entry.nil?
    end

    # Fetches once, now, in the calling thread. Returns true on success; never raises.
    def refresh
      refresh!
      true
    rescue Error
      false
    end

    # Fetches once, now, in the calling thread, and raises PromptOn::ApiError or
    # PromptOn::TransportError when it fails. This is the "fetch once now" a script wants.
    def refresh!
      unless @config.remote?
        return true if @store.load_local

        raise NotReadyError
      end

      attempt(raise_on_error: true)
    end

    def status
      @mutex.synchronize do
        { last_attempt_at: @last_attempt, failures: @failures,
          polling: !@thread.nil? && @thread.alive?,
          next_attempt_in: [@next_allowed_at - now, 0.0].max.round(3) }
      end
    end

    private

    # +only_if_due+ makes a background refresh a no-op when another thread has just done one, so
    # a burst of concurrent resolves costs a single fetch rather than one each.
    def attempt(raise_on_error: false, only_if_due: false)
      @attempt_mutex.synchronize do
        next false if only_if_due && due_in.positive?

        perform(raise_on_error: raise_on_error)
      end
    end

    def claim_refresh
      @mutex.synchronize do
        next false if @refreshing || @stopped || due_in_locked.positive?

        @refreshing = true
      end
    end

    def poll_loop
      loop do
        wait = @mutex.synchronize do
          break nil if @stopped

          delay = due_in_locked
          @wake.wait(@mutex, delay) if delay.positive?
          @stopped ? nil : due_in_locked
        end
        break if wait.nil?
        next if wait.positive?

        attempt(only_if_due: true)
      end
    rescue StandardError => e
      @config.logger.error("[PromptOn] snapshot poll loop stopped: #{e.class}: #{e.message}")
    end

    # Seconds until the server may be contacted again: the cache TTL since the last attempt, or
    # the backoff / Retry-After window, whichever is later.
    #
    # Having never attempted a fetch means "due now", not "due at absolute time cache_ttl": the
    # clock is monotonic and starts near zero at boot, so treating a missing @last_attempt as 0.0
    # would hold the very first fetch back for the whole TTL on a freshly booted host.
    def due_in
      @mutex.synchronize { due_in_locked }
    end

    def due_in_locked
      current = now
      due_at = [@last_attempt ? @last_attempt + @config.cache_ttl : current, @next_allowed_at].max
      [due_at - current, 0.0].max
    end

    def perform(raise_on_error: false)
      current = @store.entry
      @mutex.synchronize { @last_attempt = now }
      response = @http.get_snapshot(environment: @config.environment, etag: current&.etag)
      handle(response, raise_on_error: raise_on_error)
    rescue TransportError => e
      failed(e.message, raise_on_error: raise_on_error, error: e)
    end

    def handle(response, raise_on_error:)
      case response.status
      when 200
        @store.install_remote(response.body, etag: response.etag,
                                             last_modified: response.header("last-modified"))
        succeeded
        true
      when 304
        @store.confirm_current
        succeeded
        true
      when 429
        failed("rate limited by PromptOn", retry_after: response.retry_after_seconds,
                                           raise_on_error: raise_on_error,
                                           error: ApiError.new(429, response.body))
      else
        failed("PromptOn answered #{response.status}", retry_after: response.retry_after_seconds,
                                                       raise_on_error: raise_on_error,
                                                       error: ApiError.new(response.status, response.body))
      end
    rescue InvalidSnapshotError => e
      failed(e.message, raise_on_error: raise_on_error, error: e)
    end

    def succeeded
      @mutex.synchronize do
        @failures = 0
        @next_allowed_at = now + @config.cache_ttl
      end
    end

    def failed(reason, retry_after: nil, raise_on_error: false, error: nil)
      delay = @mutex.synchronize do
        @failures += 1
        computed = retry_after || [@config.cache_ttl * (2**(@failures - 1)), @config.max_backoff].min
        @next_allowed_at = now + computed
        computed
      end

      @store.mark_stale
      @config.logger.warn(
        "[PromptOn] snapshot refresh failed (#{reason}); serving the cached snapshot, " \
        "next attempt in #{delay.round(1)}s"
      )
      raise error if raise_on_error && error

      false
    end

    def now
      @clock.call
    end
  end
end
