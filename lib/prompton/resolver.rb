# frozen_string_literal: true

require_relative "errors"
require_relative "params"
require_relative "resolution"

module PromptOn
  # Local resolution: snapshot + use case key (+ prompt name) -> Resolution.
  #
  # Two lookups, no rules: a deployment revision is a pin. The only selection axis at request
  # time is the prompt name; the environment decided which snapshot was fetched.
  module Resolver
    # The prompt name used when the call gives none.
    DEFAULT_PROMPT = "default"

    module_function

    # Resolves +use_case_key+ against +snapshot+.
    #
    # Raises PromptOn::UnknownUseCaseError, PromptOn::UnresolvedError or
    # PromptOn::UnknownPromptError. A prompt name the deployment does not pin is an error, never
    # a silent fall back to "default".
    def resolve(snapshot, use_case_key, prompt: nil, source: "remote", etag: nil)
      key = use_case_key.to_s
      use_case = snapshot.use_case(key) or raise UnknownUseCaseError, key
      deployment = use_case.deployment or raise UnresolvedError, key
      prompts = prompt_names(snapshot, key)
      name, version_id = pick_prompt(use_case, deployment, prompt, prompts)

      warnings = []
      version = lookup(snapshot.prompt_versions, version_id, "missing_prompt_version", warnings)
      model = lookup(snapshot.models, deployment.model_id, "missing_model", warnings)

      Resolution.new(
        use_case: key, kind: use_case.kind, prompt: name, available_prompts: prompts,
        deployment_id: deployment.id, deployment_revision: deployment.revision,
        prompt_version_id: version&.id, prompt_version_number: version&.number,
        engine: version&.engine, model: model&.model_id, model_id: model&.id,
        provider: model&.provider,
        params: Params.merge(use_case.default_params, deployment.params),
        provider_options: Params.merge(model&.provider_options, deployment.provider_options),
        messages: use_case.kind == "chat" ? version&.messages : nil,
        text: use_case.kind == "text" ? version&.text_template : nil,
        input_schema: use_case.input_schema, source: source.to_s, etag: etag,
        payload_policy: use_case.payload_policy, warnings: warnings
      )
    end

    # The prompt names the live deployment pins, sorted. [] when there is no deployment.
    def prompt_names(snapshot, use_case_key)
      key = use_case_key.to_s
      use_case = snapshot.use_case(key) or raise UnknownUseCaseError, key
      pins = use_case.deployment&.prompt_pins
      pins ? pins.keys.sort : []
    end

    def pick_prompt(use_case, deployment, requested, available)
      # An embedding use case has no prompt at all; a prompt name passed with the request is
      # ignored rather than rejected.
      return [nil, nil] if use_case.kind == "embedding"

      name = requested.nil? || requested.to_s.empty? ? DEFAULT_PROMPT : requested.to_s
      version_id = deployment.prompt_pins[name]
      raise UnknownPromptError.new(use_case.key, name, available) if version_id.nil?

      [name, version_id]
    end

    def lookup(collection, id, warning_kind, warnings)
      return nil if id.nil?

      entry = collection[id]
      warnings << Warning.new(warning_kind, id) if entry.nil?
      entry
    end
  end
end
