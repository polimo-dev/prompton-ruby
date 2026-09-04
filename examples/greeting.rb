# frozen_string_literal: true

# A complete PromptOn call: resolve the pin, render the prompt, call the provider, log the result.
#
#   PTN_API_KEY=ptn_yourproject_… ruby examples/greeting.rb
#
# The "provider" here is a stub so the example runs with no provider key. Replace it with your
# own client — PromptOn never sits in that call.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "prompton"

prompton = PromptOn::Client.new(
  environment: ENV.fetch("PTN_ENVIRONMENT", "production"),
  bundle: File.expand_path("snapshot.production.json", __dir__)
)

resolution = prompton.resolve("greeting", prompt: ENV.fetch("PROMPT", "default"))
variables = { name: ENV.fetch("NAME", "Ada") }
messages = resolution.render(variables)

puts "model:    #{resolution.model} (#{resolution.provider})"
puts "pin:      deployment #{resolution.deployment_id} revision #{resolution.deployment_revision}"
puts "prompt:   #{resolution.prompt} (version #{resolution.prompt_version_number}) " \
     "of #{resolution.available_prompts.join(", ")}"
puts "params:   #{resolution.params}"
puts "messages: #{messages.inspect}"
puts

# Stands in for openai/anthropic/openrouter. Your key and your HTTP client stay here.
def call_provider(model, messages, params)
  sleep(0.05)
  { content: "Hello, #{messages.last["content"][/to (.+)\./, 1] || "friend"}! (#{model}, #{params})",
    finish_reason: "stop",
    usage: { input_tokens: 38, output_tokens: 9 },
    cost_usd: 0.000112, cost_source: "provider" }
end

outcome = prompton.with_generation(
  resolution,
  variables: variables, input_messages: messages,
  end_user_ref: "user-42", trace_id: "example:1", context: { language: "en" }
) do
  call_provider(resolution.model, messages, resolution.params)
end

puts "completion: #{outcome[:content]}"
puts "flush:      #{prompton.flush}"
prompton.close
