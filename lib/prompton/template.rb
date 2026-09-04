# frozen_string_literal: true

require "strscan"
require_relative "errors"

module PromptOn
  # Prompt rendering: the Liquid subset PromptOn allows.
  #
  # Tags: +for+ (with +else+, +break+, +continue+ and +forloop.*+), +if+/+elsif+/+else+,
  # +unless+, +assign+. Filters: +size+, +join+, +default+. Everything else — +include+,
  # +capture+, +case+, +raw+, +comment+, +cycle+, +render+, +tablerow+, +increment+, +liquid+ —
  # is a parse error. There is no HTML escaping.
  #
  # A variable is *missing* when its key is absent from the variables hash. A key present with a
  # nil value is not missing: it renders as the empty string and the +default+ filter replaces
  # it. Missing is an error at output positions (<tt>{{ }}</tt>), in a +for+ enumerable, in an
  # +unless+ condition and as an +assign+ source. It is not checked in a branch that does not
  # execute, nor inside an +if+/+elsif+ condition.
  #
  #   PromptOn::Template.render("Hello {{ name }}", { "name" => "Ada" })  # => "Hello Ada"
  #
  # <tt>engine: "raw"</tt> returns the source verbatim without parsing it. It exists for prompts
  # whose text genuinely contains <tt>{{</tt> or <tt>{%</tt>.
  module Template
    # The tag names this subset allows, sorted.
    ALLOWED_TAGS = %w[assign break continue for if unless].freeze
    # The filter names this subset allows.
    ALLOWED_FILTERS = %w[size join default].freeze
    # Variables the renderer injects itself; never input variables.
    BUILTIN_VARIABLES = %w[forloop].freeze

    # Every tag word the parser understands, including block terminators.
    TAG_WORDS = %w[
      assign break continue for endfor if elsif else endif unless endunless
    ].freeze

    KEYWORD_LITERALS = {
      "true" => true, "false" => false, "nil" => nil, "null" => nil
    }.freeze

    # Marker objects for Liquid's `empty` and `blank` keywords.
    EMPTY = Object.new.freeze
    BLANK = Object.new.freeze

    TOKEN_RE = /\{\{(.*?)\}\}|\{%(.*?)%\}/m
    WHITESPACE_MARKERS = /\{\{-|\{%-|-\}\}|-%\}/
    TAG_WORD_RE = /\{%-?\s*([A-Za-z_][A-Za-z0-9_]*)/

    module_function

    # The list of allowed tag names.
    def allowed_tags
      ALLOWED_TAGS
    end

    # The list of allowed filter names.
    def allowed_filters
      ALLOWED_FILTERS
    end

    # Renders +source+ with +variables+.
    #
    # Raises PromptOn::MissingVariableError when a variable the template reads is absent,
    # PromptOn::TemplateSyntaxError when the template is outside the allowed subset or
    # malformed, PromptOn::TemplateRenderError for any other rendering failure.
    def render(source, variables, engine: "liquid")
      source = source.to_s
      return source if engine.to_s == "raw"

      Renderer.new(parse(source), normalize_variables(variables)).render
    end

    # Renders the +content+ of each message in a list of <tt>{"role" =>, "content" =>}</tt>
    # hashes. Other keys are preserved as they are.
    def render_messages(messages, variables, engine: "liquid")
      vars = normalize_variables(variables)
      Array(messages).map do |message|
        symbol_key = message.key?(:content) && !message.key?("content")
        rendered = render((message["content"] || message[:content]).to_s, vars, engine: engine)
        message.merge(symbol_key ? { content: rendered } : { "content" => rendered })
      end
    end

    # The names of the top-level input variables the template reads, sorted and deduplicated.
    # Loop variables, assign targets and +forloop+ are excluded.
    def variables(source)
      ast = parse(source.to_s)
      referenced = []
      bound = []
      walk(ast, referenced, bound)
      (referenced - bound - BUILTIN_VARIABLES).uniq.sort
    rescue TemplateError
      scrape_variables(source.to_s)
    end

    # Static whitelist check. Returns [] when the template conforms, otherwise a list of
    # <tt>{kind:, value:}</tt> hashes: +whitespace_control+, +disallowed_tag+,
    # +disallowed_filter+ or +parse+.
    def lint(source)
      source = source.to_s
      reasons = whitespace_reasons(source) + disallowed_tag_reasons(source)

      if reasons.none? { |r| r[:kind] == "disallowed_tag" }
        begin
          filters_used(parse(source)).uniq.reject { |f| ALLOWED_FILTERS.include?(f) }
                                     .each { |f| reasons << { kind: "disallowed_filter", value: f } }
        rescue TemplateError => e
          reasons << { kind: "parse", value: e.message }
        end
      end

      reasons.uniq
    end

    # Parses +source+ into an abstract syntax tree. Raises PromptOn::TemplateSyntaxError.
    def parse(source)
      Parser.new(source.to_s).parse
    end

    # Recursively normalises variable keys to strings so that symbol keys work as written.
    # A nil value stays nil: a key present with a nil value is not a missing variable.
    def normalize_variables(variables)
      normalized = normalize_value(variables)
      normalized.is_a?(Hash) ? normalized : {}
    end

    def normalize_value(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), acc| acc[k.to_s] = normalize_value(v) }
      when Array then value.map { |item| normalize_value(item) }
      else value
      end
    end

    # --- lint internals ------------------------------------------------------

    def whitespace_reasons(source)
      source.scan(WHITESPACE_MARKERS).uniq.map { |marker| { kind: "whitespace_control", value: marker } }
    end

    def disallowed_tag_reasons(source)
      source.scan(TAG_WORD_RE).flatten.uniq.reject { |word| TAG_WORDS.include?(word) }
            .map { |word| { kind: "disallowed_tag", value: word } }
    end

    def filters_used(node, acc = [])
      case node
      when Array then node.each { |child| filters_used(child, acc) }
      when Hash
        acc << node[:name] if node[:type] == :filter
        node.each_value { |child| filters_used(child, acc) }
      end
      acc
    end

    # --- detected variables --------------------------------------------------

    def walk(node, referenced, bound)
      case node
      when Array then node.each { |child| walk(child, referenced, bound) }
      when Hash
        referenced << node[:path].first if node[:type] == :var && node[:path].first.is_a?(String)
        bound << node[:variable] if node[:type] == :for
        bound << node[:target] if node[:type] == :assign
        node.each_value { |child| walk(child, referenced, bound) }
      end
    end

    def scrape_variables(source)
      outputs = source.scan(/\{\{-?\s*([A-Za-z_][A-Za-z0-9_]*)/).flatten
      tags = source.scan(
        /\{%-?\s*(?:if|unless|elsif)\s+([A-Za-z_][A-Za-z0-9_]*)|\{%-?\s*for\s+\w+\s+in\s+([A-Za-z_][A-Za-z0-9_]*)/
      ).flatten.compact
      (outputs + tags - BUILTIN_VARIABLES - %w[true false nil empty blank]).uniq.sort
    end
  end
end

require_relative "template/parser"
require_relative "template/renderer"
