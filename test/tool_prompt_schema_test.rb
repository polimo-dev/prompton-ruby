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

  def test_schema8_readable_references_resolve_without_resource_ids
    document = PromptOn::UseCaseDocument.from_hash(
      "schema_version" => 8,
      "project" => "p",
      "environment" => "staging",
      "prompts" => {
        "support_reply" => { "kind" => "chat", "default_params" => { "max_tokens" => 100 } },
        "triage" => { "kind" => "chat", "default_params" => {} }
      },
      "deployments" => {
        "support_reply" => {
          "revision" => "v2026.10.14-1", "provider" => "openrouter",
          "model" => "google/gemini-3.8-flash", "prompt_version" => 2,
          "params" => { "temperature" => 0.3 }, "provider_options" => { "allow_fallbacks" => false }
        },
        "triage" => {
          "revision" => "v2026.10.14-2", "provider" => "anthropic",
          "model" => "google/gemini-3.8-flash", "prompt_version" => 2
        }
      },
      "prompt_versions" => {
        "support_reply@2" => {
          "prompt" => "support_reply", "number" => 2, "kind" => "chat", "engine" => "liquid",
          "messages" => [{ "role" => "user", "content" => "Reply to {{ question }}" }]
        },
        "triage@2" => {
          "prompt" => "triage", "number" => 2, "kind" => "chat", "engine" => "liquid",
          "messages" => [{ "role" => "system", "content" => "Classify only" }]
        }
      },
      "models" => {
        "openrouter:google/gemini-3.8-flash" => {
          "provider" => "openrouter", "model" => "google/gemini-3.8-flash",
          "provider_options" => { "only" => ["Google"] }
        },
        "anthropic:google/gemini-3.8-flash" => {
          "provider" => "anthropic", "model" => "google/gemini-3.8-flash",
          "provider_options" => { "routing" => "direct" }
        }
      }
    )

    support = PromptOn::Resolver.resolve(document, "support_reply")
    triage = PromptOn::Resolver.resolve(document, "triage")

    assert_equal 8, document.schema_version
    assert_nil support.deployment_id
    assert_nil support.prompt_version_id
    assert_nil support.model_id
    assert_equal 2, support.prompt_version_number
    assert_equal "google/gemini-3.8-flash", support.model
    assert_equal "openrouter", support.provider
    assert_equal({ "allow_fallbacks" => false, "only" => ["Google"] }, support.provider_options)
    assert_equal "Reply to Ada", support.render("question" => "Ada").last["content"]
    assert_equal "anthropic", triage.provider
    assert_equal({ "routing" => "direct" }, triage.provider_options)
  end

  def test_schema9_single_prompt_response_normalizes_to_readable_prompt_document
    document = PromptOn::UseCaseDocument.from_hash(schema9_single_prompt_document)
    support = PromptOn::Resolver.resolve(document, "support_reply")

    assert_equal 9, document.schema_version
    assert_equal ["support_reply"], document.use_case_keys
    assert_equal "anthropic/claude-sonnet-4", support.model
    assert_equal "openrouter", support.provider
    assert_equal "v2026.10.14-1", support.deployment_revision
    assert_equal 1, support.prompt_version_number
    assert_equal "Reply to Ada for pro.", support.render("question" => "Ada", "plan" => "pro").last["content"]
  end

  def test_schema9_single_prompt_response_preserves_decision_payload
    body = schema9_single_prompt_document(
      key: "decision_triage",
      kind: "decision",
      model: "typesafe/jev-1.13",
      prompt_version: {
        "prompt" => "decision_triage", "number" => 1, "kind" => "decision", "engine" => "liquid",
        "decision" => { "questions" => { "eligible" => { "type" => "noul" } } }
      },
      deployment: {
        "revision" => "v2026.10.14-1", "provider" => "openrouter", "model" => "typesafe/jev-1.13",
        "prompt_version" => 1, "api" => "decisions", "request_path" => "/api/v1/systemone"
      }
    )
    document = PromptOn::UseCaseDocument.from_hash(body)
    evidence = PromptOn::Resolver.resolve(document, "decision_triage")
    version = document.prompt_versions.fetch("decision_triage@1")

    assert_equal "decision", evidence.kind
    assert_equal({ "questions" => { "eligible" => { "type" => "noul" } } }, version.decision)
    assert_equal "/api/v1/systemone", evidence.request_path
  end

  def test_schema9_rejects_mixed_or_inconsistent_single_prompt_shapes
    [["mixed collections", schema9_single_prompt_document.merge("prompts" => {})],
     ["prompt mismatch", schema9_single_prompt_document.tap { |doc| doc["prompt_version"]["prompt"] = "other" }],
     ["model mismatch", schema9_single_prompt_document.tap { |doc| doc["deployment"]["model"] = "other" }],
     ["missing version", schema9_single_prompt_document.merge("prompt_version" => nil)],
     ["float deployment version", schema9_single_prompt_document.tap do |doc|
       doc["deployment"]["prompt_version"] = 1.0
     end],
     ["float schema", schema9_single_prompt_document.merge("schema_version" => 9.0)],
     ["missing prompt", schema9_single_prompt_document.except("prompt")]].each do |name, body|
      assert_raises(PromptOn::InvalidUseCaseDocumentError, name) do
        PromptOn::UseCaseDocument.from_hash(body)
      end
    end
  end

  def test_schema8_prompt_version_pin_must_be_positive
    error = assert_raises(PromptOn::InvalidUseCaseDocumentError) do
      PromptOn::UseCaseDocument.from_hash(
        "schema_version" => 8,
        "prompts" => { "chat" => { "kind" => "chat" } },
        "deployments" => { "chat" => { "revision" => "v2026.10.14-1", "provider" => "openrouter",
                                       "model" => "openai/gpt-4o-mini", "prompt_version" => 0 } }
      )
    end

    assert_match(/prompt_version must be a positive integer/, error.message)
  end

  def test_schema8_composite_keys_must_match_embedded_fields
    valid = {
      "schema_version" => 8,
      "prompts" => { "chat" => { "kind" => "chat" } },
      "deployments" => {
        "chat" => { "revision" => "v2026.10.14-1", "provider" => "openrouter",
                    "model" => "openai/gpt-4o-mini", "prompt_version" => 2 }
      },
      "prompt_versions" => {
        "chat@2" => { "prompt" => "chat", "number" => 2, "kind" => "chat",
                      "messages" => [{ "role" => "user", "content" => "ok" }] }
      },
      "models" => {
        "openrouter:openai/gpt-4o-mini" => {
          "provider" => "openrouter", "model" => "openai/gpt-4o-mini"
        }
      }
    }

    [["prompt mismatch", ["prompt_versions", "chat@2", "prompt"], "other"],
     ["number mismatch", ["prompt_versions", "chat@2", "number"], 99],
     ["provider mismatch", ["models", "openrouter:openai/gpt-4o-mini", "provider"], "other"],
     ["model mismatch", ["models", "openrouter:openai/gpt-4o-mini", "model"], "other"]].each do |name, path, value|
      document = Marshal.load(Marshal.dump(valid))
      document.dig(*path[0...-1])[path.last] = value

      error = assert_raises(PromptOn::InvalidUseCaseDocumentError, name) do
        PromptOn::UseCaseDocument.from_hash(document)
      end
      assert_match(/schema8/, error.message)
    end
  end

  def test_schema8_rejects_retired_reference_fields
    document = {
      "schema_version" => 8,
      "prompts" => { "chat" => { "kind" => "chat" } },
      "deployments" => {
        "chat" => { "revision" => "v2026.10.14-1", "provider" => "openrouter",
                    "model" => "openai/gpt-4o-mini", "prompt_version" => 1,
                    "prompt_pins" => { "default" => "chat@1" } }
      },
      "prompt_versions" => {
        "chat@1" => { "prompt" => "chat", "number" => 1, "kind" => "chat",
                      "messages" => [{ "role" => "user", "content" => "ok" }] }
      },
      "models" => {
        "openrouter:openai/gpt-4o-mini" => {
          "provider" => "openrouter", "model" => "openai/gpt-4o-mini"
        }
      }
    }

    error = assert_raises(PromptOn::InvalidUseCaseDocumentError) do
      PromptOn::UseCaseDocument.from_hash(document)
    end
    assert_match(/must not include prompt_pins/, error.message)
  end

  private

  def schema9_single_prompt_document(key: "support_reply", kind: "chat", model: "anthropic/claude-sonnet-4",
                                     prompt_version: nil, deployment: nil)
    prompt_version ||= {
      "prompt" => key, "number" => 1, "kind" => kind, "engine" => "liquid",
      "messages" => [{ "role" => "system", "content" => "Keep opaque 019916f4-12b0-7e6c-a1d3-8c9f2b4e6a57." },
                     { "role" => "user", "content" => "Reply to {{ question }} for {{ plan }}." }]
    }
    deployment ||= {
      "revision" => "v2026.10.14-1", "provider" => "openrouter", "model" => model,
      "prompt_version" => prompt_version["number"], "params" => {}, "provider_options" => { "only" => ["Anthropic"] },
      "api" => "chat_completions", "request_path" => "/api/v1/chat/completions"
    }
    {
      "schema_version" => 9,
      "project" => "heydiary-10242",
      "environment" => "production",
      "prompt" => {
        "key" => key, "kind" => kind,
        "input_schema" => [{ "name" => "plan", "type" => "string", "required" => false },
                           { "name" => "question", "type" => "string", "required" => false }],
        "default_params" => {},
        "payload_policy" => { "mode" => "full", "sample_rate" => 1.0, "max_bytes" => 262_144 }
      },
      "deployment" => deployment,
      "prompt_version" => prompt_version,
      "model" => {
        "provider" => "openrouter", "model" => model, "display_name" => "Claude Sonnet 4",
        "metadata" => {}, "provider_options" => {}, "capabilities" => ["tools"], "status" => "active"
      }
    }
  end
end
