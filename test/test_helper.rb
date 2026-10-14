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

  class FakeClock
    def initialize(start = 1000.0)
      @value = start
      @mutex = Mutex.new
    end

    def call
      @mutex.synchronize { @value }
    end

    def advance(seconds)
      @mutex.synchronize { @value += seconds }
    end
  end

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

  # A snapshot document with the three kinds of prompt, ready to serve or write to disk.
  def snapshot_document(environment: "production", project: "sdkfixture", temperature: 0.2)
    {
      "schema_version" => 1, "project" => project, "environment" => environment,
      "prompts" => {
        "greeting" => {
          "kind" => "chat",
          "variables" => [{ "name" => "name", "type" => "string", "required" => true }],
          "default_params" => { "temperature" => 0.7, "max_tokens" => 512 },
          "payload_policy" => { "mode" => "full", "sample_rate" => 1.0, "max_bytes" => 262_144 }
        },
        "summarize" => {
          "kind" => "text", "variables" => [], "default_params" => {}, "payload_policy" => nil
        },
        "embed" => {
          "kind" => "embedding", "variables" => [], "default_params" => {}, "payload_policy" => nil
        },
        "draft" => {
          "kind" => "chat", "variables" => [], "default_params" => {}, "payload_policy" => nil
        }
      },
      "deployments" => {
        "greeting" => {
          "revision" => "v2026.09.30-3", "provider" => "openrouter", "model" => "openai/gpt-4o-mini",
          "prompt_version" => 2, "params" => { "temperature" => temperature },
          "provider_options" => { "allow_fallbacks" => true, "sort" => nil }
        },
        "summarize" => {
          "revision" => "v2026.09.30-1", "provider" => "openrouter", "model" => "openai/gpt-4o-mini",
          "prompt_version" => 4, "params" => {}, "provider_options" => {}
        },
        "embed" => {
          "revision" => "v2026.09.30-2", "provider" => "openrouter",
          "model" => "openai/text-embedding-3-small", "params" => { "dimensions" => 256 },
          "provider_options" => {}
        }
      },
      "prompt_versions" => {
        "greeting@2" => {
          "prompt" => "greeting", "number" => 2, "kind" => "chat", "engine" => "liquid",
          "messages" => [{ "role" => "system", "content" => "You are a friendly greeter." },
                         { "role" => "user", "content" => "Say hello to {{ name }}." }],
          "text_template" => nil
        },
        "greeting@1" => {
          "prompt" => "greeting", "number" => 1, "kind" => "chat", "engine" => "liquid",
          "messages" => [{ "role" => "system", "content" => "너는 친절한 인사 도우미다." },
                         { "role" => "user", "content" => "{{ name }}님에게 인사해줘." }],
          "text_template" => nil
        },
        "summarize@4" => {
          "prompt" => "summarize", "number" => 4, "kind" => "text", "engine" => "liquid",
          "messages" => [], "text_template" => "Summarize:\n{% for item in items %}- {{ item }}\n{% endfor %}"
        }
      },
      "models" => {
        "openrouter:openai/gpt-4o-mini" => {
          "provider" => "openrouter", "model" => "openai/gpt-4o-mini", "display_name" => "GPT-4o mini",
          "metadata" => {}, "provider_options" => { "allow_fallbacks" => false, "only" => ["OpenAI"] },
          "capabilities" => %w[tools streaming], "status" => "active"
        },
        "openrouter:openai/text-embedding-3-small" => {
          "provider" => "openrouter", "model" => "openai/text-embedding-3-small", "display_name" => "embedding",
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
