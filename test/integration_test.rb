# frozen_string_literal: true

require_relative "test_helper"

# The live contract test. It runs only when PTN_API_KEY is set, against a real PromptOn:
#
#   PTN_HOST=http://localhost:4000 PTN_API_KEY=ptn_yourproject_… bundle exec rake test
#
# It asserts the two things a unit test cannot: that the snapshot this SDK fetches and resolves
# locally agrees with the server's own POST /resolve, and that the monitoring logs it builds are
# accepted by the ingest endpoint.
class IntegrationTest < Minitest::Test
  def setup
    skip("set PTN_API_KEY to run the live integration test") if ENV["PTN_API_KEY"].to_s.empty?

    @dir = Dir.mktmpdir("prompton-integration")
    @logger = MemoryLogger.new
    @client = PromptOn::Client.new(api_key: ENV.fetch("PTN_API_KEY"), logger: @logger, poll: false,
                                   flush_on_exit: false, disk_cache: File.join(@dir, "snapshot.json"))
    @http = PromptOn::Http.new(@client.config)
  end

  def teardown
    @client&.close
    FileUtils.remove_entry(@dir) if @dir
  end

  def test_snapshot_fetch_then_a_304_on_the_next_poll
    first = @http.get_snapshot(environment: "production")

    assert_equal 200, first.status
    assert_match(%r{\Aw?/?"sha256-\h{64}"\z}, first.etag)
    assert_equal "production", JSON.parse(first.body)["environment"]

    second = @http.get_snapshot(environment: "production", etag: first.etag)
    assert_equal 304, second.status
    assert_empty second.body.to_s
  end

  def test_a_snapshot_for_the_staging_environment_is_a_different_document
    production = JSON.parse(@http.get_snapshot(environment: "production").body)
    staging = JSON.parse(@http.get_snapshot(environment: "staging").body)

    assert_equal "production", production["environment"]
    assert_equal "staging", staging["environment"]
  end

  def test_an_unknown_environment_is_a_404
    response = @http.get_snapshot(environment: "nope")

    assert_equal 404, response.status
    assert_equal "nope", response.body.dig("error", "details", "environment")
  end

  def test_local_resolution_agrees_with_the_server_for_the_default_prompt
    assert_agrees_with_server("greeting", variables: { "name" => "Ada" })
  end

  def test_local_resolution_agrees_with_the_server_for_a_named_prompt
    assert_agrees_with_server("greeting", prompt: "ko", variables: { "name" => "아다" })
  end

  def test_local_resolution_agrees_with_the_server_for_a_text_use_case
    assert_agrees_with_server("summarize", variables: { "items" => %w[alpha beta gamma] })
  end

  def test_local_resolution_agrees_with_the_server_for_an_embedding_use_case
    assert_agrees_with_server("embed")
  end

  def test_the_error_cases_match_the_server
    assert_raises(PromptOn::UnknownUseCaseError) { @client.resolve("does_not_exist") }
    assert_equal 404, @http.post_resolve({ "use_case" => "does_not_exist" }).status

    error = assert_raises(PromptOn::UnknownPromptError) { @client.resolve("greeting", prompt: "fr") }
    remote = @http.post_resolve({ "use_case" => "greeting", "prompt" => "fr" })
    assert_equal 404, remote.status
    assert_equal "unknown_prompt", remote.body.dig("error", "details", "reason")
    assert_equal remote.body.dig("error", "details", "available_prompts"), error.available_prompts

    missing = assert_raises(PromptOn::MissingVariableError) { @client.resolve("greeting").render({}) }
    remote = @http.post_resolve({ "use_case" => "greeting", "variables" => {} })
    assert_equal 400, remote.status
    assert_equal remote.body.dig("error", "details", "missing_variable"), missing.variable
  end

  def test_a_generations_batch_is_accepted_and_a_resend_counts_as_duplicates
    records = [generation_record, generation_record]

    first = @http.post_generations(records, environment: "production")
    assert_equal 202, first.status
    assert_equal 2, first.body["accepted"]
    assert_equal 0, first.body["duplicates"]
    assert_empty first.body["rejected"]

    resend = @http.post_generations(records, environment: "production")
    assert_equal 202, resend.status
    assert_equal 0, resend.body["accepted"]
    assert_equal 2, resend.body["duplicates"], "the id is the idempotency key"
  end

  def test_a_record_the_server_refuses_comes_back_in_rejected_without_failing_the_batch
    good = generation_record
    bad = generation_record.merge("id" => "not-a-uuid")

    response = @http.post_generations([bad, good], environment: "production")

    assert_equal 202, response.status
    assert_equal 1, response.body["accepted"]
    assert_equal 1, response.body["rejected"].length
    assert_equal 0, response.body["rejected"].first["index"]
  end

  def test_the_client_sends_what_with_generation_builds
    resolution = @client.resolve("greeting")
    messages = resolution.render(name: "Ada")

    @client.with_generation(resolution, variables: { name: "Ada" }, input_messages: messages,
                                        trace_id: "integration:#{Process.pid}", end_user_ref: "user-42") do
      { content: "Hello, Ada!", finish_reason: "stop", cost_source: "provider", cost_usd: 0.000012,
        usage: { input_tokens: 38, output_tokens: 6 } }
    end

    summary = @client.flush(timeout: 10)

    assert_equal 1, summary[:sent]
    assert_equal 1, summary[:accepted]
    assert_equal 0, summary[:rejected]
  end

  def test_an_invalid_key_is_a_401
    other = PromptOn::Http.new(@client.config.with(api_key: "ptn_sdkfixture_definitelywrong"))
    response = other.get_snapshot(environment: "production")

    assert_equal 401, response.status
    assert_equal "unauthorized", response.body.dig("error", "code")
  end

  def test_the_disk_cache_is_written_and_answers_when_the_host_is_unreachable
    @client.resolve("greeting")

    offline = PromptOn::Client.new(api_key: ENV.fetch("PTN_API_KEY"), logger: @logger, poll: false,
                                   flush_on_exit: false, host: PromptOnTest::StubServer.dead_url,
                                   disk_cache: File.join(@dir, "snapshot.json"))

    assert_equal "disk", offline.resolve("greeting").source
    offline.close
  end

  private

  def assert_agrees_with_server(use_case, prompt: nil, variables: nil)
    local = @client.resolve(use_case, prompt: prompt)
    payload = { "use_case" => use_case, "environment" => "production" }
    payload["prompt"] = prompt if prompt
    payload["variables"] = variables if variables
    remote = @http.post_resolve(payload)

    assert_equal 200, remote.status, remote.body.inspect
    agree(remote.body["kind"], local.kind, "kind")
    agree(remote.body.dig("deployment", "id"), local.deployment_id, "deployment id")
    agree(remote.body.dig("deployment", "revision"), local.deployment_revision, "revision")
    agree(remote.body["prompt"], local.prompt, "prompt")
    agree(remote.body["prompts"], local.available_prompts, "prompts")
    agree(remote.body["model"], local.model, "model")
    agree(remote.body["model_id"], local.model_id, "model_id")
    agree(remote.body["provider"], local.provider, "provider")
    agree(remote.body["effective_params"], local.params, "effective_params")
    agree(remote.body["effective_provider_options"], local.provider_options, "provider options")
    agree(remote.body["prompt_version"]&.slice("id", "number"),
          local.prompt_version_id && { "id" => local.prompt_version_id,
                                       "number" => local.prompt_version_number },
          "prompt version")

    return if variables.nil?

    case local.kind
    when "chat"
      rendered = local.render(variables).map { |message| message.slice("role", "content") }
      assert_equal remote.body["messages"].map { |m| m.slice("role", "content") }, rendered
    when "text"
      assert_equal remote.body["text"], local.render(variables)
    end
  end

  def agree(remote_value, local_value, label)
    if remote_value.nil?
      assert_nil local_value, "#{label} must be nil locally too"
    else
      assert_equal remote_value, local_value, label
    end
  end

  def generation_record
    { "id" => PromptOn::UuidV7.generate, "use_case" => "greeting", "kind" => "chat",
      "model" => "openai/gpt-4o-mini", "provider" => "openrouter", "status" => "ok",
      "started_at" => Time.now.utc.iso8601(6), "finish_reason" => "stop", "stop_kind" => "stop",
      "latency_ms" => 842, "resolution_source" => "remote",
      "input" => { "variables" => { "name" => "Ada" } }, "output" => { "content" => "Hello, Ada!" },
      "usage" => { "input_tokens" => 38, "output_tokens" => 6, "cost_source" => "provider" },
      "trace_id" => "integration:#{Process.pid}",
      "sdk" => { "name" => PromptOn::SDK_NAME, "version" => PromptOn::VERSION } }
  end
end
