# frozen_string_literal: true

require_relative "errors"
require_relative "params"
require_relative "prompt_evidence"

module PromptOn
  # Local prompt selection: prompt document + prompt key (+ template name) -> prompt evidence.
  #
  # Two lookups, no rules: a deployment revision is a pin. The only selection axis at request
  # time is the template name; the environment decided which snapshot was fetched.
  module Resolver
    # The template name used when the call gives none.
    DEFAULT_TEMPLATE = "default"

    module_function

    # Resolves +prompt_key+ against +snapshot+.
    #
    # Raises PromptOn::UnknownPromptError, PromptOn::UnresolvedError or
    # PromptOn::UnknownTemplateError. A template name the deployment does not pin is an error, never
    # a silent fall back to "default".
    def resolve(snapshot, prompt_key, template: nil, source: "remote", etag: nil)
      key = prompt_key.to_s
      prompt = snapshot.prompt(key) or raise UnknownPromptError, key
      deployment = prompt.deployment or raise UnresolvedError, key
      templates = template_names(snapshot, key)
      name, version_id = pick_template(prompt, deployment, template, templates)

      warnings = []
      version = lookup(snapshot.prompt_versions, version_id, "missing_prompt_version", warnings)
      model = lookup(snapshot.models, deployment.model_id, "missing_model", warnings)

      runtime_kind = version&.kind || prompt.kind

      PromptEvidence.new(
        prompt: key, kind: runtime_kind, template: name, template_names: templates,
        deployment_id: deployment.id, deployment_revision: deployment.revision,
        prompt_version_id: version&.id, prompt_version_number: version&.number,
        engine: version&.engine, model: model&.model_id, model_id: model&.id,
        provider: model&.provider,
        params: Params.merge(prompt.default_params, deployment.params),
        provider_options: Params.merge(model&.provider_options, deployment.provider_options),
        messages: runtime_kind == "chat" ? version&.messages : nil,
        text: runtime_kind == "text" ? version&.text_template : nil,
        decision: runtime_kind == "decision" ? version&.decision : nil,
        variables: prompt.variables, source: source.to_s, etag: etag,
        payload_policy: prompt.payload_policy, api: deployment.api, request_path: deployment.request_path,
        tools: runtime_kind == "chat" ? version&.tools : nil, warnings: warnings
      )
    end

    # The template names the live deployment pins, sorted. [] when there is no deployment.
    def template_names(snapshot, prompt_key)
      key = prompt_key.to_s
      prompt = snapshot.prompt(key) or raise UnknownPromptError, key
      pins = prompt.deployment&.template_pins
      pins ? pins.keys.sort : []
    end

    def pick_template(prompt, deployment, requested, available)
      # An embedding prompt has no template at all; a template name passed with the request is
      # ignored rather than rejected.
      return [nil, nil] if prompt.kind == "embedding"

      name = requested.nil? || requested.to_s.empty? ? DEFAULT_TEMPLATE : requested.to_s
      version_id = deployment.template_pins[name]
      raise UnknownTemplateError.new(prompt.key, name, available) if version_id.nil?

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
