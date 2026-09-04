# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "params"

module PromptOn
  # A use-case document is malformed.
  class InvalidUseCaseDocumentError < Error
    def code
      "invalid_use_case_document"
    end
  end

  # The use-case document declares a schema version this SDK does not read. Keep polling for a good one;
  # never fall back to a hard-coded prompt.
  class UnsupportedSchemaVersionError < InvalidUseCaseDocumentError
    attr_reader :schema_version

    def initialize(schema_version)
      @schema_version = schema_version
      super("use-case document schema version #{schema_version} is not supported " \
            "(this SDK reads version #{UseCaseDocument::SCHEMA_VERSION})")
    end

    def code
      "unsupported_schema_version"
    end
  end

  # A non-fatal observation made while decoding a use-case document or selecting from it.
  Warning = Struct.new(:kind, :value) do
    def to_s
      "#{kind}: #{value}"
    end
  end

  # The decoded `GET /use-cases` document (schema v4).
  #
  # A deployment revision is a pin, not a router: one revision is one model plus one pinned
  # prompt version per prompt name. v1 and v2 documents are refused.
  class UseCaseDocument
    SCHEMA_VERSION = 4
    KINDS = %w[chat text embedding].freeze
    ENGINES = %w[liquid raw].freeze
    PAYLOAD_MODES = %w[full hash none].freeze

    # One use case: a single LLM call site, with the deployment pinned for this environment.
    UseCase = Struct.new(:id, :key, :kind, :input_schema, :default_params, :payload_policy,
                         :deployment, keyword_init: true)
    # One pin: the model, its params and one prompt version per prompt name.
    Deployment = Struct.new(:id, :use_case_key, :revision, :model_id, :params, :provider_options,
                            :prompt_pins, keyword_init: true)
    # One immutable prompt version.
    PromptVersion = Struct.new(:id, :prompt_id, :number, :engine, :messages, :text_template,
                               keyword_init: true)
    # One catalog model.
    Model = Struct.new(:id, :provider, :model_id, :display_name, :metadata, :provider_options,
                       :capabilities, :pricing, :context_length, :status, keyword_init: true)

    attr_reader :schema_version, :project, :environment, :use_cases, :deployments,
                :prompt_versions, :models, :warnings

    class << self
      # Decodes a JSON document. Raises PromptOn::InvalidUseCaseDocumentError.
      def parse(json)
        document = JSON.parse(json)
        raise InvalidUseCaseDocumentError, "use-case document must be a JSON object" unless document.is_a?(Hash)

        from_hash(document)
      rescue JSON::ParserError => e
        raise InvalidUseCaseDocumentError, "use-case document is not valid JSON: #{e.message}"
      end

      # Decodes an already-parsed document. String and symbol keys are both accepted.
      def from_hash(document)
        raise InvalidUseCaseDocumentError, "use-case document must be an object" unless document.is_a?(Hash)

        new(Params.deep_stringify(document))
      end
    end

    def initialize(document)
      @warnings = []
      @schema_version = check_schema_version(document)
      @project = string_or_nil(document["project"])
      @environment = string_or_nil(document["environment"])
      @prompt_versions = decode_by_id(document["prompt_versions"]) { |raw| decode_prompt_version(raw) }
      @models = decode_by_id(document["models"]) { |raw| decode_model(raw) }
      @deployments = decode_deployments(document["deployments"])
      @use_cases = decode_use_cases(document["use_cases"])
      freeze
    end

    # The pin for a use case key, or nil when the use case has no live deployment here.
    def deployment(use_case_key)
      @deployments[use_case_key.to_s]
    end

    # The use case entry for a key, or nil.
    def use_case(use_case_key)
      @use_cases[use_case_key.to_s]
    end

    # The use case keys this document carries, sorted.
    def use_case_keys
      @use_cases.keys.sort
    end

    private

    def check_schema_version(document)
      version = document["schema_version"]
      raise InvalidUseCaseDocumentError, "schema_version is required" if version.nil?
      raise InvalidUseCaseDocumentError, "schema_version must be an integer" unless version.is_a?(Integer)
      return version if version == SCHEMA_VERSION

      raise UnsupportedSchemaVersionError, version
    end

    def decode_use_cases(raw)
      raise InvalidUseCaseDocumentError, "use_cases is required" unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, value), acc|
        unless value.is_a?(Hash)
          @warnings << Warning.new("invalid_use_case", key)
          next
        end

        acc[key] = UseCase.new(
          id: string_or_nil(value["id"]), key: key,
          kind: enum(value["kind"], KINDS, "chat", "unknown_kind"),
          input_schema: decode_input_schema(value["input_schema"]),
          default_params: Params.stringify_keys(value["default_params"]),
          payload_policy: decode_payload_policy(value["payload_policy"]),
          deployment: @deployments[key]
        ).freeze
      end
    end

    def decode_input_schema(raw)
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
      return {} if raw.nil?

      unless raw.is_a?(Hash)
        @warnings << Warning.new("invalid_deployments", raw.class)
        return {}
      end

      raw.each_with_object({}) do |(key, value), acc|
        unless value.is_a?(Hash)
          @warnings << Warning.new("invalid_deployment", key)
          next
        end

        acc[key] = Deployment.new(
          id: string_or_nil(value["id"]), use_case_key: string_or_nil(value["use_case_key"]) || key,
          revision: integer_or(value["revision"], nil), model_id: string_or_nil(value["model_id"]),
          params: Params.stringify_keys(value["params"]),
          provider_options: Params.stringify_keys(value["provider_options"]),
          prompt_pins: decode_prompt_pins(value["prompt_pins"], key)
        ).freeze
      end
    end

    def decode_prompt_pins(raw, key)
      return {} if raw.nil?

      unless raw.is_a?(Hash)
        @warnings << Warning.new("invalid_prompt_pins", key)
        return {}
      end

      raw.each_with_object({}) do |(name, version_id), acc|
        if version_id.is_a?(String)
          acc[name.to_s] = version_id
        else
          @warnings << Warning.new("invalid_prompt_pin", "#{key}.#{name}")
        end
      end
    end

    def decode_by_id(raw)
      return {} if raw.nil?

      entries =
        case raw
        when Hash then raw.map { |id, value| value.is_a?(Hash) ? value.merge("id" => value["id"] || id) : nil }
        when Array then raw.grep(Hash)
        else
          @warnings << Warning.new("invalid_collection", raw.class)
          []
        end

      entries.compact.each_with_object({}) do |value, acc|
        entry = yield(value)
        acc[entry.id] = entry.freeze if entry.id
      end
    end

    def decode_prompt_version(raw)
      PromptVersion.new(
        id: string_or_nil(raw["id"]), prompt_id: string_or_nil(raw["prompt_id"]),
        number: integer_or(raw["number"], nil),
        engine: enum(raw["engine"], ENGINES, "liquid", "unknown_engine"),
        messages: decode_messages(raw["messages"]), text_template: string_or_nil(raw["text_template"])
      )
    end

    def decode_messages(raw)
      return nil unless raw.is_a?(Array)

      raw.filter_map do |message|
        next unless message.is_a?(Hash)

        message.merge("role" => string_or_nil(message["role"]),
                      "content" => message["content"].is_a?(String) ? message["content"] : "").freeze
      end
    end

    def decode_model(raw)
      Model.new(
        id: string_or_nil(raw["id"]), provider: string_or_nil(raw["provider"]),
        model_id: string_or_nil(raw["model_id"]), display_name: string_or_nil(raw["display_name"]),
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

    def integer_or(value, default)
      case value
      when Integer then value
      when Float then value.to_i
      when String then value.match?(/\A-?\d+\z/) ? value.to_i : default
      else default
      end
    end
  end
end
