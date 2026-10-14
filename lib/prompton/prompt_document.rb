# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "params"

module PromptOn
  # A prompt document is malformed.
  class InvalidPromptDocumentError < Error
    def code
      "invalid_prompt_document"
    end
  end

  # The prompt document declares a schema version this SDK does not read.
  class UnsupportedSchemaVersionError < InvalidPromptDocumentError
    attr_reader :schema_version

    def initialize(schema_version)
      @schema_version = schema_version
      super("prompt document schema version #{schema_version} is not supported " \
            "(this SDK reads schema version #{PromptDocument::SCHEMA_VERSION})")
    end

    def code
      "unsupported_schema_version"
    end
  end

  # A non-fatal observation made while decoding a prompt document or selecting from it.
  Warning = Struct.new(:kind, :value) do
    def to_s
      "#{kind}: #{value}"
    end
  end

  # The decoded schema1 prompt detail or aggregate prompt document.
  #
  # A deployment revision is a pin, not a router: one revision is one model plus one pinned
  # default prompt version. Only schema1 documents are accepted.
  class PromptDocument
    SCHEMA_VERSION = 1
    KINDS = %w[chat decision text embedding].freeze
    ENGINES = %w[liquid raw].freeze
    PAYLOAD_MODES = %w[full hash none].freeze

    # One prompt: a single LLM call site, with the deployment pinned for this environment.
    Prompt = Struct.new(:id, :key, :kind, :variables, :default_params, :payload_policy,
                        :deployment, keyword_init: true)
    # One pin: the model, its params and one prompt version per template name.
    Deployment = Struct.new(:id, :prompt_key, :revision, :model_id, :provider, :model,
                            :prompt_version, :params, :provider_options, :template_pins, :api,
                            :request_path, keyword_init: true)
    # One immutable prompt version.
    PromptVersion = Struct.new(:id, :prompt_id, :prompt, :number, :engine, :messages, :text_template,
                               :kind, :decision, :tools, keyword_init: true)
    # One catalog model.
    Model = Struct.new(:id, :provider, :model_id, :display_name, :metadata, :provider_options,
                       :capabilities, :pricing, :context_length, :status, keyword_init: true)

    attr_reader :schema_version, :project, :environment, :prompts, :deployments,
                :prompt_versions, :models, :warnings

    class << self
      # Decodes a JSON document. Raises PromptOn::InvalidPromptDocumentError.
      def parse(json)
        document = JSON.parse(json)
        raise InvalidPromptDocumentError, "prompt document must be a JSON object" unless document.is_a?(Hash)

        from_hash(document)
      rescue JSON::ParserError => e
        raise InvalidPromptDocumentError, "prompt document is not valid JSON: #{e.message}"
      end

      # Decodes an already-parsed document. String and symbol keys are both accepted.
      def from_hash(document)
        raise InvalidPromptDocumentError, "prompt document must be an object" unless document.is_a?(Hash)

        new(Params.deep_stringify(document))
      end
    end

    def initialize(document)
      @warnings = []
      document = normalize_schema1_document(document)
      @schema_version = check_schema_version(document)
      @project = string_or_nil(document["project"])
      @environment = string_or_nil(document["environment"])
      @prompt_versions = decode_by_key(document["prompt_versions"]) { |key, raw| decode_prompt_version(key, raw) }
      @models = decode_by_key(document["models"]) { |key, raw| decode_model(key, raw) }
      @deployments = decode_deployments(document["deployments"])
      @prompts = decode_prompts(document["prompts"])
      validate_schema1_references!
      freeze
    end

    # The pin for a prompt key, or nil when the prompt has no live deployment here.
    def deployment(prompt_key)
      @deployments[prompt_key.to_s]
    end

    # The prompt entry for a key, or nil.
    def prompt(prompt_key)
      @prompts[prompt_key.to_s]
    end

    # The prompt keys this document carries, sorted.
    def prompt_keys
      @prompts.keys.sort
    end

    private

    def check_schema_version(document)
      version = document["schema_version"]
      raise InvalidPromptDocumentError, "schema_version is required" if version.nil?
      raise InvalidPromptDocumentError, "schema_version must be an integer" unless version.is_a?(Integer)
      return version if version == SCHEMA_VERSION

      raise UnsupportedSchemaVersionError, version
    end

    def normalize_schema1_document(document)
      return document unless document["schema_version"].is_a?(Integer) && document["schema_version"] == 1

      if document["prompts"].is_a?(Array)
        raise InvalidPromptDocumentError, "schema1 prompt index is not a loadable configuration"
      end

      has_single_detail = document.key?("prompt") || document.key?("deployment") ||
                          document.key?("prompt_version") || document.key?("model")
      return document unless has_single_detail

      if %w[prompts deployments prompt_versions models].any? { |field| document.key?(field) }
        raise InvalidPromptDocumentError, "schema1 prompt detail must not include aggregate collections"
      end

      prompt = single_object(document["prompt"], "prompt")
      deployment = single_object(document["deployment"], "deployment")
      model = single_object(document["model"], "model")
      prompt_version = document["prompt_version"]

      key = string_or_nil(prompt["key"])
      raise InvalidPromptDocumentError, "schema1 prompt.key is required" unless key

      provider = string_or_nil(model["provider"])
      model_name = string_or_nil(model["model"])
      raise InvalidPromptDocumentError, "schema1 model provider and model are required" unless provider && model_name

      unless string_or_nil(deployment["provider"]) == provider && string_or_nil(deployment["model"]) == model_name
        raise InvalidPromptDocumentError, "schema1 deployment provider/model must match model"
      end

      normalized_prompt = prompt.dup
      normalized_prompt.delete("key")
      normalized = {
        "schema_version" => 1,
        "project" => document["project"],
        "environment" => document["environment"],
        "prompts" => { key => normalized_prompt },
        "deployments" => { key => deployment },
        "prompt_versions" => {},
        "models" => { "#{provider}:#{model_name}" => model }
      }

      prompt_version = single_object(prompt_version, "prompt_version")
      unless string_or_nil(prompt_version["prompt"]) == key
        raise InvalidPromptDocumentError, "schema1 prompt_version.prompt must match prompt.key"
      end

      number = prompt_version["number"]
      unless number.is_a?(Integer) && number.positive?
        raise InvalidPromptDocumentError, "schema1 prompt_version.number must be a positive integer"
      end
      unless deployment["prompt_version"] == number
        raise InvalidPromptDocumentError, "schema1 deployment.prompt_version must match prompt_version.number"
      end

      normalized["prompt_versions"]["#{key}@#{number}"] = prompt_version

      normalized
    end

    def single_object(value, field)
      raise InvalidPromptDocumentError, "schema1 #{field} must be an object" unless value.is_a?(Hash)

      value
    end

    def decode_prompts(raw)
      raise InvalidPromptDocumentError, "prompts is required" unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, value), acc|
        unless value.is_a?(Hash)
          @warnings << Warning.new("invalid_prompt", key)
          next
        end
        reject_schema1_fields!(value, %w[id], "prompt #{key}") if schema1?
        if value.key?("input_schema")
          raise InvalidPromptDocumentError, "prompt #{key} must use variables, not input_schema"
        end

        acc[key] = Prompt.new(
          id: string_or_nil(value["id"]), key: key,
          kind: enum(value["kind"], KINDS, "chat", "unknown_kind"),
          variables: decode_variables(value["variables"]),
          default_params: Params.stringify_keys(value["default_params"]),
          payload_policy: decode_payload_policy(value["payload_policy"]),
          deployment: @deployments[key]
        ).freeze
      end
    end

    def decode_variables(raw)
      return [] unless raw.is_a?(Array)

      raw.filter_map do |variable|
        next unless variable.is_a?(Hash)

        { "name" => string_or_nil(variable["name"]), "type" => variable["type"] || "string",
          "required" => variable["required"] == true, "description" => variable["description"],
          "example" => variable["example"] }.freeze
      end
    end

    def decode_payload_policy(raw)
      return nil if raw.nil?

      unless raw.is_a?(Hash)
        @warnings << Warning.new("invalid_payload_policy", raw.class)
        return nil
      end

      { mode: enum(raw["mode"], PAYLOAD_MODES, "full", "unknown_payload_mode"),
        sample_rate: raw["sample_rate"].is_a?(Numeric) ? raw["sample_rate"].to_f : 1.0,
        max_bytes: integer_or(raw["max_bytes"], 262_144),
        retention_days: integer_or(raw["retention_days"], nil),
        encrypt: raw["encrypt"] == true }.freeze
    end

    def decode_deployments(raw)
      unless raw.is_a?(Hash)
        raise InvalidPromptDocumentError, "schema1 deployments must be an object" if schema1?

        @warnings << Warning.new("invalid_deployments", raw.class)
        return {}
      end

      raw.each_with_object({}) do |(key, value), acc|
        unless value.is_a?(Hash)
          @warnings << Warning.new("invalid_deployment", key)
          next
        end
        reject_schema1_fields!(value, %w[id model_id prompt_pins template_pins], "deployment #{key}")

        acc[key] = Deployment.new(
          id: string_or_nil(value["id"]),
          prompt_key: string_or_nil(value["prompt_key"]) || key,
          revision: revision_or_nil(value["revision"]), model_id: deployment_model_key(value),
          provider: string_or_nil(value["provider"]), model: string_or_nil(value["model"]),
          prompt_version: prompt_version_number(value),
          params: Params.stringify_keys(value["params"]),
          provider_options: Params.stringify_keys(value["provider_options"]),
          template_pins: decode_template_pins(key, value["prompt_version"]),
          api: string_or_nil(value["api"]), request_path: string_or_nil(value["request_path"])
        ).freeze
      end
    end

    def deployment_model_key(value)
      provider = string_or_nil(value["provider"])
      model = string_or_nil(value["model"])
      return "#{provider}:#{model}" if provider && model

      raise InvalidPromptDocumentError, "schema1 deployment provider and model are required"
    end

    def prompt_version_number(value)
      raw = value["prompt_version"]
      return nil if raw.nil?

      unless raw.is_a?(Integer) && raw.positive?
        raise InvalidPromptDocumentError, "deployment prompt_version must be a positive integer"
      end

      raw
    end

    def decode_template_pins(key, prompt_version = nil)
      return { DEFAULT_PROMPT => "#{key}@#{prompt_version}" } if prompt_version

      {}
    end

    DEFAULT_PROMPT = "default"
    private_constant :DEFAULT_PROMPT

    def decode_by_key(raw)
      unless raw.is_a?(Hash)
        raise InvalidPromptDocumentError, "schema1 collection must be an object" if schema1?

        @warnings << Warning.new("invalid_collection", raw.class)
        return {}
      end

      raw.map { |id, value| [id, value] if value.is_a?(Hash) }.compact.each_with_object({}) do |(key, value), acc|
        entry = yield(key.to_s, value)
        lookup_key = key || entry.id
        acc[lookup_key.to_s] = entry.freeze if lookup_key
      end
    end

    def decode_prompt_version(key, raw)
      reject_schema1_fields!(raw, %w[id prompt_id prompt_template_id], "prompt_version #{key}") if schema1?
      validate_schema1_prompt_version_key!(key, raw) if schema1?

      PromptVersion.new(
        id: string_or_nil(raw["id"]),
        prompt_id: nil,
        prompt: string_or_nil(raw["prompt"]),
        number: integer_or(raw["number"], nil),
        engine: enum(raw["engine"], ENGINES, "liquid", "unknown_engine"),
        messages: decode_messages(raw["messages"]), text_template: string_or_nil(raw["text_template"]),
        kind: string_or_nil(raw["kind"]),
        decision: raw["decision"].is_a?(Hash) ? Params.stringify_keys(raw["decision"]) : nil,
        tools: decode_tools(raw["tools"])
      )
    end

    def decode_messages(raw)
      return nil unless raw.is_a?(Array)

      raw.filter_map do |message|
        next unless message.is_a?(Hash)

        message.dup.freeze
      end
    end

    def decode_tools(raw)
      return nil if raw.nil?

      unless raw.is_a?(Hash) && raw["definitions"].is_a?(Array)
        @warnings << Warning.new("invalid_tools", raw.class)
        return nil
      end

      tools = { "definitions" => raw["definitions"].grep(Hash).map(&:dup) }
      tools["tool_choice"] = raw["tool_choice"] if raw.key?("tool_choice")
      if [true, false].include?(raw["parallel_tool_calls"])
        tools["parallel_tool_calls"] =
          raw["parallel_tool_calls"]
      end
      tools.freeze
    end

    def decode_model(key, raw)
      reject_schema1_fields!(raw, %w[id model_id], "model #{key}") if schema1?
      validate_schema1_model_key!(key, raw) if schema1?

      Model.new(
        id: string_or_nil(raw["id"]), provider: string_or_nil(raw["provider"]),
        model_id: string_or_nil(raw["model"]),
        display_name: string_or_nil(raw["display_name"]),
        metadata: Params.stringify_keys(raw["metadata"]),
        provider_options: Params.stringify_keys(raw["provider_options"]),
        capabilities: Array(raw["capabilities"]).map(&:to_s), pricing: raw["pricing"],
        context_length: integer_or(raw["context_length"], nil), status: string_or_nil(raw["status"])
      )
    end

    def enum(value, allowed, default, warning_kind)
      return default if value.nil?

      string = value.to_s
      @warnings << Warning.new(warning_kind, string) unless allowed.include?(string)
      string
    end

    def string_or_nil(value)
      case value
      when String then value
      when Numeric, Symbol then value.to_s
      end
    end

    def revision_or_nil(value)
      return nil if value.nil?
      return value if value.is_a?(String)

      raise InvalidPromptDocumentError, "deployment revision must be a string like v2026.09.30-1"
    end

    def integer_or(value, default)
      case value
      when Integer then value
      when Float then value.to_i
      when String then value.match?(/\A-?\d+\z/) ? value.to_i : default
      else default
      end
    end

    def schema1?
      @schema_version == 1
    end

    def reject_schema1_fields!(raw, fields, scope)
      fields.each do |field|
        next unless raw.key?(field)

        raise InvalidPromptDocumentError, "schema1 #{scope} must not include #{field}"
      end
    end

    def validate_schema1_prompt_version_key!(key, raw)
      prompt, number = split_prompt_version_key(key)
      raw_prompt = string_or_nil(raw["prompt"])
      raw_number = raw["number"]
      return if raw_prompt == prompt && raw_number.is_a?(Integer) && raw_number.positive? && raw_number == number

      raise InvalidPromptDocumentError,
            "schema1 prompt_versions key #{key.inspect} must match prompt and positive number fields"
    end

    def split_prompt_version_key(key)
      prompt, number = key.to_s.split("@", 2)
      unless prompt && !prompt.empty? && number&.match?(/\A[1-9]\d*\z/)
        raise InvalidPromptDocumentError, "schema1 prompt_versions key must look like prompt@number"
      end

      [prompt, number.to_i]
    end

    def validate_schema1_model_key!(key, raw)
      provider, model = key.to_s.split(":", 2)
      unless provider && model && !provider.empty? && !model.empty? &&
             string_or_nil(raw["provider"]) == provider && string_or_nil(raw["model"]) == model
        raise InvalidPromptDocumentError,
              "schema1 models key #{key.inspect} must match provider and model fields"
      end
    end

    def validate_schema1_references!
      @deployments.each do |key, deployment|
        unless @models[deployment.model_id]
          raise InvalidPromptDocumentError, "schema1 deployment #{key} references unknown model"
        end

        prompt = @prompts[key]
        next if prompt&.kind == "embedding"

        unless deployment.prompt_version&.positive?
          raise InvalidPromptDocumentError, "schema1 deployment #{key} prompt_version must be a positive integer"
        end

        if deployment.template_pins.empty?
          raise InvalidPromptDocumentError, "schema1 deployment #{key} must pin a prompt version"
        end

        version_key = "#{key}@#{deployment.prompt_version}"
        unless deployment.template_pins[DEFAULT_PROMPT] == version_key
          raise InvalidPromptDocumentError, "schema1 deployment #{key} default prompt pin must match prompt_version"
        end

        version = @prompt_versions[version_key]
        unless version
          raise InvalidPromptDocumentError,
                "schema1 deployment #{key} references unknown prompt version #{version_key}"
        end
        next if version.prompt == key

        raise InvalidPromptDocumentError,
              "schema1 deployment #{key} prompt version references prompt #{version.prompt}"
      end
    end
  end
end
