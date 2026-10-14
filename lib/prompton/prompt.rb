# frozen_string_literal: true

module PromptOn
  # Resolved PromptOn configuration for one application prompt.
  class Prompt
    attr_reader :kind, :template, :template_names, :deployment_id,
                :deployment_revision, :prompt_version_id, :prompt_version_number, :engine,
                :model, :model_id, :provider, :params, :provider_options,
                :variables, :source, :etag, :payload_policy, :warnings

    def initialize(client, evidence)
      @client = client
      replace_evidence(evidence)
    end

    def key
      @evidence.prompt
    end

    def messages_template
      @evidence.messages
    end

    def text_template
      @evidence.text
    end

    def decision_template
      @evidence.decision
    end

    def detected_variables
      @evidence.detected_variables
    end

    def messages(variables = {}, template: nil, **keyword_variables)
      variables = normalize_variables(variables, keyword_variables)
      selected = select(template: template)
      replace_evidence(selected)
      raise TemplateError, "prompt #{key} is of kind #{selected.kind}, not chat" unless selected.kind == "chat"

      selected.render(variables)
    end

    def text(variables = {}, template: nil, **keyword_variables)
      variables = normalize_variables(variables, keyword_variables)
      selected = select(template: template)
      replace_evidence(selected)
      raise TemplateError, "prompt #{key} is of kind #{selected.kind}, not text" unless selected.kind == "text"

      selected.render(variables)
    end

    def decision(variables = {}, template: nil, **keyword_variables)
      variables = normalize_variables(variables, keyword_variables)
      selected = select(template: template)
      replace_evidence(selected)
      raise TemplateError, "prompt #{key} is of kind #{selected.kind}, not decision" unless selected.kind == "decision"

      selected.render(variables)
    end

    def track(**meta, &)
      @client.__send__(:track_prompt, @evidence, **meta, &)
    end

    private

    attr_reader :evidence

    def normalize_variables(variables, keyword_variables)
      return variables if keyword_variables.empty?
      raise ArgumentError, "variables must be a Hash" unless variables.is_a?(Hash)

      variables.merge(keyword_variables)
    end

    def select(template:)
      return @evidence if template.nil? || template.to_s == @evidence.template.to_s

      @client.prompt(@evidence.prompt, template: template).__send__(:evidence)
    end

    def replace_evidence(evidence)
      @evidence = evidence
      @kind = evidence.kind
      @template = evidence.template
      @template_names = evidence.template_names
      @deployment_id = evidence.deployment_id
      @deployment_revision = evidence.deployment_revision
      @prompt_version_id = evidence.prompt_version_id
      @prompt_version_number = evidence.prompt_version_number
      @engine = evidence.engine
      @model = evidence.model
      @model_id = evidence.model_id
      @provider = evidence.provider
      @params = evidence.params
      @provider_options = evidence.provider_options
      @decision_template = evidence.decision
      @variables = evidence.variables
      @source = evidence.source
      @etag = evidence.etag
      @payload_policy = evidence.payload_policy
      @warnings = evidence.warnings
    end
  end
end
