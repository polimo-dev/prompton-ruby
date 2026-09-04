# frozen_string_literal: true

require_relative "test_helper"

class ResolverTest < Minitest::Test
  def setup
    @snapshot = PromptOn::SnapshotData.from_hash(snapshot_document)
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

  def test_the_prompt_name_is_the_only_selection_axis
    default = PromptOn::Resolver.resolve(@snapshot, "greeting")
    korean = PromptOn::Resolver.resolve(@snapshot, "greeting", prompt: "ko")

    assert_equal "default", default.prompt
    assert_equal "ko", korean.prompt
    assert_equal %w[default ko], korean.prompt_names
    refute_equal default.prompt_version_id, korean.prompt_version_id
    assert_equal default.model, korean.model
  end

  def test_an_unpinned_prompt_name_never_falls_back_to_default
    error = assert_raises(PromptOn::UnknownPromptError) do
      PromptOn::Resolver.resolve(@snapshot, "greeting", prompt: "fr")
    end

    assert_equal "fr", error.prompt
    assert_equal %w[default ko], error.prompt_names
    assert_equal "unknown_prompt", error.code
  end

  def test_an_unknown_use_case_and_a_use_case_without_a_deployment_are_different_errors
    assert_raises(PromptOn::UnknownUseCaseError) { PromptOn::Resolver.resolve(@snapshot, "nope") }
    assert_raises(PromptOn::UnresolvedError) { PromptOn::Resolver.resolve(@snapshot, "draft") }
  end

  def test_an_embedding_use_case_has_no_prompt_and_ignores_a_prompt_name
    resolution = PromptOn::Resolver.resolve(@snapshot, "embed", prompt: "ko")

    assert_equal "embedding", resolution.kind
    assert_nil resolution.prompt
    assert_nil resolution.prompt_version_id
    assert_empty resolution.prompt_names
    assert_equal "openai/text-embedding-3-small", resolution.model
  end

  def test_a_text_use_case_renders_a_single_string
    resolution = PromptOn::Resolver.resolve(@snapshot, "summarize")

    assert_equal "Summarize:\n- a\n- b\n", resolution.render(items: %w[a b])
    assert_equal ["items"], resolution.detected_variables
  end

  def test_a_dangling_reference_still_resolves_with_warnings
    document = snapshot_document
    document["prompt_versions"] = {}
    document["models"] = {}
    resolution = PromptOn::Resolver.resolve(PromptOn::SnapshotData.from_hash(document), "greeting")

    assert_nil resolution.model
    assert_nil resolution.prompt_version_id
    assert_equal ["missing_prompt_version: 0198f2a1-0000-7000-8000-00000000a001",
                  "missing_model: 0198f2a1-0000-7000-8000-00000000e001"],
                 resolution.warnings.map(&:to_s)
  end

  def test_schema_version_must_be_exactly_four
    [3, 5].each do |version|
      error = assert_raises(PromptOn::UnsupportedSchemaVersionError) do
        PromptOn::SnapshotData.from_hash(snapshot_document.merge("schema_version" => version))
      end
      assert_equal version, error.schema_version
    end

    missing = snapshot_document.except("schema_version")
    assert_raises(PromptOn::InvalidSnapshotError) { PromptOn::SnapshotData.from_hash(missing) }
    legacy = snapshot_document.except("schema_version").merge("version" => 4)
    assert_raises(PromptOn::InvalidSnapshotError) { PromptOn::SnapshotData.from_hash(legacy) }

    data = PromptOn::SnapshotData.from_hash(snapshot_document.merge("schema_version" => 4))
    assert_equal 4, data.schema_version
    assert_equal "openai/gpt-4o-mini", PromptOn::Resolver.resolve(data, "greeting").model
  end

  def test_prompt_names_lists_what_resolve_accepts
    assert_equal %w[default ko], PromptOn::Resolver.prompt_names(@snapshot, "greeting")
    assert_empty PromptOn::Resolver.prompt_names(@snapshot, "draft")
  end
end
