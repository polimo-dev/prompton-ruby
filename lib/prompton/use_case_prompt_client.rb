# frozen_string_literal: true

require_relative "errors"
require_relative "use_case_evidence"

module PromptOn
  # The POST /use-cases/{key}/prompt path: the simple way in, and the smoke test.
  #
  # It follows the same resilience rules as the use-case document store. A response fetched without
  # variables is cached for the cache TTL per (use case, prompt, environment) and rendered
  # locally, so a hot loop never becomes one HTTP call per provider call; on 429, 5xx or a transport
  # failure the cached response is served instead of raising.
  #
  # For anything but a smoke test or a low-traffic path, prefer the local use-case document:
  # the prompt endpoint is not a hot-loop endpoint.
  class UseCasePromptClient
    CacheEntry = Struct.new(:body, :expires_at, keyword_init: true)

    def initialize(config, http)
      @config = config
      @http = http
      @mutex = Mutex.new
      @cache = {}
    end

    # A use-case evidence built from the server's answer.
    #
    # Passing +variables+ renders them locally into the returned evidence, so #messages (chat)
    # or #text (text) carry the rendered prompt rather than the template. Without them the
    # template comes back as it is and you call #render yourself.
    def resolve(use_case, prompt: nil, environment: nil, variables: nil)
      body = fetch(use_case, prompt: prompt, environment: environment)
      evidence = to_use_case_evidence(body, use_case.to_s)
      return evidence if variables.nil?

      evidence.with_rendered(evidence.render(variables))
    end

    # The raw POST /use-cases/{key}/prompt response body.
    #
    # Passing +variables+ asks the server to render, which is the smoke-test path and is never
    # cached. Without them the response is cached for the cache TTL.
    def fetch(use_case, prompt: nil, environment: nil, variables: nil)
      key = [use_case.to_s, prompt&.to_s, environment || @config.environment]
      cached = variables.nil? ? read_cache(key) : nil
      return cached if cached

      payload = { "environment" => environment || @config.environment }
      payload["prompt"] = prompt.to_s if prompt
      payload["variables"] = variables if variables

      begin
        response = @http.post_resolve(use_case.to_s, payload)
      rescue TransportError => e
        return serve_stale(key, e)
      end

      return handle_failure(key, response, use_case.to_s) unless response.success?

      write_cache(key, response.body) if variables.nil?
      response.body
    end

    private

    def handle_failure(key, response, requested_key)
      status = response.status
      return serve_stale(key, ApiError.new(status, response.body)) if status == 429 || status >= 500

      raise translate(response, requested_key)
    end

    def serve_stale(key, error)
      cached = read_cache(key, ignore_expiry: true)
      unless cached
        @config.logger.warn("[PromptOn] prompt endpoint failed and nothing is cached: #{error.message}")
        raise error
      end

      @config.logger.warn("[PromptOn] prompt endpoint failed (#{error.message}); serving the cached response")
      cached
    end

    def translate(response, requested_key)
      body = response.body.is_a?(Hash) ? response.body : {}
      details = body.dig("error", "details") || {}
      key = (details["key"] || requested_key).to_s

      case response.status
      when 400
        return MissingVariableError.new(details["missing_variable"]) if details["missing_variable"]
      when 404
        case details["reason"]
        when "unresolved" then return UnresolvedError.new(key)
        when "unknown_prompt"
          return UnknownPromptError.new(key, details["prompt"].to_s,
                                        details["prompt_names"] || [])
        end
        return UnknownUseCaseError.new(key) if details["key"]
      end

      ApiError.new(response.status, response.body)
    end

    def to_use_case_evidence(body, requested_key)
      deployment = body["deployment"] || {}
      version = body["prompt_version"] || {}

      UseCaseEvidence.new(
        use_case: body["key"] || requested_key, kind: body["kind"], prompt: body["prompt"],
        prompt_names: body["prompt_names"] || [],
        deployment_id: deployment["id"], deployment_revision: deployment["revision"],
        prompt_version_id: version["id"], prompt_version_number: version["number"],
        engine: body["engine"] || "liquid", model: body["model"], model_id: body["model_id"],
        provider: body["provider"], params: body["params"] || {},
        provider_options: body["provider_options"] || {},
        messages: body["messages"], text: body["text"], source: body["source"] || "remote", etag: body["etag"],
        warnings: Array(body["warnings"])
      )
    end

    def read_cache(key, ignore_expiry: false)
      @mutex.synchronize do
        entry = @cache[key]
        next nil if entry.nil?
        next nil if !ignore_expiry && entry.expires_at < now

        entry.body
      end
    end

    def write_cache(key, body)
      @mutex.synchronize { @cache[key] = CacheEntry.new(body: body, expires_at: now + @config.cache_ttl) }
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
