# frozen_string_literal: true

require_relative "prompton/version"
require_relative "prompton/errors"
require_relative "prompton/logging"
require_relative "prompton/params"
require_relative "prompton/uuid_v7"
require_relative "prompton/stop_kind"
require_relative "prompton/template"
require_relative "prompton/snapshot_data"
require_relative "prompton/resolution"
require_relative "prompton/resolver"
require_relative "prompton/payload"
require_relative "prompton/config"
require_relative "prompton/http"
require_relative "prompton/snapshot_store"
require_relative "prompton/snapshot_poller"
require_relative "prompton/resolve_client"
require_relative "prompton/log_buffer"
require_relative "prompton/generation"
require_relative "prompton/client"

# PromptOn is the control plane for an app's LLM prompts.
#
# This SDK fetches a snapshot of the app's pins (per use case and environment: prompt version,
# one model, params), renders the pinned prompt with this call's variables, and batches
# monitoring logs back. Your app calls the provider itself, with its own key and its own HTTP
# client — PromptOn is never in the request path, and if it is down your app keeps running on the
# last snapshot it received.
#
#   PromptOn.configure(api_key: ENV["PTN_API_KEY"])
#
#   resolution = PromptOn.resolve("greeting", prompt: "ko")
#   messages   = resolution.render(name: "Ada")
#
#   PromptOn.with_generation(resolution, variables: { name: "Ada" }, input_messages: messages) do
#     openai.chat(model: resolution.model, messages: messages, **resolution.params)
#   end
#
# Every method here delegates to a default PromptOn::Client. Build your own with
# PromptOn::Client.new when you want several, or when you would rather not have a global.
module PromptOn
  DELEGATED = %i[
    resolve prompt_names render remote_resolve api_resolve
    snapshot snapshot_info snapshot_status refresh refresh! export_snapshot
    log with_generation generation_id flush log_stats
    logged clear_logs put_snapshot stub config
  ].freeze

  # Guards the default client so two threads racing on the first call cannot each build one,
  # each with its own background threads.
  LOCK = Mutex.new

  class << self
    # Replaces the default client with one built from these options. Returns the new client.
    def configure(**options)
      self.client = Client.new(**options)
    end

    # The default client, built from the environment on first use.
    def client
      LOCK.synchronize { @client ||= Client.new }
    end

    # Replaces the default client, closing the one it replaces.
    def client=(value)
      previous = LOCK.synchronize do
        was = @client
        @client = value
        was
      end
      previous.close if previous && !previous.equal?(value)
      value
    end

    # Closes the default client and forgets it. The next call builds a fresh one.
    def reset!
      previous = LOCK.synchronize do
        was = @client
        @client = nil
        was
      end
      previous&.close
      nil
    end

    DELEGATED.each do |name|
      define_method(name) { |*args, **options, &block| client.public_send(name, *args, **options, &block) }
    end
  end
end
