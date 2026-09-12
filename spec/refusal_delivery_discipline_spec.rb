# frozen_string_literal: true

require "pathname"
require "strscan"

# Mechanical enforcement of HOW a user command refuses, and deliberately the
# same shape {OutputDiscipline} and {RefusalWidthDiscipline} are: read the
# tree, derive the subject set from the code, fail naming file and line. It
# sits at `spec/*_discipline_spec.rb` with its eight siblings rather than at a
# mirror path, because it derives from the whole runtime and not from one
# directory -- a gate nobody finds gets duplicated or disabled.
#
# `refusal_width_discipline_spec.rb` is the near sibling and the division is
# by LANGUAGE, not by subject: that one is pure Ripper, so it reads Ruby-side
# call sites and cannot see a lua literal at all. This one lexes lua. Between
# them they cover both halves of one rule -- a refusal rides the rail, and it
# fits.
#
# THE DEFECT. `define` (`runtime/30_commands.lua:8-11`) is
# `nvim_create_user_command` with an idempotent delete in front of it, and its
# only `pcall` guards that delete. Nothing rescues the callback. So an
# `error()` inside a `define`d user-command callback escapes into nvim, which
# appends its own `stack traceback:` to the sentence -- `error(msg, 0)` does
# not suppress that, the traceback is the outer wrapper's doing -- and, with a
# UI attached, raises a hit-enter prompt. A hit-enter prompt answers no RPC
# request that is not `fast`, so the editor stops serving lain exactly while a
# refusal naming the recovery is on screen, and the recovery it names cannot be
# taken. That defect was filed on the annotate rail and again on the sidebar's;
# the first fix covered one site and the same defect turned up at a second.
# This spec is what stops a third.
#
# THE FIX AT EVERY SITE IS THE SAME: hand the sentence to
# `_G.__lain.review_refused` (`runtime/65_review.lua:236`) and RETURN. The rail
# echoes, folds and fits, records the whole sentence in `:messages`, and
# prepends `"lain: "` -- so a converted sentence drops its own prefix or the
# human reads `lain: lain: ...`.
#
# WHAT THE SUBJECT SET IS, AND WHY IT IS LEXICAL. A violation is an `error(`
# written INSIDE a `define(...)` call -- textually, between that call's opening
# and closing parenthesis. Three things follow, and all three are the point:
#
#   - An `_G.__lain.*` RPC ENTRY POINT IS NOT IN THE SET. `set_thread`,
#     `open_changeset`, `set_approval` and their neighbours are
#     called by `nvim_exec_lua` from the Ruby side, where a raise legitimately
#     becomes the RPC request's error and is the only way to answer one. They
#     are top-level `function _G.__lain.name(...)` statements, never nested
#     inside a `define` call, so the lexical bound excludes them by
#     construction rather than by an allowlist somebody has to maintain. A gate
#     that swept them in would be disabled by the next person, and rightly.
#   - A HELPER THE CALLBACK CALLS IS NOT IN THE SET EITHER, and this is a
#     KNOWN, DELIBERATE GAP rather than an oversight. `review_notes.assert_saved`
#     (`48_annotate.lua`) raises an unprefixed sentence that `:LainNoteDone`
#     `pcall`s and hands to the rail -- correct, and invisible to a lexical
#     rule. Reaching it would take call-graph analysis, and the same analysis
#     would flag that correct site as loudly as a real one. So the bound stays
#     where a reader can check it by eye, and the gap is written down here
#     instead of being discovered as a false green. `62_approval.lua`'s
#     `submit_approval` and `70_inbox.lua`'s `submit_reply` sit in that gap on
#     the other side: both are refusals of a user command, reached one call
#     down, and both were converted BY HAND rather than by this gate naming
#     them. A reviewer is the only thing that catches the next one.
#   - A CALLBACK THAT IS NOT LEXICALLY THERE IS INVISIBLE, which is the same
#     gap wearing a different shape and the one most likely to be misread as
#     coverage. `50_request.lua:30-31` is
#     `define("LainSend", agent_command("send"))` -- the callback is BUILT by a
#     factory, so this gate sees the factory CALL and nothing of the body it
#     returns. Every such body today is a bare `vim.rpcrequest` with no refusal
#     in it, so nothing is missed in fact; but greenness here does NOT mean
#     "every `define`d callback was read", and a factory that grew a refusal
#     would pass. There is a self-test pinning the shape so the next reader
#     meets it as a decision.
#
# `vim.notify` IS IN THE SET TOO, and it is the same defect reached by WIDTH
# rather than by a raise -- which is why this spec is named for DELIVERY and not
# for `error`. `51_thread.lua`'s `:LainThread` carries the measurement: a plain
# `vim.notify` blocks at roughly `#sentence + 12 > columns`, so the 95-character
# refusal it used to send raised the hit-enter prompt at every width up to 105.
# It writes the message AREA exactly as `nvim_echo` does, and it does it without
# any of the rail's protections -- no `fitted`, no `folded`, no whole sentence
# kept in `:messages`, and a second hand-written copy of the `"lain: "` prefix
# the rail owns. `:LainThread` was converted for those reasons; nothing else
# about a user-command refusal makes the notification handler the right door.
#
# ⚠️ WHAT A CALL IS HERE, AND WHAT THIS MISSES. A call is a name with a `(`
# behind it whose own name is not qualified by a `.` or a `:`. That last
# clause is what keeps `log.error("...")` and `rail:error("...")` out: neither
# is lua's `error`, and a gate that flagged them would be reaching for a name
# rather than for a thing. It is also, honestly, a gate with a hole in it:
# lua lets a call omit its parentheses when the single argument is a literal
# string or a table, so `error "boom"` and `vim.notify "boom"` are real calls
# that this DOES NOT SEE. No such site exists in the runtime today (every one
# is written with parentheses), and adding the shape would cost a token of
# lookahead -- but it is a gap, it is not "unreachable", and it is written
# down here rather than implied by a comment about call forms that reach
# neither door.
#
# ⚠️ A `pcall`ed raise INSIDE a callback is flagged too, and that one IS a
# false positive in principle: `pcall(function() error("x", 0) end)` never
# escapes and so never reaches nvim. There is no such site today. If one
# arrives, the answer is to lift the raising body into a named helper -- where
# `assert_saved` already sits, outside the bound -- and not to widen the gate.
module RefusalDeliveryDiscipline
  # The rail every refusal from a user command goes out on.
  RAIL = "review_refused"

  # What the rail prepends (`65_review.lua:237`). A sentence handed to it must
  # not spell this itself.
  PREFIX = "lain: "

  # The budget, in columns, INCLUDING {PREFIX}. NOT `v:echospace`, which is the
  # measured hard ceiling (98 in the cockpit's 110-column pane) and a RUNTIME
  # value besides. `refusal_width_discipline_spec.rb`'s own header records both
  # numbers and why the stricter one is the bar, and warns that inheriting the
  # ceiling silently is how a bar rots -- which is exactly what happened when
  # this card's lua sentences were first measured by hand against 98 and four
  # of them shipped over 80. There is an example below asserting that this 80
  # and that file's `BAR` are the same 80.
  BAR = 80

  # ⚠️ THE AMNESTY, AND THE TWO SENTENCES IT IS HOLDING. Turning this rule on
  # found lua rail sentences ALREADY over the budget -- none written by the
  # card that added the rule, and every one of them invisible until now,
  # because `refusal_width_discipline_spec.rb` is pure Ripper and reads only
  # Ruby. That is the finding, not a footnote: it is why the enforcement gap
  # mattered.
  #
  #   `65_review.lua`  162  `:LainReviewDone`'s wrong-buffer refusal -- MORE
  #                         THAN TWICE the budget, on the most ordinary refusal
  #                         there is. A human who types the verb in the wrong
  #                         buffer meets this one.
  #   `51_thread.lua`  131  the ask-failed refusal. This is the sentence the
  #                         plan CITED AS THE WORKED CONVERSION, the shape
  #                         every other site was told to copy -- and the
  #                         exemplar was itself twice over the bar.
  #
  # They are held rather than fixed because shortening a refusal is a WORDING
  # JUDGEMENT that earns its own review. The evidence is an experiment run
  # during this card and abandoned: cutting the 162-column sentence dropped
  # `:LainReviewVerdict` -- the REMEDY, the thing the sentence exists to tell
  # somebody -- and turned a pre-existing example red. A tail-end edit does not
  # reach that; a card with a panel does.
  #
  # ⚠️ THE AMNESTY IS PER SENTENCE, NEVER PER FILE. An earlier draft recorded a
  # per-file ceiling, and a per-file ceiling is an amnesty that admits sentences
  # nobody has ever read: a brand-new 120-column refusal added to
  # `65_review.lua` passed SILENTLY GREEN under it, which is this card's own
  # defect one level up -- a bar that cannot see the thing it exists to catch.
  # So an entry names its module, the OPENING OF THE SENTENCE, and the exact
  # width, and all three must match. Every other sentence in those files is
  # held to {BAR}, including a new one.
  #
  # ⚠️ EVERY ENTRY IS A DEBT, AND THE ONLY LEGAL EDIT IS DELETION. Shorten the
  # sentence and its entry stops matching, which turns the suite red until the
  # entry is removed -- `stale_amnesty` below is what says so. Widening a
  # number or loosening an opening to buy room for a new sentence is the one
  # thing this table must never be used for.
  #
  # Widths are of LITERAL text, so each is a lower bound on what a human reads.
  # Keyed by module WITHOUT its load-order prefix: a module renumbered by a
  # card that inserts a neighbour is the same module, and its debt should not
  # silently retire. That also keeps the thread pane's name out of CODE here,
  # which `thread_view_spec.rb`'s deletability census requires of every file
  # that is not an enumerated consumer of it.
  Amnesty = Struct.new(:module_name, :opening, :width)

  KNOWN_EXCEEDANCES = [
    Amnesty.new("review.lua", ":LainReviewDone needs an open EPIC review", 162),
    Amnesty.new("thread.lua", "nothing has been typed under the conversation", 131)
  ].freeze

  # One detected violation, with enough context to fix it without opening the
  # file first.
  Violation = Struct.new(:path, :line, :command, :detail) do
    def to_s = "#{path}:#{line} (:#{command}) -> #{detail}"
  end

  # A `define`d callback: the command it creates, and the token indices its
  # call spans.
  Callback = Struct.new(:command, :range)

  Token = Struct.new(:kind, :text, :line)

  # A Lua lexer, because the trigger words all appear in this runtime's prose.
  # `48_annotate.lua` alone writes `error(_, 0)` in three comments explaining
  # why a site raises the way it does, and a text scan reads every one of them
  # as the defect they document. Comments and string bodies are consumed and
  # dropped here, so nothing downstream can match inside one.
  class Lua
    NAME = /[A-Za-z_][A-Za-z0-9_]*/
    NUMBER = /0[xX]\h+|\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?/
    QUOTED = /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/m

    def initialize(source)
      @scanner = StringScanner.new(source)
      @line = 1
      @tokens = []
    end

    # @return [Array<Token>] every token but whitespace and comments
    def tokens
      read until @scanner.eos?
      @tokens
    end

    private

    def read
      blank = @scanner.scan(/\s+/)
      return advance(blank) if blank
      return if consumed_comment?

      literal = long_bracket || @scanner.scan(QUOTED)
      return record(:string, literal) if literal
      return record(:number, @scanner.matched) if @scanner.scan(NUMBER)
      return record(:name, @scanner.matched) if @scanner.scan(NAME)

      record(:punct, @scanner.getch)
    end

    def consumed_comment?
      return false unless @scanner.scan("--")

      advance("--")
      advance(long_bracket || @scanner.scan(/[^\n]*/))
      true
    end

    # Lua's long form -- `[[...]]`, `[==[...]==]` -- serves both strings and
    # comments, which is the whole reason this is a lexer and not a regexp.
    def long_bracket
      opener = @scanner.scan(/\[=*\[/)
      return nil if opener.nil?

      closer = "]#{"=" * (opener.length - 2)}]"
      opener + (@scanner.scan_until(/#{Regexp.escape(closer)}/) || @scanner.scan(/.*/m))
    end

    def record(kind, text)
      @tokens << Token.new(kind, text, @line)
      advance(text)
    end

    # A token's LINE is where it starts, so this runs after the token is
    # recorded and never before.
    def advance(text)
      @line += text.count("\n")
    end
  end

  # Reads one file's tokens for the three things this spec asserts: a refusal
  # leaving a `define`d callback by a door that is not the rail, a rail
  # sentence spelling the prefix the rail already prepends, and a rail sentence
  # over the column budget.
  # Pure token reading: "what is this token", "where does this call end".
  # Shared because both rules below need it and neither owns it -- {Doors} asks
  # which call this is, {Sentences} asks what it spells, and both have to agree
  # about where a call's parentheses close.
  module Reading
    PAREN = { "(" => 1, ")" => -1 }.freeze

    # A name qualified by either of these belongs to somebody else's table.
    QUALIFIERS = %w[. :].freeze

    # Lua spells a string three ways and all three reach the rail. Stripping
    # one leading and one trailing character handles the quoted forms; a LONG
    # bracket needs its whole delimiter taken off, and getting that wrong is
    # not cosmetic -- `[[...]]` would have measured 4 columns and walked
    # through both the budget check and the doubled-prefix check. No such
    # sentence exists today, which is exactly why it would have gone unnoticed.
    LONG_BRACKET = /\A\[(=*)\[(.*)\]\1\]\z/m

    # A call is a name with a `(` behind it. See the header for the call form
    # this misses.
    def call?(tokens, at) = tokens[at].kind == :name && tokens[at + 1]&.text == "("

    # A name nobody's table owns. This is what keeps `log.error(...)` and
    # `rail:error(...)` out: neither is lua's `error`, and a gate reaching for
    # a NAME rather than for a thing is one the next person disables.
    def unqualified?(tokens, at) = at.zero? || !QUALIFIERS.include?(tokens[at - 1].text)

    # True when this name is the one being DEFINED rather than called. Walks
    # back over any `a.b.c` qualification first, so it guards `function
    # define(...)` and `function _G.__lain.review_refused(...)` alike.
    def defined_here?(tokens, at)
      back = at
      back -= 2 while back > 1 && tokens[back - 1].text == "." && tokens[back - 2].kind == :name
      back.positive? && tokens[back - 1].text == "function"
    end

    # The index of the `)` closing the `(` at `from`. Bracket and brace pairs
    # nest inside it and hold no stray parenthesis, so parentheses alone are
    # counted.
    def closing(tokens, from)
      depth = 0
      found = tokens.each_index.drop(from).find do |at|
        depth += nesting(tokens[at])
        depth.zero?
      end
      raise "unbalanced call at #{path}:#{tokens[from].line}" if found.nil?

      found
    end

    def nesting(token) = token.kind == :punct ? PAREN.fetch(token.text, 0) : 0

    def unquoted(text)
      long = LONG_BRACKET.match(text)
      return long[2] if long

      text.sub(/\A["']/, "").sub(/["']\z/, "")
    end
  end

  # WHICH DOOR A REFUSAL LEAVES BY. Everything here is about the CALL -- is it
  # inside a `define`d callback, and is it one of the two doors that are not
  # the rail. Nothing here reads what the sentence says.
  class Doors
    include Reading

    # The two doors that are not the rail, and what each costs.
    OFF_RAIL = {
      "error" => "error() escapes the callback and wears nvim's traceback; " \
                 "send it out on _G.__lain.#{RAIL} and return",
      "notify" => "vim.notify() blocks at roughly #sentence + 12 > columns and is unfitted; " \
                  "send it out on _G.__lain.#{RAIL} and return"
    }.freeze

    attr_reader :path

    def initialize(path)
      @path = path
    end

    # @return [Array<Violation>]
    def violations(tokens)
      callbacks(tokens).flat_map { |callback| off_rail_in(tokens, callback) }
    end

    private

    def callbacks(tokens)
      tokens.each_index.select { |at| opens_define?(tokens, at) }.map { |at| callback_at(tokens, at) }
    end

    def callback_at(tokens, at)
      Callback.new(named(tokens[at + 2]), at..closing(tokens, at + 1))
    end

    # The command a `define` call creates. `plugin/nvim_plugin_spec.rb` reads
    # the same literal for the doc sweep, so a name assembled from a variable
    # is already refused one file over; here it degrades to a placeholder
    # rather than raising, because this spec's job is to name a LINE.
    def named(token)
      token&.kind == :string ? unquoted(token.text) : "?"
    end

    def opens_define?(tokens, at)
      return false unless call?(tokens, at) && unqualified?(tokens, at) && tokens[at].text == "define"

      # `local function define(...)` is the primitive itself, not a call of it.
      !defined_here?(tokens, at)
    end

    def off_rail_in(tokens, callback)
      callback.range.select { |at| off_rail?(tokens, at) }.map do |at|
        Violation.new(@path, tokens[at].line, callback.command, OFF_RAIL.fetch(tokens[at].text))
      end
    end

    def off_rail?(tokens, at)
      return false unless call?(tokens, at)

      bare_error?(tokens, at) || vim_notify?(tokens, at)
    end

    def bare_error?(tokens, at) = tokens[at].text == "error" && unqualified?(tokens, at)

    # `vim.notify(` IS qualified, so it is recognised BY its qualifier rather
    # than in spite of one: the two tokens in front are the whole distinction
    # between it and anybody else's `notify`.
    def vim_notify?(tokens, at)
      tokens[at].text == "notify" && at > 1 && tokens[at - 1].text == "." && tokens[at - 2].text == "vim"
    end
  end

  # WHAT THE SENTENCE SAYS, once it is already on the rail: does it spell the
  # prefix the rail prepends, and does it fit the budget. A separate object
  # from {Doors} because it applies to EVERY `review_refused` in the runtime,
  # inside a `define`d callback or not -- the two rules have different subject
  # sets, which is the clearest sign they are different rules.
  class Sentences
    include Reading

    attr_reader :path

    def initialize(path)
      @path = path
      # The module, independent of the load-order prefix a later card may
      # renumber. See {KNOWN_EXCEEDANCES}.
      @module = path.sub(/\A\d+_/, "")
    end

    # @return [Array<Violation>]
    def violations(tokens)
      rail_calls(tokens).flat_map { |at| [doubled_prefix(tokens, at), over_budget(tokens, at)].compact }
    end

    # Every rail sentence with its width, the amnesty's own view: what the
    # budget rule WOULD see with {KNOWN_EXCEEDANCES} empty. Public so the table
    # can be checked against the tree.
    #
    # @return [Array<Array(String, Integer)>] sentence, width
    def measured(tokens)
      rail_calls(tokens).map do |at|
        text = sentence_at(tokens, at)
        [text, PREFIX.length + text.length]
      end
    end

    private

    def rail_calls(tokens) = tokens.each_index.select { |at| rail_call?(tokens, at) }

    # `_G.__lain.review_refused(` at a CALL. `function _G.__lain.review_refused(message)`
    # is the definition and is excluded by name: {Doors#opens_define?} guards
    # its mirror case, and leaving this one to survive on "the next token
    # happens to be a name" was an accident waiting for a parameterless rail.
    def rail_call?(tokens, at)
      call?(tokens, at) && tokens[at].text == RAIL && !defined_here?(tokens, at)
    end

    def doubled_prefix(tokens, at)
      sentence = tokens[at + 2]
      return nil unless sentence&.kind == :string && unquoted(sentence.text).start_with?(PREFIX)

      Violation.new(@path, tokens[at].line, RAIL,
                    "the sentence spells #{PREFIX.inspect}, which #{RAIL} prepends -- drop it")
    end

    # The STATIC width of the sentence, with the prefix in front. Interpolated
    # values -- `.. kind ..`, `.. tostring(state)`, a buffer name -- render as
    # nothing, which is `refusal_width_discipline_spec.rb`'s own convention for
    # a field no bar can reach. So for a concatenation this is a LOWER BOUND
    # and the real sentence is wider; a closed-set vocabulary spliced in by
    # `table.concat` is bounded and known but not statically evaluable here,
    # and those sentences are pinned at their real width by the nvim-driven
    # examples in `annotate_spec.rb` and `review_view_spec.rb` instead. A
    # sentence that is a single literal is measured exactly.
    def over_budget(tokens, at)
      text = sentence_at(tokens, at)
      width = PREFIX.length + text.length
      return nil if width <= BAR || amnesty_for(text, width)

      Violation.new(@path, tokens[at].line, RAIL,
                    "#{width} columns of literal text against a #{BAR}-column budget -- shorten the sentence")
    end

    # The grandfathered entry covering this exact sentence, or nil. Matched on
    # the SENTENCE and its width, never on the file: a file is not an amnesty.
    def amnesty_for(text, width)
      KNOWN_EXCEEDANCES.find do |entry|
        entry.module_name == @module && entry.width == width && text.start_with?(entry.opening)
      end
    end

    # The widest thing this call can put on screen. Every string literal
    # between its parentheses, joined -- except that a lua `cond and "A" or
    # "B"` chooses ONE of its branches, so alternatives are compared rather
    # than summed. Without that, `51_thread.lua`'s two-branch refusal measured
    # 87 -- the sum of a 62-column sentence and a 28-column one, neither of
    # which is over the bar and neither of which any human can see at once.
    # An over-count is a false RED rather than a false green, so it was never
    # a safety hole; it would have put a phantom entry in the amnesty table,
    # which is worse -- a grandfathered sentence that does not exist.
    def sentence_at(tokens, at)
      alternatives(tokens, (at + 1)..closing(tokens, at + 1)).max_by(&:length) || ""
    end

    # The argument split on its top-level `or`s, each branch's literals joined.
    def alternatives(tokens, range)
      depth = 0
      range.each_with_object([+""]) do |inner, branches|
        token = tokens[inner]
        depth += nesting(token)
        branches << +"" if alternation?(token, depth)
        branches.last << unquoted(token.text) if token.kind == :string
      end
    end

    # Depth 1 is the rail call's OWN parentheses, so an `or` there separates two
    # whole sentences. Deeper, it belongs to a subexpression and its operands
    # are parts of one sentence rather than alternatives to it.
    def alternation?(token, depth) = depth == 1 && token.kind == :name && token.text == "or"
  end

  # One file, read once, by both rules.
  class Scanner
    def initialize(path)
      @doors = Doors.new(path)
      @sentences = Sentences.new(path)
    end

    # @return [Array<Violation>]
    def scan(source)
      tokens = Lua.new(source).tokens
      @doors.violations(tokens) + @sentences.violations(tokens)
    end

    # @return [Array<Array(String, Integer)>] sentence, width
    def sentences(source) = @sentences.measured(Lua.new(source).tokens)
  end

  module_function

  # The head and every module, which is exactly the chunk the loader injects.
  def sources
    head = Pathname(Lain::Frontend::Neovim::RuntimeLoader::HEAD)
    [head, *Pathname(Lain::Frontend::Neovim::RuntimeLoader::MODULES).glob("*.lua").sort]
  end

  # @return [Array<Violation>] every violation across the injected runtime
  def violations
    sources.flat_map { |file| Scanner.new(file.basename.to_s).scan(file.read) }
  end

  # Every rail sentence in the tree that is over {BAR}, with the module it sits
  # in -- computed with the amnesty ignored. This is what makes
  # {KNOWN_EXCEEDANCES} checkable against the code rather than against a
  # reader's memory of when it was last true.
  #
  # @return [Array<Array(String, String, Integer)>] module, sentence, width
  def exceedances
    sources.flat_map do |file|
      mod = file.basename.to_s.sub(/\A\d+_/, "")
      Scanner.new(file.basename.to_s).sentences(file.read)
             .filter_map { |text, width| [mod, text, width] if width > BAR }
    end
  end

  # Amnesty entries that no longer match anything in the tree. An entry goes
  # stale the moment its sentence is shortened, and a stale entry is a bar
  # quietly raised for nothing -- so this is asserted empty, which is what
  # makes the debt DELETE itself rather than linger.
  #
  # @return [Array<Amnesty>]
  def stale_amnesty
    KNOWN_EXCEEDANCES.reject do |entry|
      exceedances.any? do |mod, text, width|
        mod == entry.module_name && width == entry.width && text.start_with?(entry.opening)
      end
    end
  end
end

RSpec.describe "refusal delivery discipline" do
  it "refuses on the rail in every define()d user-command callback" do
    violations = RefusalDeliveryDiscipline.violations

    expect(violations).to be_empty, lambda {
      listing = violations.map { |violation| "  #{violation}" }.join("\n")
      "A user command refuses on the rail, never by raising and never by notifying, " \
        "and it fits. Both other doors raise nvim's hit-enter prompt -- one by " \
        "traceback, one by width -- and every non-fast RPC request queues behind it, " \
        "so the editor answers nothing at all while the refusal is on screen. " \
        "Found:\n#{listing}\n" \
        "Hand the sentence to _G.__lain.review_refused (runtime/65_review.lua:236) and " \
        "return, dropping the 'lain: ' prefix -- the rail prepends it."
    }
  end

  # THE AMNESTY DELETES ITSELF. An entry stops matching the moment its sentence
  # is shortened, and this is what turns that into a red run rather than into a
  # bar quietly held open for a file nobody is looking at.
  it "keeps no amnesty entry for a sentence that is no longer over the bar" do
    stale = RefusalDeliveryDiscipline.stale_amnesty

    expect(stale).to be_empty, lambda {
      "these amnesty entries match nothing in the tree. If the sentence was shortened, " \
      "DELETE the entry -- an entry left behind is a budget quietly raised. Stale:\n" +
        stale.map { |entry| "  #{entry.module_name} #{entry.width} #{entry.opening.inspect}" }.join("\n")
    }
  end

  # The bar is a budget somebody chose, so two copies of it is two bars. This
  # reads the sibling's SOURCE rather than its constant so a single-file run
  # asserts it too -- referencing `RefusalWidthDiscipline::BAR` directly would
  # be a NameError whenever this file runs alone, which is the documented inner
  # loop.
  #
  # THE COUPLING IS TO A SPELLING, and that is a known cost: a trailing comment
  # on that file's `BAR = 80` breaks this match. It breaks LOUDLY and in one
  # place, which is the trade -- if it fires, widen the pattern here rather than
  # copying the number, because a copied number is the failure this whole rule
  # exists to stop.
  it "shares one bar with refusal_width_discipline_spec.rb rather than keeping a second copy of 80" do
    sibling = Pathname(__dir__).join("refusal_width_discipline_spec.rb")

    expect(sibling.read).to match(/^\s*BAR = #{RefusalDeliveryDiscipline::BAR}$/o)
  end

  it "reads the whole injected chunk, so a new module cannot arrive unscanned" do
    names = RefusalDeliveryDiscipline.sources.map { |path| path.basename.to_s }

    expect(names).to include("runtime.lua", "30_commands.lua", "48_annotate.lua")
    expect(names.length).to be > 20
  end

  it "flags an error() inside a define()d callback (self-test)" do
    source = <<~LUA
      define("LainNote", function(opts)
        if opts == nil then
          error("lain: :LainNote needs a buffer", 0)
        end
      end, { nargs = "+" })
    LUA

    found = RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)

    expect(found.map { |violation| [violation.line, violation.command] }).to eq([[3, "LainNote"]])
  end

  it "flags a vim.notify() inside a define()d callback (self-test)" do
    source = <<~LUA
      define("LainPin", function()
        if vim.api.nvim_buf_get_name(0) ~= TIMELINE then
          vim.notify("lain: :LainPin pins the turn under the cursor", vim.log.levels.WARN)
          return
        end
      end)
    LUA

    found = RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)

    expect(found.map { |violation| [violation.line, violation.command] }).to eq([[3, "LainPin"]])
  end

  # A qualified name is somebody else's method. Both spellings of qualification
  # are guarded, because lua has two.
  it "does not flag a qualified error() that is not lua's (self-test)" do
    source = <<~LUA
      define("LainPin", function()
        log.error("a diagnostic, not a refusal")
        rail:error("nor is this one")
        watcher.notify("something happened")
        notify("and so did this")
      end)
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  # The boundary this gate would be disabled for getting wrong. An RPC entry
  # point ANSWERS its request by raising; converting one would throw away the
  # only channel it has.
  it "does not flag an error() in an _G.__lain RPC entry point (self-test)" do
    source = <<~LUA
      function _G.__lain.set_thread(anchor)
        if anchor == nil then
          error("lain: set_thread needs an anchor", 0)
        end
      end

      define("LainThread", function()
        _G.__lain.set_thread(nil)
      end)
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  # The gap named in the module comment, asserted so it stays a decision rather
  # than becoming a surprise.
  it "does not flag a helper the callback calls (self-test)" do
    source = <<~LUA
      local function assert_saved()
        error("save before settling its notes", 0)
      end

      define("LainNoteDone", function()
        local ok, refusal = pcall(assert_saved)
        if not ok then
          _G.__lain.review_refused(refusal)
        end
      end)
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  # The SECOND gap, and the one a reader is likeliest to mistake for coverage:
  # `50_request.lua:30-31`'s real shape. The factory's body is not lexically
  # inside the `define`, so a refusal grown inside it would pass this gate.
  it "sees nothing of a callback built by a factory (self-test)" do
    source = <<~LUA
      local function agent_command(name)
        return function()
          error("a refusal this gate cannot see", 0)
        end
      end

      define("LainSend", agent_command("send"))
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  it "does not flag error() inside a comment or a string (self-test)" do
    source = <<~LUA
      define("LainNote", function()
        -- `error(msg, 0)` still wears a traceback, which is why this refuses instead.
        --[==[ error("a long comment", 0) ]==]
        _G.__lain.review_refused("the word error(  in a sentence is not a call")
      end)
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  it "does not mistake the define primitive itself for a call of it (self-test)" do
    source = <<~LUA
      local function define(name, fn, opts)
        if name == nil then error("define needs a name", 0) end
        vim.api.nvim_create_user_command(name, fn, opts or {})
      end
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  it "flags a rail sentence that spells the prefix the rail prepends (self-test)" do
    source = <<~LUA
      define("LainPin", function()
        _G.__lain.review_refused("lain: :LainPin needs the timeline")
      end)
    LUA

    found = RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)

    expect(found.map(&:line)).to eq([2])
  end

  it "leaves an unprefixed rail sentence alone (self-test)" do
    source = <<~LUA
      define("LainPin", function()
        _G.__lain.review_refused(":LainPin needs the timeline")
      end)
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  it "does not read the rail's own definition as a call of it (self-test)" do
    source = <<~LUA
      function _G.__lain.review_refused(message)
        local full = "lain: " .. tostring(message)
        vim.api.nvim_echo({ { full, "WarningMsg" } }, true, {})
      end
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  it "flags a rail sentence over the column budget (self-test)" do
    long = "x" * (RefusalDeliveryDiscipline::BAR - RefusalDeliveryDiscipline::PREFIX.length + 1)
    source = <<~LUA
      define("LainPin", function()
        _G.__lain.review_refused("#{long}")
      end)
    LUA

    found = RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)

    expect(found.map(&:detail)).to contain_exactly(a_string_including("81 columns of literal text"))
  end

  # THE PANEL'S OWN DEMONSTRATION, and the reason the amnesty is keyed on the
  # sentence: under the per-file ceiling this draft started with, this example
  # passed. A file is not an amnesty.
  it "flags a NEW over-budget sentence in a file that has a grandfathered one (self-test)" do
    source = <<~LUA
        define("LainReviewDone", function()
          _G.__lain.review_refused(":LainReviewDone needs an open EPIC review, and this buffer is not one -- " ..
      "a changeset review or a survey hands back with :LainReviewVerdict {verdict} instead")
          _G.__lain.review_refused("#{"y" * 75}")
        end)
    LUA

    found = RefusalDeliveryDiscipline::Scanner.new("65_review.lua").scan(source)

    expect(found.map(&:line)).to eq([4])
    expect(found.map(&:detail)).to contain_exactly(a_string_including("81 columns"))
  end

  # The other direction: the grandfathered sentence itself still passes, so the
  # amnesty is real until somebody fixes it.
  it "lets the grandfathered sentence through untouched (self-test)" do
    source = <<~LUA
        define("LainReviewDone", function()
          _G.__lain.review_refused(":LainReviewDone needs an open EPIC review, and this buffer is not one -- " ..
      "a changeset review or a survey hands back with :LainReviewVerdict {verdict} instead")
        end)
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("65_review.lua").scan(source)).to be_empty
  end

  # And the amnesty does not travel: the same sentence in another module is
  # over the bar there, because an entry names the module it forgave.
  it "does not carry a grandfathered sentence into another module (self-test)" do
    source = <<~LUA
        define("LainPin", function()
          _G.__lain.review_refused(":LainReviewDone needs an open EPIC review, and this buffer is not one -- " ..
      "a changeset review or a survey hands back with :LainReviewVerdict {verdict} instead")
        end)
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("75_timeline.lua").scan(source)).not_to be_empty
  end

  # A lua `cond and "A" or "B"` puts ONE branch on screen, so the branches are
  # compared rather than summed. Summing them invented an 87-column sentence in
  # `51_thread.lua` out of a 62 and a 28 -- a false red, and very nearly a
  # phantom entry in the amnesty table above.
  it "measures a two-branch refusal by its widest branch, not by both (self-test)" do
    source = <<~LUA
      define("LainThread", function()
        _G.__lain.review_refused(held
          and "#{"a" * 60}"
          or "#{"b" * 60}")
      end)
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  # A lua LONG-BRACKET sentence. Before `unquoted` learned the form, `[[...]]`
  # measured 4 columns -- one character stripped from each end -- so a refusal
  # written this way evaded the budget AND the doubled-prefix check at once.
  it "measures a long-bracket sentence by its contents (self-test)" do
    source = <<~LUA
      define("LainPin", function()
        _G.__lain.review_refused([[#{"z" * 75}]])
      end)
    LUA

    found = RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)

    expect(found.map(&:detail)).to contain_exactly(a_string_including("81 columns"))
  end

  it "sees the prefix inside a long-bracket sentence too (self-test)" do
    source = <<~LUA
      define("LainPin", function()
        _G.__lain.review_refused([[lain: :LainPin needs the timeline]])
      end)
    LUA

    found = RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)

    expect(found.map(&:detail)).to contain_exactly(a_string_including("prepends"))
  end

  it "measures a concatenation by its literal parts only (self-test)" do
    source = <<~LUA
      define("LainPin", function()
        _G.__lain.review_refused("a short frame -- " .. some_unbounded_value)
      end)
    LUA

    expect(RefusalDeliveryDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end
end
