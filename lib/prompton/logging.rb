# frozen_string_literal: true

module PromptOn
  # The SDK logs through any object that responds to +info+, +warn+ and +error+ — a stdlib
  # Logger, Rails.logger, or your own. This is the default: warnings and errors on $stderr,
  # nothing else, and no dependency on a gem that moved out of the standard library.
  class DefaultLogger
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze

    attr_reader :level

    def initialize(io = $stderr, level: :warn)
      @io = io
      @level = level
      @threshold = LEVELS.fetch(level) { raise ConfigurationError, "unknown log level #{level.inspect}" }
      @mutex = Mutex.new
    end

    LEVELS.each_key do |name|
      define_method(name) do |message = nil, &block|
        write(name, message || block&.call)
      end
    end

    private

    def write(level, message)
      return true if LEVELS.fetch(level) < @threshold

      @mutex.synchronize { @io.puts("[#{level.to_s.upcase}] #{message}") }
      true
    rescue IOError, Errno::EPIPE
      true
    end
  end

  # Drops everything. Useful in tests and in a process that logs elsewhere.
  class NullLogger
    DefaultLogger::LEVELS.each_key { |name| define_method(name) { |_message = nil| true } }
  end
end
