# frozen_string_literal: true

require_relative "test_helper"

class TemplateTest < Minitest::Test
  def test_raw_engine_returns_the_source_verbatim
    source = "{% include \"x\" %} {{ a"
    assert_equal source, PromptOn::Template.render(source, { "a" => 1 }, engine: "raw")
  end

  def test_render_messages_renders_content_and_keeps_the_other_keys
    messages = [{ "role" => "system", "content" => "You greet." },
                { "role" => "user", "content" => "Hi {{ name }}.", "name" => "ada" }]

    rendered = PromptOn::Template.render_messages(messages, { name: "Ada" })

    assert_equal "Hi Ada.", rendered.last["content"]
    assert_equal "user", rendered.last["role"]
    assert_equal "ada", rendered.last["name"]
    assert_equal "Hi {{ name }}.", messages.last["content"], "the input must not be mutated"
  end

  def test_symbol_keys_and_nested_symbol_keys_are_accepted
    assert_equal "Ada", PromptOn::Template.render("{{ user.name }}", { user: { name: "Ada" } })
  end

  def test_a_missing_variable_reports_the_dotted_path
    error = assert_raises(PromptOn::MissingVariableError) do
      PromptOn::Template.render("{{ user.name }}", { "user" => {} })
    end

    assert_equal "user.name", error.variable
    assert_equal "missing_variable", error.code
  end

  def test_a_key_present_with_nil_is_not_missing
    assert_equal "[]", PromptOn::Template.render("[{{ x }}]", { "x" => nil })
    assert_equal "fallback", PromptOn::Template.render("{{ x | default: \"fallback\" }}", { "x" => nil })
  end

  def test_a_filter_outside_the_whitelist_is_refused
    assert_raises(PromptOn::TemplateSyntaxError) do
      PromptOn::Template.render("{{ s | upcase }}", { "s" => "abc" })
    end
  end

  def test_lint_accepts_a_conforming_template_and_names_every_problem
    assert_empty PromptOn::Template.lint("{% for i in xs %}{{ i | join: \",\" }}{% endfor %}")

    reasons = PromptOn::Template.lint("{% capture x %}{{ y | upcase }}{% endcapture %}")
    assert_equal [{ kind: "disallowed_tag", value: "capture" },
                  { kind: "disallowed_tag", value: "endcapture" }], reasons
  end

  def test_detected_variables_exclude_loop_variables_and_assign_targets
    template = "{% assign greeting = salutation %}{% for row in rows %}{{ greeting }} {{ row.name }}{% endfor %}"
    assert_equal %w[rows salutation], PromptOn::Template.variables(template)
  end

  def test_an_unclosed_block_reports_the_tag_it_expected
    error = assert_raises(PromptOn::TemplateSyntaxError) { PromptOn::Template.parse("{% if a %}x") }
    assert_equal "Expected 'endif'", error.message
  end

  def test_a_blank_if_body_produces_no_output
    # A body made only of whitespace is dropped rather than rendered, which is what makes
    # `{% unless forloop.last %} {% endunless %}` a no-op.
    assert_equal "ab", PromptOn::Template.render(
      "{% for i in xs %}{{ i }}{% unless forloop.last %} {% endunless %}{% endfor %}",
      { "xs" => %w[a b] }
    )
  end
end
