# frozen_string_literal: true

require_relative "test_helper"

class ResolverTest < Minitest::Test
  def setup
    @snapshot = PromptOn::PromptDocument.from_hash(snapshot_document)
  end

  def test_params_merge_shallowly_with_the_deployment_winning
    resolution = PromptOn::Resolver.resolve(@snapshot, "greeting")

    assert_equal({ "temperature" => 0.2, "max_tokens" => 512 }, resolution.params)
    assert_equal({ "allow_fallbacks" => true, "only" => ["OpenAI"], "sort" => nil },
                 resolution.provider_options)
  end

  def test_an_override_of_nil_is_kept_rather_than_deleted
    resolution = PromptOn::Resolver.resolve(@snapshot, "greeting")

    assert resolution.provider_options.key?("sort")
    assert_nil resolution.provider_options["sort"]
  end

  def test_the_default_template_is_selected
    default = PromptOn::Resolver.resolve(@snapshot, "greeting")

    assert_equal "default", default.template
    assert_equal ["default"], default.template_names
    assert_equal 2, default.prompt_version_number
  end

  def test_an_unpinned_template_name_never_falls_back_to_default
    error = assert_raises(PromptOn::UnknownTemplateError) do
      PromptOn::Resolver.resolve(@snapshot, "greeting", template: "fr")
    end

    assert_equal "greeting", error.prompt
    assert_equal "fr", error.template
    assert_equal ["default"], error.template_names
    assert_equal "unknown_template", error.code
  end

  def test_an_unknown_prompt_and_a_prompt_without_a_deployment_are_different_errors
    assert_raises(PromptOn::UnknownPromptError) { PromptOn::Resolver.resolve(@snapshot, "nope") }
    assert_raises(PromptOn::UnresolvedError) { PromptOn::Resolver.resolve(@snapshot, "draft") }
  end

  def test_an_embedding_prompt_has_no_template_and_ignores_a_template_name
    resolution = PromptOn::Resolver.resolve(@snapshot, "embed", template: "other")

    assert_equal "embedding", resolution.kind
    assert_nil resolution.template
    assert_nil resolution.prompt_version_id
    assert_empty resolution.template_names
    assert_equal "openai/text-embedding-3-small", resolution.model
  end

  def test_a_text_prompt_renders_a_single_string
    resolution = PromptOn::Resolver.resolve(@snapshot, "summarize")

    assert_equal "Summarize:\n- a\n- b\n", resolution.render(items: %w[a b])
    assert_equal ["items"], resolution.detected_variables
  end

  def test_schema1_rejects_dangling_references
    document = snapshot_document
    document["prompt_versions"] = {}
    document["models"] = {}

    error = assert_raises(PromptOn::InvalidPromptDocumentError) do
      PromptOn::PromptDocument.from_hash(document)
    end
    assert_match(/references unknown model/, error.message)
  end

  def test_schema_version_accepts_only_current_version
    [3, 4, 5, 6, 7, 8, 10].each do |version|
      error = assert_raises(PromptOn::UnsupportedSchemaVersionError) do
        PromptOn::PromptDocument.from_hash(snapshot_document.merge("schema_version" => version))
      end
      assert_equal version, error.schema_version
    end

    missing = snapshot_document.except("schema_version")
    assert_raises(PromptOn::InvalidPromptDocumentError) { PromptOn::PromptDocument.from_hash(missing) }
    legacy = snapshot_document.except("schema_version").merge("version" => 4)
    assert_raises(PromptOn::InvalidPromptDocumentError) { PromptOn::PromptDocument.from_hash(legacy) }

    data = PromptOn::PromptDocument.from_hash(snapshot_document)
    assert_equal 1, data.schema_version
    assert_equal "openai/gpt-4o-mini", PromptOn::Resolver.resolve(data, "greeting").model
  end

  def test_deployment_revision_must_be_a_string
    document = snapshot_document
    document["deployments"]["greeting"]["revision"] = 1

    error = assert_raises(PromptOn::InvalidPromptDocumentError) do
      PromptOn::PromptDocument.from_hash(document)
    end
    assert_match(/revision must be a string/, error.message)
  end

  def test_template_names_lists_what_resolve_accepts
    assert_equal ["default"], PromptOn::Resolver.template_names(@snapshot, "greeting")
    assert_empty PromptOn::Resolver.template_names(@snapshot, "draft")
  end
end
