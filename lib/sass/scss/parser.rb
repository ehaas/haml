require 'strscan'
require 'set'

module Sass
  module SCSS
    # The parser for SCSS.
    # It parses a string of code into a tree of {Sass::Tree::Node}s.
    #
    # @todo Add a CSS-only parser that doesn't parse the SassScript extensions,
    #   so css2sass will work properly.
    class Parser
      # @param str [String] The source document to parse
      def initialize(str)
        @template = str
        @line = 1
        @strs = []
      end

      # Parses an SCSS document.
      #
      # @return [Sass::Tree::RootNode] The root node of the document tree
      # @raise [Sass::SyntaxError] if there's a syntax error in the document
      def parse
        init_scanner!
        root = stylesheet
        expected("selector or at-rule") unless @scanner.eos?
        root
      end

      private

      include Sass::SCSS::RX

      def init_scanner!
        @scanner = StringScanner.new(
          Haml::Util.check_encoding(@template) do |msg, line|
            raise Sass::SyntaxError.new(msg, :line => line)
          end.gsub("\r", ""))
      end

      def stylesheet
        node = node(Sass::Tree::RootNode.new(@scanner.string))
        block_contents(node, :stylesheet) {s(node)}
      end

      def s(node)
        while tok(S) || tok(CDC) || tok(CDO) || (c = tok(SINGLE_LINE_COMMENT)) || (c = tok(COMMENT))
          next unless c
          process_comment c, node
          c = nil
        end
        true
      end

      def ss
        nil while tok(S) || tok(SINGLE_LINE_COMMENT) || tok(COMMENT)
        true
      end

      def ss_comments(node)
        while tok(S) || (c = tok(SINGLE_LINE_COMMENT)) || (c = tok(COMMENT))
          next unless c
          process_comment c, node
          c = nil
        end

        true
      end

      def whitespace
        return unless tok(S) || tok(SINGLE_LINE_COMMENT) || tok(COMMENT)
        ss
      end

      def process_comment(text, node)
        single_line = text =~ /^\/\//
        pre_str = single_line ? "" : @scanner.
          string[0...@scanner.pos].
          reverse[/.*?\*\/(.*?)($|\Z)/, 1].
          reverse.gsub(/[^\s]/, ' ')
        text = text.sub(/^\s*\/\//, '/*').gsub(/^\s*\/\//, ' *') + ' */' if single_line
        comment = Sass::Tree::CommentNode.new(pre_str + text, single_line)
        comment.line = @line - text.count("\n")
        node << comment
      end

      DIRECTIVES = Set[:mixin, :include, :debug, :for, :while, :if, :import, :media]

      def directive
        return unless tok(/@/)
        name = tok!(IDENT)
        ss

        if dir = special_directive(name)
          return dir
        end

        val = str do
          # Most at-rules take expressions (e.g. @import),
          # but some (e.g. @page) take selector-like arguments
          expr || selector
        end
        node = node(Sass::Tree::DirectiveNode.new("@#{name} #{val}".strip))

        if tok(/\{/)
          node.has_children = true
          block_contents(node, :directive)
          tok!(/\}/)
        end

        node
      end

      def special_directive(name)
        sym = name.gsub('-', '_').to_sym
        DIRECTIVES.include?(sym) && send(sym)
      end

      def mixin
        name = tok! IDENT
        args = sass_script(:parse_mixin_definition_arglist)
        ss
        block(node(Sass::Tree::MixinDefNode.new(name, args)), :directive)
      end

      def include
        name = tok! IDENT
        args = sass_script(:parse_mixin_include_arglist)
        ss
        node(Sass::Tree::MixinNode.new(name, args))
      end

      def debug
        node(Sass::Tree::DebugNode.new(sass_script(:parse)))
      end

      def for
        tok!(/!/)
        var = tok! IDENT
        ss

        tok!(/from/)
        from = sass_script(:parse_until, Set["to", "through"])
        ss

        @expected = '"to" or "through"'
        exclusive = (tok(/to/) || tok!(/through/)) == 'to'
        to = sass_script(:parse)
        ss

        block(node(Sass::Tree::ForNode.new(var, from, to, exclusive)), :directive)
      end

      def while
        expr = sass_script(:parse)
        ss
        block(node(Sass::Tree::WhileNode.new(expr)), :directive)
      end

      def if
        expr = sass_script(:parse)
        ss
        node = block(node(Sass::Tree::IfNode.new(expr)), :directive)
        ss
        else_block(node)
      end

      def else_block(node)
        return node unless tok(/@else/)
        ss
        else_node = block(
          Sass::Tree::IfNode.new((sass_script(:parse) if tok(/if/))),
          :directive)
        node.add_else(else_node)
        ss
        else_block(node)
      end

      def import
        @expected = "string or url()"
        arg = tok(STRING) || tok!(URI)
        path = @scanner[1] || @scanner[2] || @scanner[3]
        ss

        media = str {media_type}.strip

        if !media.strip.empty? || use_css_import?
          return node(Sass::Tree::DirectiveNode.new("@import #{arg} #{media}".strip))
        end

        node(Sass::Tree::ImportNode.new(path.strip))
      end

      def use_css_import?; false; end

      def media
        val = str {media_type}.strip
        block(node(Sass::Tree::DirectiveNode.new("@media #{val}")), :directive)
      end

      def media_type
        return unless media_term

        ss
        while tok(/,|and/)
          ss; expr!(:media_term); ss
        end

        true
      end

      def media_term
        return unless tok(IDENT) || (p = tok(/\(/))
        ss

        if p
          media_type
          ss
          tok!(/\)/)
        elsif tok(/:/)
          ss
          tok! NUMBER
        end

        return true
      end

      def variable
        return unless tok(/!/)
        name = tok!(IDENT)
        ss

        if tok(/\|/)
          tok!(/\|/)
          guarded = true
        end

        tok!(/=/)
        ss
        expr = sass_script(:parse)

        node(Sass::Tree::VariableNode.new(name, expr, guarded))
      end

      def operator
        # Many of these operators (all except / and ,)
        # are disallowed by the CSS spec,
        # but they're included here for compatibility
        # with some proprietary MS properties
        str {ss if tok(/[\/,:.=]/)}
      end

      def unary_operator
        tok(/[+-]/)
      end

      def property
        return unless e = (tok(IDENT) || interpolation)
        res = [e, str{ss}]

        while e = (interpolation || tok(IDENT))
          res << e
        end

        ss
        res
      end

      def ruleset
        rules = []
        return unless v = selector
        rules.concat v

        while tok(/,/)
          rules << ',' << str {ss}
          rules.concat expr!(:selector)
        end

        block(node(Sass::Tree::RuleNode.new(rules.flatten.compact)), :ruleset)
      end

      def block(node, context)
        node.has_children = true
        tok!(/\{/)
        block_contents(node, context)
        tok!(/\}/)
        node
      end

      # A block may contain declarations and/or rulesets
      def block_contents(node, context)
        block_given? ? yield : ss_comments(node)
        node << (child = block_child(context))
        while tok(/;/) || (child && child.has_children)
          block_given? ? yield : ss_comments(node)
          node << (child = block_child(context))
        end
        node
      end

      def block_child(context)
        variable || directive || declaration_or_ruleset
      end

      # This is a nasty hack, and the only place in the parser
      # that requires backtracking.
      # The reason is that we can't figure out if certain strings
      # are declarations or rulesets with fixed finite lookahead.
      # For example, "foo:bar baz baz baz..." could be either a property
      # or a selector.
      #
      # To handle this, we simply check if it works as a property
      # (which is the most common case)
      # and, if it doesn't, try it as a ruleset.
      #
      # We could eke some more efficiency out of this
      # by handling some easy cases (first token isn't an identifier,
      # no colon after the identifier, whitespace after the colon),
      # but I'm not sure the gains would be worth the added complexity.
      def declaration_or_ruleset
        pos = @scanner.pos
        line = @line
        old_use_property_exception, @use_property_exception =
          @use_property_exception, false
        begin
          decl = declaration
          # We want an exception if it's not there,
          # but we don't want to consume if it is
          tok!(/[;}]/) unless tok?(/[;}]/)
          return decl
        rescue Sass::SyntaxError => decl_err
        end

        @line = line
        @scanner.pos = pos

        begin
          return ruleset
        rescue Sass::SyntaxError => ruleset_err
          raise @use_property_exception ? decl_err : ruleset_err
        end
      ensure
        @use_property_exception = old_use_property_exception
      end

      def selector
        return unless sel = _selector
        sel.to_a
      end

      def _selector
        # The combinator here allows the "> E" hack
        return unless val = combinator || simple_selector_sequence
        nl = str{ss}.include?("\n")
        res = []
        res << val
        res << "\n" if nl

        while val = combinator || simple_selector_sequence
          res << val
          res << "\n" if str{ss}.include?("\n")
        end
        Selector::Sequence.new(res.compact)
      end

      def combinator
        tok(PLUS) || tok(GREATER) || tok(TILDE)
      end

      def simple_selector_sequence
        # This allows for stuff like http://www.w3.org/TR/css3-animations/#keyframes-
        return expr unless e = element_name || id_expr || class_expr ||
          attrib || negation || pseudo || parent_selector || interpolation_selector
        res = [e]

        # The tok(/\*/) allows the "E*" hack
        while v = element_name || id_expr || class_expr ||
            attrib || negation || pseudo || tok(/\*/) || interpolation_selector
          res << v
        end
        Selector::SimpleSequence.new(res)
      end

      def parent_selector
        return unless tok(/&/)
        Selector::Parent.new
      end

      def class_expr
        return unless tok(/\./)
        Selector::Class.new(tok!(IDENT))
      end

      def id_expr
        return unless hash = tok(HASH)
        Selector::Id.new(hash[1..-1])
      end

      def element_name
        return unless name = tok(IDENT) || tok(/\*/) || (tok?(/\|/) && "")
        if tok(/\|/)
          @expected = "element name or *"
          ns = name
          name = tok(IDENT) || tok!(/\*/)
        end

        name == '*' ? Selector::Universal.new(ns) : Selector::Element.new(name, ns)
      end

      def interpolation_selector
        return unless script = interpolation
        Selector::Interpolation.new(script)
      end

      def attrib
        return unless tok(/\[/)
        ss
        ns, name = attrib_name!
        ss

        if op = tok(/=/) ||
            tok(INCLUDES) ||
            tok(DASHMATCH) ||
            tok(PREFIXMATCH) ||
            tok(SUFFIXMATCH) ||
            tok(SUBSTRINGMATCH)
          @expected = "identifier or string"
          ss
          if val = tok(IDENT)
            val = [val]
          else
            val = expr!(:interp_string)
          end
          ss
        end
        tok(/\]/)

        Selector::Attribute.new(name, ns, op, val)
      end

      def attrib_name!
        if name_or_ns = tok(IDENT)
          # E, E|E
          if tok(/\|(?!=)/)
            ns = name_or_ns
            name = tok(IDENT)
          else
            name = name_or_ns
          end
        else
          # *|E or |E
          ns = tok(/\*/) || ""
          tok!(/\|/)
          name = tok! IDENT
        end
        return ns, name
      end

      def pseudo
        return unless s = tok(/::?/)

        @expected = "pseudoclass or pseudoelement"
        name, arg = functional_pseudo
        name ||= tok!(IDENT)
        Selector::Pseudo.new(s == ':' ? :class : :element, name, arg)
      end

      def functional_pseudo
        return unless fn = tok(FUNCTION)
        val = [str{ss}] + expr!(:pseudo_expr)
        tok!(/\)/)
        return fn[0...-1], val
      end

      def pseudo_expr
        return unless e = tok(PLUS) || tok(/-/) || tok(NUMBER) ||
          interp_string || tok(IDENT) || interpolation
        res = [e, str{ss}]
        while e = tok(PLUS) || tok(/-/) || tok(NUMBER) ||
            interp_string || tok(IDENT) || interpolation
          res << e << str{ss}
        end
        res
      end

      def negation
        return unless tok(NOT)
        ss
        @expected = "selector"
        sel = element_name || id_expr || class_expr || attrib || expr!(:pseudo)
        tok!(/\)/)
        Selector::Negation.new(sel)
      end

      def declaration
        # This allows the "*prop: val", ":prop: val", and ".prop: val" hacks
        if s = tok(/[:\*\.]/)
          @use_property_exception = s != '.'
          name = [s, str{ss}] + expr!(:property)
        else
          return unless name = property
        end

        @expected = expected_property_separator
        expression, space, value = (script_value || expr!(:plain_value))
        ss
        require_block = !expression || tok?(/\{/)

        node = node(Sass::Tree::PropNode.new(name.flatten.compact, value.flatten.compact, :new))

        return node unless require_block
        nested_properties! node, expression, space
      end

      def expected_property_separator
        '":" or "="'
      end

      def script_value
        return unless tok(/=/)
        @use_property_exception = true
        # expression, space, value
        return true, true, [sass_script(:parse)]
      end

      def plain_value
        return unless tok(/:/)
        space = !str {ss}.empty?
        @use_property_exception ||= space || !tok?(IDENT)

        expression = expr
        expression << tok(IMPORTANT) if expression
        # expression, space, value
        return expression, space, expression || [""]
      end

      def nested_properties!(node, expression, space)
        if expression && !space
          @use_property_exception = true
          raise Sass::SyntaxError.new(<<MESSAGE, :line => @line)
Invalid CSS: a space is required between a property and its definition
when it has other properties nested beneath it.
MESSAGE
        end

        @use_property_exception = true
        @expected = 'expression (e.g. 1px, bold) or "{"'
        block(node, :property)
      end

      def expr
        return unless t = term
        res = [t, str{ss}]

        while (o = operator) && (t = term)
          res << o << t << str{ss}
        end

        res
      end

      def term
        unless e = tok(NUMBER) ||
            tok(URI) ||
            function ||
            interp_string ||
            tok(UNICODERANGE) ||
            tok(IDENT) ||
            tok(HEXCOLOR) ||
            interpolation

          return unless op = unary_operator
          @expected = "number or function"
          return [op, tok(NUMBER) || expr!(:function)]
        end
        e
      end

      def function
        return unless name = tok(FUNCTION)
        if name == "expression(" || name == "calc("
          str, _ = Haml::Shared.balance(@scanner, ?(, ?), 1)
          [name, str]
        else
          [name, str{ss}, expr, tok!(/\)/)]
        end
      end

      def interpolation
        return unless tok(/#\{/)
        sass_script(:parse_interpolated)
      end

      def interp_string
        _interp_string(:double) || _interp_string(:single)
      end

      def _interp_string(type)
        return unless start = tok(Sass::Script::Lexer::STRING_REGULAR_EXPRESSIONS[[type, false]])
        res = [start]

        mid_re = Sass::Script::Lexer::STRING_REGULAR_EXPRESSIONS[[type, true]]
        # @scanner[2].empty? means we've started an interpolated section
        res << expr!(:interpolation) << tok(mid_re) while @scanner[2].empty?
        res
      end

      def str
        @strs.push ""
        yield
        @strs.last
      ensure
        @strs.pop
      end

      def str?
        @strs.push ""
        yield && @strs.last
      ensure
        @strs.pop
      end

      def node(node)
        node.line = @line
        node
      end

      def sass_script(*args)
        parser = ScriptParser.new(@scanner, @line,
          @scanner.pos - (@scanner.string.rindex("\n") || 0))
        result = parser.send(*args)
        @line = parser.line
        result
      end

      EXPR_NAMES = {
        :media_term => "medium (e.g. print, screen)",
        :pseudo_expr => "expression (e.g. fr, 2n+1)",
        :expr => "expression (e.g. 1px, bold)",
        :_selector => "selector",
        :simple_selector_sequence => "selector",
      }

      TOK_NAMES = Haml::Util.to_hash(
        Sass::SCSS::RX.constants.map {|c| [Sass::SCSS::RX.const_get(c), c.downcase]}).
        merge(IDENT => "identifier", /[;}]/ => '";"')

      def tok?(rx)
        @scanner.match?(rx)
      end

      def expr!(name)
        (e = send(name)) && (return e)
        expected(EXPR_NAMES[name] || name.to_s)
      end

      def tok!(rx)
        (t = tok(rx)) && (return t)
        name = TOK_NAMES[rx]

        unless name
          # Display basic regexps as plain old strings
          string = rx.source.gsub(/\\(.)/, '\1')
          name = rx.source == Regexp.escape(string) ? string.inspect : rx.inspect
        end

        expected(name)
      end

      def expected(name)
        pos = @scanner.pos

        after = @scanner.string[0...pos]
        # Get rid of whitespace between pos and the last token,
        # but only if there's a newline in there
        after.gsub!(/\s*\n\s*$/, '')
        # Also get rid of stuff before the last newline
        after.gsub!(/.*\n/, '')
        after = "..." + after[-15..-1] if after.size > 18

        expected = @expected || name

        was = @scanner.rest.dup
        # Get rid of whitespace between pos and the next token,
        # but only if there's a newline in there
        was.gsub!(/^\s*\n\s*/, '')
        # Also get rid of stuff after the next newline
        was.gsub!(/\n.*/, '')
        was = was[0...15] + "..." if was.size > 18

        raise Sass::SyntaxError.new(
          "Invalid CSS after \"#{after}\": expected #{expected}, was \"#{was}\"",
          :line => @line)
      end

      def tok(rx)
        res = @scanner.scan(rx)
        if res
          @line += res.count("\n")
          @expected = nil
          if !@strs.empty? && rx != COMMENT && rx != SINGLE_LINE_COMMENT
            @strs.each {|s| s << res}
          end
        end

        res
      end
    end
  end
end
