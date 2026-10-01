# frozen_string_literal: true

require "json"
require_relative "test_helper"

class ToolPromptSchemaTest < Minitest::Test
  SLOT_ERROR = "Message slots are not supported; compose conversation history in app code."

  def test_schema7_tools_are_preserved_and_message_slots_are_rejected
    document = PromptOn::UseCaseDocument.from_hash(
      "schema_version" => 7,
      "prompts" => { "chat" => { "kind" => "chat", "default_params" => {} } },
      "deployments" => {
        "chat" => {
          "prompt_key" => "chat", "model_id" => "m", "api" => "chat_completions",
          "request_path" => "/api/v1/chat/completions", "template_pins" => { "default" => "v" }
        }
      },
      "prompt_versions" => {
        "v" => {
          "id" => "v", "kind" => "chat", "engine" => "liquid",
          "messages" => [
            { "role" => "system", "content" => "Hi {{ name }}" },
            { "type" => "slot", "name" => "history" },
            { "role" => "assistant", "content" => nil,
              "tool_calls" => [{ "id" => "call_1", "type" => "function",
                                 "function" => { "name" => "lookup", "arguments" => "{}" } }] },
            { "role" => "tool", "tool_call_id" => "call_1",
              "content" => [{ "type" => "text", "text" => "ok" }] }
          ],
          "tools" => {
            "definitions" => [
              {
                "type" => "function",
                "function" => {
                  "name" => "lookup",
                  "parameters" => { "type" => "object" },
                  "output_schema" => { "type" => "object" }
                }
              }
            ],
            "tool_choice" => "auto", "parallel_tool_calls" => true
          }
        }
      },
      "models" => { "m" => { "id" => "m", "provider" => "openrouter", "model_id" => "openai/gpt-4o-mini" } }
    )

    resolution = PromptOn::Resolver.resolve(document, "chat")

    assert_equal "chat_completions", resolution.api
    assert_equal "auto", resolution.tools["tool_choice"]

    error = assert_raises(PromptOn::TemplateRenderError) do
      PromptOn::Template.render_messages(
        resolution.messages,
        { name: "Ada", history: [{ "role" => "user", "content" => "past", "tool_call_id" => "keep" }] }
      )
    end
    assert_equal SLOT_ERROR, error.message

    error = assert_raises(PromptOn::TemplateRenderError) do
      PromptOn::Template.render_messages(
        [{ "type" => "slot", "name" => "history" }],
        { history: [] },
        engine: "raw"
      )
    end
    assert_equal SLOT_ERROR, error.message
  end

  def test_native_messages_are_preserved_and_app_history_is_composed_explicitly
    managed_messages = [
      { "role" => "system", "content" => "Hi {{ name }}" },
      { "role" => "assistant", "content" => nil,
        "tool_calls" => [{ "id" => "call_1", "type" => "function",
                           "function" => { "name" => "lookup", "arguments" => "{}" } }] },
      { "role" => "tool", "tool_call_id" => "call_1",
        "content" => [{ "type" => "text", "text" => "ok" }] }
    ]
    app_history = [{ "role" => "user", "content" => "past", "tool_call_id" => "keep" }]

    rendered = PromptOn::Template.render_messages(managed_messages, { name: "Ada" })
    final_messages = [
      rendered[0],
      *app_history,
      *rendered[1..],
      { "role" => "user", "content" => "now" }
    ]

    assert_equal({ "role" => "system", "content" => "Hi Ada" }, final_messages[0])
    assert_equal({ "role" => "user", "content" => "past", "tool_call_id" => "keep" }, final_messages[1])
    assert_nil final_messages[2]["content"]
    assert_equal "call_1", final_messages[2]["tool_calls"][0]["id"]
    assert_equal [{ "type" => "text", "text" => "ok" }], final_messages[3]["content"]
    assert_equal({ "role" => "user", "content" => "now" }, final_messages[4])
  end

  def test_preview_http_contract_slot_fixture_is_rejected_and_tools_survive
    fixture = JSON.parse(File.read(File.join(__dir__, "conformance", "http_contract.json")))
    document = PromptOn::UseCaseDocument.from_hash(fixture["snapshot"])
    evidence = PromptOn::Resolver.resolve(document, fixture["render"]["key"])

    error = assert_raises(PromptOn::TemplateRenderError) do
      PromptOn::Template.render_messages(
        evidence.messages,
        { "locale" => "ko-KR", "topic" => "park walks",
          "history" => fixture["render"]["request"]["body"]["messages"][1, 3] },
        engine: evidence.engine
      )
    end

    assert_equal SLOT_ERROR, error.message
    assert_equal "auto", evidence.tools["tool_choice"]
    refute evidence.tools["parallel_tool_calls"]
    assert_equal "object", evidence.tools["definitions"].first["output_schema"]["type"]
  end
end
