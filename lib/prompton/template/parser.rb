# frozen_string_literal: true

module PromptOn
  module Template
    # Turns template source into the node tree the renderer walks. Any construct outside the
    # allowed subset is a PromptOn::TemplateSyntaxError, which is what keeps a template the
    # server would refuse from silently half-working here.
    class Parser
      def initialize(source)
        @source = source
        @tokens = tokenize(source)
        @position = 0
      end

      def parse
        nodes, word, = parse_block([], nil)
        raise TemplateSyntaxError, "Unexpected tag '#{word}'" if word

        nodes
      end

      private

      # --- lexing ------------------------------------------------------------

      def tokenize(source)
        tokens = []
        position = 0

        while (match = TOKEN_RE.match(source, position))
          inner = match[1] || match[2]
          kind = match[1] ? :output : :tag
          trim_left = inner.start_with?("-")
          trim_right = inner.end_with?("-")
          inner = inner[1..] if trim_left
          inner = inner[0..-2] if trim_right

          text = source[position...match.begin(0)]
          text = text.rstrip if trim_left
          tokens << [:text, text] unless text.empty?
          tokens << [kind, inner.strip, trim_right]
          position = match.end(0)
        end

        tail = source[position..]
        tokens << [:text, tail] if tail && !tail.empty?
        apply_right_trims(tokens)
      end

      def apply_right_trims(tokens)
        tokens.each_with_index do |token, index|
          next unless token[0] != :text && token[2]

          following = tokens[index + 1]
          following[1] = following[1].lstrip if following && following[0] == :text
        end
        tokens.reject { |token| token[0] == :text && token[1].empty? }
      end

      # --- blocks ------------------------------------------------------------

      def peek
        @tokens[@position]
      end

      def advance
        @position += 1
      end

      # Parses until one of +stop_words+ is peeked (it is left unconsumed for the caller) or the
      # tokens run out. +expected+ names the closing tag in the error message.
      def parse_block(stop_words, expected)
        nodes = []

        loop do
          token = peek
          if token.nil?
            raise TemplateSyntaxError, "Expected '#{expected}'" if expected

            return [nodes, nil, nil]
          end

          case token[0]
          when :text
            nodes << { type: :text, value: token[1] }
            advance
          when :output
            nodes << { type: :output, expr: Expression.parse(token[1]) }
            advance
          when :tag
            word, rest = split_tag(token[1])
            return [nodes, word, rest] if stop_words.include?(word)

            advance
            nodes << parse_tag(word, rest)
          end
        end
      end

      def split_tag(body)
        word, rest = body.split(/\s+/, 2)
        [word.to_s, rest]
      end

      def parse_tag(word, rest)
        case word
        when "if" then parse_if(rest)
        when "unless" then parse_unless(rest)
        when "for" then parse_for(rest)
        when "assign" then parse_assign(rest)
        when "break" then { type: :break }
        when "continue" then { type: :continue }
        else raise TemplateSyntaxError, "Unexpected tag '#{word}'"
        end
      end

      def parse_if(rest)
        branches = []
        condition = Expression.parse_condition(require_argument(rest, "if"))
        else_body = nil

        loop do
          body, word, next_rest = parse_block(%w[elsif else endif], "endif")
          branches << { condition: condition, body: strip_blank_body(body) }
          advance

          case word
          when "elsif"
            condition = Expression.parse_condition(require_argument(next_rest, "elsif"))
          when "else"
            else_body, = parse_block(%w[endif], "endif")
            else_body = strip_blank_body(else_body)
            advance
            break
          else
            break
          end
        end

        { type: :if, branches: branches, else_body: else_body }
      end

      def parse_unless(rest)
        condition = Expression.parse_condition(require_argument(rest, "unless"))
        body, word, = parse_block(%w[else endunless], "endunless")
        advance
        else_body = nil

        if word == "else"
          else_body, = parse_block(%w[endunless], "endunless")
          else_body = strip_blank_body(else_body)
          advance
        end

        { type: :unless, condition: condition, body: strip_blank_body(body), else_body: else_body }
      end

      def parse_for(rest)
        match = /\A([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+)\z/m.match(require_argument(rest, "for"))
        raise TemplateSyntaxError, "Malformed 'for' tag: #{rest.inspect}" unless match

        body, word, = parse_block(%w[else endfor], "endfor")
        advance
        else_body = nil

        if word == "else"
          else_body, = parse_block(%w[endfor], "endfor")
          else_body = strip_blank_body(else_body)
          advance
        end

        { type: :for, variable: match[1], collection: Expression.parse(match[2]),
          body: strip_blank_body(body), else_body: else_body }
      end

      def parse_assign(rest)
        target, source = require_argument(rest, "assign").split("=", 2)
        target = target.to_s.strip
        unless source && target.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          raise TemplateSyntaxError, "Malformed 'assign' tag: #{rest.inspect}"
        end

        { type: :assign, target: target, expr: Expression.parse(source) }
      end

      # A block body made only of whitespace text and assign tags produces no output at all:
      # the whitespace is dropped rather than rendered. This is what makes
      # `{% unless forloop.last %} {% endunless %}` render nothing.
      def strip_blank_body(body)
        return body unless body.all? { |node| blank_node?(node) }

        body.reject { |node| node[:type] == :text }
      end

      def blank_node?(node)
        case node[:type]
        when :text then node[:value].strip.empty?
        when :assign then true
        else false
        end
      end

      def require_argument(rest, tag)
        return rest if rest && !rest.strip.empty?

        raise TemplateSyntaxError, "Tag '#{tag}' requires an argument"
      end
    end

    # Parses the expression grammar shared by output positions, filter arguments, conditions and
    # assign sources.
    module Expression
      COMPARISON_OPS = %w[== != <> >= <= > <].freeze

      module_function

      # An output / assign expression: a primary with any number of trailing filters.
      def parse(source)
        tokens = tokenize(source)
        expression = parse_filters(tokens)
        raise TemplateSyntaxError, "Unexpected #{tokens.first[1].inspect}" unless tokens.empty?

        expression
      end

      # A condition expression: comparisons joined by +and+ / +or+, right-associative and
      # without precedence, exactly as Liquid evaluates them.
      def parse_condition(source)
        tokens = tokenize(source)
        condition = parse_boolean(tokens)
        raise TemplateSyntaxError, "Unexpected #{tokens.first[1].inspect}" unless tokens.empty?

        condition
      end

      def parse_boolean(tokens)
        left = parse_comparison(tokens)
        head = tokens.first

        if head && head[0] == :ident && %w[and or].include?(head[1])
          tokens.shift
          { type: head[1].to_sym, left: left, right: parse_boolean(tokens) }
        else
          left
        end
      end

      def parse_comparison(tokens)
        left = parse_primary(tokens)
        head = tokens.first
        return left unless head && ((head[0] == :op && COMPARISON_OPS.include?(head[1])) ||
                                    (head[0] == :ident && head[1] == "contains"))

        tokens.shift
        { type: :compare, op: head[1], left: left, right: parse_primary(tokens) }
      end

      def parse_filters(tokens)
        expression = parse_primary(tokens)

        while tokens.first && tokens.first[0] == :punct && tokens.first[1] == "|"
          tokens.shift
          name = tokens.shift
          raise TemplateSyntaxError, "Expected a filter name" unless name && name[0] == :ident

          expression = { type: :filter, name: name[1], input: expression,
                         args: parse_filter_args(tokens) }
        end

        expression
      end

      def parse_filter_args(tokens)
        head = tokens.first
        return [] unless head && head[0] == :punct && head[1] == ":"

        tokens.shift
        args = [parse_primary(tokens)]
        while tokens.first && tokens.first[0] == :punct && tokens.first[1] == ","
          tokens.shift
          args << parse_primary(tokens)
        end
        args
      end

      def parse_primary(tokens)
        token = tokens.shift
        raise TemplateSyntaxError, "Unexpected end of expression" if token.nil?

        case token[0]
        when :string, :number then { type: :lit, value: token[1] }
        when :ident then parse_identifier(token[1], tokens)
        else raise TemplateSyntaxError, "Unexpected #{token[1].inspect}"
        end
      end

      def parse_identifier(name, tokens)
        return { type: :lit, value: KEYWORD_LITERALS[name] } if KEYWORD_LITERALS.key?(name)
        return { type: :lit, value: EMPTY } if name == "empty"
        return { type: :lit, value: BLANK } if name == "blank"

        { type: :var, path: parse_path(name, tokens) }
      end

      def parse_path(name, tokens)
        path = [name]

        loop do
          head = tokens.first
          break unless head && head[0] == :punct

          case head[1]
          when "."
            tokens.shift
            segment = tokens.shift
            raise TemplateSyntaxError, "Expected a property name after '.'" unless segment && segment[0] == :ident

            path << segment[1]
          when "["
            tokens.shift
            index = tokens.shift
            raise TemplateSyntaxError, "Expected an index" unless index && %i[number string ident].include?(index[0])

            path << (index[0] == :ident ? { type: :var, path: [index[1]] } : index[1])
            closing = tokens.shift
            raise TemplateSyntaxError, "Expected ']'" unless closing && closing[1] == "]"
          else
            break
          end
        end

        path
      end

      def tokenize(source)
        scanner = StringScanner.new(source.to_s)
        tokens = []

        until scanner.eos?
          next if scanner.skip(/\s+/)

          if (matched = scanner.scan(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/))
            tokens << [:string, unquote(matched)]
          elsif (matched = scanner.scan(/-?\d+\.\d+/))
            tokens << [:number, matched.to_f]
          elsif (matched = scanner.scan(/-?\d+/))
            tokens << [:number, matched.to_i]
          elsif (matched = scanner.scan(/==|!=|<>|>=|<=|>|</))
            tokens << [:op, matched]
          elsif (matched = scanner.scan(/[A-Za-z_][A-Za-z0-9_]*/))
            tokens << [:ident, matched]
          elsif (matched = scanner.scan(/[.\[\]|:,]/))
            tokens << [:punct, matched]
          else
            raise TemplateSyntaxError, "Unexpected character #{scanner.getch.inspect}"
          end
        end

        tokens
      end

      def unquote(literal)
        literal[1..-2].gsub(/\\(.)/) { Regexp.last_match(1) }
      end
    end
  end
end
