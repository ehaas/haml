require 'pathname'

module Sass::Tree
  # A static node reprenting a CSS rule.
  #
  # @see Sass::Tree
  class RuleNode < Node
    # The character used to include the parent selector
    # @private
    PARENT = '&'

    # The CSS selector for this rule,
    # interspersed with {Sass::Script::Node}s
    # representing `#{}`-interpolation.
    # Any adjacent strings will be merged together.
    #
    # @return [Array<String, Sass::Script::Node>]
    attr_accessor :rule

    # The CSS selector for this rule,
    # without any unresolved interpolation
    # but with parent references still intact.
    # It's only set once {Tree::Node#perform} has been called.
    #
    # @return [Selector::CommaSequence]
    attr_accessor :parsed_rules

    # The CSS selector for this rule,
    # without any unresolved interpolation or parent references.
    # It's only set once {Tree::Node#cssize} has been called.
    #
    # @return [Selector::CommaSequence]
    attr_accessor :resolved_rules

    # How deep this rule is indented
    # relative to a base-level rule.
    # This is only greater than 0 in the case that:
    #
    # * This node is in a CSS tree
    # * The style is :nested
    # * This is a child rule of another rule
    # * The parent rule has properties, and thus will be rendered
    #
    # @return [Fixnum]
    attr_accessor :tabs

    # Whether or not this rule is the last rule in a nested group.
    # This is only set in a CSS tree.
    #
    # @return [Boolean]
    attr_accessor :group_end

    # @param rule [Array<String, Sass::Script::Node>]
    #   The CSS rule. See \{#rule}
    def initialize(rule)
      @rule = Haml::Util.strip_string_array(
        Haml::Util.merge_adjacent_strings(rule))
      @tabs = 0
      super()
    end

    # Compares the contents of two rules.
    #
    # @param other [Object] The object to compare with
    # @return [Boolean] Whether or not this node and the other object
    #   are the same
    def ==(other)
      self.class == other.class && rule == other.rule && super
    end

    # Adds another {RuleNode}'s rules to this one's.
    #
    # @param node [RuleNode] The other node
    def add_rules(node)
      @rule = Haml::Util.strip_string_array(
        Haml::Util.merge_adjacent_strings(@rule + ["\n"] + node.rule))
    end

    # @return [Boolean] Whether or not this rule is continued on the next line
    def continued?
      last = @rule.last
      last.is_a?(String) && last[-1] == ?,
    end

    # @see Node#to_sass
    def to_sass(tabs, opts = {})
      name = rule.map do |r|
        if r.is_a?(String)
          r.gsub(/(,[ \t]*)?\n\s*/) {$1 ? $1 + "\n" : " "}
        else
          "\#{#{r.to_sass}}"
        end
      end.join
      name = "\\" + name if name[0] == ?:
      name.gsub(/^/, '  ' * tabs) + children_to_src(tabs, opts, :sass)
    end

    def to_scss(tabs, opts = {})
      name = rule.map {|r| r.is_a?(String) ? r : "\#{#{r.to_sass}}"}.
        join.gsub(/^[ \t]*/, '  ' * tabs)

      res = name + children_to_src(tabs, opts, :scss)

      if children.last.is_a?(CommentNode) && children.last.silent
        res.slice!(-3..-1)
        res << "\n" << ('  ' * tabs) << "}\n"
      end

      res
    end

    protected

    # Computes the CSS for the rule.
    #
    # @param tabs [Fixnum] The level of indentation for the CSS
    # @return [String] The resulting CSS
    def _to_s(tabs)
      tabs = tabs + self.tabs

      rule_separator = style == :compressed ? ',' : ', '
      line_separator =
        case style
          when :nested, :expanded; "\n"
          when :compressed; ""
          else; " "
        end
      rule_indent = '  ' * (tabs - 1)
      per_rule_indent, total_indent = [:nested, :expanded].include?(style) ? [rule_indent, ''] : ['', rule_indent]

      total_rule = total_indent + resolved_rules.members.
        map {|seq| seq.to_a.join}.
        join(rule_separator).split("\n").map do |line|
        per_rule_indent + line.strip
      end.join(line_separator)

      to_return = ''
      old_spaces = '  ' * (tabs - 1)
      spaces = '  ' * tabs
      if @options[:line_comments] && style != :compressed
        to_return << "#{old_spaces}/* line #{line}"

        if filename
          relative_filename = if @options[:css_filename]
            begin
              Pathname.new(filename).relative_path_from(
                Pathname.new(File.dirname(@options[:css_filename]))).to_s
            rescue ArgumentError
              nil
            end
          end
          relative_filename ||= filename
          to_return << ", #{relative_filename}"
        end

        to_return << " */\n"
      end

      if style == :compact
        properties = children.map { |a| a.to_s(1) }.join(' ')
        to_return << "#{total_rule} { #{properties} }#{"\n" if group_end}"
      elsif style == :compressed
        properties = children.map { |a| a.to_s(1) }.join(';')
        to_return << "#{total_rule}{#{properties}}"
      else
        properties = children.map { |a| a.to_s(tabs + 1) }.join("\n")
        end_props = (style == :expanded ? "\n" + old_spaces : ' ')
        to_return << "#{total_rule} {\n#{properties}#{end_props}}#{"\n" if group_end}"
      end

      to_return
    end

    # Runs any SassScript that may be embedded in the rule,
    # and parses the selectors for commas.
    #
    # @param environment [Sass::Environment] The lexical environment containing
    #   variable and mixin values
    def perform!(environment)
      @parsed_rules = Sass::SCSS::StaticParser.new(run_interp(@rule, environment)).parse_selector
      super
    end

    # Converts nested rules into a flat list of rules.
    #
    # @param parent [RuleNode, nil] The parent node of this node,
    #   or nil if the parent isn't a {RuleNode}
    def _cssize(extends, parent)
      node = super
      rules = node.children.select {|c| c.is_a?(RuleNode)}
      props = node.children.reject {|c| c.is_a?(RuleNode) || c.invisible?}

      unless props.empty?
        node.children = props
        rules.each {|r| r.tabs += 1} if style == :nested
        rules.unshift(node)
      end

      rules.last.group_end = true unless parent || rules.empty?

      rules
    end

    # Resolves parent references and nested selectors,
    # and updates the indentation based on the parent's indentation.
    #
    # @param parent [RuleNode, nil] The parent node of this node,
    #   or nil if the parent isn't a {RuleNode}
    # @raise [Sass::SyntaxError] if the rule has no parents but uses `&`
    def cssize!(extends, parent)
      self.resolved_rules = @parsed_rules.resolve_parent_refs(parent && parent.resolved_rules)
      super
    end

    # Returns an error message if the given child node is invalid,
    # and false otherwise.
    #
    # {ExtendNode}s are valid within {RuleNode}s.
    #
    # @param child [Tree::Node] A potential child nodecompact.
    # @return [Boolean, String] Whether or not the child node is valid,
    #   as well as the error message to display if it is invalid
    def invalid_child?(child)
      super unless child.is_a?(ExtendNode)
    end
  end
end
