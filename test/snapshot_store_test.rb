# frozen_string_literal: true

require_relative "test_helper"

# The three tiers: memory, one local file, the file bundled into the app. No database, no Redis,
# nothing shared between instances.
class SnapshotStoreTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("prompton-test")
    @logger = MemoryLogger.new
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_a_remote_document_is_mirrored_to_disk_with_a_sidecar
    store = build_store(disk_cache: path("snapshot.json"))
    store.install_remote(snapshot_json, etag: "\"v1\"", last_modified: "Fri, 04 Sep 2026 00:21:48 GMT")

    assert_path_exists path("snapshot.json")
    meta = JSON.parse(File.read(path("snapshot.json.meta.json")))
    assert_equal "\"v1\"", meta["etag"]
    assert_equal "production", meta["environment"]
    assert_equal "sdkfixture", meta["project"]
    assert_empty Dir.glob(path("*.tmp.*")), "the temp file must be renamed, not left behind"
  end

  def test_a_second_process_loads_what_the_first_one_wrote
    build_store(disk_cache: path("snapshot.json")).install_remote(snapshot_json, etag: "\"v1\"")

    entry = build_store(disk_cache: path("snapshot.json")).load_local

    assert_equal "disk", entry.source
    assert_equal "\"v1\"", entry.etag
    assert_equal "openai/gpt-4o-mini", entry.data.models.values.first.model_id
  end

  def test_the_bundle_is_used_only_when_the_disk_cache_is_empty
    File.write(path("bundle.json"), snapshot_json(temperature: 0.9))
    store = build_store(disk_cache: path("missing.json"), bundle: path("bundle.json"))

    assert_equal "bundle", store.load_local.source

    File.write(path("missing.json"), snapshot_json(temperature: 0.1))
    assert_equal "disk", build_store(disk_cache: path("missing.json"), bundle: path("bundle.json")).load_local.source
  end

  def test_a_document_for_another_environment_is_never_used
    File.write(path("snapshot.json"), snapshot_json(environment: "staging"))
    store = build_store(disk_cache: path("snapshot.json"))

    assert_nil store.load_local
    assert(@logger.lines.any? { |line| line.include?("environment") })
  end

  def test_a_document_for_another_project_is_never_used
    File.write(path("snapshot.json"), snapshot_json(project: "someone-else"))
    store = build_store(disk_cache: path("snapshot.json"))

    assert_nil store.load_local
    assert(@logger.lines.any? { |line| line.include?("project") })
  end

  def test_a_corrupt_or_partial_file_is_ignored_rather_than_raised
    File.write(path("snapshot.json"), snapshot_json[0, 200])
    store = build_store(disk_cache: path("snapshot.json"))

    assert_nil store.load_local
  end

  def test_a_missing_or_corrupt_sidecar_still_loads_the_document
    File.write(path("snapshot.json"), snapshot_json)
    File.write(path("snapshot.json.meta.json"), "{not json")

    entry = build_store(disk_cache: path("snapshot.json")).load_local

    assert_equal "disk", entry.source
    assert_nil entry.etag
  end

  def test_export_writes_the_document_and_its_sidecar_for_committing_as_a_bundle
    store = build_store(disk_cache: false)
    store.install_remote(snapshot_json, etag: "\"v7\"")

    store.export(path("use-cases.production.json"))

    assert_equal JSON.parse(snapshot_json), JSON.parse(File.read(path("use-cases.production.json")))
    assert_equal "\"v7\"", JSON.parse(File.read(path("use-cases.production.json.meta.json")))["etag"]
  end

  def test_export_without_a_document_says_so
    assert_raises(PromptOn::NotReadyError) { build_store(disk_cache: false).export(path("out.json")) }
  end

  def test_a_304_promotes_a_disk_document_back_to_remote
    File.write(path("snapshot.json"), snapshot_json)
    store = build_store(disk_cache: path("snapshot.json"))
    store.load_local
    assert_equal "disk", store.entry.source

    store.confirm_current
    assert_equal "remote", store.entry.source
    refute_predicate store.entry, :stale?
  end

  def test_a_failed_refresh_marks_the_document_stale_without_losing_it
    store = build_store(disk_cache: false)
    store.install_remote(snapshot_json, etag: "\"v1\"")

    store.mark_stale

    assert_predicate store.entry, :stale?
    assert_equal "openai/gpt-4o-mini", store.data.models.values.first.model_id
  end

  private

  def path(name)
    File.join(@dir, name)
  end

  def build_store(**overrides)
    PromptOn::SnapshotStore.new(PromptOn::Config.new(**client_options(logger: @logger, **overrides)))
  end
end
