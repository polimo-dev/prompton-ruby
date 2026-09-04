# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def setup
    @saved = ENV.to_hash.slice("PTN_HOST", "PTN_API_KEY", "PTN_ENVIRONMENT", "PTN_PROJECT", "PTN_BUNDLE")
    %w[PTN_HOST PTN_API_KEY PTN_ENVIRONMENT PTN_PROJECT PTN_BUNDLE].each { |name| ENV.delete(name) }
  end

  def teardown
    %w[PTN_HOST PTN_API_KEY PTN_ENVIRONMENT PTN_PROJECT PTN_BUNDLE].each { |name| ENV.delete(name) }
    @saved.each { |name, value| ENV[name] = value }
  end

  def test_defaults
    config = PromptOn::Config.new

    assert_equal "https://app.prompton.ai/api/v1", config.api_url
    assert_equal "production", config.environment
    assert_nil config.api_key
    assert_in_delta 10.0, config.cache_ttl
    assert_equal "prompton-ruby/#{PromptOn::VERSION}", config.user_agent
    refute_predicate config, :remote?
  end

  def test_an_explicit_nil_beats_the_environment_variable
    ENV["PTN_API_KEY"] = "ptn_fromenv_key"

    assert_equal "ptn_fromenv_key", PromptOn::Config.new.api_key
    assert_nil PromptOn::Config.new(api_key: nil).api_key
  end

  def test_precedence_is_explicit_option_then_environment_variable_then_default
    ENV["PTN_HOST"] = "https://env.example"
    ENV["PTN_API_KEY"] = "ptn_fromenv_key"
    ENV["PTN_ENVIRONMENT"] = "staging"

    from_env = PromptOn::Config.new
    assert_equal "https://env.example/api/v1", from_env.api_url
    assert_equal "ptn_fromenv_key", from_env.api_key
    assert_equal "staging", from_env.environment

    explicit = PromptOn::Config.new(host: "https://explicit.example", api_key: "ptn_explicit_key",
                                    environment: "production")
    assert_equal "https://explicit.example/api/v1", explicit.api_url
    assert_equal "ptn_explicit_key", explicit.api_key
    assert_equal "production", explicit.environment
  end

  def test_the_api_path_is_appended_once
    assert_equal "http://localhost:4000/api/v1", PromptOn::Config.new(host: "http://localhost:4000/").api_url
    assert_equal "http://localhost:4000/api/v1",
                 PromptOn::Config.new(host: "http://localhost:4000/api/v1").api_url
  end

  def test_the_project_is_read_from_the_api_key_when_not_given
    assert_equal "heydiary", PromptOn::Config.new(api_key: "ptn_heydiary_abc123").project
    assert_equal "other", PromptOn::Config.new(api_key: "ptn_heydiary_abc123", project: "other").project
  end

  def test_the_disk_cache_path_is_named_by_project_and_environment
    config = PromptOn::Config.new(api_key: "ptn_heydiary_abc", environment: "staging")

    assert_match(%r{prompton/snapshot-heydiary-staging\.json\z}, config.disk_cache_path)
    assert_nil PromptOn::Config.new(disk_cache: false).disk_cache_path
    assert_equal "/tmp/snap.json", PromptOn::Config.new(disk_cache: "/tmp/snap.json").disk_cache_path
  end

  def test_remote_calls_need_an_api_key_and_live_mode
    assert_predicate PromptOn::Config.new(api_key: "ptn_x_y"), :remote?
    refute_predicate PromptOn::Config.new(api_key: "ptn_x_y", mode: :offline), :remote?
    refute_predicate PromptOn::Config.new(api_key: "ptn_x_y", mode: :test), :remote?
  end

  def test_invalid_options_are_refused_at_construction
    assert_raises(PromptOn::ConfigurationError) { PromptOn::Config.new(mode: :sideways) }
    assert_raises(PromptOn::ConfigurationError) { PromptOn::Config.new(cache_ttl: 0) }
    assert_raises(PromptOn::ConfigurationError) { PromptOn::Config.new(flush_size: 1.5) }
    assert_raises(PromptOn::ConfigurationError) { PromptOn::Config.new(redact: "not callable") }
  end

  def test_with_returns_a_copy
    config = PromptOn::Config.new(api_key: "ptn_x_y").with(environment: "staging")

    assert_equal "staging", config.environment
    assert_equal "ptn_x_y", config.api_key
  end
end
