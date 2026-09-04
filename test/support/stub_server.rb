# frozen_string_literal: true

require "socket"
require "json"
require "uri"

module PromptOnTest
  # A minimal HTTP server for the tests that must not touch the fixture server: rate limiting,
  # server errors, oversized batches and a host that is simply down.
  #
  # The handler receives a Request and returns [status, headers, body].
  class StubServer
    Request = Struct.new(:verb, :path, :query, :headers, :body, keyword_init: true) do
      def json
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end

    attr_reader :requests

    def initialize(&handler)
      @handler = handler
      @requests = []
      @mutex = Mutex.new
      @socket = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { accept_loop }
      @thread.abort_on_exception = false
    end

    def port
      @socket.addr[1]
    end

    def url
      "http://127.0.0.1:#{port}"
    end

    def request_count
      @mutex.synchronize { @requests.length }
    end

    def recorded
      @mutex.synchronize { @requests.dup }
    end

    def stop
      @socket.close unless @socket.closed?
      @thread&.join(2)
      self
    rescue IOError
      self
    end

    # A URL that nothing is listening on, for the "PromptOn is down" tests.
    def self.dead_url
      server = new { [200, {}, "{}"] }
      url = server.url
      server.stop
      url
    end

    private

    def accept_loop
      loop do
        client = @socket.accept
        Thread.new(client) { |connection| serve(connection) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(connection)
      request = read_request(connection)
      return if request.nil?

      @mutex.synchronize { @requests << request }
      status, headers, body = @handler.call(request)
      write_response(connection, status, headers, body)
    rescue StandardError => e
      warn("stub server error: #{e.class}: #{e.message}")
    ensure
      connection.close
    end

    def read_request(connection)
      line = connection.gets
      return nil if line.nil?

      verb, target, = line.split
      headers = {}
      while (header = connection.gets) && header != "\r\n"
        name, value = header.split(":", 2)
        headers[name.downcase.strip] = value.to_s.strip
      end

      length = headers["content-length"].to_i
      body = length.positive? ? connection.read(length) : nil
      uri = URI.parse(target)
      Request.new(verb: verb, path: uri.path, query: URI.decode_www_form(uri.query.to_s).to_h,
                  headers: headers, body: body)
    end

    def write_response(connection, status, headers, body)
      body = JSON.generate(body) unless body.is_a?(String) || body.nil?
      body ||= ""
      lines = ["HTTP/1.1 #{status} #{status == 304 ? "Not Modified" : "OK"}"]
      headers.each { |name, value| lines << "#{name}: #{value}" }
      lines << "Content-Length: #{body.bytesize}" unless status == 304
      lines << "Connection: close"
      connection.write("#{lines.join("\r\n")}\r\n\r\n")
      connection.write(body) unless status == 304
    end
  end
end
