# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "json"
require "tmpdir"
require "prompton"
require_relative "support/stub_server"

module PromptOnTest
  CONFORMANCE_DIR = File.expand_path("conformance", __dir__)

  module_function

  def conformance(name)
    JSON.parse(File.read(File.join(CONFORMANCE_DIR, name)))
  end

  # A logger that keeps its lines instead of printing them, so a test can assert on the one line
  # the SDK promises to emit.
  class MemoryLogger
    attr_reader :lines

    def initialize
      @lines = []
    end

    %i[debug info warn error].each do |level|
      define_method(level) do |message = nil, &block|
        @lines << (message || block&.call).to_s
        true
      end
    end
  end

  # A snapshot document with the three kinds of use case, ready to serve or write to disk.
  def snapshot_document(environment: "production", project: "sdkfixture", temperature: 0.2)
    {
      "schema_version" => 3, "project" => project, "environment" => environment,
      "use_cases" => {
        "greeting" => {
          "id" => "0198f2a1-0000-7000-8000-00000000c001", "kind" => "chat",
          "input_schema" => [{ "name" => "name", "type" => "string", "required" => true }],
          "default_params" => { "temperature" => 0.7, "max_tokens" => 512 },
          "payload_policy" => { "mode" => "full", "sample_rate" => 1.0, "max_bytes" => 262_144 }
        },
        "summarize" => {
          "id" => "0198f2a1-0000-7000-8000-00000000c002", "kind" => "text",
          "input_schema" => [], "default_params" => {}, "payload_policy" => nil
        },
        "embed" => {
          "id" => "0198f2a1-0000-7000-8000-00000000c003", "kind" => "embedding",
          "input_schema" => [], "default_params" => {}, "payload_policy" => nil
        },
        "draft" => {
          "id" => "0198f2a1-0000-7000-8000-00000000c004", "kind" => "chat",
          "input_schema" => [], "default_params" => {}, "payload_policy" => nil
        }
      },
      "deployments" => {
        "greeting" => {
          "id" => "0198f2a1-0000-7000-8000-00000000d001", "revision" => 3,
          "model_id" => "0198f2a1-0000-7000-8000-00000000e001",
          "params" => { "temperature" => temperature },
          "provider_options" => { "allow_fallbacks" => true, "sort" => nil },
          "prompt_pins" => { "default" => "0198f2a1-0000-7000-8000-00000000a001",
                             "ko" => "0198f2a1-0000-7000-8000-00000000a002" }
        },
        "summarize" => {
          "id" => "0198f2a1-0000-7000-8000-00000000d002", "revision" => 1,
          "model_id" => "0198f2a1-0000-7000-8000-00000000e001", "params" => {},
          "provider_options" => {},
          "prompt_pins" => { "default" => "0198f2a1-0000-7000-8000-00000000a003" }
        },
        "embed" => {
          "id" => "0198f2a1-0000-7000-8000-00000000d003", "revision" => 2,
          "model_id" => "0198f2a1-0000-7000-8000-00000000e002",
          "params" => { "dimensions" => 256 }, "provider_options" => {}, "prompt_pins" => {}
        }
      },
      "prompt_versions" => {
        "0198f2a1-0000-7000-8000-00000000a001" => {
          "id" => "0198f2a1-0000-7000-8000-00000000a001", "number" => 2, "engine" => "liquid",
          "messages" => [{ "role" => "system", "content" => "You are a friendly greeter." },
                         { "role" => "user", "content" => "Say hello to {{ name }}." }],
          "text_template" => nil
        },
        "0198f2a1-0000-7000-8000-00000000a002" => {
          "id" => "0198f2a1-0000-7000-8000-00000000a002", "number" => 1, "engine" => "liquid",
          "messages" => [{ "role" => "system", "content" => "너는 친절한 인사 도우미다." },
                         { "role" => "user", "content" => "{{ name }}님에게 인사해줘." }],
          "text_template" => nil
        },
        "0198f2a1-0000-7000-8000-00000000a003" => {
          "id" => "0198f2a1-0000-7000-8000-00000000a003", "number" => 4, "engine" => "liquid",
          "messages" => [], "text_template" => "Summarize:\n{% for item in items %}- {{ item }}\n{% endfor %}"
        }
      },
      "models" => {
        "0198f2a1-0000-7000-8000-00000000e001" => {
          "id" => "0198f2a1-0000-7000-8000-00000000e001", "provider" => "openrouter",
          "model_id" => "openai/gpt-4o-mini", "display_name" => "GPT-4o mini", "metadata" => {},
          "provider_options" => { "allow_fallbacks" => false, "only" => ["OpenAI"] },
          "capabilities" => %w[tools streaming], "status" => "active"
        },
        "0198f2a1-0000-7000-8000-00000000e002" => {
          "id" => "0198f2a1-0000-7000-8000-00000000e002", "provider" => "openrouter",
          "model_id" => "openai/text-embedding-3-small", "display_name" => "embedding",
          "metadata" => {}, "provider_options" => {}, "capabilities" => [], "status" => "active"
        }
      }
    }
  end

  def snapshot_json(**options)
    JSON.generate(snapshot_document(**options))
  end

  # Base options every test client shares: no disk cache, no poll thread, no exit hook, and a
  # logger that keeps its lines.
  def client_options(logger: MemoryLogger.new, **overrides)
    { api_key: "ptn_sdkfixture_test", project: "sdkfixture", disk_cache: false, poll: false,
      flush_on_exit: false, logger: logger, cache_ttl: 10.0 }.merge(overrides)
  end
end

module Minitest
  class Test
    include PromptOnTest

    # Waits for a condition instead of sleeping a fixed amount, so the thread tests stay quick
    # and do not flake on a loaded machine.
    def wait_until(timeout: 3.0, interval: 0.01)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        result = yield
        return result if result

        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise Minitest::Assertion, "condition not met within #{timeout}s"
        end

        sleep(interval)
      end
    end
  end
end
