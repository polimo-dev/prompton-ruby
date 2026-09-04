# frozen_string_literal: true

require_relative "test_helper"

class StopKindTest < Minitest::Test
  def test_provider_finish_reasons_normalise
    assert_equal "stop", PromptOn::StopKind.normalize("end_turn")
    assert_equal "length", PromptOn::StopKind.normalize("MAX_TOKENS")
    assert_equal "tool_call", PromptOn::StopKind.normalize("tool_use")
    assert_equal "content_filter", PromptOn::StopKind.normalize("content_filter")
  end

  def test_comparison_trims_and_lowercases
    assert_equal "stop", PromptOn::StopKind.normalize("  STOP  ")
  end

  def test_unknown_empty_and_absent_reasons_become_other
    assert_equal "other", PromptOn::StopKind.normalize(nil)
    assert_equal "other", PromptOn::StopKind.normalize("")
    assert_equal "other", PromptOn::StopKind.normalize("SAFETY")
    assert_equal "other", PromptOn::StopKind.normalize("RECITATION")
  end

  def test_normalisation_is_idempotent
    PromptOn::StopKind::ALL.each do |kind|
      assert_equal kind, PromptOn::StopKind.normalize(kind)
    end
  end

  def test_only_length_counts_as_truncated
    assert PromptOn::StopKind.truncated?("length")
    refute PromptOn::StopKind.truncated?("tool_calls")
    refute PromptOn::StopKind.truncated?("stop")
  end
end
