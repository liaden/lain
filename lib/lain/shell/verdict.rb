# frozen_string_literal: true

module Lain
  module Shell
    # Reads what {Shell::Parse} reported and answers ONE question: *is this
    # command syntactically literal and fully understood?* It does not answer
    # "is it safe", it cannot answer "is it safe", and no reason string it
    # writes ever says so. `git -c core.fsmonitor=id status --short` satisfies
    # every structural test in here -- not broken, every byte covered, the
    # blandest kind set the grammar can produce -- and it executes `id`. That is
    # why {CLAIM} travels on every record this object hands to a journal.
    #
    # The answer is three-valued, which is the whole design. {Approval::Judge}
    # states the doctrine one rung up -- *"an ambiguous answer MUST fall toward
    # defer, never toward approve"* -- and this is the same rule made
    # deterministic:
    #
    # * *allow* -- every stage is literal and fully understood. The term runs as
    #   reconstructed argv, with no shell anywhere.
    # * *deny* -- this command names a program the session's shell exclusion
    #   lists. A decision the session already made, so it is reported as a
    #   decision and not as a doubt.
    # * *abstain* -- anything else, including every failure mode. It falls
    #   through to {Approval::Parked::Queue} and a human. Abstention is cheap and
    #   expected; the job is to be right when it answers, not to answer often.
    #
    # The three detection tiers -- node kinds, program names, and WORD TEXT,
    # the tier a designer forgets -- and the fourth thing that has to be COUNTED
    # rather than read (a newline has no node) are argued in ARCHITECTURE.md's
    # "Triaging a bash command"; the constants below carry the per-family
    # reasoning. Three consequences live here:
    #
    # * Coverage is a necessary condition and never a sufficient one, so it is
    #   asked as `covered?` and never as `uncovered.empty?` -- the refusal path
    #   has no source, so its `uncovered` is `[]` while `covered?` is correctly
    #   false.
    # * An allow hands over a {Term} -- `grep -r foo .` piped to `wc -l` as two
    #   argv stages, and `pwd && ls` as two pipelines run in order -- and
    #   deliberately NOT the original string, because
    #   re-running an accepted string through `sh -c` turns every parser/shell
    #   disagreement into a live bypass, and the cheapest way to make that
    #   impossible is to not hand the string over.
    # * A quoted or escaped argument ABSTAINS, and so do `;`, `||` and `&`.
    #   {Parse} does not strip quotes -- `echo 'a b'` reconstructs as
    #   `["echo", "'a b'"]`, and `echo foo\ bar` as `["echo", "foo\\ bar"]`
    #   where bash gives `["echo", "foo bar"]` -- so allowing either would exec a
    #   term carrying literal quoting characters. Widening it needs dequoting
    #   first, and dequoting is interpretation. `&&` is the one control flow a
    #   term carries, because "run the next pipeline only if this one
    #   succeeded" needs no shell to decide; the other three would make this
    #   layer hand over a shell.
    class Verdict
      # What every record says this object was asked, so a reader of the Journal
      # cannot mistake an allow for a safety judgement.
      CLAIM = "whether this command is syntactically literal and fully understood -- " \
              "never whether it is safe to run"

      ALLOWED = "every stage is literal and fully understood"

      # The kinds a fully literal command is made of. Everything else the grammar
      # can report -- tagged today or added tomorrow -- falls outside and
      # abstains. `list` and `pipeline` are literal STRUCTURE; which of them can
      # actually be run without a shell is the separator's question, and it has
      # its own tier and its own message.
      LITERAL_KINDS = %w[program list pipeline command command_name word number concatenation].freeze

      # Literal only when every redirect in the command is a {DISCARDS} entry
      # sent to /dev/null after its stage; otherwise they abstain as kinds.
      REDIRECT_KINDS = %w[file_redirect redirected_statement].freeze

      SPACING = /\A[ \t]+\z/

      # The redirects a term carries, by descriptor and operator, and the
      # streams each one sends to /dev/null. `2>&1`, `>>` and `1>` stay out:
      # a duplication is not a discard, and the rest are spellings nobody asked
      # for yet.
      DISCARDS = {
        ["2", ">"] => %i[stderr],
        ["", ">"] => %i[stdout],
        ["", "&>"] => %i[stdout stderr]
      }.freeze

      # The families, and the rule that puts a name in one, are in {Programs}.
      PROGRAM_RUNNERS = Programs::RUNNERS

      # Bash's reserved words, minus the two that also EXECUTE and so live in
      # {WRAPPERS}. As an argv0 these are not programs at all: the string was a
      # syntax error bash would have rejected, and `exec` failing with ENOENT is
      # luck rather than a check. "Fully understood" must not be claimed about
      # them.
      RESERVED_WORDS = %w[! [[ ]] { } case do done elif else esac fi for function if in select then until while].freeze

      # Bash builtins that act on the shell itself, so no program on disk can
      # stand in for them: `cd /tmp && pwd` as a term would fail, or change
      # nothing, where the string arm runs it. Abstaining keeps them there. The
      # ones that run a command are in {TAKES_A_COMMAND}; `echo`, `test`, `pwd`
      # and `kill` have real binaries and are not here.
      SHELL_BUILTINS = %w[
        : cd pushd popd dirs export unset set shopt declare typeset local readonly let
        exit logout return break continue shift trap umask ulimit read readarray mapfile getopts
        wait jobs fg bg disown suspend hash type unalias history fc enable bind help
        compgen complete compopt caller times
      ].freeze

      # Glob, tilde and brace. No node kind exists for any of them, so the term's
      # text is the entire signal.
      EXPANDING = /[*?\[\]{}~]/

      # The third quoting form, and the one with no node kind: `echo foo\ bar` is
      # ONE `word`, and {Parse} hands back `"foo\\ bar"` where bash gives
      # `"foo bar"`. Same reasoning as the quote kinds -- unescaping is
      # interpretation, so the answer is to abstain rather than to guess.
      ESCAPING = /\\/

      # The combinators a term carries: a pipe joins stages, and `&&` binds
      # looser, so it splits the stages into the pipelines a term runs in order.
      PIPE = "|"
      AND = "&&"
      JOINS = [PIPE, AND].freeze

      NO_TERM = Term::NONE

      # A verdict, and the term it authorises. `term` is empty on anything but an
      # allow -- a Null Object, so no caller writes `if decision.term`.
      Decision = Data.define(:name, :reason, :term) do
        def allow? = name == :allow
        def deny? = name == :deny
        def abstain? = name == :abstain

        # What goes in the Journal. {CLAIM} rides along on every one of them, so
        # no record can be read as a claim about safety.
        def record = { verdict: name, reason:, term: term.to_journal, claim: CLAIM }.freeze
      end

      # The capability set of a session that restricts no program name. Answers
      # the same one message a real one does, so no code path guards on `nil`.
      class AnyProgram
        def permits?(_program) = true
      end

      # @param parse [#call] `String -> Parse::Result`
      # @param capability_set [#permits?] answers `permits?(program_name)` for
      #   the session; the basename is what it is asked about.
      def initialize(parse: Parse.new, capability_set: AnyProgram.new)
        @parse = parse
        @capability_set = capability_set
        freeze
      end

      # @param command [String]
      # @return [Decision]
      def call(command) = judge(@parse.call(command))

      # @param redirect [Parse::Redirect]
      # @return [Array<Symbol>] the streams its descriptor and operator would
      #   send to its target, empty for anything {DISCARDS} does not name
      def self.discarded(redirect) = DISCARDS.fetch([redirect.descriptor, redirect.operator], [])

      # A name with a slash in it is exec'd even when its last segment is a builtin's.
      #
      # @param program [String, nil] a stage's first word, as written
      # @return [Boolean] whether only a shell can run it
      def self.builtin?(program) = SHELL_BUILTINS.include?(program)

      private

      # Exclusion is consulted before the abstention ladder because it can only
      # ever make the outcome stricter: a program the session has already ruled
      # out is a decision, not a doubt, and saying so is more useful to a human
      # than "I did not understand this". Every command it does not fire on still
      # faces the whole ladder.
      def judge(result)
        doubts = Doubts.new(result)
        excluded = excluded_programs(result, doubts)
        return deny(excluded) unless excluded.empty?

        causes = doubts.causes
        causes.empty? ? allow(result) : abstain(causes)
      end

      # Gated on `covered?`, because a denial names a program, and a parse that
      # was not understood has no reliable name to offer: `rm x $` reconstructs
      # an argv the parser itself does not stand behind, and reasoning a decision
      # off it would be a confident answer built on an admitted doubt. Abstention
      # is the honest outcome there, and it is not weaker -- an abstention still
      # goes to a human.
      def excluded_programs(result, doubts)
        return [] unless result.covered?

        doubts.programs.reject { |program| @capability_set.permits?(program) }
      end

      def allow(result)
        Decision.new(name: :allow, reason: ALLOWED, term: Term.new(pipelines: pipelines(result)))
      end

      # By byte position, because the stage and separator lists are ordered
      # only against the source.
      def pipelines(result)
        ands = result.separators.select { |separator| separator.text == AND }.map(&:byte_range)
        result.stages.slice_when { |left, right| ands.any? { |range| joins?(range, left, right) } }
              .map { |stages| Term::Pipeline.new(stages: stages.map { |stage| term_stage(stage) }) }
      end

      def joins?(range, left, right) = range.begin.between?(left.byte_range.end, right.byte_range.begin)

      def term_stage(stage)
        Term::Stage.new(argv: stage.argv, discards: stage.redirects.flat_map { |redirect| Verdict.discarded(redirect) })
      end

      def deny(excluded)
        Decision.new(name: :deny, reason: Doubts.sentence(EXCLUDED, excluded), term: NO_TERM)
      end

      def abstain(causes)
        Decision.new(name: :abstain, reason: "#{NOT_UNDERSTOOD}#{causes.join("; ")}".freeze, term: NO_TERM)
      end

      # One {Parse::Result}, read for everything about it this layer cannot say
      # literally. Separate from {Verdict} because the two answer different
      # questions: Verdict owns the three-valued judgement, the session's
      # capability set and the promise never to claim safety, and this owns the
      # reading of one parse -- the same split {Parse} makes with its own Reading.
      class Doubts
        # Offenders keep the order they were found in -- kinds arrive sorted from
        # {Parse}, and everything else reads better in source order. Each is
        # QUOTED, because the offenders include the punctuation the sentences are
        # punctuated with: an unquoted `;` renders as `express: ;; the stages`.
        # Interpolation returns a MUTABLE String even under
        # `frozen_string_literal`, and a Decision has to be `Ractor.shareable?`.
        def self.sentence(label, offenders)
          "#{label}: #{offenders.map { |offender| offender.to_s.inspect }.uniq.join(", ")}".freeze
        end

        def initialize(result)
          @result = result
          freeze
        end

        # The last path segment of each stage's program, because a list of bare
        # names that `/bin/sh` walks around is not a check. `rpartition` rather
        # than `File.basename`, which raises `ArgumentError` on a NUL byte -- and
        # a NUL parses CLEAN into an ordinary word (`parse.rb:86`), so it reaches
        # here from any tool call, and a layer whose whole doctrine is to fail
        # toward abstain must not raise. `reject(&:empty?)` keeps this total the
        # other way: an argv that came back empty is {NOTHING_TO_RUN}'s business.
        def programs
          @result.stages.map(&:argv).reject(&:empty?).map { |argv| argv.first.rpartition("/").last }
        end

        # The first tier with something to say wins, so a reason names the
        # reader's nearest cause rather than every consequence of it --
        # `find . -exec rm {} +` abstains over `find`, not over the `{}` that
        # follows from it.
        def causes
          [unread, unknown_kinds, program_runners, expanding_words, control_flow]
            .find { |tier| !tier.empty? } || []
        end

        private

        # `broken?` is asked HERE rather than inferred from `covered?` being a
        # conjunction over both. That it is a conjunction is true and pinned in
        # `parse_spec`, but leaning on it makes this object's abstention depend on
        # another object's internals; asking both keeps the claim local.
        #
        # And `covered?`, never `uncovered.empty?`: a refusal has no source at
        # all, so its `uncovered` field is empty while it accounted for nothing.
        def unread
          return breakages if @result.broken?
          return unaccounted unless @result.covered?
          return [NOTHING_TO_RUN] if nothing_to_run?

          []
        end

        def breakages = sentences("nothing was parsed", @result.breakages.map(&:kind))

        # Bounded rather than exhaustive: a 4 KiB command can leave hundreds of
        # runs unaccounted for, and a Journal line wants the shape, not the
        # census. Always yields one cause, so it cannot hand back "no doubts" for
        # a result that told us it covered nothing.
        def unaccounted
          [self.class.sentence("bytes nothing accounted for, at offsets", @result.uncovered.map(&:begin).first(8))]
        end

        # An empty argv is an ArgumentError out of `Open3`, and an empty STRING
        # as a term execs nothing -- `echo hi &&` really does reconstruct
        # a second stage whose only word is empty. Neither may be reachable
        # through an allow.
        def nothing_to_run?
          @result.stages.empty? ||
            @result.stages.any? { |stage| stage.argv.empty? || stage.argv.any?(&:empty?) }
        end

        def unknown_kinds
          literal = discards_only? ? LITERAL_KINDS + REDIRECT_KINDS : LITERAL_KINDS
          sentences("node kinds this layer cannot read literally", @result.kinds - literal)
        end

        def discards_only?
          owned = @result.stages.sum { |stage| stage.redirects.size }
          owned == @result.redirects.size &&
            @result.stages.each_with_index.all? { |stage, index| stage_discards_only?(stage, index) }
        end

        # Each redirect must sit after what precedes it with only spaces or tabs
        # between. Touching, `0>` is a descriptor to bash and the word `0` to
        # the grammar; across a newline, bash runs it as a command of its own;
        # and a leading redirect has no gap after its stage at all.
        def stage_discards_only?(stage, index)
          afters = [stage.byte_range.end, *stage.redirects.map { |redirect| redirect.byte_range.end }]
          piped = piped?(stage, @result.stages[index + 1])
          stage.redirects.zip(afters).all? do |redirect, after|
            discard?(redirect) && spaced?(after, redirect) && !(piped && Verdict.discarded(redirect).include?(:stdout))
          end
        end

        def discard?(redirect)
          !Verdict.discarded(redirect).empty? && redirect.target == File::NULL && redirect.extra_words.empty?
        end

        def spaced?(after, redirect) = SPACING.match?(@result.source.byteslice(after...redirect.byte_range.begin))

        # Open3 owns the descriptor between two stages, so a stdout discard
        # there is a term no runner here can express.
        def piped?(stage, following)
          return false if following.nil?

          @result.separators.any? do |separator|
            separator.text == PIPE &&
              separator.byte_range.begin.between?(stage.byte_range.end, following.byte_range.begin)
          end
        end

        def program_runners
          names = programs
          sentences("programs that run what their arguments name", names & PROGRAM_RUNNERS) +
            sentences("bash reserved words, which are not programs at all", names & RESERVED_WORDS) +
            sentences("shell builtins, which only a shell can run", names & SHELL_BUILTINS)
        end

        def expanding_words
          sentences("words a shell would expand", terms.grep(EXPANDING)) +
            sentences("words carrying an escape this layer does not unescape", terms.grep(ESCAPING))
        end

        def control_flow
          sentences("combinators no argv can express",
                    @result.separators.map(&:text).reject { |text| JOINS.include?(text) }) + malformed_pipeline
        end

        # Counting, because the one separator {Parse} CANNOT report is a newline
        # -- tree-sitter-bash lexes it as whitespace, so there is no anonymous
        # node to query (`parse.rb:248`). `echo hi\nrm -rf /tmp/x` therefore
        # arrives as TWO stages with an EMPTY separator list, and reading the
        # separator texts is blind to exactly the separator that is invisible.
        # N stages are a term only if N-1 pipes and `&&`s join them and
        # nothing else does; the newline case fails that arithmetic, and
        # without it `Open3.pipeline` would be handed a term that lies about its
        # own structure and would run `echo hi | rm -rf /tmp/x`.
        def malformed_pipeline
          joins = @result.separators.count { |separator| JOINS.include?(separator.text) }
          return [] if @result.stages.size == joins + 1 && @result.separators.size == joins

          ["#{NOT_A_PIPELINE}: stages=#{@result.stages.size} joins=#{joins} " \
           "separators=#{@result.separators.size}".freeze]
        end

        def terms = @result.stages.flat_map(&:argv)

        def sentences(label, offenders)
          offenders.empty? ? [] : [self.class.sentence(label, offenders)]
        end
      end

      NOTHING_TO_RUN = "there is no command to run"
      NOT_UNDERSTOOD = "not fully understood -- "
      NOT_A_PIPELINE = "the stages are joined by something other than pipes and &&"
      EXCLUDED = "the session's shell exclusion covers bash commands and excludes"
      private_constant :NOTHING_TO_RUN, :NOT_UNDERSTOOD, :NOT_A_PIPELINE, :EXCLUDED, :Doubts
    end
  end
end
