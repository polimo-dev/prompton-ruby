# frozen_string_literal: true

require_relative "template"

module PromptOn
  # What to use for this call: the model, its params and provider options, and the pinned prompt
  # template. The app calls the LLM itself with these values and records the resolution evidence
  # (deployment_id, deployment_revision, prompt, prompt_version_id) in the monitoring log.
  class Resolution
    attr_reader :use_case, :kind, :prompt, :available_prompts, :deployment_id,
                :deployment_revision, :prompt_version_id, :prompt_version_number, :engine,
                :model, :model_id, :provider, :params, :provider_options, :messages, :text,
                :input_schema, :source, :etag, :payload_policy, :warnings

    def initialize(**attributes)
      @use_case = attributes[:use_case]
      @kind = attributes[:kind]
      @prompt = attributes[:prompt]
      @available_prompts = attributes[:available_prompts] || []
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
      @input_schema = attributes[:input_schema] || []
      @source = attributes[:source] || "remote"
      @etag = attributes[:etag]
      @payload_policy = attributes[:payload_policy]
      @warnings = attributes[:warnings] || []
      freeze
    end

    alias effective_params params
    alias effective_provider_options provider_options
    alias text_template text

    # Renders this call's variables into the pinned prompt.
    #
    # Returns the rendered message list for a chat use case and the rendered string for a text
    # use case. An embedding use case has no prompt, so this raises PromptOn::TemplateError.
    def render(variables = {})
      case kind
      when "chat"
        raise TemplateError, "use case #{use_case} pins no chat messages" if messages.nil?

        Template.render_messages(messages, variables, engine: engine)
      when "text"
        raise TemplateError, "use case #{use_case} pins no text template" if text.nil?

        Template.render(text, variables, engine: engine)
      else
        raise TemplateError, "use case #{use_case} is of kind #{kind} and has no prompt to render"
      end
    end

    # A copy carrying the rendered prompt in place of the template, so a caller that asked for a
    # resolution with variables can read #messages or #text and send them straight to the
    # provider. Embedding use cases have no prompt and come back unchanged.
    def with_rendered(rendered)
      case kind
      when "chat" then with(messages: rendered)
      when "text" then with(text: rendered)
      else self
      end
    end

    # A copy with some attributes replaced.
    def with(**overrides)
      Resolution.new(**to_attributes, **overrides)
    end

    # The input variables the pinned prompt reads, sorted.
    def detected_variables
      sources = kind == "chat" ? Array(messages).map { |m| m["content"].to_s } : [text.to_s]
      sources.flat_map { |source| Template.variables(source) }.uniq.sort
    end

    # The keyword attributes this resolution was built from.
    def to_attributes
      { use_case: use_case, kind: kind, prompt: prompt, available_prompts: available_prompts,
        deployment_id: deployment_id, deployment_revision: deployment_revision,
        prompt_version_id: prompt_version_id, prompt_version_number: prompt_version_number,
        engine: engine, model: model, model_id: model_id, provider: provider, params: params,
        provider_options: provider_options, messages: messages, text: text,
        input_schema: input_schema, source: source, etag: etag, payload_policy: payload_policy,
        warnings: warnings }
    end

    def to_h
      { "use_case" => use_case, "kind" => kind, "prompt" => prompt, "prompts" => available_prompts,
        "deployment" => { "id" => deployment_id, "revision" => deployment_revision },
        "model" => model, "model_id" => model_id, "provider" => provider,
        "effective_params" => params, "effective_provider_options" => provider_options,
        "prompt_version" => prompt_version_id && { "id" => prompt_version_id, "number" => prompt_version_number },
        "messages" => messages, "text" => text, "resolution_source" => source,
        "etag" => etag, "warnings" => warnings.map(&:to_s) }.compact
    end
  end
end
