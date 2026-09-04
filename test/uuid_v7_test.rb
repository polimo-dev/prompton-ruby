# frozen_string_literal: true

require_relative "test_helper"

class UuidV7Test < Minitest::Test
  def test_layout_is_rfc_9562_version_7
    uuid = PromptOn::UuidV7.generate

    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, uuid)
    assert_equal "7", uuid[14], "the version nibble must be 7, not 4"
    assert_includes %w[8 9 a b], uuid[19], "the variant nibble must be 10xx"
  end

  def test_the_timestamp_is_the_first_48_bits
    uuid = PromptOn::UuidV7.generate(1_756_000_000_123)

    assert_equal 1_756_000_000_123, PromptOn::UuidV7.timestamp_ms(uuid)
    assert_nil PromptOn::UuidV7.timestamp_ms("not-a-uuid")
  end

  def test_ids_from_different_milliseconds_sort_by_time
    earlier = PromptOn::UuidV7.generate(1_756_000_000_000)
    later = PromptOn::UuidV7.generate(1_756_000_001_000)

    assert_operator earlier, :<, later
  end

  def test_ids_are_unique
    ids = Array.new(2_000) { PromptOn::UuidV7.generate }

    assert_equal ids.length, ids.uniq.length
  end
end
