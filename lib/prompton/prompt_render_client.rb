# frozen_string_literal: true

require_relative "errors"
require_relative "prompt_document"
require_relative "prompt_evidence"

module PromptOn
  # The POST /prompts/{key}/render path: the simple way in, and the smoke test.
  #
  # It follows the same resilience rules as the prompt document store. A response fetched without
  # variables is cached for the cache TTL per (prompt, template, environment) and rendered
  # locally, so a hot loop never becomes one HTTP call per provider call; on 429, 5xx or a transport
  # failure the cached response is served instead of raising.
  #
  # For anything but a smoke test or a low-traffic path, prefer the local prompt document:
  # the template endpoint is not a hot-loop endpoint.
  class PromptRenderClient
    CacheEntry = Struct.new(:body, :expires_at, keyword_init: true)

    def initialize(config, http)
      @config = config
      @http = http
      @mutex = Mutex.new
      @cache = {}
    end

    # A prompt evidence built from the server's answer.
    #
    # Passing +variables+ renders them locally into the returned evidence, so #messages (chat)
    # or #text (text) carry the rendered template rather than the template. Without them the
    # template comes back as it is and you call #render yourself.
    def resolve(prompt_key, template: nil, environment: nil, variables: nil)
      body = fetch(prompt_key, template: template, environment: environment)
      evidence = to_prompt_evidence(body, prompt_key.to_s)
      return evidence if variables.nil?

      evidence.with_rendered(evidence.render(variables))
    end

    # The raw POST /prompts/{key}/render response body.
    #
    # Passing +variables+ asks the server to render, which is the smoke-test path and is never
    # cached. Without them the response is cached for the cache TTL.
    def fetch(prompt_key, template: nil, environment: nil, variables: nil)
      key = [prompt_key.to_s, template&.to_s, environment || @config.environment]
      cached = variables.nil? ? read_cache(key) : nil
      return cached if cached

      payload = { "environment" => environment || @config.environment }
      payload["template"] = template.to_s if template
      payload["variables"] = variables if variables

      begin
        response = @http.post_resolve(prompt_key.to_s, payload)
      rescue TransportError => e
        return serve_stale(key, e)
      end

      return handle_failure(key, response, prompt_key.to_s) unless response.success?

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
        @config.logger.warn("[PromptOn] template endpoint failed and nothing is cached: #{error.message}")
        raise error
      end

      @config.logger.warn("[PromptOn] template endpoint failed (#{error.message}); serving the cached response")
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
        when "unknown_template"
          return UnknownTemplateError.new(key, details["template"].to_s,
                                          details["template_names"] || [])
        end
        return UnknownPromptError.new(key) if details["key"]
      end

      ApiError.new(response.status, response.body)
    end

    def to_prompt_evidence(body, requested_key)
      deployment = body["deployment"] || {}
      version = body["prompt_version"] || {}
      revision = deployment["revision"]
      unless revision.nil? || revision.is_a?(String)
        raise InvalidPromptDocumentError, "deployment revision must be a string like v2026.09.30-1"
      end

      PromptEvidence.new(
        prompt: body["key"] || requested_key, kind: body["kind"], template: body["template"],
        template_names: body["template_names"] || [],
        deployment_id: deployment["id"], deployment_revision: revision,
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
      @mutex.synchronize { @cache[key] = CacheEntry.new(body: body, expires_at: now + @config.prompt_cache_ttl) }
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
