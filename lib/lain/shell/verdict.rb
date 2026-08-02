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
    # The answer is three-valued, which is the whole design. {Approval::AutoSurface}
    # states the doctrine one rung up -- *"an ambiguous answer MUST fall toward
    # defer, never toward approve"* -- and this is the same rule made
    # deterministic:
    #
    # * *allow* -- every stage is literal and fully understood. The term runs as
    #   reconstructed argv, with no shell anywhere.
    # * *deny* -- the session's capability set excludes a program this command
    #   names. A decision the session already made, so it is reported as a
    #   decision and not as a doubt.
    # * *abstain* -- anything else, including every failure mode. It falls
    #   through to {Approval::Queue} and a human. Abstention is cheap and
    #   expected; the job is to be right when it answers, not to answer often.
    #
    # == Three tiers of detection, and why the third exists
    #
    # 1. *Node kinds*, allowlisted -- {LITERAL_KINDS}. An allowlist, never a
    #    metacharacter denylist: `command_substitution`, `expansion`,
    #    `process_substitution`, `file_redirect`, `heredoc_redirect`,
    #    `variable_assignment`, `subshell`, `function_definition` and
    #    `arithmetic_expansion` are all *tagged* by the grammar, and anything the
    #    grammar grows later is outside the allowlist by default.
    # 2. *Program names*, {PROGRAM_RUNNERS}. Some programs run whatever their
    #    arguments name, and no node kind distinguishes `find . -exec rm {} +`
    #    from `ls -la`. Read from EVERY stage's `argv.first`, never the first
    #    stage's: `echo hi; time { rm x; }`, `ls | time rm x` and
    #    `true && time rm -rf /tmp/x` are all fully covered with an innocuous
    #    leading stage.
    # 3. *Word text* -- {EXPANDING} and {ESCAPING}. A glob, a tilde, a brace and
    #    a backslash have NO node kind at all. `rm *` and `ls ~/secret` parse to
    #    `program/command/command_name/word` and full coverage, exactly like
    #    `ls -la` does. The text of the term is the only signal that exists, and
    #    this is the tier a designer forgets.
    #
    # There is a fourth thing to count, because one separator has no node either:
    # tree-sitter-bash lexes a NEWLINE as whitespace, so `echo hi\nrm -rf /tmp/x`
    # arrives as two stages and an EMPTY separator list. Reading separator texts
    # cannot see it; N stages against N-1 pipes can.
    #
    # Coverage is a necessary condition and never a sufficient one, so it is
    # asked as `covered?` and never as `uncovered.empty?` -- the refusal path has
    # no source, so its `uncovered` is `[]` while `covered?` is correctly false.
    #
    # == What an allow hands over
    #
    # `[["grep", "-r", "foo", "."], ["wc", "-l"]]`: a non-empty list of non-empty
    # argvs whose only combinator is the pipe. The Decision deliberately does NOT
    # carry the original string, because re-running an accepted string through
    # `sh -c` turns every parser/shell disagreement into a live bypass, and the
    # cheapest way to make that impossible is to not hand the string over.
    #
    # Two consequences the executing layer inherits, both from {Parse}:
    #
    # * A quoted or escaped argument ABSTAINS. `Parse` does not strip quotes --
    #   `echo 'a b'` reconstructs as `["echo", "'a b'"]`, and `echo foo\ bar` as
    #   `["echo", "foo\\ bar"]` where bash gives `["echo", "foo bar"]` -- so
    #   allowing either would exec a term carrying literal quoting characters.
    #   Widening this needs dequoting first, and dequoting is interpretation,
    #   which is a reviewed decision and not an optimization.
    # * `;`, `&&`, `||` and `&` abstain. Running them means interpreting control
    #   flow, and this layer hands over a pipeline, not a shell.
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

      # THE GENERATING RULE for the six families below: a name belongs here when
      # something the MODEL writes -- an argument, a flag, or the stdin it pipes
      # in -- can name the program that ends up executing. The Design's first
      # non-negotiable is that there is no string for the model to control, and
      # each of these hands one back.
      #
      # It follows that SYNONYMS are not optional. `sh` without `dash`, or `sudo`
      # without `doas`, is not a check; both are on `PATH` here.
      #
      # The list is HAND-MAINTAINED and therefore incomplete -- `sudoers(5)` has
      # made exactly this point since the 1990s, and a comment claiming otherwise
      # would be the defect. Extend it by applying the rule, not by guessing.
      # Known and deliberately absent: `make`, `cargo`, `rake`, `go`, `mvn`,
      # `gradle` and `dotnet`. What they run comes from a BUILD FILE in the
      # workspace, which this layer does not model at all -- so listing them
      # would buy nothing here while abstaining on most of what a session
      # legitimately runs. That is a judgement about where the threat lives, not
      # a proof that they cannot execute: `make -f -` reads a makefile from
      # STDIN and `make --eval=` takes one inline, `mvn exec:exec` names an
      # executable in a property, and `go run` takes a package path. Both make
      # exceptions ALLOW today; what stops them mattering is that a working
      # recipe needs a newline or quoting to carry its TAB-indented line, and
      # both of those abstain -- a fact about today's tiers, not a guarantee.
      # `bundle` is on the list rather than off it: `bundle exec
      # <program>` names the program in the ARGUMENT, which is the rule exactly,
      # and it is what `env` and `nice` are here for.
      #
      # `make` is not the next `time`, and the difference is worth recording:
      # `time` was special because the PARSER hides its tail behind full coverage
      # and bland kinds, so nothing structural could see it. `make -f Makefile`
      # hides nothing and is exactly what it looks like.

      # A command handed over as an argument, now or on a timer.
      TAKES_A_COMMAND = %w[
        eval source . alias command builtin exec xargs parallel find watch
        strace ltrace script systemd-run gdb ssh docker podman kubectl
        npx npm bundle at batch crontab
      ].freeze

      # A shell or an interpreter: `-c`, `-e`, or a program on stdin. `awk` and
      # `sed` are here rather than filed as utilities because that is what they
      # are -- `awk 'BEGIN{system("id")}'`, `sed 'e id'`.
      INTERPRETERS = %w[
        sh bash dash zsh ksh mksh ash csh tcsh fish rbash busybox
        perl python python2 python3 ruby irb node deno bun php lua tclsh java awk sed
      ].freeze

      # Wrappers whose whole job is to exec the program their arguments name.
      # `time` and `coproc` are here because tree-sitter-bash does not model them
      # as keywords, so `time { echo PWNED; }` and `time rm -rf /tmp/x` reach FULL
      # coverage as ordinary commands: neither the kind tier nor the byte backstop
      # says anything about them, and this list is the only thing that abstains.
      WRAPPERS = %w[
        env nice ionice taskset chrt setarch timeout nohup setsid stdbuf flock
        chroot unshare nsenter time coproc
      ].freeze

      # The same shape, with a privilege change on the way through.
      PRIVILEGE = %w[sudo su runuser doas pkexec setpriv].freeze

      # Interactive programs with a documented shell escape. `less` is on the
      # card's list for this reason, so its whole family is here with it.
      SHELL_ESCAPES = %w[less more most man info vi vim nvim ed emacs nano psql mysql sqlite3].freeze

      # Run a program named in their own options. `git` is here for a measured
      # reason -- `-c core.fsmonitor=id`, `-c include.path=...`,
      # `-c alias.<new-name>=!sh` all execute, and `git status --short` is
      # structurally indistinguishable from `ls -la`.
      OPTION_DIRECTED = %w[git tar rsync].freeze

      PROGRAM_RUNNERS =
        (TAKES_A_COMMAND + INTERPRETERS + WRAPPERS + PRIVILEGE + SHELL_ESCAPES + OPTION_DIRECTED).freeze

      # Bash's reserved words, minus the two that also EXECUTE and so live in
      # {WRAPPERS}. As an argv0 these are not programs at all: the string was a
      # syntax error bash would have rejected, and `exec` failing with ENOENT is
      # luck rather than a check. "Fully understood" must not be claimed about
      # them.
      RESERVED_WORDS = %w[! [[ ]] { } case do done elif else esac fi for function if in select then until while].freeze

      # Glob, tilde and brace. No node kind exists for any of them, so the term's
      # text is the entire signal.
      EXPANDING = /[*?\[\]{}~]/

      # The third quoting form, and the one with no node kind: `echo foo\ bar` is
      # ONE `word`, and {Parse} hands back `"foo\\ bar"` where bash gives
      # `"foo bar"`. Same reasoning as the quote kinds -- unescaping is
      # interpretation, so the answer is to abstain rather than to guess.
      ESCAPING = /\\/

      # The one combinator a term carries, because `Open3.pipeline` is a pipeline
      # and nothing else.
      PIPE = "|"

      NO_TERM = [].freeze

      # A verdict, and the term it authorises. `term` is empty on anything but an
      # allow -- a Null Object, so no caller writes `if decision.term`.
      Decision = Data.define(:name, :reason, :term) do
        def allow? = name == :allow
        def deny? = name == :deny
        def abstain? = name == :abstain

        # What goes in the Journal. {CLAIM} rides along on every one of them, so
        # no record can be read as a claim about safety.
        def record = { verdict: name, reason:, term:, claim: CLAIM }.freeze
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
        Decision.new(name: :allow, reason: ALLOWED, term: result.stages.map(&:argv).freeze)
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
        # `[["echo", "hi"], [""]]`. Neither may be reachable through an allow.
        def nothing_to_run?
          @result.stages.empty? ||
            @result.stages.any? { |stage| stage.argv.empty? || stage.argv.any?(&:empty?) }
        end

        def unknown_kinds
          sentences("node kinds this layer cannot read literally", @result.kinds - LITERAL_KINDS)
        end

        def program_runners
          names = programs
          sentences("programs that run what their arguments name", names & PROGRAM_RUNNERS) +
            sentences("bash reserved words, which are not programs at all", names & RESERVED_WORDS)
        end

        def expanding_words
          sentences("words a shell would expand", terms.grep(EXPANDING)) +
            sentences("words carrying an escape this layer does not unescape", terms.grep(ESCAPING))
        end

        def control_flow
          sentences("combinators no argv can express",
                    @result.separators.map(&:text).reject { |text| text == PIPE }) + malformed_pipeline
        end

        # Counting, because the one separator {Parse} CANNOT report is a newline
        # -- tree-sitter-bash lexes it as whitespace, so there is no anonymous
        # node to query (`parse.rb:248`). `echo hi\nrm -rf /tmp/x` therefore
        # arrives as TWO stages with an EMPTY separator list, and reading the
        # separator texts is blind to exactly the separator that is invisible.
        # N stages are a pipeline only if N-1 pipes join them and nothing else
        # does; the newline case fails that arithmetic, and without it
        # `Open3.pipeline` would be handed a term that lies about its own
        # structure and would run `echo hi | rm -rf /tmp/x`.
        def malformed_pipeline
          pipes = @result.separators.count { |separator| separator.text == PIPE }
          return [] if @result.stages.size == pipes + 1 && @result.separators.size == pipes

          ["#{NOT_A_PIPELINE}: stages=#{@result.stages.size} pipes=#{pipes} " \
           "separators=#{@result.separators.size}".freeze]
        end

        def terms = @result.stages.flat_map(&:argv)

        def sentences(label, offenders)
          offenders.empty? ? [] : [self.class.sentence(label, offenders)]
        end
      end

      NOTHING_TO_RUN = "there is no command to run"
      NOT_UNDERSTOOD = "not fully understood -- "
      NOT_A_PIPELINE = "the stages are joined by something other than pipes"
      EXCLUDED = "the session's capability set excludes"
      private_constant :NOTHING_TO_RUN, :NOT_UNDERSTOOD, :NOT_A_PIPELINE, :EXCLUDED, :Doubts
      private_constant :TAKES_A_COMMAND, :INTERPRETERS, :WRAPPERS, :PRIVILEGE, :SHELL_ESCAPES, :OPTION_DIRECTED
    end
  end
end
