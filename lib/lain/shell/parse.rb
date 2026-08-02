# frozen_string_literal: true

module Lain
  module Shell
    # One bash command, as tree-sitter's grammar sees it -- and, just as
    # importantly, the parts of it tree-sitter did NOT see.
    #
    # This object reports; it never judges. It says "these are the stages, this
    # is the argv, these node kinds are present, these bytes nothing accounted
    # for". Whether any of that is acceptable is a separate object's question,
    # and even that one answers "literal and fully understood", never "safe".
    #
    # == The three signals, and why there are three
    #
    # 1. *Broken.* An ERROR or a MISSING node. Both, in ONE query --
    #    tree-sitter's `(ERROR)` pattern does not match MISSING nodes, and
    #    `has_error()` alone has already been measured letting `")"`, `"def"`,
    #    `"1 +"` and `"[1,"` through as silent zero-matches
    #    (`ext/lain/src/astgrep.rs:78-96`).
    # 2. *Uncovered bytes.* Every non-whitespace byte must sit inside a span this
    #    parser recognizes. This is the signal that does not depend on the
    #    grammar admitting a mistake: tree-sitter-bash#315 parses `$FOO/$BAR/`
    #    into a corrupted `command_name` of `"$FOO/$"` with zero ERROR and zero
    #    MISSING nodes, and only the swallowed `$` at byte 5 gives it away.
    # 3. *Kinds and separators.* The vocabulary a verdict allowlists over.
    #
    # A refusal -- over the length cap, or anything raising out of the ext -- is
    # reported as broken AND as not covered. Nothing was parsed, so claiming
    # coverage would be the vacuous success this whole layer exists to avoid.
    #
    # == What coverage does NOT guarantee
    #
    # Coverage catches an anonymous keyword only where the grammar *lexes* it as
    # one. It is NOT a general "compound syntax cannot hide here" guarantee, and
    # a verdict must not treat a kind allowlist over {KINDS} as total.
    #
    # tree-sitter-bash does not model `time` as a keyword. A leading command word
    # the grammar does not know degrades its whole tail to plain `word` nodes in
    # an ordinary `command`, and that reaches FULL coverage with the blandest
    # possible kind set:
    #
    #   "time { echo PWNED; }"       => not broken, fully covered, kinds are
    #                                   program/command/command_name/word only
    #   "time if true; then ls; fi"  => the same; `if`, `then` and `fi` all
    #                                   arrive as ordinary words
    #   "time rm -rf /tmp/x"         => the same, and its argv execs faithfully
    #
    # Only `time (echo hi)` is caught, and only because a subshell's parentheses
    # are still anonymous.
    #
    # `time` is not alone. Swept as a leading token, twelve of bash's reserved
    # words reach covered-and-unbroken: `}`, `coproc`, `do`, `done`, `elif`,
    # `else`, `esac`, `fi`, `in`, `then`, `time`, `]]`. `coproc` is the other one
    # worth naming, because bash really does run its argument -- it is benign
    # here only by accident, since no `coproc` binary exists so a reconstructed
    # argv dies with ENOENT, whereas `/usr/bin/time` exists and executes.
    #
    # And it is not only the LEADING stage. `echo hi; time { rm x; }`,
    # `ls | time rm x` and `true && time rm -rf /tmp/x` are all fully covered
    # with `time` as the head of a later stage, so a name check must read
    # EVERY stage's `argv.first`, never just the first stage's.
    #
    # So the residual risk is a *program name*, and a program name is a
    # judgement -- it belongs to the layer above, as a name denylist alongside
    # `nice`, `timeout`, `nohup`, `setsid`, `stdbuf` and `watch`. Putting a
    # "suspicious leading word" heuristic in here would be precisely the
    # comforting lie {Lain::Tool::Input} argues against.
    #
    # == What the argv is, and is not
    #
    # It is the tree's word splitting, and none of a shell's interpretation.
    # Whoever executes it owns these four:
    #
    # * *Quotes survive.* `echo 'a b'` reconstructs as `["echo", "'a b'"]`, not
    #   `["echo", "a b"]` -- the term is the `raw_string`/`string` node's text
    #   verbatim. Dequoting is interpretation, so it is not done here.
    # * *A redirection is a term when it sits inside the command node, and is
    #   dropped when it does not.* `> out echo hi` yields `["> out", "echo",
    #   "hi"]`, while `echo a >b c` yields `["echo", "a"]` -- `c` belongs to the
    #   enclosing `redirected_statement` and is GONE from the argv. `kinds`
    #   reporting `file_redirect` or `redirected_statement` is the only reliable
    #   tell; there is no reading of the argv alone that recovers it.
    # * *A heredoc body is blanketed, not tokenised.* `heredoc_redirect` spans
    #   the delimiter and the body together, so "covered" there means "we saw a
    #   heredoc", not "we understood these bytes".
    # * *A NUL byte parses clean* into an ordinary word, and `exec` refuses it.
    #
    # A `command` lying inside a terminal span -- the `id` of `FOO=$(id)` -- is
    # that span's innards, not a stage, and is dropped. That is what keeps
    # {Stage#argv} from coming back empty on a caller that would then hand `[]`
    # to `Open3`.
    class Parse
      LANGUAGE = "bash"

      # Cap the input before parsing, not after. `AstGrep.dump` truncates at
      # 64 KiB, which is how 84 KB of padding followed by `echo $(id)` yields a
      # dump with no `command_substitution` in it; this path uses `query`, which
      # does not truncate, but the cap stays because a refusal must never be
      # reachable by making the input bigger. 4 KiB is orders of magnitude above
      # any command a model realistically writes.
      MAX_BYTES = 4096

      # Kinds whose byte span this parser claims to understand end to end. A
      # kind belongs here only if its span is what its children tile, or if it is
      # delimited -- a quote, a `$(...)` -- so nothing can hide inside it.
      #
      # `concatenation` and `command_name` are deliberately ABSENT even though
      # both are queried below: on tree-sitter-bash#315 they span bytes their
      # children do not, so counting them as coverage is exactly what would hide
      # the corruption.
      TERMINAL_KINDS = %w[
        word number raw_string string ansi_c_string translated_string comment
        simple_expansion expansion command_substitution process_substitution
        arithmetic_expansion variable_assignment file_redirect heredoc_redirect
      ].freeze

      # Kinds that group adjacent terminals into ONE argv term without counting
      # as coverage. `{}` in `find . -exec rm {} +` lexes as the two words `{`
      # and `}` under one `concatenation`, and a shell passes it as the single
      # argument `{}` -- reconstructing two arguments there is argv corruption on
      # a parse that reported no error at all. Grouping fixes that while leaving
      # the #315 detection intact, because coverage still ignores the
      # concatenation's own span and so still sees the `$` it swallowed.
      GROUP_KINDS = %w[concatenation].freeze

      # Reported so a verdict can allowlist over them, but never counted as
      # coverage -- a container's span may exceed the union of its children.
      CONTAINER_KINDS = %w[
        program list pipeline command command_name subshell
        redirected_statement compound_statement function_definition
        if_statement while_statement for_statement case_statement
        negated_command test_command declaration_command unset_command
      ].freeze

      KINDS = (TERMINAL_KINDS + GROUP_KINDS + CONTAINER_KINDS).freeze

      # The operators this parser recognizes as structure. Anything else joining
      # two commands is an anonymous token nothing covers, so it surfaces as an
      # uncovered byte rather than as a silently accepted separator.
      OPERATORS = ["|", "||", "&&", ";", "&"].freeze

      COMMAND = "command"
      SEPARATOR = "separator"

      # One query, one compilation, one FFI crossing (~2.7 ms measured). The
      # ERROR/MISSING alternation is first and carries two capture names, so a
      # caller can tell which of the two fired.
      QUERY = [
        "[(ERROR) @error (MISSING) @missing]",
        *KINDS.map { |kind| "(#{kind}) @#{kind}" },
        "[#{OPERATORS.map(&:inspect).join(" ")}] @#{SEPARATOR}"
      ].join("\n").freeze

      private_constant :COMMAND, :SEPARATOR

      # Why a parse cannot be trusted. `:error_node` and `:missing_node` name
      # which of the two tree-sitter signals fired; `:too_long` and
      # `:unparseable` mean no tree was produced at all.
      Breakage = Data.define(:kind, :detail)

      # One command in a pipeline or list, with its argv reconstructed from the
      # outermost terminal spans lying inside it. A caller runs THIS, never the
      # original string -- re-running an accepted string through `sh -c` turns
      # every parser/shell disagreement into a live bypass.
      Stage = Data.define(:argv, :byte_range)

      # An operator, and WHERE it sits. Counting cannot tell a caller which stage
      # is downstream of a pipe -- `ls &` is one stage and one separator, and
      # `time { echo a; } | wc` is three stages and `[";", "|"]` -- so the byte
      # range is the only thing that orders the two lists against each other.
      Separator = Data.define(:text, :byte_range)

      Result = Data.define(:source, :stages, :kinds, :separators, :uncovered, :breakages) do
        # The grammar reported a defect, or nothing could be parsed at all.
        def broken? = !breakages.empty?

        # Every non-whitespace byte sat inside a span this parser recognizes.
        #
        # Not the negation of {#broken?}: a command can parse without complaint
        # and still leave bytes unaccounted for, which is the whole point of
        # #315. The implication runs one way only -- a parse that did not happen
        # accounted for nothing, so a broken Result is never covered, and there
        # is no state in which a refusal reads as a vacuous success.
        def covered? = breakages.empty? && uncovered.empty?
      end

      # Interpolation returns a MUTABLE String even under a frozen_string_literal
      # magic comment, and this Breakage is a shared constant -- an unfrozen
      # detail here is one `<<` away from poisoning every later parse in the
      # process. Same trap as `Symbol#to_s`, same fix.
      TOO_LONG = Breakage.new(kind: :too_long, detail: "over the #{MAX_BYTES}-byte cap".freeze)

      def initialize
        freeze
      end

      # @param command [String]
      # @return [Result] never raises, for ANY argument. Every failure mode lands
      #   as a Breakage, because a raise escaping here becomes an agent-visible
      #   crash. The outer rescue covers the argument itself -- `#dup` and
      #   `#bytesize` are messages a non-String does not answer, and `call(nil)`
      #   has to be a refusal rather than a NoMethodError.
      def call(command)
        source = command.dup.freeze
        return refused(source, TOO_LONG) if source.bytesize > MAX_BYTES

        read(source)
      rescue StandardError => e
        refused(NOTHING, unparseable(e))
      end

      private

      # The source a refusal reports when the argument was never usable as one.
      NOTHING = ""
      private_constant :NOTHING

      def read(source)
        Reading.new(source, Ext::TreeSitter.query(source, LANGUAGE, QUERY)).result
      rescue StandardError => e
        refused(source, unparseable(e))
      end

      def unparseable(error)
        Breakage.new(kind: :unparseable, detail: "#{error.class}: #{error.message}".freeze)
      end

      # Nothing was parsed, so nothing is covered. Reporting an empty `uncovered`
      # here would read as "every byte accounted for", which is the vacuous
      # success a refusal must never look like.
      def refused(source, breakage)
        Result.new(source:, stages: [].freeze, kinds: [].freeze, separators: [].freeze,
                   uncovered: Reading.runs((0...source.bytesize).to_a), breakages: [breakage].freeze)
      end

      # The flat capture list, read as a tree. {Ext::TreeSitter} returns captures
      # with no per-match grouping, so every structural question here is answered
      # by byte-range containment rather than by walking nodes -- which is why
      # this needs no new ext capability.
      #
      # Separate from {Parse} because the two answer different questions: Parse
      # owns the policy (the cap, the refusal, the promise never to raise), and
      # this owns reading one tree that already parsed.
      class Reading
        # Bytes a shell treats as separation between words. `\n` is here rather
        # than in {OPERATORS} because tree-sitter-bash has no anonymous `"\n"`
        # node to query -- it lexes newline as whitespace.
        BLANK_BYTES = " \t\n\r\f\v".bytes.freeze

        Span = Data.define(:range, :text) do
          def contains?(other) = range.begin <= other.range.begin && other.range.end <= range.end
        end

        private_constant :BLANK_BYTES, :Span

        # Consecutive byte indexes, merged into the spans a human reads.
        def self.runs(indexes)
          indexes.chunk_while { |left, right| right == left + 1 }
                 .map { |run| run.first...(run.last + 1) }
                 .freeze
        end

        def initialize(source, captures)
          @source = source
          @spans = captures.group_by { |capture| capture.fetch("name") }.transform_values do |group|
            group.map { |capture| Span.new(capture.fetch("start")...capture.fetch("end"), capture.fetch("text")) }
          end
          freeze
        end

        def result
          Result.new(source: @source, stages:, kinds:, separators:, uncovered:, breakages:)
        end

        private

        # What argv is built from: terminals, with a concatenation preferred over
        # the pieces it joins.
        def terms = outermost(spans_for(TERMINAL_KINDS + GROUP_KINDS))

        # What coverage is built from: terminals ONLY. A group's span may exceed
        # the union of its children, which is precisely the #315 tell.
        def covering = spans_for(TERMINAL_KINDS)

        def spans_for(kinds) = @spans.values_at(*kinds).compact.flatten

        def kinds = @spans.keys.intersection(KINDS).sort.freeze

        def separator_spans = ordered(@spans.fetch(SEPARATOR, []))

        def separators
          separator_spans.map { |span| Separator.new(text: span.text, byte_range: span.range) }.freeze
        end

        def breakages
          %w[error missing].select { |name| @spans.key?(name) }.map do |name|
            Breakage.new(kind: :"#{name}_node", detail: "tree-sitter reported a #{name.upcase} node".freeze)
          end.freeze
        end

        # A stage is a top-level `command`: one that is neither nested in another
        # command nor swallowed by a terminal. The second half is what keeps an
        # argv from coming back EMPTY -- the `id` of `FOO=$(id)` is a command
        # node sitting inside a `variable_assignment`, and reporting it as a
        # stage hands `[]` to whatever runs the pipeline.
        # Containment must be STRICT here: a one-word command shares its exact
        # range with the `word` that spells it, and `wc` is a stage, not a word
        # swallowed by a terminal.
        def top_level_commands
          nested = covering
          outermost(@spans.fetch(COMMAND, [])).reject do |command|
            nested.any? { |span| span.range != command.range && span.contains?(command) }
          end
        end

        def stages
          words = terms
          ordered(top_level_commands).map do |command|
            argv = ordered(words.select { |word| command.contains?(word) })
            Stage.new(argv: argv.map(&:text).freeze, byte_range: command.range)
          end.freeze
        end

        def uncovered = self.class.runs(gaps(covered_bytes))

        def covered_bytes
          (covering + separator_spans).each_with_object(Array.new(@source.bytesize, false)) do |span, covered|
            span.range.each { |byte| covered[byte] = true }
          end
        end

        def gaps(covered)
          @source.each_byte.with_index
                 .reject { |byte, index| covered[index] || BLANK_BYTES.include?(byte) }
                 .map(&:last)
        end

        # Spans nested inside another span of the same set are that span's
        # innards, not its siblings: `$(id)` is one term, not `$(id)` plus `id`.
        def outermost(spans)
          distinct = spans.uniq(&:range)
          distinct.reject do |span|
            distinct.any? { |other| other.range != span.range && other.contains?(span) }
          end
        end

        def ordered(spans) = spans.sort_by { |span| span.range.begin }
      end

      private_constant :Reading
    end
  end
end
