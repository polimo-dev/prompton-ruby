# frozen_string_literal: true

require_relative "template"

module PromptOn
  # What to use for this call: the model, its params and provider options, and the pinned prompt
  # template. The app calls the LLM itself with these values and records the prompt evidence
  # (deployment_revision, template, prompt_version_number, provider, model) in the monitoring log.
  class PromptEvidence
    attr_reader :prompt, :kind, :template, :template_names, :deployment_id,
                :deployment_revision, :prompt_version_id, :prompt_version_number, :engine,
                :model, :model_id, :provider, :params, :provider_options, :messages, :text,
                :decision, :variables, :source, :etag, :payload_policy, :api, :request_path,
                :tools, :warnings

    def initialize(**attributes)
      @prompt = attributes[:prompt]
      @kind = attributes[:kind]
      @template = attributes[:template]
      @template_names = attributes[:template_names] || []
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
        raise TemplateError, "prompt #{prompt} pins no chat messages" if messages.nil?

        Template.render_messages(messages, variables, engine: engine)
      when "text"
        raise TemplateError, "prompt #{prompt} pins no text template" if text.nil?

        Template.render(text, variables, engine: engine)
      when "decision"
        raise TemplateError, "prompt #{prompt} pins no decision payload" if decision.nil?

        render_value(decision, variables)
      else
        raise TemplateError, "prompt #{prompt} is of kind #{kind} and has no template to render"
      end
    end

    # A copy carrying the rendered template in place of the template, so a caller that asked for a
    # prompt selection with variables can read #messages or #text and send them straight to the
    # provider. Embedding prompts have no template and come back unchanged.
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
      PromptEvidence.new(**to_attributes, **overrides)
    end

    # The input variables the pinned template reads, sorted.
    def detected_variables
      sources = case kind
                when "chat" then Array(@messages).map { |m| m["content"].to_s }
                when "decision" then decision_sources(@decision)
                else [@text.to_s]
                end
      sources.flat_map { |source| Template.variables(source) }.uniq.sort
    end

    # The keyword attributes this prompt selection was built from.
    def to_attributes
      { prompt: prompt, kind: kind, template: template, template_names: template_names,
        deployment_id: deployment_id, deployment_revision: deployment_revision,
        prompt_version_id: prompt_version_id, prompt_version_number: prompt_version_number,
        engine: engine, model: model, model_id: model_id, provider: provider, params: params,
        provider_options: provider_options, messages: @messages, text: @text, decision: @decision,
        variables: variables, source: source, etag: etag, payload_policy: payload_policy,
        api: api, request_path: request_path, tools: tools, warnings: warnings }
    end

    def to_h
      { "prompt_key" => prompt, "kind" => kind, "template" => template, "template_names" => template_names,
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
