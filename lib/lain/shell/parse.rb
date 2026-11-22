# frozen_string_literal: true

module Lain
  module Shell
    # One bash command, as tree-sitter's grammar sees it -- and, just as
    # importantly, the parts of it tree-sitter did NOT see.
    #
    # This object reports; it never judges. It says "these are the stages, this
    # is the argv, these node kinds are present, these bytes nothing accounted
    # for". Whether any of that is acceptable is {Shell::Verdict}'s question,
    # and even that one answers "literal and fully understood", never "safe".
    #
    # The three signals it carries, what coverage does NOT guarantee (the `time`
    # sweep), and the four argv caveats an executing layer inherits are argued in
    # docs/devs/architecture.md's "Triaging a bash command". Two of those consequences are
    # load-bearing in this file:
    #
    # * A refusal -- over the length cap, or anything raising out of the ext --
    #   is reported as broken AND as not covered. Nothing was parsed, so claiming
    #   coverage would be the vacuous success this whole layer exists to avoid.
    # * A `command` lying inside a terminal span -- the `id` of `FOO=$(id)` --
    #   is that span's innards, not a stage, and is dropped. That is what keeps
    #   {Stage#argv} from coming back empty on a caller that would then hand `[]`
    #   to `Open3`.
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

      SPACING = /\A[ \t]+\z/
      private_constant :SPACING

      COMMAND = "command"
      SEPARATOR = "separator"
      KEYWORD = "keyword"
      REDIRECT = "file_redirect"
      DESCRIPTOR = "redirect_descriptor"
      TARGET = "redirect_target"
      ASSIGNMENT = "variable_assignment"
      HEREDOC = "heredoc_redirect"
      HEREDOC_START = "heredoc_start"
      HEREDOC_OPERATOR = /\A<<-?/

      # The compound statements whose keywords count as coverage, each placed by
      # its parent node. A for loop's are left out, because the loop reading
      # matches its source text against exactly those uncovered bytes.
      COMPOUND_KINDS = %w[subshell compound_statement while_statement if_statement].freeze
      KEYWORDS = [
        '(while_statement ["while" "until"] @KEY)', '(while_statement body: (do_group "do" @KEY "done" @KEY))',
        '(subshell "(" @KEY ")" @KEY)', '(compound_statement "{" @KEY "}" @KEY)',
        '(if_statement "if" @KEY "then" @KEY "fi" @KEY)', '(elif_clause "elif" @KEY "then" @KEY)',
        '(else_clause "else" @KEY)'
      ].map { _1.gsub("KEY", KEYWORD) }.freeze

      # One query, compiled once per thread by the extension, one FFI crossing. The
      # ERROR/MISSING alternation is first and carries two capture names, so a
      # caller can tell which of the two fired.
      QUERY = [
        "[(ERROR) @error (MISSING) @missing]",
        *KINDS.map { |kind| "(#{kind}) @#{kind}" },
        "[#{OPERATORS.map(&:inspect).join(" ")}] @#{SEPARATOR}",
        "(#{REDIRECT} descriptor: (file_descriptor) @#{DESCRIPTOR})",
        "(#{REDIRECT} destination: (_) @#{TARGET})",
        "(#{HEREDOC} (#{HEREDOC_START}) @#{HEREDOC_START})",
        *KEYWORDS
      ].join("\n").freeze

      private_constant :COMMAND, :SEPARATOR, :KEYWORD, :KEYWORDS, :REDIRECT, :DESCRIPTOR, :TARGET, :ASSIGNMENT,
                       :HEREDOC, :HEREDOC_START, :HEREDOC_OPERATOR

      # Why a parse cannot be trusted. `:error_node` and `:missing_node` name
      # which of the two tree-sitter signals fired; `:too_long` and
      # `:unparseable` mean no tree was produced at all.
      Breakage = Data.define(:kind, :detail)

      # One command in a pipeline or list, with its argv reconstructed from the
      # outermost terminal spans lying inside it. A caller runs THIS, never the
      # original string -- re-running an accepted string through `sh -c` turns
      # every parser/shell disagreement into a live bypass.
      Stage = Data.define(:argv, :byte_range, :redirects)

      # A `file_redirect`, in parts. `descriptor` is empty when none was
      # written, and `extra_words` are what the grammar folds into the redirect
      # after its target: `b` in `echo a >/dev/null b`, which bash passes to
      # `echo` and {Stage#argv} does not.
      Redirect = Data.define(:text, :descriptor, :operator, :target, :extra_words, :byte_range)

      # An operator, and WHERE it sits. Counting cannot tell a caller which stage
      # is downstream of a pipe -- `ls &` is one stage and one separator, and
      # `time { echo a; } | wc` is three stages and `[";", "|"]` -- so the byte
      # range is the only thing that orders the two lists against each other.
      Separator = Data.define(:text, :byte_range)

      # A heredoc, by its operator, its delimiter as written, the rest of the
      # line after it, and each line after that up to the one the grammar ended
      # it on. The grammar folds into the heredoc whatever shares that line, a
      # word or a whole command after `&&`, so neither shows up as a stage.
      Heredoc = Data.define(:operator, :delimiter, :rest_of_line, :lines, :byte_range)

      # A subshell, brace group, while or until loop, or if, by its node kind.
      Compound = Data.define(:kind, :byte_range)

      # `redirects` is every redirect, including one no stage owns, such as a
      # redirect after a dangling `&&`; `assignments` the byte range of every
      # outermost `NAME=value`, inside a stage or standing alone; `compounds`
      # every {Compound}, in source order.
      Result = Data.define(:source, :stages, :kinds, :separators, :redirects, :heredocs, :assignments, :compounds,
                           :uncovered, :breakages) do
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

        # Every redirect belongs to a stage and sits after what precedes it with
        # only spaces or tabs between. Touching, `0>` is a descriptor to bash
        # and the word `0` to the grammar; across a newline, bash runs it as a
        # command of its own; and a leading redirect has no gap after its stage.
        #
        # @yield [redirect, index] required, so a forgotten block fails on every
        #   command rather than only on the first one carrying a redirect
        # @yieldparam redirect [Redirect] each placed one
        # @yieldparam index [Integer] the index of the stage that owns it
        # @yieldreturn [Boolean] whether the caller accepts that redirect
        # @return [Boolean]
        # @raise [ArgumentError] when no block is given
        def redirects_placed?(&accept)
          raise ArgumentError, "redirects_placed? needs a block that accepts each redirect" unless accept

          stages.sum { _1.redirects.size } == redirects.size &&
            stages.each_with_index.all? { |stage, index| stage_placed?(stage, index, &accept) }
        end

        private

        def stage_placed?(stage, index)
          afters = [stage.byte_range.end, *stage.redirects.map { _1.byte_range.end }]
          stage.redirects.zip(afters).all? { |redirect, after| spaced?(after, redirect) && yield(redirect, index) }
        end

        def spaced?(after, redirect) = SPACING.match?(source.byteslice(after...redirect.byte_range.begin))
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
        Result.new(source:, stages: [].freeze, kinds: [].freeze, separators: [].freeze, redirects: [].freeze,
                   heredocs: [].freeze, assignments: [].freeze, compounds: [].freeze,
                   uncovered: Reading.runs((0...source.bytesize).to_a),
                   breakages: [breakage].freeze)
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
        # Bytes a shell treats as separation between words: bash's default IFS,
        # exactly. `\n` is here rather than in {OPERATORS} because
        # tree-sitter-bash has no anonymous `"\n"` node to query -- it lexes
        # newline as whitespace.
        #
        # `\r`, `\f` and `\v` are deliberately NOT here, though the grammar does
        # split words on them. They are not IFS, so bash keeps them INSIDE the
        # word, and counting them as blank made `rm tmp/build\f-rf\f/home/joel`
        # reconstruct as four argv terms where bash passes ONE. That is a
        # misparse yielding a different VALID argv, which is worse than a broken
        # one. Left out, the byte is covered by nothing and surfaces as an
        # uncovered run, which is the signal a verdict already refuses on.
        BLANK_BYTES = " \t\n".bytes.freeze

        NOT_WRITTEN = ""

        Span = Data.define(:range, :text) do
          def contains?(other) = range.begin <= other.range.begin && other.range.end <= range.end
        end

        # Whether some span holds a range, answered from the spans' begins and
        # ends alone so no span is rescanned.
        class Holders
          def initialize(spans)
            @widest = spans.group_by { _1.range.begin }.transform_values { |group| group.map { _1.range.end }.max }
            @begins = @widest.keys.sort
            reach = -1
            @before = @begins.map { |at| reach = [reach, @widest.fetch(at)].max }
          end

          def hold?(span)
            held = (@begins.bsearch_index { _1 > span.range.begin } || @begins.size) - 1
            held >= 0 && @before.fetch(held) >= span.range.end
          end

          # Strictly: a span of the very same range does not count.
          def swallow?(command)
            begin_at = command.range.begin
            end_at = command.range.end
            earlier = (@begins.bsearch_index { _1 >= begin_at } || @begins.size) - 1
            (earlier >= 0 && @before.fetch(earlier) >= end_at) || @widest.fetch(begin_at, -1) > end_at
          end
        end

        # The spans a range holds, in source order, from a list sorted once by begin.
        class Within
          def initialize(spans)
            @sorted = spans.sort_by { _1.range.begin }
            @begins = @sorted.map { _1.range.begin }
            @arrival = {}.compare_by_identity
            spans.each_with_index { |span, index| @arrival[span] = index }
          end

          def of(span)
            from = @begins.bsearch_index { _1 >= span.range.begin } || @sorted.size
            last = @begins.bsearch_index { _1 > span.range.end } || @sorted.size
            @sorted[from...last].select { span.contains?(_1) }
          end

          # The held span the query returned first, which is not always the leftmost.
          def first_of(span) = of(span).min_by { @arrival.fetch(_1) }
        end

        # The command a redirect belongs to. Top-level commands are disjoint, so
        # both the holder and the nearest one before are found by bisection.
        class Owners
          def initialize(commands, break_begins)
            @commands = commands
            @begins = commands.map { _1.range.begin }
            @ends = commands.map { _1.range.end }
            @breaks = break_begins.sort
          end

          def of(span) = holder(span) || before(span)

          private

          def holder(span)
            at = (@begins.bsearch_index { _1 > span.range.begin } || @begins.size) - 1
            @commands.fetch(at) if at >= 0 && @commands.fetch(at).contains?(span)
          end

          def before(span)
            at = (@ends.bsearch_index { _1 > span.range.begin } || @ends.size) - 1
            @commands.fetch(at) if at >= 0 && !split?(@commands.fetch(at), span)
          end

          # A keyword or separator between them closes a compound, whose redirect bash applies to the whole of it.
          def split?(command, span)
            first = @breaks.bsearch { _1 >= command.range.end }
            !first.nil? && first <= span.range.begin
          end
        end

        private_constant :BLANK_BYTES, :NOT_WRITTEN, :Span, :Holders, :Within, :Owners

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
          @keywords = free_standing_keywords
          @inside = [DESCRIPTOR, TARGET, HEREDOC_START].to_h { [_1, Within.new(@spans.fetch(_1, []))] }
          @words = Within.new(spans_for(TERMINAL_KINDS + GROUP_KINDS))
          freeze
        end

        def result
          redirects = self.redirects
          Result.new(source: @source, stages: stages(redirects), kinds:, separators:,
                     redirects: redirects.values.freeze, heredocs:, assignments:, compounds:, uncovered:, breakages:)
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

        # A stage is a top-level `command`: one that is neither nested in
        # another command nor swallowed by a terminal. The second half is what
        # keeps an argv from coming back EMPTY -- the `id` of `FOO=$(id)` is a
        # command node inside a `variable_assignment`, and reporting it as a
        # stage hands `[]` to whatever runs the pipeline. Containment must be
        # STRICT: a one-word command shares its exact range with the `word` that
        # spells it, and `wc` is a stage, not a swallowed word.
        def top_level_commands
          swallowed = Holders.new(covering)
          outermost(@spans.fetch(COMMAND, [])).reject { |command| swallowed.swallow?(command) }
        end

        def stages(redirects)
          words = terms
          commands = ordered(top_level_commands)
          owners = owners_of(commands)
          owned = redirects.group_by { |span, _redirect| owners.of(span) }
          within = Within.new(words)
          commands.map do |command|
            argv = within.of(command)
            Stage.new(argv: argv.map(&:text).freeze, byte_range: command.range,
                      redirects: owned.fetch(command, []).map(&:last).freeze)
          end.freeze
        end

        def owners_of(commands) = Owners.new(commands, (separator_spans + @keywords).map { _1.range.begin })

        # Keyed by span, in source order, so a stage can claim its own.
        def redirects
          ordered(@spans.fetch(REDIRECT, [])).to_h { |span| [span, redirect(span)] }
        end

        def redirect(span)
          descriptor = @inside.fetch(DESCRIPTOR).first_of(span)
          target = @inside.fetch(TARGET).first_of(span)
          Redirect.new(text: span.text, descriptor: descriptor&.text || NOT_WRITTEN,
                       operator: operator(span, descriptor, target), target: target&.text || NOT_WRITTEN,
                       extra_words: extra_words(span, target), byte_range: span.range)
        end

        # The operator is an anonymous token, so it is read off the source
        # between the descriptor and the target rather than queried: a token
        # list in the query raises on any name the grammar does not define.
        def operator(span, descriptor, target)
          from = descriptor ? descriptor.range.end : span.range.begin
          to = target ? target.range.begin : span.range.end
          @source.byteslice(from...to).strip.freeze
        end

        def extra_words(span, target)
          words = outermost(@words.of(span).reject { |word| word.range == span.range })
          ordered(words.reject { |word| target&.contains?(word) }).map(&:text).freeze
        end

        def heredocs
          ordered(@spans.fetch(HEREDOC, [])).map do |span|
            start = @inside.fetch(HEREDOC_START).first_of(span)
            from = start&.range&.end || span.range.end
            Heredoc.new(operator: span.text[HEREDOC_OPERATOR].freeze, delimiter: start&.text || NOT_WRITTEN,
                        rest_of_line: rest_of_line(from), lines: lines_after(from, span.range.end),
                        byte_range: span.range)
          end.freeze
        end

        def rest_of_line(from) = @source.byteslice(from..)[/\A[^\n]*/].freeze

        # Whole lines, so text the grammar left after its end on the same line is kept.
        def lines_after(from, to)
          first = @source.byteindex("\n", from)
          return [].freeze if first.nil? || first >= to

          last = @source.byteindex("\n", to) || @source.bytesize
          @source.byteslice((first + 1)...last).split("\n", -1).map(&:freeze).freeze
        end

        def assignments = ordered(outermost(@spans.fetch(ASSIGNMENT, []))).map(&:range).freeze

        def compounds
          spans = COMPOUND_KINDS.flat_map { |kind| @spans.fetch(kind, []).map { [kind, _1] } }
          spans.sort_by { |_, span| span.range.begin }.map { |kind, span| Compound.new(kind:, byte_range: span.range) }
               .freeze
        end

        # A keyword inside a command is the grammar folding a compound into an
        # argument, as it does after `time`, so only a free-standing one counts.
        def free_standing_keywords
          holders = Holders.new(@spans.fetch(COMMAND, []))
          @spans.fetch(KEYWORD, []).reject { |keyword| holders.hold?(keyword) }
        end

        def uncovered = self.class.runs(gaps(covered_bytes))

        def covered_bytes
          spans = covering + separator_spans + @keywords
          merged(spans.map(&:range).sort_by(&:begin)).each_with_object(Array.new(@source.bytesize,
                                                                                 false)) do |range, covered|
            range.each { |byte| covered[byte] = true }
          end
        end

        # Nested terminals overlap, so marking each span's bytes would write the same byte once per level.
        def merged(sorted)
          sorted.each_with_object([]) do |range, runs|
            last = runs.last
            runs[-1] = last.begin...[last.end, range.end].max if last && range.begin <= last.end
            runs << range unless last && range.begin <= last.end
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
          keep = unnested(distinct).to_h { [_1, true] }.compare_by_identity
          distinct.select { keep.key?(_1) }
        end

        # Widest first at each begin, so a span is nested exactly when an earlier one reaches as far.
        def unnested(distinct)
          reach = -1
          distinct.sort { |one, two| (one.range.begin <=> two.range.begin).nonzero? || two.range.end <=> one.range.end }
                  .select { |span| (span.range.end > reach).tap { reach = [reach, span.range.end].max } }
        end

        def ordered(spans) = spans.sort_by { |span| span.range.begin }
      end

      private_constant :Reading
    end
  end
end
