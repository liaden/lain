# frozen_string_literal: true

require "ripper"
require "pathname"
require "tmpdir"

# Mechanical enforcement of the width of every sentence that rides the echo
# rail, and deliberately the same shape {OutputDiscipline}, {DesktopDiscipline}
# and {ApprovalConsumerDiscipline} are: read `lib/`, derive the subject set from
# the code, fail naming the violation.
#
# THE RAIL. `_G.__lain.review_refused` (`runtime/65_review.lua:36`) is a single
# `nvim_echo` with a `"lain: "` prefix, and Ruby reaches it three ways.
# `RpcThread#review_refused` sends that eval directly; `RpcThread#refusable`
# answers a detached editor with a sentence its caller supplied; and a refusal
# RETURNED from an rpcrequest handler comes back as `respond(id, nil, failure)`,
# which the lua half catches as `pcall`'s second value and hands straight to
# `review_refused` (`46_sidebar.lua:216`, `48_annotate.lua:419`,
# `65_review.lua:117`). A sentence longer than the message area raises a
# hit-enter prompt over the human's editor; T5 stops that being modal, and this
# stops the sentences being long in the first place.
#
# THE BAR IS 80 COLUMNS INCLUDING THE `"lain: "` PREFIX, and it is a budget
# rather than a measured ceiling. Two numbers were derived independently during
# this chunk, and both are recorded here because inheriting one silently is how
# a bar rots:
#
# - T5 measured the HARD ceiling as `v:echospace`, which is `&columns - 12`
#   ('showcmd' reserves twelve cells) -- 98 in the cockpit's 110-column nvim
#   pane. That is where the rail actually pages.
# - T7 chose 80 including the prefix, and brought `ApprovalView`'s own refusals
#   under it.
#
# 80 is the stricter of the two, it is the one that already ships, and it leaves
# eighteen cells of headroom against the pane the cockpit actually builds -- so
# a sentence passing here survives a narrower pane than the cockpit makes.
# `v:echospace` is not used as the bar because it is a RUNTIME value: a
# discipline spec reading it would pass or fail by the width of whatever
# terminal happened to run the suite.
#
# WHAT THE BAR GOVERNS: LAIN'S OWN WORDS. Several sentences quote text whose
# length lain does not choose -- a `Lain::Error#message` from a half-refused
# mark, a repository path, an exception a docent raised. No width bar can reach
# those, so {UNBOUNDED_FIELDS} render as the empty string and the bar applies to
# the frame around them. The corollary is a design rule this spec cannot assert
# and a reviewer must: a sentence quoting foreign text puts its OWN words -- the
# condition and the remedy -- FIRST, so that a shortened echo truncates the
# quotation and not the instruction. `Review::Handover::PARTLY_MARKED` was
# rewritten that way under this card.
#
# ⚠️ THE ONE KNOWN EXCEEDANCE, NAMED SO THAT 66 DOES NOT READ AS COMPLIANCE.
# `PARTLY_MARKED` measures 66 here, and its real echo is ALWAYS over the bar:
# `%<refusal>s` is never empty in service -- it is a `Lain::Error#message` from
# the mark that stopped, and it is the reason the sentence exists. So that row
# pages, every time, and no shortening of lain's own words can prevent it. The
# reorder is the whole mitigation available: after it, T5's shortened echo
# shows `marked 3 of 7 hunks on that row; the rest were refused` and truncates
# the quotation, where before the truncation ate the counts and left the human
# with somebody else's sentence and no idea what had landed. Every other
# unbounded-field subject is a frame that CAN be empty (`FAILED` with a docent
# that said nothing, `NO_ROW` with a line number); this one cannot.
module RefusalWidthDiscipline
  # The bar, in columns, INCLUDING {PREFIX}. See the module comment.
  BAR = 80

  # What `65_review.lua:33-38` prepends before echoing.
  PREFIX = "lain: "

  # The calls whose named argument IS a rail sentence, with the position that
  # carries it. Anchored on the method name at the CALL SITE, which is what
  # keeps this honest: `rpc_thread.rb` also holds nine lua eval sources
  # (`SET_VIEW` and its siblings, 82-132 characters and long for good reason),
  # and they are excluded because of how they are USED -- as the body of an
  # `nvim_exec_lua` -- rather than because of which class holds them. A rule
  # keyed on the holding class sweeps every one of them in.
  #
  # `refuse` is deliberately NOT a sink, though `Review::Surface::Neovim#refuse`
  # is the port's decline-in-words entry point. The name means five different
  # things in `lib/` -- a shell pipeline's, a TTY's, a sensitivity handler's, a
  # recorded-forge replay miss that RAISES, and the docent's, which writes the
  # thread PANE and not the rail -- and seeding on it admitted six sentences
  # that no `nvim_echo` ever sees. The real one needs no seed: `def refuse(message)
  # = @rpc.review_refused(message)` binds its own parameter through the sink
  # above, in its own file, which is where its callers are.
  SINKS = { "review_refused" => 0, "refusable" => 0 }.freeze

  # The refusal SLOT. A gesture's outcome carries its sentence as `report:` --
  # `ReviewView::Opened`, `ReviewView::Marked`, `ApprovalView::Decided` -- and
  # `CLI::HumanReplies::Gestures#gestured` reads exactly that member and hands
  # it to `review_refused`. So a constant reaching a `report:` keyword reaches
  # the rail, one member read later.
  SLOTS = %w[report refusal].freeze

  # The three ways a template is filled in. `String#%` is here because it is the
  # idiomatic one-character substitute for `format`, so `review_refused(T % [n])`
  # is what a shortened call site turns into -- and it smuggled a 140-column
  # sentence past this spec until the panel round.
  FORMATS = %w[format sprintf].freeze

  # Pure Ripper reading. Its own namespace because none of it knows anything
  # about refusals -- it answers "what call is this", "what constant is this",
  # "what can this body end on".
  module Sexp
    module_function

    def each_node(node, &block)
      return unless node.is_a?(Array)

      yield node
      node.each { |child| each_node(child, &block) }
    end

    def ident(node) = node.is_a?(Array) && %i[@ident @const @op @kw].include?(node[0]) ? node[1] : nil

    # "A" or "A::B", or nil for anything that is not a constant reference.
    def const_of(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :@const then node[1]
      when :var_ref, :const_ref, :vcall, :top_const_ref then const_of(node[1])
      when :const_path_ref then qualify(const_of(node[1]), ident(node[2]))
      end
    end

    def qualify(head, tail) = head && tail ? "#{head}::#{tail}" : tail

    # A LOCAL read only. Ripper spells a bare `foo` that is a local as
    # `:var_ref` and a bare `foo` that is a METHOD CALL as `:vcall`, and the
    # distinction matters: read as a local, `def refused = LONG` plus
    # `review_refused(refused)` binds a local nothing assigns and the constant
    # slips. `:vcall` therefore belongs to {call_parts}, not here.
    def local_of(node)
      return nil unless node.is_a?(Array) && node[0] == :var_ref

      node[1].is_a?(Array) && node[1][0] == :@ident ? node[1][1] : nil
    end

    def args_of(node)
      return [] unless node.is_a?(Array)

      case node[0]
      when :arg_paren then args_of(node[1])
      when :args_add_block then Array(node[1])
      else []
      end
    end

    # [name, arguments] for every call shape Ripper spells differently, or nil.
    def call_parts(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :method_add_arg then [called(node[1]), args_of(node[2])]
      when :method_add_block then call_parts(node[1])
      else bare_call(node)
      end
    end

    # An `fcall` names the method at [1], a `call` (explicit receiver) at [3].
    def called(inner) = ident(inner[1]) || ident(inner[3])

    def bare_call(node)
      case node[0]
      when :command then [ident(node[1]), args_of(node[2])]
      when :command_call then [ident(node[3]), args_of(node[4])]
      when :call then [ident(node[3]), []]
      when :vcall then [ident(node[1]), []] # a receiverless, argumentless call
      end
    end

    def param_names(node)
      names = []
      each_node(node) { |found| names << found[1] if found[0] == :@ident }
      names
    end

    # A Null-object stand-in ignores EVERY parameter it takes. See {Reach}.
    def stand_in?(node)
      names = param_names(node)
      !names.empty? && names.all? { |name| name.start_with?("_") }
    end

    # Where control flow carries a body's value onward rather than ending it.
    # A table rather than a `case` so this stays one branch wide.
    ONWARD = {
      ifop: ->(node) { [node[2], node[3]] },
      if: ->(node) { [*Array(node[2]).grep(Array), node[3]] },
      unless: ->(node) { [*Array(node[2]).grep(Array), node[3]] },
      elsif: ->(node) { [*Array(node[2]).grep(Array), node[3]] },
      if_mod: ->(node) { [node[2]] }, # [:if_mod, CONDITION, statement]
      unless_mod: ->(node) { [node[2]] },
      paren: ->(node) { Array(node[1]).grep(Array) },
      begin: ->(node) { Array(node[1]).grep(Array) },
      else: ->(node) { Array(node[1]).grep(Array) },
      args_add_block: ->(node) { Array(node[1]).grep(Array) },
      # `case`/`in` chain their clauses through the last slot, so one entry per
      # clause kind walks the whole ladder. A `case` is the natural way to write
      # "which refusal is this" -- `ReviewView#refused` is one refactor from
      # being one -- so dropping it would lose three constants in silence.
      case: ->(node) { [node[2]] },
      when: ->(node) { [*Array(node[2]).grep(Array), node[3]] },
      in: ->(node) { [*Array(node[2]).grep(Array), node[3]] },
      # A rescue's own body answers where the begin's did not, which is exactly
      # how `Handover#unrecorded` is reached.
      rescue: ->(node) { [*Array(node[3]).grep(Array), node[4]] },
      rescue_mod: ->(node) { [node[1], node[2]] },
      ensure: ->(node) { Array(node[1]).grep(Array) },
      # `@a || FALLBACK` and `@a && REFUSAL` both answer the operand.
      binary: ->(node) { %i[|| && or and].include?(node[2]) ? [node[1], node[3]] : nil },
      while_mod: ->(node) { [node[2]] },
      until_mod: ->(node) { [node[2]] },
      void_stmt: ->(_node) { [] }
    }.freeze

    # Every expression a body can END on, which is what its caller receives:
    # the last statement, every explicit `return`, and both legs of a tail
    # conditional.
    def tails(node)
      out = []
      queue = [node]
      until queue.empty?
        expression = queue.shift
        next unless expression.is_a?(Array)

        onward = expression[0] == :bodystmt ? body_tails(expression) : ONWARD[expression[0]]&.call(expression)
        onward ? queue.concat(onward.compact) : out << expression
      end
      out
    end

    # [:bodystmt, statements, rescue, else, ensure] -- all four can be what a
    # caller receives, and only the first was read before the panel round.
    def body_tails(node)
      statements = Array(node[1]).grep(Array)
      returns = []
      each_node(node) { |found| returns << found[1] if found[0] == :return }
      [statements.last, *returns, node[2], node[3], node[4]]
    end
  end

  # Reading a String literal out of the tree: its text, the constants hiding in
  # its interpolations, and where it sits. Its own module because none of it is
  # about NODES -- it is about the sentence a node spells.
  module Text
    module_function

    # The text of a String literal, with every `#{...}` rendered as
    # {UNBOUNDED_FIELDS} are -- foreign text of a length no bar reaches. Returns
    # nil for anything that is not a literal, `format(CONST, ...)` included, so
    # a real call still classifies as one.
    def literal_of(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :string_literal then string_parts(node[1])
      when :string_concat then joined(literal_of(node[1]), literal_of(node[2]))
      when :heredoc_dedent, :method_add_arg, :method_add_block, :call then literal_of(node[1])
      end
    end

    def joined(one, two) = one && two ? one + two : nil

    def string_parts(node)
      return nil unless node.is_a?(Array) && node[0] == :string_content

      parts = node[1..].map { |part| part_text(part) }
      parts.any?(&:nil?) ? nil : parts.join
    end

    def part_text(part)
      return nil unless part.is_a?(Array)

      case part[0]
      when :@tstring_content then part[1]
      when :string_embexpr, :string_dvar then ""
      end
    end

    # Constants named INSIDE a literal's interpolations. `#{e.message}` is
    # foreign text and renders empty, but `#{SOME_REFUSAL}` is lain's own words
    # wearing an interpolation, and measuring only the frame around it lets a
    # 140-column sentence through a sink. Anything that resolves to something
    # other than a String falls out later, so `#{Foo.bar}`'s `Foo` costs nothing.
    def interpolated_constants(node)
      embedded(node).flat_map { |inner| named_in(inner) }
    end

    def embedded(node)
      found = []
      Sexp.each_node(node) { |inner| found << inner if inner[0] == :string_embexpr }
      found
    end

    def named_in(node)
      found = []
      Sexp.each_node(node) { |deep| found << Sexp.const_of(deep) if %i[var_ref const_path_ref].include?(deep[0]) }
      found.compact
    end

    # The first source line any token of this subtree sits on.
    def line_of(node)
      found = nil
      Sexp.each_node(node) { |inner| found ||= inner[2][0] if inner[2].is_a?(Array) && inner[2][0].is_a?(Integer) }
      found || 0
    end
  end

  Method = Struct.new(:name, :params, :stand_in, :tails)
  Constant = Struct.new(:path, :name, :line)

  # One file's parsed facts, gathered in a single walk: its method definitions
  # with their tail expressions, its call sites with the method each sits in,
  # its keyword arguments, its local assignments, and its constant definitions
  # with the lexical namespace they land in.
  class FileIndex
    attr_reader :methods, :calls, :kwargs, :assigns, :constants, :namespaces

    def initialize(sexp)
      @methods = []
      @calls = []
      @kwargs = []
      @assigns = []
      @constants = []
      @namespaces = []
      visit(sexp, nil, [])
    end

    private

    def visit(node, enclosing, namespace)
      return unless node.is_a?(Array)

      here = %i[def defs].include?(node[0]) ? define(node) : enclosing
      inner = opened(node, namespace)

      record_assign(node, inner)
      record_call(node, here)
      node.each { |child| visit(child, here, inner) }
    end

    # The lexical namespace inside this node, recorded on the way in so
    # {Derivation#shared} can key a homonym on how near it is rather than on
    # which file happened to sort first.
    def opened(node, namespace)
      return namespace unless %i[class module].include?(node[0])

      inner = namespace + Array(Sexp.const_of(node[1])&.split("::"))
      @namespaces << inner.join("::")
      inner
    end

    def define(node)
      offset = node[0] == :def ? 1 : 3
      method = Method.new(Sexp.ident(node[offset]), Sexp.param_names(node[offset + 1]),
                          Sexp.stand_in?(node[offset + 1]), Sexp.tails(node[offset + 2]))
      @methods << method
      method
    end

    def record_assign(node, namespace)
      target = assign_target(node)
      return if target.nil?

      @assigns << [target[1], node[2]] if target[0] == :@ident
      record_constant(target, node[2], namespace) if target[0] == :@const
    end

    # The name a plain `X = ...` assigns, local or constant, or nil.
    def assign_target(node)
      return nil unless node[0] == :assign

      field = node[1]
      return nil unless field.is_a?(Array) && field[0] == :var_field && field[1].is_a?(Array)

      field[1]
    end

    def record_constant(target, value, namespace)
      @constants << [Constant.new((namespace + [target[1]]).join("::"), target[1], target[2][0]), value]
    end

    def record_call(node, enclosing)
      parts = Sexp.call_parts(node)
      return if parts.nil?

      @calls << [parts[0], parts[1], enclosing]
      parts[1].grep(Array).select { |argument| argument[0] == :bare_assoc_hash }.each do |hash|
        Array(hash[1]).each { |assoc| record_kwarg(assoc, enclosing) }
      end
    end

    def record_kwarg(assoc, enclosing)
      return unless assoc.is_a?(Array) && assoc[0] == :assoc_new
      return unless assoc[1].is_a?(Array) && assoc[1][0] == :@label

      label = assoc[1][1].delete_suffix(":")
      # `report:` with no value is shorthand for the local `report`.
      @kwargs << [label, assoc[2] || [:var_ref, [:@ident, label, [0, 0]]], enclosing]
    end
  end

  # The reverse dataflow, run to a fixpoint over ONE file.
  #
  # "Every constant delivered through `review_refused`" is a dataflow property
  # crossing Ruby -> a lua eval -> `65_review.lua`, and there is no AST pattern
  # for it. This propagates backwards from {SINKS} and {SLOTS} through
  # parameters, returns and locals -- and only WITHIN a file. That restriction
  # is what makes it usable: an earlier draft propagated method names across
  # `lib/` and admitted 182 constants, because `report`, `call` and `run` mean
  # twenty things in a tree this size.
  #
  # One seed is a SHAPE rather than a delivery, and it is the one that can
  # over-reach: a method that IGNORES every parameter it takes and answers a
  # fixed String is a refusal by construction -- it tells a caller "I cannot do
  # this" in words, whatever it was asked -- which is how `NoReviewWrites`,
  # `RpcThread::Listener::Null` and `Surface::Neovim::Unbound` answer. It
  # over-reaches SAFELY, by asking an unrelated stand-in's sentence to be short
  # too, and the failure names the file so a false positive is one line to
  # diagnose. At least one parameter is required: a zero-arity
  # `def self.surface = SURFACE` is an attribute, not a refusal.
  #
  # A LITERAL at a rail-bound position is a subject too, with no constant to
  # name it. That is not a nicety: `human_replies.rb` shipped a 128-column
  # refusal as a bare literal at the sink itself, invisible to a constant-only
  # scan, which is the exact failure this spec exists to prevent. Constants
  # NAMED INSIDE such a literal's interpolations are also taken -- `#{e.message}`
  # is foreign text and renders empty, but `#{SOME_REFUSAL}` is lain's own words
  # wearing an interpolation, and measuring only the frame lets it through.
  #
  # WHAT THIS MISSES, after the panel round closed seven routes that were open.
  # The frontier is now: a refusal handed between two files by a method whose
  # name is neither a sink nor a slot (a fully-qualified constant at a sink is
  # NOT this case -- see {Derivation#shared}); a sentence assembled by
  # concatenation across statements; and a value arriving through a collection.
  # What it CATCHES it catches automatically, including constants nobody has
  # written yet, which is the property that matters: a discipline spec missing
  # the next violation is worse than none. Every route the review panel found
  # open is an example under "the routes a refusal takes to the rail", because a
  # derivation whose blind spots are untested regrows them -- and the literal
  # branch of {Derivation#sites_in} has its own example one level up, because
  # deleting it left every route example green.
  class Reach
    def initialize(index)
      @index = index
      @constants = Set.new
      @literals = Set.new
      @arguments = Set.new
      @returns = Set.new
      @locals = Set.new
    end

    # @return [Set<String>] every constant name this file delivers to the rail
    def constants
      settle
      @constants
    end

    # @return [Set<Array(String, Integer)>] every bare String LITERAL this file
    #   delivers to the rail, with the line it sits on. A literal at a sink is
    #   the shape that shipped `human_replies.rb`'s 128-column refusal past the
    #   first cut of this spec: it has no definition site, so a constant-only
    #   scan cannot see it. It is measured here and it CANNOT be named, which is
    #   the reason to promote one to a constant rather than merely shorten it.
    def literals
      settle
      @literals
    end

    private

    def settle
      return if @settled

      loop do
        @changed = false
        pass
        break unless @changed
      end
      @settled = true
    end

    def pass
      absorb_arguments
      @index.assigns.each { |assign| absorb_tails(assign[1]) if @locals.include?(assign[0]) }
      @index.methods.each { |method| absorb_method(method) }
    end

    def absorb_arguments
      @index.calls.each { |name, args, enclosing| absorb_call(name, args, enclosing) }
      @index.kwargs.each { |label, value, enclosing| absorb(value, enclosing) if SLOTS.include?(label) }
    end

    def absorb_tails(value) = Sexp.tails(value).each { |tail| absorb(tail, nil) }

    def absorb_call(name, args, enclosing)
      args.each_with_index do |argument, position|
        absorb(argument, enclosing) if SINKS[name] == position || @arguments.include?([name, position])
      end
    end

    def absorb_method(method)
      return unless method.stand_in || slot_reader?(method) || @returns.include?(method.name)

      method.tails.each { |tail| absorb(tail, method) }
    end

    # `def self.report = NO_DOCENT` -- the slot answered by a method rather than
    # by a Data member. Restricted to a body that is a bare constant, because
    # `report` names other things in `lib/` (`cli/review.rb` builds a fallback
    # NOTE into a local of that name) and a looser rule admits them.
    def slot_reader?(method)
      SLOTS.include?(method.name) && method.tails.size == 1 && !Sexp.const_of(method.tails.first).nil?
    end

    def absorb(expression, enclosing)
      case classify(expression)
      in [:const, name] then note(@constants, name)
      in [:format, args] then absorb_format(args)
      in [:call, name] then note(@returns, name)
      in [:literal, text, line, named]
        note(@literals, [text, line])
        named.each { |name| note(@constants, name) }
      in [:local, name] then absorb_local(name, enclosing)
      else nil
      end
    end

    # A template is a subject however it is spelled: a constant, or a literal
    # written straight into the call. {Text.literal_of} answers nil for a
    # `format(...)` by design, so the literal case has to be read HERE or it is
    # invisible the moment the template takes an argument.
    def absorb_format(args)
      template = args.first
      name = Sexp.const_of(template)
      return note(@constants, name) if name

      text = Text.literal_of(template)
      return if text.nil?

      note(@literals, [text, Text.line_of(template)])
      Text.interpolated_constants(template).each { |found| note(@constants, found) }
    end

    def absorb_local(name, enclosing)
      position = enclosing&.params&.index(name)
      position ? note(@arguments, [enclosing.name, position]) : note(@locals, name)
    end

    def note(set, value)
      @changed = true if !value.nil? && set.add?(value)
    end

    # What an expression sitting in a rail-bound position tells the fixpoint.
    # A bare constant, then a template, then a reference -- and the order is
    # load-bearing at every step.
    def classify(expression)
      return nil unless expression.is_a?(Array)

      name = Sexp.const_of(expression)
      return [:const, name] if name

      classify_template(expression) || classify_reference(expression)
    end

    # `T % [x]` is a binary operator and reaches neither of the two below; a
    # literal has to be read BEFORE {Sexp.call_parts}, because `"...".freeze`
    # is spelled as a call.
    def classify_template(expression)
      classify_percent(expression) || classify_literal(expression)
    end

    def classify_reference(expression)
      parts = Sexp.call_parts(expression)
      return classify_call(parts) if parts

      local = Sexp.local_of(expression)
      local && [:local, local]
    end

    def classify_literal(expression)
      text = Text.literal_of(expression)
      text && [:literal, text, Text.line_of(expression), Text.interpolated_constants(expression)]
    end

    def classify_call(parts) = FORMATS.include?(parts[0]) ? [:format, parts[1]] : [:call, parts[0]]

    # `TEMPLATE % [line]` -- Ripper spells it as a binary operator, not a call,
    # so it reaches neither {Sexp.call_parts} nor {Text.literal_of}.
    def classify_percent(expression)
      return nil unless expression.is_a?(Array) && expression[0] == :binary && expression[2] == :%

      [:format, [expression[1]]]
    end
  end

  # What a violation is called when it has no name to be called by.
  LITERAL = "(literal)"

  Site = Struct.new(:file, :constant, :value) do
    # One subject per DEFINITION, however many files name it.
    def key = constant.path || [file, constant.line]
  end

  # Every file's {Reach}, resolved against the LOADED library. The real runtime
  # String rather than a reconstruction of it: the suite has already required
  # `lain`, and `#{BUFFER}`-style interpolation and `.freeze` are exactly the
  # parts a re-read of the source gets wrong.
  class Derivation
    def initialize(lib_root) = @lib_root = lib_root

    # @return [Array<Site>] every String constant and bare literal the rail reaches
    def sites
      indexes = read
      table = indexes.flat_map { |file, index| index.constants.map { |constant, _| [file, constant] } }
      indexes.flat_map { |file, index| sites_in(file, index, table) }.uniq(&:key)
    end

    private

    def read
      @lib_root.glob("**/*.rb").sort.to_h do |file|
        [file.relative_path_from(@lib_root).to_s, FileIndex.new(parse(file))]
      end
    end

    def parse(file)
      Ripper.sexp(file.read) || raise("could not parse #{file}")
    end

    def sites_in(file, index, table)
      reach = Reach.new(index)
      named = reach.constants.sort.filter_map { |name| named_site(file, index, table, name) }
      named + reach.literals.sort.map { |text, line| Site.new(file, Constant.new(nil, LITERAL, line), text) }
    end

    def named_site(file, index, table, name)
      found = own(file, index, name) || shared(table, index, name)
      return nil if found.nil?

      value = resolve(found.last.path)
      value.is_a?(String) ? Site.new(found.first, found.last, value) : nil
    end

    def own(file, index, name)
      constant = index.constants.map(&:first).find { |found| matches?(found.path, name) }
      constant && [file, constant]
    end

    # A constant defined in file A and named IN FULL at a sink in file B. Not a
    # hop this cannot see -- a direct, fully-qualified reference at argument 0,
    # and three sinks use it today (`refusable(Compose::DETACHED)`,
    # `QuestionView::DETACHED`, `ApprovalView::DETACHED`). Resolved against
    # every definition in `lib/`, nearest namespace winning, so a new
    # `refusable(NewView::DETACHED)` in a file holding no seed of its own is
    # still measured.
    def shared(table, index, name)
      candidates = table.select { |_, constant| matches?(constant.path, name) }
      candidates.max_by { |_, constant| nearness(constant.path, index.namespaces) }
    end

    # How deep the LEXICAL namespace shared with the referencing file goes. It
    # was directory-path proximity with an alphabetical `max_by` tie, which is a
    # coin flip: a sink inside `Lain::Alpha` naming a bare `COLLIDE` resolved to
    # `Lain::Beta::COLLIDE` because that file sorted first. That erred toward a
    # false alarm here, but the same flip can pick the SHORTER homonym and pass
    # a real over-bar constant. {FileIndex} already records every namespace a
    # file opens, so the right key was already to hand.
    def nearness(path, namespaces)
      segments = path.split("::")
      namespaces.map { |namespace| shared_prefix(segments, namespace.split("::")) }.max.to_i
    end

    # A `::`-BOUNDARY match, never a raw string suffix. `end_with?("KNOWN")`
    # resolves KNOWN to UNKNOWN -- it mis-resolves five pairs in `lib/` today,
    # and is latent for the rail only because MARKED happens to be defined
    # before PARTLY_MARKED. Swap those two and MARKED goes unmeasured.
    def matches?(path, name) = RefusalWidthDiscipline.boundary_match?(path, name)

    def shared_prefix(one, other)
      one.zip(other).take_while { |first, second| first == second && !first.nil? }.size
    end

    def resolve(path)
      Object.const_get(path)
    rescue NameError
      nil
    end
  end

  # Fields whose value the code CHOOSES from a set it controls, rendered at the
  # longest value that set holds -- which is the adversarial reading, and the
  # one a template-length check misses. `%<verdicts>s` is not four characters of
  # template, it is however many `Review::VERDICTS` joins to.
  def self.bounded_fields = CHOSEN_FIELDS.merge(vocabulary_fields).freeze

  # Values this spec picks, each at the longest the code can produce.
  CHOSEN_FIELDS = {
    "generation" => "1024",       # a rendering stamp as #inspect writes it
    "line" => "1024",             # a cursor line in a long changeset
    "landed" => "99",
    "total" => "99",
    "given" => "unreviewed",      # a mistyped verdict, at this vocabulary's longest word
    "decision" => "approved",
    "surface" => "auto_approver"  # the longest surface name that decides an approval
  }.freeze

  # Values read off the code's OWN vocabulary, so widening a vocabulary
  # re-measures every sentence quoting it without anyone remembering to.
  def self.vocabulary_fields
    {
      "verdicts" => Lain::Review::VERDICTS.join("/"),
      "verdict" => Lain::Review::VERDICTS.max_by(&:length),
      "state" => Lain::Review::MARK_STATES.max_by(&:length),
      "hunk_key" => hunk_key_preview
    }
  end

  # What `Review::Surface.preview` truncates a hunk key to.
  def self.hunk_key_preview
    scheme = [Lain::Review::Hunk::CONTENT_SCHEME, Lain::Review::Hunk::SPAN_SCHEME].max_by(&:length)
    "#{scheme}:#{"0" * Lain::Review::Surface::DIGEST_PREVIEW_LENGTH}..."
  end

  # Fields quoting text lain did not write and cannot bound: another
  # component's refusal, an exception message, a repository path. They render
  # EMPTY, and the bar governs the frame -- see the module comment for the
  # design rule that follows.
  UNBOUNDED_FIELDS = %w[refusal message path reason].freeze

  # Positional conversions. `%d` renders a number; `%s` and `%p` in this set
  # always quote foreign text, so they render empty for {UNBOUNDED_FIELDS}'
  # reason. The one understatement this admits is a positional carrying a
  # NUMBER through `%s` (`format(NO_ROW, line.inspect)`) -- at most four
  # characters, and it errs toward permitting rather than toward a false alarm.
  POSITIONAL = { "d" => "1024", "i" => "1024", "s" => "", "p" => "" }.freeze

  NAMED = /%[-+ 0#]*\d*(?:\.\d+)?<([a-z_]+)>[a-z]/
  BARE = /%[-+ 0#]*\d*(?:\.\d+)?([a-z])/

  # @return [String] the sentence as `nvim_echo` receives it
  def self.render(template)
    fields = bounded_fields
    named = template.gsub(NAMED) do
      field = Regexp.last_match(1)
      fields.fetch(field) { UNBOUNDED_FIELDS.include?(field) ? "" : "1024" }
    end
    PREFIX + named.gsub("%%", "%").gsub(BARE) { POSITIONAL.fetch(Regexp.last_match(1), "") }
  end

  Measured = Struct.new(:site, :rendered) do
    def width = rendered.length
    def over? = width > BAR
    def name = site.constant.name

    def to_s = "#{site.file}:#{site.constant.line} #{name} renders at #{width} (bar #{BAR}): #{rendered.inspect}"
  end

  module_function

  def lib_root = Pathname(__dir__).join("..", "lib").expand_path

  # @return [Array<Measured>] every rail sentence, rendered. Called ONCE -- see
  #   MEASURED_REFUSALS below.
  def measured
    Derivation.new(lib_root).sites.map { |site| Measured.new(site, render(site.value)) }
  end

  # A `::`-BOUNDARY match. See {Derivation#matches?} for why a raw string suffix
  # is not good enough; module_function so the rule itself is testable.
  def boundary_match?(path, name) = path == name || path.end_with?("::#{name}")

  # Runs the derivation over a source STRING, so the routes an over-long refusal
  # can take to the rail are EXAMPLES rather than a harness that edits `lib/`.
  # @return [Array(Set<String>, Array<String>)] constant names, literal texts
  def reaches(source)
    reach = Reach.new(FileIndex.new(Ripper.sexp(source)))
    [reach.constants, reach.literals.map(&:first)]
  end
end

# A constant that has to EXIST for the cross-file example below: the derivation
# resolves against the loaded library, so a synthetic reference needs a real
# referent. Long on purpose -- the example asserts it is caught, not that it fits.
module RefusalWidthFixture
  FAR = "x" * 140

  # Two homonyms in two files, for the namespace-proximity example below. Their
  # VALUES differ so the example can say which one was resolved.
  module Alpha
    COLLIDE = "the near one"
  end

  module Beta
    COLLIDE = "the far one"
  end
end

# The control-flow shapes a refusal can be written in. At file scope rather than
# inside the example group, which would leak a constant out of a block. `OVER`
# inside these is TEXT that Ripper parses, never a Ruby constant.
REFUSAL_SHAPES = {
  "last statement" => "def m(_x); OVER; end",
  "endless def" => "def m(_x) = OVER",
  "explicit return" => "def m(_x); return OVER; end",
  "if/else" => "def m(_x); if @a then A else OVER end; end",
  "trailing if modifier" => "def m(_x); OVER if @a; end",
  "ternary" => "def m(_x); @a ? A : OVER; end",
  "case/when" => "def m(_x); case @a when 1 then A else OVER end; end",
  "case/in" => "def m(_x); case @a; in [1] then A; else OVER; end; end",
  "rescue clause" => "def m(_x); risky; rescue => e; OVER; end",
  "rescue modifier" => "def m(_x); risky rescue OVER; end",
  "|| fallback" => "def m(_x); @a || OVER; end",
  "&& guard" => "def m(_x); @a && OVER; end",
  "while modifier" => "def m(_x); OVER while @a; end",
  "ensure" => "def m(_x); A; ensure; OVER; end"
}.freeze

# ONE derivation for the whole file: 465 files parsed, at load rather than per
# example. A `let` re-ran it four times over and this file runs in one worker of
# every `pspec`; `before(:all)` would say the same thing and leak state between
# examples, which for a value nothing mutates is a worse trade than a constant.
MEASURED_REFUSALS = RefusalWidthDiscipline.measured.each(&:freeze).freeze

RSpec.describe "refusal width discipline" do
  let(:measured) { MEASURED_REFUSALS }

  # THE ROUTES AN OVER-LONG REFUSAL CAN TAKE TO THE RAIL, each one a way the
  # panel's smuggling probe got a 140-column sentence past the first cut of this
  # spec. A derivation whose blind spots are untested regrows them, so every
  # route that was open is an example here, driven over a source STRING rather
  # than by editing `lib/`.
  describe "the routes a refusal takes to the rail" do
    def reached(source) = RefusalWidthDiscipline.reaches(source)

    it "follows a constant aliased from another constant" do
      constants, = reached("class S\n ALIAS = LONG\n def go = review_refused(ALIAS)\nend")

      expect(constants).to include("ALIAS")
    end

    it "follows a bare receiverless helper, which Ripper spells :vcall and not a local read" do
      constants, = reached("class S\n SENT = 'x'\n def go = review_refused(sentence)\n def sentence = SENT\nend")

      expect(constants).to include("SENT")
    end

    it "measures a bare String literal at a sink, which has no constant to name" do
      _, literals = reached("class S\n def go = review_refused('a literal nobody named')\nend")

      expect(literals).to eq(["a literal nobody named"])
    end

    it "follows a constant interpolated into a literal at a sink" do
      source = "class S\n LONG = 'x'\n def go = review_refused(\"note -- \#{LONG}\")\nend"
      constants, literals = reached(source)

      expect(constants).to include("LONG")
      expect(literals).to eq(["note -- "])
    end

    # `%` is the idiomatic one-character substitute for `format`, and it is the
    # natural authoring shape the moment somebody shortens a call site. There is
    # no live violation -- this is prophylaxis, which is the whole point of the
    # card.
    it "follows a constant used as a String#% template at a sink" do
      constants, = reached("class S\n TEMPLATE = 'x'\n def go(line) = review_refused(TEMPLATE % [line])\nend")

      expect(constants).to include("TEMPLATE")
    end

    # The other half of the same hole: {Text.literal_of} answers nil for a
    # `format(...)` by design, so the literal a template is written AS was
    # invisible the moment it took an argument.
    it "measures a literal template handed to format at a sink" do
      _, literals = reached("class S\n def go(n) = review_refused(format('on line %d, nothing', n))\nend")

      expect(literals).to eq(["on line %d, nothing"])
    end

    it "leaves foreign text in an interpolation unmeasured, because no bar reaches it" do
      _, literals = reached("class S\n def go(e) = review_refused(\"broke: \#{e.message}\")\nend")

      expect(literals).to eq(["broke: "])
    end

    # `refusable(ApprovalView::DETACHED)` is this shape, and three sinks use it.
    # A file-local lookup drops it, so the four DETACHED sentences were covered
    # only by the accident of their own files holding a seed.
    it "follows a constant defined in one file and named in full at a sink in another" do
      Dir.mktmpdir("rwd-", ENV.fetch("TMPDIR", nil)) do |root|
        lib = Pathname(root)
        lib.join("far.rb").write("module RefusalWidthFixture\n  FAR = 'x'\nend\n")
        lib.join("sink.rb").write("class S\n def go = refusable(RefusalWidthFixture::FAR) { nil }\nend\n")

        sites = RefusalWidthDiscipline::Derivation.new(lib).sites

        expect(sites.map { |site| site.constant.path }).to include("RefusalWidthFixture::FAR")
      end
    end

    # The tiebreak was directory-path proximity with an alphabetical `max_by`
    # tie, so a bare name resolved to whichever homonym's FILE sorted first --
    # here `a_beta.rb`, which is the wrong one. That erred toward a false alarm
    # in the case the panel probed; the same flip can pick the shorter homonym
    # and pass a real over-bar constant.
    it "resolves a bare homonym by lexical namespace, not by which file sorts first" do
      Dir.mktmpdir("rwd-", ENV.fetch("TMPDIR", nil)) do |root|
        lib = Pathname(root)
        lib.join("a_beta.rb").write(namespaced("Beta", "COLLIDE = 'x'"))
        lib.join("m_alpha.rb").write(namespaced("Alpha", "COLLIDE = 'x'"))
        lib.join("z_sink.rb").write(namespaced("Alpha", "class S\n def go = refusable(COLLIDE) { nil }\nend"))

        sites = RefusalWidthDiscipline::Derivation.new(lib).sites

        expect(sites.map(&:value)).to contain_exactly(RefusalWidthFixture::Alpha::COLLIDE)
      end
    end

    def namespaced(inner, body) = "module RefusalWidthFixture\n module #{inner}\n #{body}\n end\nend\n"

    # The `if_mod` bug that hid Docent::DUPLICATE from the first red run was one
    # of these. `case`/`when` and `|| FALLBACK` are the natural way to write
    # "which refusal is this" -- ReviewView#refused is one refactor from being a
    # `case` -- so a dropped shape loses constants in silence.

    REFUSAL_SHAPES.each do |shape, source|
      it "carries a refusal written as #{shape}" do
        constants, = reached(source)

        expect(constants).to include("OVER")
      end
    end
  end

  # Latent for the rail only by luck of definition order: MARKED happens to be
  # written before PARTLY_MARKED. Swap them and a raw-suffix match measures
  # PARTLY_MARKED twice and MARKED never. Five pairs in `lib/` already collide
  # this way (KNOWN/UNKNOWN, SIDES/GITHUB_SIDES, KINDS/TERMINAL_KINDS, ...).
  it "resolves a constant on a :: boundary rather than a raw string suffix" do
    expect(RefusalWidthDiscipline.boundary_match?("Lain::Response::UNKNOWN", "KNOWN")).to be(false)
    expect(RefusalWidthDiscipline.boundary_match?("Lain::Response::UNKNOWN", "UNKNOWN")).to be(true)
    expect(RefusalWidthDiscipline.boundary_match?("Lain::A::B::C", "B::C")).to be(true)
  end

  # The pin on the literal half of the derivation, and it exists because deleting
  # `Derivation#sites_in`'s literal branch left every other example GREEN: the
  # route examples drive {Reach#literals} directly, so they never notice that
  # nothing carries a literal into the MEASURED set. A regression suite that
  # passes against the bug it was written for is worse than none, one level up.
  it "carries a bare literal all the way into the measured set, not just into Reach" do
    literals = measured.select { |one| one.name == RefusalWidthDiscipline::LITERAL }

    expect(literals).not_to be_empty
    expect(literals.map { |one| one.site.constant.line }).to all(be_positive)
  end

  it "derives its subjects from lib/, and finds the rail's sentences there" do
    files = measured.map { |one| one.site.file }.uniq

    expect(files).to include(
      "lain/review/surface/neovim.rb",
      "lain/review/handover.rb",
      "lain/frontend/neovim/review_view.rb",
      "lain/frontend/neovim/approval_view.rb",
      "lain/frontend/neovim/rpc_thread.rb"
    )
  end

  # The false positive that would wreck this spec, pinned so a looser derivation
  # cannot land quietly. These nine are 82-132 characters of lua, they are long
  # for a good reason, and a rule keyed on which CLASS holds a constant sweeps
  # every one of them into the subject set.
  it "excludes the lua eval sources that share a file with the rail's own refusals" do
    names = measured.select { |one| one.site.file == "lain/frontend/neovim/rpc_thread.rb" }.map(&:name)

    expect(names).not_to include("SET_VIEW", "SET_REQUEST", "SET_COMPOSE", "SET_QUESTION", "SET_REVIEW",
                                 "SET_THREAD", "SET_APPROVAL", "OPEN_CHANGESET", "REVIEW_REFUSED")
  end

  # A template is SHORTER than what nvim_echo receives, so measuring one passes
  # sentences that page. This is the guard on the guard.
  it "renders a template rather than measuring it" do
    marked = measured.find { |one| one.name == "MARKED" }

    expect(marked.rendered).not_to include("%<")
    expect(marked.rendered).to include(Lain::Review::MARK_STATES.max_by(&:length))
  end

  it "keeps every sentence that rides the rail within the bar once rendered" do
    over = measured.select(&:over?)

    expect(over).to be_empty, lambda {
      listing = over.sort_by { |one| -one.width }.map { |one| "  #{one}" }.join("\n")
      "A refusal echoed by _G.__lain.review_refused writes the message area, and one longer than it " \
        "raises a hit-enter prompt over the human's editor. The bar is #{RefusalWidthDiscipline::BAR} " \
        "columns including the #{RefusalWidthDiscipline::PREFIX.inspect} prefix, measured on the " \
        "RENDERED sentence. Over it:\n#{listing}\n" \
        "Shorten it -- it must still name its CONDITION and its REMEDY, so cut the prose between them " \
        "and not the instruction. If it genuinely cannot keep both, raise BAR deliberately and say why " \
        "in this file; the hard ceiling is v:echospace (&columns - 12), 98 in a 110-column pane."
    }
  end
end
