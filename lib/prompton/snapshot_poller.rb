# frozen_string_literal: true

require_relative "errors"

module PromptOn
  # Demand-driven prompt config fetcher. The class keeps the legacy name because it is part of the
  # internal wiring, but it no longer polls: remote config is fetched only when a prompt key is
  # resolved for an LLM call.
  class SnapshotPoller
    State = Struct.new(:last_attempt_at, :last_success_at, :inflight, :failures, keyword_init: true)
    Inflight = Struct.new(:done, :ok, :deadline_at, :condition, keyword_init: true)

    def initialize(config, store, http, clock: nil)
      @config = config
      @store = store
      @http = http
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @mutex = Mutex.new
      @states = {}
    end

    def start
      self
    end

    def stop
      self
    end

    def ensure_fresh(_prompt_key = nil)
      nil
    end

    def ensure_prompt(prompt_key)
      key = prompt_key.to_s
      @store.load_local if @store.entry.nil?
      return true if fresh?(key)
      return !@store.prompt_entry(key).nil? unless @config.remote?

      inflight, owner = claim(key)
      return wait_for(key, inflight) unless owner

      perform(key, inflight)
      !@store.prompt_entry(key).nil?
    end

    alias ensure_document ensure_prompt

    def refresh(prompt_key = nil)
      refresh!(prompt_key)
      true
    rescue Error
      false
    end

    def refresh!(prompt_key = nil)
      unless @config.remote?
        return true if @store.load_local

        raise NotReadyError
      end

      keys = prompt_key ? [prompt_key.to_s] : known_keys
      raise NotReadyError if keys.empty?

      keys.each do |key|
        inflight, owner = claim(key)
        owner ? perform(key, inflight, raise_on_error: true) : wait_for(key, inflight, raise_on_error: true)
      end
      true
    end

    def status(prompt_key = nil)
      @mutex.synchronize do
        if prompt_key
          state = @states[prompt_key.to_s]
          return state_status(state)
        end

        { last_attempt_at: @states.values.filter_map(&:last_attempt_at).max,
          failures: @states.values.sum { |state| state.failures || 0 },
          polling: false,
          next_attempt_in: @states.values.map { |state| due_in_locked(state) }.min || 0.0 }
      end
    end

    private

    def fresh?(key)
      entry = @store.prompt_entry(key)
      return false if entry.nil? || entry.source != "remote"

      now - monotonic_success_at(key, entry) < @config.cache_ttl
    end

    def claim(key, force: false)
      @mutex.synchronize do
        state = (@states[key] ||= State.new(failures: 0))
        return [state.inflight, false] if state.inflight
        return [nil, false] if !force && state.last_attempt_at && now - state.last_attempt_at < @config.cache_ttl

        inflight = Inflight.new(done: false, ok: false, deadline_at: now + @config.config_fetch_timeout,
                                condition: ConditionVariable.new)
        state.last_attempt_at = now
        state.inflight = inflight
        [inflight, true]
      end
    end

    def wait_for(key, inflight, raise_on_error: false)
      return !@store.prompt_entry(key).nil? if inflight.nil?

      @mutex.synchronize do
        until inflight.done
          remaining = inflight.deadline_at - now
          break if remaining <= 0

          inflight.condition.wait(@mutex, remaining)
        end
      end
      entry = @store.prompt_entry(key)
      raise NotReadyError if raise_on_error && entry.nil?

      !entry.nil?
    end

    def perform(key, inflight, raise_on_error: false)
      error = nil
      ok = false
      begin
        current = @store.prompt_entry(key)
        budget = [inflight.deadline_at - now, 0.001].max
        response = @http.get_prompt(key, environment: @config.environment, etag: current&.etag,
                                         timeout: budget)
        ok = handle(key, response, inflight.deadline_at)
      rescue Error => e
        error = e
        failed(key, e.message)
      rescue StandardError => e
        error = TransportError.new("#{e.class}: #{e.message}")
        failed(key, error.message)
      ensure
        finish(key, inflight, ok)
      end
      raise error if raise_on_error && error && @store.prompt_entry(key).nil?

      ok
    end

    def handle(key, response, deadline_at)
      if now > deadline_at
        failed(key, "config fetch exceeded #{@config.config_fetch_timeout}s")
        return false
      end

      case response.status
      when 200
        @store.install_prompt_remote(key, response.body, etag: response.etag,
                                                         last_modified: response.header("last-modified"),
                                                         deadline_expired: -> { now > deadline_at })
        succeeded(key)
        true
      when 304
        unless @store.prompt_entry(key)
          failed(key, "PromptOn answered 304 without a cached prompt")
          return false
        end
        @store.confirm_current(key, etag: response.etag, last_modified: response.header("last-modified"))
        succeeded(key)
        true
      else
        failed(key, "PromptOn answered #{response.status}")
        raise ApiError.new(response.status, response.body) if @store.prompt_entry(key).nil?

        false
      end
    rescue InvalidUseCaseDocumentError => e
      failed(key, e.message)
      raise e if @store.prompt_entry(key).nil?

      false
    end

    def succeeded(key)
      @mutex.synchronize do
        state = (@states[key] ||= State.new(failures: 0))
        state.last_success_at = now
        state.failures = 0
      end
    end

    def failed(key, reason)
      @store.mark_stale(key)
      @mutex.synchronize do
        state = (@states[key] ||= State.new(failures: 0))
        state.failures = state.failures.to_i + 1
      end
      @config.logger.warn("[PromptOn] config fetch for #{key.inspect} failed (#{reason}); serving cached config")
      false
    end

    def finish(key, inflight, success)
      @mutex.synchronize do
        state = @states[key]
        state.inflight = nil if state&.inflight.equal?(inflight)
        inflight.ok = success
        inflight.done = true
        inflight.condition.broadcast
      end
    end

    def known_keys
      @store.entry&.data&.use_case_keys || []
    end

    def state_status(state)
      { last_attempt_at: state&.last_attempt_at, failures: state&.failures.to_i,
        polling: false, next_attempt_in: due_in_locked(state).round(3) }
    end

    def due_in_locked(state)
      return 0.0 unless state&.last_attempt_at

      [state.last_attempt_at + @config.cache_ttl - now, 0.0].max
    end

    def monotonic_success_at(key, entry)
      @mutex.synchronize do
        state = (@states[key] ||= State.new(failures: 0))
        state.last_success_at ||= now - (Time.now - entry.fetched_at)
      end
    end

    def now
      @clock.call
    end
  end
end
