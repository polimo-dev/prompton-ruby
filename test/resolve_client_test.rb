# frozen_string_literal: true

require_relative "test_helper"

# POST /use-cases/:key/prompt is the simple path and the smoke test. It follows the same rules as
# the document store: cache the answer, and serve the cached one when PromptOn says 429 or 5xx.
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

    3.times { client.remote_use_case("greeting") }
    assert_equal 1, @server.request_count

    client.remote_use_case("greeting", prompt: "ko")
    client.remote_use_case("greeting", environment: "staging")
    assert_equal 3, @server.request_count
  end

  def test_the_cache_expires_with_the_cache_ttl
    client = build_client(cache_ttl: 0.05)
    client.remote_use_case("greeting")
    sleep(0.1)
    client.remote_use_case("greeting")

    assert_equal 2, @server.request_count
  end

  def test_variables_are_rendered_locally_rather_than_on_every_request
    client = build_client
    use_case = client.remote_use_case("greeting", variables: { name: "Ada" })

    assert_equal 1, @server.request_count
    assert_nil @server.recorded.first.json["variables"], "the cached answer is the unrendered one"
    assert_equal [{ "role" => "system", "content" => "You greet." },
                  { "role" => "user", "content" => "Say hello to Ada." }],
                 use_case.messages, "the returned use case carries the rendered prompt"
    assert_equal "openai/gpt-4o-mini", use_case.model
    assert_equal({ "temperature" => 0.2 }, use_case.params)
  end

  def test_without_variables_the_template_comes_back_as_it_is
    client = build_client
    use_case = client.remote_use_case("greeting")

    assert_equal "Say hello to {{ name }}.", use_case.messages_template.last["content"]
    assert_equal [{ "role" => "system", "content" => "You greet." },
                  { "role" => "user", "content" => "Say hello to Ada." }],
                 use_case.messages(name: "Ada")
  end

  def test_source_is_decoded_with_remote_fallback
    @body = resolve_body.merge("source" => "disk")
    assert_equal "disk", build_client.remote_use_case("greeting").source

    @body = resolve_body
    assert_equal "remote", build_client.remote_use_case("greeting").source
  end

  def test_a_429_or_5xx_serves_the_cached_answer
    client = build_client(cache_ttl: 0.01)
    client.remote_use_case("greeting")
    sleep(0.02)

    @status = 429
    assert_equal "openai/gpt-4o-mini", client.remote_use_case("greeting").model

    @status = 503
    sleep(0.02)
    assert_equal "openai/gpt-4o-mini", client.remote_use_case("greeting").model
    assert(@logger.lines.any? { |line| line.include?("serving the cached response") })
  end

  def test_a_down_server_serves_the_cached_answer_and_otherwise_raises
    client = build_client(cache_ttl: 0.01)
    client.remote_use_case("greeting")
    @server.stop
    sleep(0.02)

    assert_equal "openai/gpt-4o-mini", client.remote_use_case("greeting").model
    assert_raises(PromptOn::TransportError) { client.remote_use_case("summarize") }
  end

  def test_the_documented_404_and_400_shapes_become_typed_errors
    client = build_client

    @status = 404
    @body = { "error" => { "code" => "not_found", "message" => "unknown use case",
                           "details" => { "key" => "nope" } } }
    assert_raises(PromptOn::UnknownUseCaseError) { client.remote_use_case("nope") }

    @body = { "error" => { "code" => "not_found", "message" => "no live deployment",
                           "details" => { "reason" => "unresolved" } } }
    assert_raises(PromptOn::UnresolvedError) { client.remote_use_case("draft") }

    @body = { "error" => { "code" => "not_found", "message" => "no such prompt",
                           "details" => { "key" => "greeting", "reason" => "unknown_prompt",
                                          "prompt" => "fr", "prompt_names" => %w[default ko] } } }
    error = assert_raises(PromptOn::UnknownPromptError) { client.remote_use_case("greeting", prompt: "fr") }
    assert_equal %w[default ko], error.prompt_names

    @status = 400
    @body = { "error" => { "code" => "invalid_request", "message" => "missing variable: name",
                           "details" => { "missing_variable" => "name" } } }
    error = assert_raises(PromptOn::MissingVariableError) { client.api_use_case("greeting", variables: {}) }
    assert_equal "name", error.variable
  end

  def test_api_use_case_returns_the_raw_server_answer_and_can_ask_the_server_to_render
    client = build_client
    body = client.api_use_case("greeting", variables: { "name" => "Ada" })

    assert_equal({ "variables" => { "name" => "Ada" }, "environment" => "production" },
                 @server.recorded.first.json)
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
    { "key" => "greeting", "kind" => "chat",
      "deployment" => { "id" => "0198f2a1-0000-7000-8000-00000000d001", "revision" => 3 },
      "prompt" => "default", "prompt_names" => %w[default ko],
      "model_id" => "0198f2a1-0000-7000-8000-00000000e001", "model" => "openai/gpt-4o-mini",
      "provider" => "openrouter", "params" => { "temperature" => 0.2 },
      "provider_options" => { "only" => ["OpenAI"] },
      "prompt_version" => { "id" => "0198f2a1-0000-7000-8000-00000000a001", "number" => 2 },
      "messages" => [{ "role" => "system", "content" => "You greet." },
                     { "role" => "user", "content" => "Say hello to {{ name }}." }],
      "warnings" => [], "etag" => "sha256-abc" }
  end
end
