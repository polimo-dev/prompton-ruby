# frozen_string_literal: true

require_relative "template"

module PromptOn
  # What to use for this call: the model, its params and provider options, and the pinned prompt
  # template. The app calls the LLM itself with these values and records readable evidence
  # (deployment_revision, prompt, prompt_version_number, provider, model) in the monitoring log.
  class UseCaseEvidence
    attr_reader :use_case, :kind, :prompt, :prompt_names, :deployment_id,
                :deployment_revision, :prompt_version_id, :prompt_version_number, :engine,
                :model, :model_id, :provider, :params, :provider_options, :messages, :text,
                :decision, :variables, :source, :etag, :payload_policy, :api, :request_path,
                :tools, :warnings

    def initialize(**attributes)
      @use_case = attributes[:use_case]
      @kind = attributes[:kind]
      @prompt = attributes[:prompt]
      @prompt_names = attributes[:prompt_names] || []
      @deployment_id = attributes[:deployment_id]
      @deployment_revision = attributes[:deployment_revision]
      @prompt_version_id = attributes[:prompt_version_id]
      @prompt_version_number = attributes[:prompt_version_number]
      @engine = attributes[:engine] || "liquid"
      @model = attributes[:model]
      @model_id = attributes[:model_id]
      @provider = attributes[:provider]
      @params = attributes[:params] || {}
      @provider_options = attributes[:provider_options] || {}
      @messages = attributes[:messages]
      @text = attributes[:text]
      @decision = attributes[:decision]
      @variables = attributes[:variables] || []
      @source = attributes[:source] || "remote"
      @etag = attributes[:etag]
      @payload_policy = attributes[:payload_policy]
      @api = attributes[:api]
      @request_path = attributes[:request_path]
      @tools = attributes[:tools]
      @warnings = attributes[:warnings] || []
      freeze
    end

    alias text_template text

    def render(variables = {})
      case kind
      when "chat"
        raise TemplateError, "use case #{use_case} pins no chat messages" if messages.nil?

        Template.render_messages(messages, variables, engine: engine)
      when "text"
        raise TemplateError, "use case #{use_case} pins no text template" if text.nil?

        Template.render(text, variables, engine: engine)
      when "decision"
        raise TemplateError, "use case #{use_case} pins no decision payload" if decision.nil?

        render_value(decision, variables)
      else
        raise TemplateError, "use case #{use_case} is of kind #{kind} and has no prompt to render"
      end
    end

    # A copy carrying the rendered prompt in place of the template, so a caller that asked for a
    # use-case selection with variables can read #messages or #text and send them straight to the
    # provider. Embedding use cases have no prompt and come back unchanged.
    def with_rendered(rendered)
      case kind
      when "chat" then with(messages: rendered)
      when "text" then with(text: rendered)
      when "decision" then with(decision: rendered)
      else self
      end
    end

    # A copy with some attributes replaced.
    def with(**overrides)
      UseCaseEvidence.new(**to_attributes, **overrides)
    end

    # The input variables the pinned prompt reads, sorted.
    def detected_variables
      sources = case kind
                when "chat" then Array(@messages).map { |m| m["content"].to_s }
                when "decision" then decision_sources(@decision)
                else [@text.to_s]
                end
      sources.flat_map { |source| Template.variables(source) }.uniq.sort
    end

    # The keyword attributes this use-case selection was built from.
    def to_attributes
      { use_case: use_case, kind: kind, prompt: prompt, prompt_names: prompt_names,
        deployment_id: deployment_id, deployment_revision: deployment_revision,
        prompt_version_id: prompt_version_id, prompt_version_number: prompt_version_number,
        engine: engine, model: model, model_id: model_id, provider: provider, params: params,
        provider_options: provider_options, messages: @messages, text: @text, decision: @decision,
        variables: variables, source: source, etag: etag, payload_policy: payload_policy,
        api: api, request_path: request_path, tools: tools, warnings: warnings }
    end

    def to_h
      { "use_case" => use_case, "kind" => kind, "prompt" => prompt, "prompt_names" => prompt_names,
        "deployment" => { "id" => deployment_id, "revision" => deployment_revision },
        "model" => model, "model_id" => model_id, "provider" => provider,
        "params" => params, "provider_options" => provider_options, "variables" => variables,
        "prompt_version" => prompt_version_number && { "id" => prompt_version_id,
                                                       "number" => prompt_version_number }.compact,
        "messages" => @messages, "text" => @text, "decision" => @decision,
        "api" => api, "request_path" => request_path,
        "tools" => tools, "source" => source, "etag" => etag, "warnings" => warnings.map(&:to_s) }.compact
    end

    private

    def render_value(value, variables)
      case value
      when Hash
        value.transform_values { |item| render_value(item, variables) }
      when Array
        value.map { |item| render_value(item, variables) }
      when String
        Template.render(value, variables, engine: engine)
      else
        value
      end
    end

    def decision_sources(value)
      case value
      when Hash
        value.values.flat_map { |item| decision_sources(item) }
      when Array
        value.flat_map { |item| decision_sources(item) }
      when String
        [value]
      else
        []
      end
    end
  end
end
