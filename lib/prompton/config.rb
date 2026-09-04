# frozen_string_literal: true

require "tmpdir"
require_relative "errors"
require_relative "logging"
require_relative "version"
require_relative "payload"

module PromptOn
  # Runtime configuration. Every value follows the same precedence:
  # explicit option > environment variable > default.
  #
  #   PromptOn::Config.new(api_key: "ptn_myapp_…", environment: "staging")
  #
  # Without an API key the SDK makes no remote calls at all: it serves whatever the disk cache
  # or the bundled snapshot holds, and says so once in a log line.
  class Config
    DEFAULT_HOST = "https://app.prompton.ai"
    API_PATH = "/api/v1"
    DEFAULT_ENVIRONMENT = "production"
    MODES = %i[live test offline].freeze

    attr_reader :host, :api_url, :api_key, :environment, :project, :cache_ttl, :max_backoff,
                :open_timeout, :read_timeout, :disk_cache_path, :bundle_path, :mode, :poll,
                :hash_end_user, :redact, :logger, :user_agent, :flush_interval, :flush_size,
                :flush_bytes, :max_buffer, :max_send_attempts, :payload_defaults, :flush_on_exit

    def initialize(**options)
      @host = normalize_host(pick(options, :host, "PTN_HOST") || pick(options, :base_url, nil) || DEFAULT_HOST)
      @api_url = @host.end_with?(API_PATH) ? @host : "#{@host}#{API_PATH}"
      @api_key = presence(pick(options, :api_key, "PTN_API_KEY"))
      @environment = presence(pick(options, :environment, "PTN_ENVIRONMENT")) || DEFAULT_ENVIRONMENT
      @project = presence(pick(options, :project, "PTN_PROJECT")) || project_from_api_key(@api_key)
      @mode = normalize_mode(options.fetch(:mode, :live))
      @logger = logger_for(options)

      @cache_ttl = positive_number(options.fetch(:cache_ttl, 10.0), :cache_ttl)
      @max_backoff = positive_number(options.fetch(:max_backoff, 300.0), :max_backoff)
      timeout = positive_number(options.fetch(:timeout, 5.0), :timeout)
      @open_timeout = positive_number(options.fetch(:open_timeout, timeout), :open_timeout)
      @read_timeout = positive_number(options.fetch(:read_timeout, timeout), :read_timeout)
      @poll = options.fetch(:poll, true) == true && @mode == :live

      @disk_cache_path = resolve_disk_cache(options.fetch(:disk_cache, true))
      @bundle_path = presence(pick(options, :bundle, "PTN_BUNDLE"))

      @hash_end_user = options.fetch(:hash_end_user, false) == true
      @redact = callable(options[:redact], :redact)
      @user_agent = options.fetch(:user_agent, "#{SDK_NAME}/#{VERSION}")

      @flush_interval = positive_number(options.fetch(:flush_interval, 2.0), :flush_interval)
      @flush_size = positive_integer(options.fetch(:flush_size, 100), :flush_size)
      @flush_bytes = positive_integer(options.fetch(:flush_bytes, 1_000_000), :flush_bytes)
      @max_buffer = positive_integer(options.fetch(:max_buffer, 10_000), :max_buffer)
      @max_send_attempts = positive_integer(options.fetch(:max_send_attempts, 8), :max_send_attempts)
      @flush_on_exit = options.fetch(:flush_on_exit, true) == true
      @payload_defaults = Payload::DEFAULTS.merge(options.fetch(:payload_defaults, {}))

      freeze
    end

    # Whether remote calls are possible at all.
    def remote?
      mode == :live && !api_key.nil?
    end

    def test?
      mode == :test
    end

    def offline?
      mode == :offline
    end

    # A copy with some options replaced.
    def with(**overrides)
      Config.new(**to_h, **overrides)
    end

    def to_h
      { host: host, api_key: api_key, environment: environment, project: project, mode: mode,
        logger: logger, cache_ttl: cache_ttl, max_backoff: max_backoff,
        open_timeout: open_timeout, read_timeout: read_timeout, poll: poll,
        disk_cache: disk_cache_path || false, bundle: bundle_path, hash_end_user: hash_end_user,
        redact: redact, user_agent: user_agent, flush_interval: flush_interval,
        flush_size: flush_size, flush_bytes: flush_bytes, max_buffer: max_buffer,
        max_send_attempts: max_send_attempts, flush_on_exit: flush_on_exit,
        payload_defaults: payload_defaults }
    end

    private

    # Explicit wins even when it is nil: passing api_key: nil is how an app says "no remote
    # calls" on a machine where PTN_API_KEY happens to be set.
    def pick(options, key, env_name)
      return options[key] if options.key?(key)

      env_name && ENV.fetch(env_name, nil)
    end

    def presence(value)
      string = value&.to_s
      string.nil? || string.empty? ? nil : string
    end

    def normalize_host(value)
      host = value.to_s.sub(%r{/+\z}, "")
      raise ConfigurationError, "host must not be empty" if host.empty?

      host
    end

    def normalize_mode(value)
      mode = value.to_sym
      return mode if MODES.include?(mode)

      raise ConfigurationError, "mode must be one of #{MODES.join(", ")}, got #{value.inspect}"
    end

    def project_from_api_key(key)
      match = /\Aptn_([a-z0-9][a-z0-9_-]*)_/.match(key.to_s)
      match && match[1]
    end

    def resolve_disk_cache(value)
      case value
      when false, nil then nil
      when true then File.join(cache_directory, "prompton", "snapshot-#{project || "default"}-#{environment}.json")
      when String then value
      else raise ConfigurationError, "disk_cache must be true, false or a path, got #{value.inspect}"
      end
    end

    def cache_directory
      return ENV.fetch("XDG_CACHE_HOME", nil) unless ENV["XDG_CACHE_HOME"].to_s.empty?

      home = Dir.home
      return Dir.tmpdir if home.to_s.empty?

      RUBY_PLATFORM.include?("darwin") ? File.join(home, "Library", "Caches") : File.join(home, ".cache")
    rescue StandardError
      Dir.tmpdir
    end

    def callable(value, name)
      return nil if value.nil?
      raise ConfigurationError, "#{name} must respond to #call" unless value.respond_to?(:call)

      value
    end

    def positive_number(value, name)
      raise ConfigurationError, "#{name} must be a positive number" unless value.is_a?(Numeric) && value.positive?

      value.to_f
    end

    def positive_integer(value, name)
      raise ConfigurationError, "#{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?

      value
    end

    # Any object that responds to info, warn and error will do, including a stdlib Logger.
    def logger_for(options)
      logger = options.fetch(:logger) { DefaultLogger.new }
      return logger if %i[info warn error].all? { |name| logger.respond_to?(name) }

      raise ConfigurationError, "logger must respond to info, warn and error"
    end
  end
end
