# frozen_string_literal: true

module PromptOn
  # Base class for everything this SDK raises. Rescuing PromptOn::Error catches all of it.
  class Error < StandardError
    # A stable machine-readable code, the same string the PromptOn API uses.
    def code
      "error"
    end
  end

  # An option, an environment variable or a call argument is not usable.
  class ConfigurationError < Error
    def code
      "configuration"
    end
  end

  # No prompt document is available from any tier (memory, disk, bundle, remote), so nothing can be
  # resolved. This is the only prompt selection failure caused by PromptOn being unreachable.
  class NotReadyError < Error
    def initialize(message = "PromptOn is unreachable and nothing is cached " \
                             "(memory, disk and bundle are all empty)")
      super
    end

    def code
      "not_ready"
    end
  end

  # The prompt document holds no prompt with this key.
  class UnknownPromptError < Error
    attr_reader :prompt

    def initialize(prompt)
      @prompt = prompt
      super("unknown prompt: #{prompt}")
    end

    def code
      "unknown_prompt"
    end
  end

  # The prompt exists but has no live deployment in this environment.
  class UnresolvedError < Error
    attr_reader :prompt

    def initialize(prompt)
      @prompt = prompt
      super("prompt #{prompt} has no live deployment in this environment")
    end

    def code
      "unresolved"
    end
  end

  # The live deployment pins no template version under the requested name. There is never a
  # fallback to "default": shipping English to a request that asked for "ko" is worse than an
  # error.
  class UnknownTemplateError < Error
    attr_reader :prompt, :template, :template_names

    def initialize(prompt, template, template_names)
      @prompt = prompt
      @template = template
      @template_names = template_names
      super("the live deployment of #{prompt} pins no template named #{template.inspect} — " \
            "template names: #{template_names.join(", ")}")
    end

    def code
      "unknown_template"
    end
  end

  # Base class for template failures.
  class TemplateError < Error
    def code
      "template_error"
    end
  end

  # The template reads a variable that the call did not supply. `variable` is the reported name,
  # dotted for nested access ("user.name").
  class MissingVariableError < TemplateError
    attr_reader :variable

    def initialize(variable)
      @variable = variable
      super("missing variable: #{variable}")
    end

    def code
      "missing_variable"
    end
  end

  # The template uses a construct outside the allowed subset, or is malformed.
  class TemplateSyntaxError < TemplateError
    def code
      "parse_error"
    end
  end

  # The template parsed but rendering failed for another reason.
  class TemplateRenderError < TemplateError
    def code
      "render_error"
    end
  end

  # The PromptOn API answered with a non-success status.
  class ApiError < Error
    attr_reader :status, :body, :details, :error_code, :retry_after

    def initialize(status, body, retry_after: nil)
      @status = status
      @body = body
      @retry_after = retry_after
      error = body.is_a?(Hash) ? body["error"] : nil
      @error_code = error.is_a?(Hash) ? error["code"] : nil
      @details = (error.is_a?(Hash) ? error["details"] : nil) || {}
      message = error.is_a?(Hash) ? error["message"] : nil
      super("PromptOn API returned #{status}#{": #{message}" if message}")
    end

    def code
      @error_code || "http_#{status}"
    end
  end

  # The transport failed: DNS, connection refused, TLS, a timeout.
  class TransportError < Error
    def code
      "transport"
    end
  end

  # A monitoring-log record is missing a field the server requires.
  class InvalidRecordError < Error
    attr_reader :field

    def initialize(field)
      @field = field
      super("monitoring log record is missing the required field #{field.inspect}")
    end

    def code
      "invalid_record"
    end
  end
end
