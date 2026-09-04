# frozen_string_literal: true

module PromptOn
  module Template
    # Walks the node tree and produces the rendered string.
    #
    # Strictness follows the contract: a variable that is absent from the variables hash is an
    # error at output positions, in a +for+ enumerable, in an +unless+ condition and as an
    # +assign+ source, and is silently nil inside an +if+/+elsif+ condition. Branches that do not
    # execute are never looked up at all.
    class Renderer
      def initialize(nodes, variables)
        @nodes = nodes
        @variables = variables
        @assigns = {}
        @frames = []
      end

      def render
        buffer = +""
        render_nodes(@nodes, buffer)
        buffer
      end

      private

      def render_nodes(nodes, buffer)
        nodes.each { |node| render_node(node, buffer) }
      end

      def render_node(node, buffer)
        case node[:type]
        when :text then buffer << node[:value]
        when :output then buffer << stringify(evaluate(node[:expr], strict: true))
        when :if then render_if(node, buffer)
        when :unless then render_unless(node, buffer)
        when :for then render_for(node, buffer)
        when :assign then @assigns[node[:target]] = evaluate(node[:expr], strict: true)
        when :break then throw(:prompton_break)
        when :continue then throw(:prompton_continue)
        end
      end

      def render_if(node, buffer)
        node[:branches].each do |branch|
          next unless truthy?(evaluate(branch[:condition], strict: false))

          return render_nodes(branch[:body], buffer)
        end

        render_nodes(node[:else_body], buffer) if node[:else_body]
      end

      def render_unless(node, buffer)
        if truthy?(evaluate(node[:condition], strict: true))
          render_nodes(node[:else_body], buffer) if node[:else_body]
        else
          render_nodes(node[:body], buffer)
        end
      end

      def render_for(node, buffer)
        collection = evaluate(node[:collection], strict: true)
        items = enumerate(collection)

        if items.empty?
          render_nodes(node[:else_body], buffer) if node[:else_body]
          return
        end

        length = items.length
        catch(:prompton_break) do
          items.each_with_index do |item, index|
            frame = {
              node[:variable] => item,
              "forloop" => {
                "index" => index + 1, "index0" => index,
                "rindex" => length - index, "rindex0" => length - index - 1,
                "first" => index.zero?, "last" => index == length - 1, "length" => length
              }
            }
            @frames.push(frame)
            begin
              catch(:prompton_continue) { render_nodes(node[:body], buffer) }
            ensure
              @frames.pop
            end
          end
        end
      end

      def enumerate(collection)
        case collection
        when Array then collection
        when Hash then collection.map { |key, value| [key, value] }
        when nil then []
        else [collection]
        end
      end

      # --- expressions ---------------------------------------------------------

      def evaluate(node, strict:)
        case node[:type]
        when :lit then node[:value]
        when :var then lookup(node[:path], strict: strict)
        when :filter then apply_filter(node, strict: strict)
        when :and then truthy?(evaluate(node[:left], strict: strict)) && truthy?(evaluate(node[:right], strict: strict))
        when :or then truthy?(evaluate(node[:left], strict: strict)) || truthy?(evaluate(node[:right], strict: strict))
        when :compare then compare(node, strict: strict)
        else raise TemplateRenderError, "cannot evaluate #{node[:type]}"
        end
      end

      def compare(node, strict:)
        left = evaluate(node[:left], strict: strict)
        right = evaluate(node[:right], strict: strict)

        case node[:op]
        when "==" then values_equal?(left, right)
        when "!=", "<>" then !values_equal?(left, right)
        when "contains" then contains?(left, right)
        else ordered(node[:op], left, right)
        end
      end

      def values_equal?(left, right)
        return blank?(left) if right.equal?(EMPTY) || right.equal?(BLANK)
        return blank?(right) if left.equal?(EMPTY) || left.equal?(BLANK)

        left == right
      end

      def ordered(operator, left, right)
        return false unless left.is_a?(Comparable) && right.is_a?(Comparable)

        result = (left <=> right)
        return false if result.nil?

        case operator
        when ">" then result.positive?
        when "<" then result.negative?
        when ">=" then !result.negative?
        when "<=" then !result.positive?
        else false
        end
      rescue ArgumentError, TypeError
        false
      end

      def contains?(left, right)
        case left
        when String then left.include?(stringify(right))
        when Array then left.include?(right)
        else false
        end
      end

      def apply_filter(node, strict:)
        value = evaluate(node[:input], strict: strict)
        args = node[:args].map { |arg| evaluate(arg, strict: false) }

        case node[:name]
        when "size" then filter_size(value)
        when "join" then Array(value).map { |item| stringify(item) }.join(args.fetch(0, " ").to_s)
        when "default" then blank?(value) ? args[0] : value
        else raise TemplateSyntaxError, "Unknown filter '#{node[:name]}'"
        end
      end

      def filter_size(value)
        case value
        when String then value.length
        when Array, Hash then value.size
        else 0
        end
      end

      # --- variable lookup -----------------------------------------------------

      def lookup(path, strict:)
        root = path.first
        found, value = lookup_root(root)
        return missing(path, strict) unless found

        path.drop(1).each do |segment|
          segment = evaluate(segment, strict: false) if segment.is_a?(Hash)
          found, value = step(value, segment)
          return missing(path, strict) unless found
        end

        value
      end

      def lookup_root(name)
        @frames.reverse_each { |frame| return [true, frame[name]] if frame.key?(name) }
        return [true, @assigns[name]] if @assigns.key?(name)
        return [true, @variables[name]] if @variables.key?(name)

        [false, nil]
      end

      def step(value, segment)
        case value
        when Hash
          key = segment.to_s
          value.key?(key) ? [true, value[key]] : [false, nil]
        when Array
          return [true, value[segment]] if segment.is_a?(Integer)

          array_property(value, segment.to_s)
        when String
          string_property(value, segment.to_s)
        else
          [false, nil]
        end
      end

      def array_property(value, name)
        case name
        when "size" then [true, value.size]
        when "first" then [true, value.first]
        when "last" then [true, value.last]
        else [false, nil]
        end
      end

      def string_property(value, name)
        name == "size" ? [true, value.length] : [false, nil]
      end

      def missing(path, strict)
        raise MissingVariableError, path_name(path) if strict

        nil
      end

      def path_name(path)
        path.each_with_index.map do |segment, index|
          case segment
          when Integer then "[#{segment}]"
          when Hash then "[#{segment[:path]&.first}]"
          else index.zero? ? segment.to_s : ".#{segment}"
          end
        end.join
      end

      # --- value rendering -----------------------------------------------------

      def truthy?(value)
        !(value.nil? || value == false)
      end

      def blank?(value)
        return true if value.nil? || value == false
        return value.empty? if value.respond_to?(:empty?)

        false
      end

      def stringify(value)
        case value
        when nil then ""
        when String then value
        when true, false, Integer, Float then value.to_s
        when Array then value.map { |item| stringify(item) }.join
        else value.inspect
        end
      end
    end
  end
end
