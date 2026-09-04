# frozen_string_literal: true

module PromptOn
  # Resolved PromptOn configuration for one application use case.
  class UseCase
    attr_reader :kind, :prompt, :prompt_names, :deployment_id,
                :deployment_revision, :prompt_version_id, :prompt_version_number, :engine,
                :model, :model_id, :provider, :params, :provider_options,
                :input_schema, :source, :etag, :payload_policy, :warnings

    def initialize(client, evidence)
      @client = client
      replace_evidence(evidence)
    end

    def key
      @evidence.use_case
    end

    def messages_template
      @evidence.messages
    end

    def text_template
      @evidence.text
    end

    def detected_variables
      @evidence.detected_variables
    end

    def messages(variables = {}, prompt: nil, **keyword_variables)
      variables = normalize_variables(variables, keyword_variables)
      selected = select(prompt: prompt)
      replace_evidence(selected)
      raise TemplateError, "use case #{key} is of kind #{selected.kind}, not chat" unless selected.kind == "chat"

      selected.render(variables)
    end

    def text(variables = {}, prompt: nil, **keyword_variables)
      variables = normalize_variables(variables, keyword_variables)
      selected = select(prompt: prompt)
      replace_evidence(selected)
      raise TemplateError, "use case #{key} is of kind #{selected.kind}, not text" unless selected.kind == "text"

      selected.render(variables)
    end

    def track(**meta, &)
      @client.__send__(:track_use_case, @evidence, **meta, &)
    end

    private

    attr_reader :evidence

    def normalize_variables(variables, keyword_variables)
      return variables if keyword_variables.empty?
      raise ArgumentError, "variables must be a Hash" unless variables.is_a?(Hash)

      variables.merge(keyword_variables)
    end

    def select(prompt:)
      return @evidence if prompt.nil? || prompt.to_s == @evidence.prompt.to_s

      @client.use_case(@evidence.use_case, prompt: prompt).__send__(:evidence)
    end

    def replace_evidence(evidence)
      @evidence = evidence
      @kind = evidence.kind
      @prompt = evidence.prompt
      @prompt_names = evidence.prompt_names
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
      @input_schema = evidence.input_schema
      @source = evidence.source
      @etag = evidence.etag
      @payload_policy = evidence.payload_policy
      @warnings = evidence.warnings
    end
  end
end
