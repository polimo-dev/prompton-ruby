# frozen_string_literal: true

require_relative "test_helper"

# Executes conformance/*.json, the cross-language contract every PromptOn SDK ships in its own
# test suite. When two SDKs disagree about how a prompt renders, which model a snapshot resolves
# to, or how a monitoring log is truncated, an app that talks to PromptOn from two languages gets
# two different answers. That is what these files prevent.
class ConformanceTest < Minitest::Test
  FILES = %w[template.json use_case.json truncation.json stop_kind.json log_record.json].freeze
  REQUIRED_RECORD_FIELDS = %w[id use_case model status started_at].freeze
  ERROR_KINDS = %w[http_4xx http_5xx rate_limited timeout transport parse app].freeze
  KINDS = %w[chat text embedding].freeze
  PROVIDERS = %w[openrouter groq openai anthropic google other].freeze
  RESOLUTION_SOURCES = %w[remote disk bundle manual].freeze
  COST_SOURCES = %w[provider catalog unknown].freeze
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def test_every_fixture_declares_the_shared_format
    FILES.each do |name|
      document = conformance(name)
      assert_equal 1, document["format_version"], name
      assert_equal File.basename(name, ".json"), document["conformance"], name
    end
  end

  # --- template.json -------------------------------------------------------

  def test_template_render_cases
    normative, other = conformance("template.json")["cases"].partition { |c| c.fetch("normative", true) }

    normative.each do |kase|
      assert_equal kase["expect"], render_expectation(kase), "template case #{kase["name"]}"
    end

    # A non-normative case is reference behaviour other SDKs need not reproduce. This SDK
    # implements only the whitelisted filters and renders a hash with Ruby's own inspect, so two
    # of them differ; every case still has to produce an answer rather than blow up.
    refute_empty other
    other.each do |kase|
      actual = render_expectation(kase)
      assert(actual == kase["expect"] || actual["error"] == "parse_error" || actual.key?("output"),
             "non-normative case #{kase["name"]} produced #{actual.inspect}")
    end
  end

  def test_template_lint_cases
    conformance("template.json")["lint_cases"].each do |kase|
      reasons = PromptOn::Template.lint(kase["template"])
      actual = if reasons.empty?
                 { "lint" => "ok" }
               else
                 { "lint" => "error",
                   "reasons" => reasons.map { |r| { "kind" => r[:kind], "value" => r[:value] } } }
               end
      assert_equal kase["expect"], actual, "lint case #{kase["name"]}"
    end
  end

  def test_template_detected_variables_cases
    conformance("template.json")["variables_cases"].each do |kase|
      actual = { "variables" => PromptOn::Template.variables(kase["template"]) }
      assert_equal kase["expect"], actual, "variables case #{kase["name"]}"
    end
  end

  def test_template_whitelists_are_the_sdks
    document = conformance("template.json")
    assert_equal document["allowed_tags"], PromptOn::Template.allowed_tags
    assert_equal document["allowed_filters"], PromptOn::Template.allowed_filters
    assert_equal %w[liquid raw], document["engines"].sort
  end

  # --- use_case.json --------------------------------------------------------

  def test_every_conformance_document_decodes_as_schema_v4
    conformance("use_case.json")["documents"].each do |reference, raw|
      data = PromptOn::UseCaseDocument.from_hash(raw)
      assert_equal PromptOn::UseCaseDocument::SCHEMA_VERSION, data.schema_version, reference
    end
  end

  def test_resolve_cases
    document = conformance("use_case.json")
    assert_equal document["default_prompt"], PromptOn::Resolver::DEFAULT_PROMPT

    snapshots = document["documents"].transform_values { |raw| PromptOn::UseCaseDocument.from_hash(raw) }

    document["cases"].each do |kase|
      data = snapshots.fetch(kase["document_ref"])
      assert_equal kase["environment"], data.environment, "environment of #{kase["name"]}"
      assert_equal kase["expect"], resolve_expectation(data, kase), "resolve case #{kase["name"]}"
    end
  end

  # --- truncation.json -----------------------------------------------------

  def test_payload_policy_cases
    conformance("truncation.json")["cases"].each do |kase|
      actual = PromptOn::Payload.apply(kase["log"], symbolized_policy(kase["policy"]),
                                       hash_end_user: kase.dig("config", "hash_end_user") == true)
      assert_equal kase["expect"]["log"], actual, "truncation case #{kase["name"]}"
    end
  end

  def test_sampling_buckets
    conformance("truncation.json")["sampling"]["buckets"].each do |bucket|
      assert_equal bucket["bucket"], PromptOn::Payload.bucket(bucket["id"]),
                   "bucket of #{bucket["id"].inspect}"
    end
  end

  def test_every_truncated_string_stays_valid_utf8_and_within_its_cap
    conformance("truncation.json")["cases"].each do |kase|
      max_bytes = kase["policy"]["max_bytes"]
      log = kase["expect"]["log"]

      (log.dig("input", "messages") || []).each do |message|
        next unless message["content"].is_a?(String)

        assert_predicate message["content"], :valid_encoding?, "#{kase["name"]}: message content"
        assert_operator message["content"].bytesize, :<=, [max_bytes / 8, 64].max,
                        "#{kase["name"]}: per-message cap"
      end

      content = log.dig("output", "content")
      next unless content.is_a?(String)

      assert_predicate content, :valid_encoding?, "#{kase["name"]}: output content"
      assert_operator content.bytesize, :<=, [max_bytes / 4, 64].max, "#{kase["name"]}: output cap"
    end
  end

  # --- stop_kind.json ------------------------------------------------------

  def test_stop_kind_cases
    document = conformance("stop_kind.json")
    assert_equal document["stop_kinds"].sort, PromptOn::StopKind::ALL.sort

    document["cases"].each do |kase|
      kind = PromptOn::StopKind.normalize(kase["finish_reason"])
      assert_equal kase["stop_kind"], kind, "stop_kind of #{kase["finish_reason"].inspect}"
      assert_equal kase["truncated"], PromptOn::StopKind.truncated?(kind),
                   "truncated? of #{kase["finish_reason"].inspect}"
      assert_equal kind, PromptOn::StopKind.normalize(kind), "normalisation must be idempotent"
    end
  end

  # --- log_record.json ----------------------------------------------

  def test_golden_records_satisfy_the_ingest_rules
    conformance("log_record.json")["records"].each do |entry|
      record = entry["record"]
      name = entry["name"]

      REQUIRED_RECORD_FIELDS.each { |field| assert record.key?(field), "#{name}: missing #{field}" }
      assert_match UUID, record["id"], "#{name}: id must be a UUID"
      assert_equal "7", record["id"][14], "#{name}: id must be a UUIDv7, not a v4"
      assert_includes %w[ok error], record["status"], "#{name}: status"
      assert Time.iso8601(record["started_at"]), "#{name}: started_at"
      assert_operator record["use_case"].bytesize, :<=, 512, "#{name}: use_case"

      assert_optional_enum(record["kind"], KINDS, "#{name}: kind")
      assert_optional_enum(record["provider"], PROVIDERS, "#{name}: provider")
      assert_optional_enum(record["stop_kind"], PromptOn::StopKind::ALL, "#{name}: stop_kind")
      assert_optional_enum(record["source"], RESOLUTION_SOURCES, "#{name}: resolution_source")
      assert_optional_enum(record.dig("usage", "cost_source"), COST_SOURCES, "#{name}: cost_source")

      %w[deployment_id prompt_version_id model_id].each do |key|
        assert_match UUID, record[key], "#{name}: #{key} must be a UUID" if record[key]
      end

      if record["error"]
        assert_includes ERROR_KINDS, record["error"]["kind"], "#{name}: error.kind"
        assert_operator record["error"]["message"].to_s.bytesize, :<=, 2048, "#{name}: error.message"
      end

      assert_operator JSON.generate(record["context"] || {}).bytesize, :<=, 2048, "#{name}: context"
      assert_operator JSON.generate(record["metadata"] || {}).bytesize, :<=, 4096, "#{name}: metadata"
      assert_operator JSON.generate(record["params"] || {}).bytesize, :<=, 4096, "#{name}: params"
      assert_operator JSON.generate(record.dig("usage", "raw") || {}).bytesize, :<=, 16_384,
                      "#{name}: usage.raw"

      json = JSON.generate(record)
      assert_predicate json, :valid_encoding?, "#{name}: must be valid UTF-8"
      refute_includes json, "\u0000", "#{name}: must contain no NUL byte"
    end
  end

  def test_golden_records_pass_the_default_payload_policy_unchanged
    conformance("log_record.json")["records"].each do |entry|
      policy = { mode: "full", sample_rate: 1.0, max_bytes: 262_144 }
      assert_equal entry["record"], PromptOn::Payload.apply(entry["record"], policy),
                   "#{entry["name"]} should pass through the payload policy unchanged"
    end
  end

  def test_batch_envelope_holds_exactly_the_documented_records
    document = conformance("log_record.json")
    records = document["records"].map { |entry| entry["record"] }

    assert_equal records, document["batch_envelope"]["request"]["logs"]
    assert_equal records.length, document["batch_envelope"]["response_example"]["accepted"]
    assert_equal records.length, document["batch_envelope"]["response_on_resend"]["duplicates"]
    assert_operator records.length, :<=, document["endpoint"]["max_records_per_request"]
    assert_equal PromptOn::LogBuffer::MAX_RECORDS_PER_REQUEST,
                 document["endpoint"]["max_records_per_request"]
  end

  private

  def symbolized_policy(policy)
    { mode: policy["mode"], sample_rate: policy["sample_rate"], max_bytes: policy["max_bytes"] }
  end

  def assert_optional_enum(value, allowed, label)
    assert_includes allowed, value, label unless value.nil?
  end

  def render_expectation(kase)
    { "output" => PromptOn::Template.render(kase["template"], kase["variables"], engine: kase["engine"]) }
  rescue PromptOn::MissingVariableError => e
    { "error" => "missing_variable", "variable" => e.variable }
  rescue PromptOn::TemplateSyntaxError
    { "error" => "parse_error" }
  rescue PromptOn::TemplateRenderError
    { "error" => "render_error" }
  end

  def resolve_expectation(data, kase)
    resolution = PromptOn::Resolver.resolve(data, kase["use_case"], prompt: kase["prompt"])
    expectation = {
      "key" => resolution.use_case, "kind" => resolution.kind, "deployment_id" => resolution.deployment_id,
      "revision" => resolution.deployment_revision, "prompt" => resolution.prompt,
      "prompt_names" => resolution.prompt_names, "model_id" => resolution.model_id,
      "model" => resolution.model, "provider" => resolution.provider,
      "params" => resolution.params,
      "provider_options" => resolution.provider_options,
      "prompt_version" => resolution.prompt_version_id &&
                          { "id" => resolution.prompt_version_id, "number" => resolution.prompt_version_number },
      "source" => resolution.source,
      "warnings" => resolution.warnings.map(&:to_s)
    }
    expectation.merge(rendered(resolution, kase["variables"]))
  rescue PromptOn::UnknownPromptError => e
    { "error" => "unknown_prompt", "key" => e.use_case, "prompt" => e.prompt, "prompt_names" => e.prompt_names }
  rescue PromptOn::UnknownUseCaseError => e
    { "error" => "unknown_use_case", "key" => e.use_case }
  rescue PromptOn::MissingVariableError => e
    { "error" => "missing_variable", "variable" => e.variable }
  rescue PromptOn::Error => e
    { "error" => e.code }
  end

  def rendered(resolution, variables)
    if resolution.kind == "chat" && resolution.messages
      messages = variables ? resolution.render(variables) : resolution.messages
      { "messages" => messages.map { |m| { "role" => m["role"], "content" => m["content"] } } }
    elsif resolution.kind == "text" && resolution.text
      { "text" => variables ? resolution.render(variables) : resolution.text }
    else
      {}
    end
  end
end
