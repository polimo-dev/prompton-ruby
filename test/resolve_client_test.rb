# frozen_string_literal: true

require_relative "test_helper"

# POST /resolve is the simple path and the smoke test. It follows the same rules as the snapshot
# store: cache the answer, and serve the cached one when PromptOn says 429 or 5xx or says nothing.
class ResolveClientTest < Minitest::Test
  def setup
    @logger = MemoryLogger.new
    @status = 200
    @body = resolve_body
    @server = PromptOnTest::StubServer.new { |request| respond(request) }
    @server_url = @server.url
  end

  def teardown
    @server.stop
  end

  def test_the_answer_is_cached_per_use_case_prompt_and_environment
    client = build_client

    3.times { client.remote_resolve("greeting") }
    assert_equal 1, @server.request_count

    client.remote_resolve("greeting", prompt: "ko")
    client.remote_resolve("greeting", environment: "staging")
    assert_equal 3, @server.request_count
  end

  def test_the_cache_expires_with_the_cache_ttl
    client = build_client(cache_ttl: 0.05)
    client.remote_resolve("greeting")
    sleep(0.1)
    client.remote_resolve("greeting")

    assert_equal 2, @server.request_count
  end

  def test_variables_are_rendered_locally_rather_than_on_every_request
    client = build_client
    resolution = client.remote_resolve("greeting", variables: { name: "Ada" })

    assert_equal 1, @server.request_count
    assert_nil @server.recorded.first.json["variables"], "the cached answer is the unrendered one"
    assert_equal [{ "role" => "system", "content" => "You greet." },
                  { "role" => "user", "content" => "Say hello to Ada." }],
                 resolution.messages, "the returned resolution carries the rendered prompt"
    assert_equal "openai/gpt-4o-mini", resolution.model
    assert_equal({ "temperature" => 0.2 }, resolution.params)
  end

  def test_without_variables_the_template_comes_back_as_it_is
    client = build_client
    resolution = client.remote_resolve("greeting")

    assert_equal "Say hello to {{ name }}.", resolution.messages.last["content"]
    assert_equal [{ "role" => "system", "content" => "You greet." },
                  { "role" => "user", "content" => "Say hello to Ada." }],
                 resolution.render(name: "Ada")
  end

  def test_a_429_or_5xx_serves_the_cached_answer
    client = build_client(cache_ttl: 0.01)
    client.remote_resolve("greeting")
    sleep(0.02)

    @status = 429
    assert_equal "openai/gpt-4o-mini", client.remote_resolve("greeting").model

    @status = 503
    sleep(0.02)
    assert_equal "openai/gpt-4o-mini", client.remote_resolve("greeting").model
    assert(@logger.lines.any? { |line| line.include?("serving the cached response") })
  end

  def test_a_down_server_serves_the_cached_answer_and_otherwise_raises
    client = build_client(cache_ttl: 0.01)
    client.remote_resolve("greeting")
    @server.stop
    sleep(0.02)

    assert_equal "openai/gpt-4o-mini", client.remote_resolve("greeting").model
    assert_raises(PromptOn::TransportError) { client.remote_resolve("summarize") }
  end

  def test_the_documented_404_and_400_shapes_become_typed_errors
    client = build_client

    @status = 404
    @body = { "error" => { "code" => "not_found", "message" => "unknown use case",
                           "details" => { "use_case" => "nope" } } }
    assert_raises(PromptOn::UnknownUseCaseError) { client.remote_resolve("nope") }

    @body = { "error" => { "code" => "not_found", "message" => "no live deployment",
                           "details" => { "use_case" => "draft", "reason" => "unresolved" } } }
    assert_raises(PromptOn::UnresolvedError) { client.remote_resolve("draft") }

    @body = { "error" => { "code" => "not_found", "message" => "no such prompt",
                           "details" => { "use_case" => "greeting", "reason" => "unknown_prompt",
                                          "prompt" => "fr", "available_prompts" => %w[default ko] } } }
    error = assert_raises(PromptOn::UnknownPromptError) { client.remote_resolve("greeting", prompt: "fr") }
    assert_equal %w[default ko], error.available_prompts

    @status = 400
    @body = { "error" => { "code" => "invalid_request", "message" => "missing variable: name",
                           "details" => { "missing_variable" => "name" } } }
    error = assert_raises(PromptOn::MissingVariableError) { client.api_resolve("greeting", variables: {}) }
    assert_equal "name", error.variable
  end

  def test_api_resolve_returns_the_raw_server_answer_and_can_ask_the_server_to_render
    client = build_client
    body = client.api_resolve("greeting", variables: { "name" => "Ada" })

    assert_equal({ "use_case" => "greeting", "variables" => { "name" => "Ada" },
                   "environment" => "production" }, @server.recorded.first.json)
    assert_equal "openai/gpt-4o-mini", body["model"]
  end

  private

  def build_client(**overrides)
    PromptOn::Client.new(**client_options(logger: @logger, host: @server_url, mode: :offline,
                                          **overrides))
  end

  def respond(_request)
    return [200, { "content-type" => "application/json" }, @body] if @status == 200

    [@status, { "content-type" => "application/json" }, @body.is_a?(Hash) ? @body : { "error" => {} }]
  end

  def resolve_body
    { "use_case" => "greeting", "kind" => "chat",
      "deployment" => { "id" => "0198f2a1-0000-7000-8000-00000000d001", "revision" => 3 },
      "prompt" => "default", "prompts" => %w[default ko],
      "model_id" => "0198f2a1-0000-7000-8000-00000000e001", "model" => "openai/gpt-4o-mini",
      "provider" => "openrouter", "effective_params" => { "temperature" => 0.2 },
      "effective_provider_options" => { "only" => ["OpenAI"] },
      "prompt_version" => { "id" => "0198f2a1-0000-7000-8000-00000000a001", "number" => 2 },
      "messages" => [{ "role" => "system", "content" => "You greet." },
                     { "role" => "user", "content" => "Say hello to {{ name }}." }],
      "warnings" => [], "etag" => "sha256-abc" }
  end
end
