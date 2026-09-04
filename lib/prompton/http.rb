# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require_relative "errors"

module PromptOn
  # The PromptOn HTTP layer: three endpoints, no retry policy of its own.
  #
  # Retries and backoff belong to the snapshot store and the log buffer, which know what to do
  # with a stale document or an unsent batch. This class only turns a request into a Response or
  # a PromptOn::TransportError.
  class Http
    # One HTTP answer. +body+ is the raw string for snapshot fetches and the parsed JSON for
    # everything else.
    Response = Struct.new(:status, :body, :headers, keyword_init: true) do
      def success?
        status.between?(200, 299)
      end

      def header(name)
        headers[name.to_s.downcase]
      end

      def etag
        header("etag")
      end

      # Retry-After as a number of seconds, from the header or from error.details.retry_after.
      def retry_after_seconds
        from_header = parse_retry_after(header("retry-after"))
        return from_header if from_header

        details = body.is_a?(Hash) ? body.dig("error", "details", "retry_after") : nil
        details.is_a?(Numeric) ? details.to_f : nil
      end

      private

      def parse_retry_after(value)
        return nil if value.nil?

        stripped = value.strip
        return stripped.to_f if stripped.match?(/\A\d+(\.\d+)?\z/)

        seconds = (Time.httpdate(stripped) - Time.now).ceil
        seconds.negative? ? 0.0 : seconds.to_f
      rescue ArgumentError
        nil
      end
    end

    def initialize(config)
      @config = config
      @uri = URI.parse(config.api_url)
    end

    # GET /snapshot?environment=… with If-None-Match. The body is left as raw bytes: the ETag is
    # a hash of them, so the disk cache stores exactly what the server sent.
    def get_snapshot(environment:, etag: nil, read_timeout: nil)
      request = Net::HTTP::Get.new(request_uri("/snapshot", environment: environment))
      request["If-None-Match"] = etag if etag
      response = perform(request, read_timeout: read_timeout, parse_json: false)
      return response if response.success?

      # Only a 200 body is a snapshot; anything else is an error envelope worth parsing, because
      # that is where a Retry-After can hide.
      Response.new(status: response.status, headers: response.headers, body: parse(response.body))
    end

    # POST /resolve — the simple path and the smoke test.
    def post_resolve(payload)
      request = Net::HTTP::Post.new(request_uri("/resolve"))
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      perform(request)
    end

    # POST /generations?environment=… — one batch, one environment.
    def post_generations(records, environment:)
      request = Net::HTTP::Post.new(request_uri("/generations", environment: environment))
      request["Content-Type"] = "application/json"
      request.body = JSON.generate({ "generations" => records })
      perform(request)
    end

    private

    def request_uri(path, query = {})
      uri = "#{@uri.path}#{path}"
      params = query.compact
      params.empty? ? uri : "#{uri}?#{URI.encode_www_form(params)}"
    end

    def perform(request, read_timeout: nil, parse_json: true)
      request["Accept"] = "application/json"
      request["User-Agent"] = @config.user_agent
      request["Authorization"] = "Bearer #{@config.api_key}" if @config.api_key

      response = start(read_timeout) { |http| http.request(request) }
      body = response.body
      Response.new(status: response.code.to_i, headers: flatten_headers(response),
                   body: parse_json ? parse(body) : body)
    rescue Timeout::Error => e
      raise TransportError, "PromptOn request timed out: #{e.class}"
    rescue SystemCallError, SocketError, IOError, OpenSSL::OpenSSLError, Net::HTTPBadResponse => e
      raise TransportError, "PromptOn request failed: #{e.class}: #{e.message}"
    end

    def start(read_timeout, &)
      Net::HTTP.start(@uri.hostname, @uri.port,
                      use_ssl: @uri.scheme == "https",
                      open_timeout: @config.open_timeout,
                      read_timeout: read_timeout || @config.read_timeout,
                      &)
    end

    def parse(body)
      return nil if body.nil? || body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      body
    end

    def flatten_headers(response)
      response.each_header.to_h { |name, value| [name.downcase, value] }
    end
  end
end
