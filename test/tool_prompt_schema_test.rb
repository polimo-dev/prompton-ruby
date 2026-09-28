# frozen_string_literal: true

require "json"
require_relative "test_helper"

class ToolPromptSchemaTest < Minitest::Test
  def test_schema7_tools_and_message_slots_preserve_native_messages
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

    messages = PromptOn::Template.render_messages(
      resolution.messages,
      { name: "Ada", history: [{ "role" => "user", "content" => "past", "tool_call_id" => "keep" }] }
    )

    assert_equal({ "role" => "system", "content" => "Hi Ada" }, messages[0])
    assert_equal({ "role" => "user", "content" => "past", "tool_call_id" => "keep" }, messages[1])
    assert_nil messages[2]["content"]
    assert_equal "call_1", messages[2]["tool_calls"][0]["id"]
    assert_equal [{ "type" => "text", "text" => "ok" }], messages[3]["content"]
  end

  def test_preview_http_contract_preserves_native_history_and_tools
    fixture = JSON.parse(File.read(File.join(__dir__, "conformance", "http_contract.json")))
    document = PromptOn::UseCaseDocument.from_hash(fixture["snapshot"])
    evidence = PromptOn::Resolver.resolve(document, fixture["render"]["key"])

    messages = PromptOn::Template.render_messages(
      evidence.messages,
      { "locale" => "ko-KR", "topic" => "park walks",
        "history" => fixture["render"]["request"]["body"]["messages"][1, 3] },
      engine: evidence.engine
    )

    assert_equal fixture["render"]["request"]["body"]["messages"], messages
    assert_equal "auto", evidence.tools["tool_choice"]
    refute evidence.tools["parallel_tool_calls"]
    assert_equal "object", evidence.tools["definitions"].first["output_schema"]["type"]
  end
end
