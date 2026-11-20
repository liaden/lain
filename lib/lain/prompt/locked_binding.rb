# frozen_string_literal: true

require "erb"
require "prism"

module Lain
  module Prompt
    # The pure render engine for prompt partials. A partial is a markdown doc that
    # MAY interpolate a whitelisted local via ERB (the `render` helper), nothing
    # else -- the model is a Rails view partial, not a scripting language.
    #
    # == Why a static purity check rather than a "clean room" binding
    #
    # `Context#render` is pure: identical inputs must yield identical bytes, because
    # that purity is the SAME constraint prompt caching imposes (a `Time.now` in the
    # system prompt busts the cached prefix every turn, silently, forever). A slot
    # fill is above the cache line, so an impure reference there must fail LOUDLY,
    # never resolve to a silently nondeterministic value.
    #
    # Ruby's own evaluation machinery cannot be trusted to refuse impurity: constant
    # lookup inside a template is lexical, so a BasicObject clean-room `self` does
    # not intercept `::Time`, and it never intercepts `rand`, a `` `subshell` ``, or
    # reflection through a receiver (`0.send(:rand)`) at all. So we refuse it
    # ourselves: every partial's compiled Ruby is parsed (Prism) and checked by
    # {Purity} BEFORE it is evaluated. Impure code therefore never runs; the
    # failure is a named {ImpureSlot}, raised at render.
    class LockedBinding
      # The inert token the one ERB pass emits for a value, spliced afterward. A
      # template can build one at evaluation time, so each must appear exactly
      # once and in order, or a template could copy, move or invent a value.
      SENTINEL = "\u0000"
      PLACEHOLDER = /#{SENTINEL}lain-fragment:(?<index>\d+)#{SENTINEL}/
      private_constant :SENTINEL, :PLACEHOLDER

      # @param resolve [#call] slot name to template source
      # @param locals [Hash{Symbol=>String,#call}] names a template may read bare;
      #   any other bare name is still a refused call. A callable value is
      #   resolved only for a template whose source mentions its name, so a
      #   costly or failing lookup never runs for a template that ignores it.
      # @param values [Hash{String=>String,#call}] slot names whose String is
      #   DATA, never a template: rendered through an inert placeholder and
      #   spliced in after the one ERB pass, so a transcript quoting a Rails
      #   view is never compiled. A callable is resolved only when rendered.
      def initialize(resolve:, locals: {}, values: {})
        @resolve = resolve
        @locals = locals
        @values = values
        @rendering = []
        @fragments = []
      end

      # Render a top-level template (the shipped base prompt) purely. Its `render`
      # calls recurse into the slot resolver below, and the values they name are
      # spliced in last, in one pass that never rescans a spliced value.
      #
      # @param source [String] the template
      # @param label [String] names the template in a refusal
      # @return [String]
      def render_template(source, label)
        outer = @fragments
        @fragments = []
        splice(evaluate(source, label), label)
      ensure
        @fragments = outer
      end

      # The ERB helper. A value renders as its placeholder; any other name
      # resolves to its active partial (project override or shipped default) and
      # renders THAT partial in turn. A slot that renders itself is a loud
      # {CircularSlot} rather than a stack overflow.
      #
      # @param name [#to_s]
      # @return [String]
      def render(name)
        name = name.to_s
        @values.key?(name) ? placeholder(name) : partial(name)
      end

      private

      def partial(name)
        raise CircularSlot, "slot #{name.inspect} renders itself (chain: #{@rendering.join(" -> ")})" \
          if @rendering.include?(name)

        @rendering.push(name)
        evaluate(@resolve.call(name), name)
      ensure
        @rendering.pop
      end

      def placeholder(name)
        value = @values.fetch(name)
        @fragments.push(string!(value.respond_to?(:call) ? value.call : value, name))
        "#{SENTINEL}lain-fragment:#{@fragments.size - 1}#{SENTINEL}"
      end

      def string!(source, label)
        return source if source.is_a?(String)

        raise NonStringSlot, "slot #{label.inspect} resolved to #{source.class}, not String " \
                             "(#{source.inspect}); callers stringify slot values deliberately"
      end

      def splice(rendered, label)
        return rendered if @fragments.empty? && !rendered.match?(PLACEHOLDER)

        unless rendered.scan(PLACEHOLDER).flatten.map(&:to_i) == (0...@fragments.size).to_a
          raise ImpureSlot, "slot #{label.inspect} is impure: its value placeholders are not each value once, in order"
        end

        rendered.gsub(PLACEHOLDER) { @fragments.fetch(Regexp.last_match[:index].to_i) }
      end

      def evaluate(source, label)
        string!(source, label)
        template = ERB.new(source, trim_mode: "-")
        Purity.check!(template.src, label, locals: @locals.keys)
        template.result(clean_binding(template.src))
      end

      # A binding with zero locals of its own, so a fill's `template = template`
      # (pure to Prism's grammar -- LocalVariableWrite/Read are both allowed
      # nodes) can never read {#evaluate}'s ERB instance back out. Split into
      # its own zero-argument frame rather than reusing {#evaluate}'s: a
      # binding closes over the LOCALS of the method that captured it, not
      # just its receiver, so nothing short of a separate call escapes them.
      # `self` (and therefore the `render` helper) still resolves, because
      # self travels with the binding regardless of which frame captured it.
      def clean_binding(source)
        read = @locals.select { |name, _| source.match?(/\b#{name}\b/) }
        read.each_with_object(binding) do |(name, value), clean|
          clean.local_variable_set(name, (value.respond_to?(:call) ? value.call : value).freeze)
        end
      end
    end

    # Rejects a partial's compiled Ruby BEFORE evaluation unless every AST node
    # fits the tiny grammar a markdown partial needs. An ALLOWLIST with
    # default-reject, not a blocklist: `self`, globals ($$/$0), ivars, receiver'd
    # calls, and the send/eval family all fall out rejected without being
    # individually named -- a novel escape hatch is impure until proven pure,
    # never pure until noticed. (The review probes are the evidence a
    # blocklist loses that race: `0.send(:rand)` and `"".object_id` both walked
    # straight past one.)
    module Purity
      # The only receiverless names a partial may call: the exposed helpers.
      HELPERS = %i[render].freeze

      # The node types the partial grammar needs, verified by compiling
      # representative templates and enumerating what ERB actually emits:
      # literals, interpolation, and the locals ERB's own plumbing writes.
      # Calls are NOT here -- they get shape-checked in {call_offense}.
      GRAMMAR = [
        Prism::ProgramNode, Prism::StatementsNode, Prism::ParenthesesNode,
        Prism::ArgumentsNode, Prism::StringNode, Prism::InterpolatedStringNode,
        Prism::EmbeddedStatementsNode, Prism::IntegerNode, Prism::FloatNode,
        Prism::SymbolNode, Prism::TrueNode, Prism::FalseNode, Prism::NilNode,
        Prism::LocalVariableWriteNode, Prism::LocalVariableReadNode,
        Prism::LocalVariableTargetNode
      ].freeze

      # `locals` are parsed as in scope, so a bare read of one is a local read
      # rather than the receiverless call the grammar refuses.
      def self.check!(ruby_source, label, locals: [])
        offense = offense_in(Prism.parse(ruby_source, scopes: [locals]).value)
        return unless offense

        raise ImpureSlot, "slot #{label.inspect} is impure: #{offense}; " \
                          "prompt partials are pure markdown plus the render helper, not a scripting language"
      end

      def self.offense_in(root)
        descend(root).lazy.filter_map { |node| offense_for(node) }.first
      end

      def self.offense_for(node)
        case node
        when Prism::CallNode then call_offense(node)
        when *GRAMMAR then nil
        else "#{node.class.name.split("::").last.delete_suffix("Node")} #{node.slice.strip[0, 60].inspect}"
        end
      end

      # A call is pure only in two shapes: the exposed helper, or the exact
      # plumbing ERB's compiler emits around user expressions (`_erbout = +''`,
      # `_erbout.<<("...".freeze)`, `_erbout.<<((expr).to_s)`). Everything else
      # -- bare Kernel calls, any user-written receiver'd call, send/eval on any
      # receiver -- is rejected by default. Receivers of the allowed shapes are
      # themselves walked, so a marked shape cannot smuggle an impure operand.
      # Named by both method and source slice: pre-order hits the CallNode
      # before its receiver, so `Time.now` reports here -- the slice is what
      # keeps "Time" in the message.
      def self.call_offense(node)
        return nil if helper_call?(node) || erb_plumbing?(node)

        "call to #{node.name} (#{node.slice.strip[0, 60].inspect})"
      end

      def self.helper_call?(node)
        node.receiver.nil? && HELPERS.include?(node.name)
      end

      def self.erb_plumbing?(node)
        case node.name
        when :<< then node.receiver.is_a?(Prism::LocalVariableReadNode)
        when :freeze, :+@ then node.receiver.is_a?(Prism::StringNode)
        when :to_s then node.receiver.is_a?(Prism::ParenthesesNode)
        else false
        end
      end

      # Depth-first enumeration of every node, itself included. Returned as an
      # Enumerator so {offense_in} can walk it lazily and stop at the first hit.
      def self.descend(node, &block)
        return enum_for(:descend, node) unless block

        yield node
        node.compact_child_nodes.each { |child| descend(child, &block) }
      end
    end
  end
end
