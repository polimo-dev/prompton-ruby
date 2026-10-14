# frozen_string_literal: true

# A complete PromptOn call: select the prompt, render the prompt, call the provider, log the result.
#
#   PTN_API_KEY=ptn_yourproject_… ruby examples/greeting.rb
#
# The "provider" here is a stub so the example runs with no provider key. Replace it with your
# own client — PromptOn never sits in that call.

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "prompton"

prompton = PromptOn::Client.new(
  environment: ENV.fetch("PTN_ENVIRONMENT", "production"),
  bundle: File.expand_path("prompts.production.json", __dir__)
)

prompt = prompton.prompt("greeting", prompt: ENV.fetch("PROMPT", "default"))
variables = { name: ENV.fetch("NAME", "Ada") }
managed_messages = prompt.messages(variables)
app_history = [{ "role" => "assistant", "content" => "Ready to greet." }]
messages = managed_messages +
           app_history +
           [{ "role" => "user", "content" => "Say hello to #{variables[:name]}." }]

puts "model:    #{prompt.model} (#{prompt.provider})"
puts "pin:      revision #{prompt.deployment_revision}"
puts "prompt:   #{prompt.prompt} (version #{prompt.prompt_version_number}) " \
     "of #{prompt.template_names.join(", ")}"
puts "params:   #{prompt.params}"
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

result = prompt.track(
  variables: variables, input_messages: messages,
  end_user_ref: "user-42", trace_id: "example:1", context: { language: "en" }
) do
  call_provider(prompt.model, messages, prompt.params)
end

puts "completion: #{result[:content]}"
puts "flush:      #{prompton.flush}"
prompton.close
