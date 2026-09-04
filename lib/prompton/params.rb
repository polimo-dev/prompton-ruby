# frozen_string_literal: true

module PromptOn
  # Shallow merge helper for parameter maps.
  #
  #   effective_params           = use_case.default_params <- deployment.params
  #   effective_provider_options = model.provider_options   <- deployment.provider_options
  #
  # The merge is shallow: a nested hash on the right replaces the left side whole. Keys are
  # normalised to strings so that `{temperature: 0.7}` and `{"temperature" => 0.5}` are the same
  # key. An override value of nil is kept as nil, never deleted — apps rely on sending
  # `"only" => nil` to clear a provider restriction.
  module Params
    module_function

    # Shallow-merges `override` on top of `base`; `override` wins.
    def merge(base, override)
      stringify_keys(base).merge(stringify_keys(override))
    end

    # Normalises a hash's top-level keys to strings. Anything that is not a hash becomes {}.
    def stringify_keys(map)
      return {} unless map.is_a?(Hash)

      map.each_with_object({}) { |(key, value), acc| acc[key.to_s] = value }
    end

    # Recursively normalises hash keys to strings, walking arrays too. Values are untouched.
    def deep_stringify(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = deep_stringify(v) }
      when Array then value.map { |v| deep_stringify(v) }
      else value
      end
    end
  end
end
