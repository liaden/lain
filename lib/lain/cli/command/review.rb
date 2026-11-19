# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/review <pull-request|branch>` at `you>`: draw a colleague's changeset
      # in the editor this chat is ALREADY attached to, and bind its gesture
      # rails to the review it opened.
      #
      # A repl command rather than a second process, because the first draft --
      # `qa-lain review --nvim=<socket>` -- was measured to be data destruction:
      # the human's only socket is the cockpit's, a second attach re-injects the
      # runtime with its own channel id and reassigns every `_G.__lain.*`
      # function, and the parked chat then loses `:LainReply` and every review
      # verb with no sign that it has. Inside the chat the frontend is already
      # attached and {Repl#run} has already bound the editor, so the whole card
      # is: resolve a target, open a round, bind the rails.
      #
      # `review_surface` is nil exactly when no editor is attached, and
      # coalescing that to {Review::Surface::Null} would report an opened review
      # that nothing drew and no gesture could ever reach. So the nil is a
      # refusal, not a default, and the question is asked once: everything below
      # it holds a live surface.
      #
      # Spelling, against a shadow: a bare `Review` inside `Lain::CLI::Command`
      # resolves to THIS class, so every `Lain::Review::*` reference below is
      # spelled out in full.
      class Review
        # The flags this command carries, each taking the word after it.
        # Anything else beginning with `--` is refused rather than read as a
        # branch name: `refs/heads/--squash` is nobody's ref, so resolving it
        # would answer a confusing UnknownRef instead of naming the typo.
        FLAGS = %w[--base --scope --since].freeze

        # The flags that take nothing, held apart from {FLAGS} because the parse
        # drops TWO words for one and ONE for the other. It is here so the
        # partial-review refusal is honest from a `/review` round too: that
        # sentence offers `--permissive` as the way past a changeset nobody
        # finished reading, and a command that could not read it would name a
        # remedy unreachable from the very review that refused. Spelled here
        # rather than read from {Review::Verdict::Policy::FLAG}, which
        # {#policy_for} asks what it MEANS.
        SWITCHES = %w[--permissive].freeze

        # What each of {FLAGS} takes, in the word a refusal names it by --
        # naming the THING missing (a ref, a scope) rather than the generic
        # "a value", which said nothing a human could act on beyond "retype
        # something".
        NEEDS_VALUE = { "base" => "a ref", "scope" => "a scope", "since" => "a commit" }.freeze

        # A FORMAT rather than the sentence: the scopes come off
        # {Review::Partition::STRATEGIES}, and {#usage} fills them in, so a
        # strategy registered there cannot leave this line advertising a stale set.
        USAGE = "/review <pull-request|branch> [--base <ref>] [--since <sha>] [--scope %<scopes>s] [--permissive] " \
                "[--critique[=FOCUS]] -- open a changeset review in the attached editor; /review close lets the " \
                "open round go without a verdict (a branch named close is refs/heads/close); --critique runs " \
                "/critique over the opened round, and takes the rest of the line as its options and focus"

        # `--critique` closes the line: whatever follows `=` is `/critique`'s own
        # options and focus, which hold spaces and words that look like flags, so
        # it is cut off before the rest is split into words.
        CRITIQUE_FLAG = /(?:\A|\s)--critique(?:=(?<focus>.*))?\z/m

        # The collaborator a command built without one gets. A critique asked for
        # from a command that was never given a way to run one is refused, not
        # skipped: the human typed the flag expecting findings.
        NO_CRITIQUE = lambda do |_args|
          raise Error, "this chat has no critique to run -- open the review without --critique, then type /critique"
        end

        # The word that closes the chat's open round instead of naming a target.
        # It shadows a branch literally called `close`, which `refs/heads/close`
        # still reaches.
        CLOSE = "close"

        # `/review close --base main` is a close with a typo in it or a review of
        # a branch named close, and guessing which would do one of them wrongly.
        CLOSE_TAKES_NOTHING = "/review close takes nothing after it -- to review a branch named close, " \
                              "say refs/heads/close"

        # Said beside whatever `/review close` answers, whenever this repository
        # HAS a branch the word shadows: a human who meant that branch has to
        # learn the spelling that reaches it from the answer they got instead.
        CLOSE_BRANCH_HINT = "a branch named close is reviewed with /review refs/heads/close"

        # What a branch named close is, spelled the way git resolves it alone.
        CLOSE_REF = "refs/heads/close"

        # Where a local branch lives, which a target may spell out.
        BRANCH_REFS = "refs/heads/"

        # The review rounds the sessions this chat resumed left behind, read for
        # one banner. Every EARLIER file of the resume chain is asked, newest
        # first, and the first one holding any round decides: a resumed chat has
        # a fresh outbox, so no later session can have ended an earlier one's
        # round.
        #
        # IT DEGRADES, and that is the point of it being its own object. The
        # banner is advice about history and guards nothing, so a file it cannot
        # read -- gone, or holding a record today's guards refuse -- must never
        # stop a new round opening. It says what it could not read instead, which
        # keeps the failure in front of the human. A TORN line is not damage: the
        # journal reader drops it by contract, and a killed session leaves one.
        class EarlierRounds
          UNREADABLE = "could not read the review rounds in %<file>s (%<reason>s) -- if a round was open " \
                       "there, its notes are not carried over either"

          # Nothing about a round in that file: ask the one before it.
          NO_ROUND = Object.new.freeze
          private_constant :NO_ROUND

          # @param journal_path [String, nil] this chat's own session file
          # @param paths [Paths] finds an earlier file of the chain by basename
          def initialize(journal_path, paths:)
            @journal_path = journal_path
            @paths = paths
            freeze
          end

          # @param target [String] what this round is being opened on
          # @return [String, nil] the banner, a note naming what could not be
          #   read, or nothing
          def banner(target)
            earlier.reverse.lazy.map { |file| answer(file, target) }.reject { |said| NO_ROUND.equal?(said) }.first
          rescue SystemCallError, Lain::Error => e
            format(UNREADABLE, file: "the sessions #{File.basename(@journal_path)} resumed", reason: e.message)
          end

          private

          def earlier
            return [] if @journal_path.nil? || !File.file?(@journal_path)

            walk = Lain::CLI::Resume::ChainWalk.new(paths: @paths, dir: File.dirname(@journal_path))
            walk.paths(@journal_path)[0...-1]
          end

          def answer(file, target)
            replay = Lain::Review::Session::Replay.new(File.foreach(file))
            return NO_ROUND if replay.opened.nil?

            format(Lain::Review::Session::NOT_CARRIED_OVER, target:) if replay.open_on?(target)
          rescue SystemCallError, ArgumentError, Lain::Error => e
            format(UNREADABLE, file: File.basename(file), reason: e.message)
          end
        end

        # The refusal a headless chat gets. It names the flag that attaches an
        # editor, because that is a fact the human can act on.
        NO_EDITOR = "no editor is attached to this chat, so a changeset review would be drawn nowhere and " \
                    "no gesture could reach it -- start the cockpit with `lain up --nvim` (or " \
                    "`lain chat --nvim <socket>`) and run /review there."

        # Any word that is not a corpus: a changeset review is the other kind to
        # {Lain::Review::Submit::Outbox#refuse_other!} whichever of its sources it opens over.
        CHANGESET_SOURCE = "changeset"

        # The refusal a changeset review opened over an open SURVEY gets -- the
        # mirror of {Command::Survey::ALREADY_OPEN}: one chat has one set of
        # gesture rails, so a second SURFACE would rebind them to a sidebar the
        # survey's marks cannot reach. A second `/review` over a `/review` still
        # rebinds, and `/review close` is the way past an open survey.
        SURVEY_OPEN = "%<target>s is already open in this chat, and one chat draws one review at a time -- " \
                      "a changeset review opened over it would rebind the gesture rails to a sidebar the " \
                      "survey's marks cannot reach. Run `/review close` to let it go without a verdict."

        # @param outbox [Review::Submit::Outbox] the run's ONE open review, so
        #   the round this opens is reachable from `/review-submit`. Required
        #   rather than defaulted: an outbox nothing else holds is a review that
        #   can never be posted, and nothing about the wiring would look wrong.
        # @param paths [Paths] the state home an earlier session of the chain is found under
        # @param root [String] the repository every git call reads -- the
        #   project the chat was started in, threaded from {Command::Surface}
        # @param bounds [Lain::Review::Bounds] the sizes past which the sidebar
        #   refuses, enforced by {Lain::Review::Session#present}. Injected
        #   because the ceilings are a bench parameter, and a command that built
        #   its own could not be driven past one.
        # @param shell_out_factory [#call] builds the subprocess runner, injected
        #   as {Lain::CLI::Review} and both sources do
        # @param ledger [Lain::Sensitivity::Ledger] the run's ONE region ledger, so
        #   a note's anchor text journals a released region as released
        # @param gh_account [Lain::Forge::Gh::Account, Lain::Forge::Gh::Account::None] the
        #   process's one account, whose token a pull request's gh reads run with
        # @param secrets [#to_a] the values the chat knows, masked in a note's evidence and the briefs
        # @param critique [#call] takes what follows `/critique` and answers a callable that runs it,
        #   having raised every refusal a typed `/critique` raises before it spawns; asked BEFORE
        #   the round opens, so a critique that cannot run leaves no review behind
        def initialize(outbox:, ledger:, gh_account:, paths:, root: Dir.pwd, bounds: Lain::Review::Bounds.new,
                       shell_out_factory: Lain::Shell::Out.public_method(:new), critique: NO_CRITIQUE,
                       secrets: Lain::Sensitivity::Secrets::Source::DEFAULT)
          @outbox = outbox
          @ledger = ledger
          @secrets = secrets
          @root = root
          @bounds = bounds
          @shell_out_factory = shell_out_factory
          @gh_account = gh_account
          @critique = critique
          @round = ReviewRound.new(outbox:, paths:)
          freeze
        end

        def name = "review"

        # Only a review asking for the critique hands the repl a follow-up, and a reply prompt cannot
        # run one, so it is refused before the round opens rather than left half done.
        def returns_action?(args) = CRITIQUE_FLAG.match?(args.to_s)

        # The offered scopes are the registered ones, so a strategy that ships
        # is advertised without a second list to edit -- and one that stops
        # shipping stops being advertised.
        def usage = format(USAGE, scopes: Lain::Review::Partition::STRATEGIES.each_key.to_a.join("|"))

        # @param args [String] the target, and this command's flags
        # @param env [Env] read for the run's {HumanReplies} (the editor, and
        #   both rails) and its {Chronicle} (the journal this round lands in)
        # @return [String, Repl::Followup] the headline and where to read the review, or what
        #   a close let go of; with --critique, the follow-up that says the headline and runs /critique
        # @raise [Lain::Error] no editor, an unknown flag, an unresolvable ref,
        #   an ambiguous target, an undeclared scope, a changeset past a
        #   ceiling, nothing open to close -- each already worded by whoever
        #   owns the refusal
        def call(args, env)
          parsed = parse(args.to_s)
          return usage if parsed.target.nil?
          return closed(parsed, env) if parsed.target == CLOSE

          return critiqued(parsed, env) if parsed.critique

          opened(parsed, env, policy: policy_for(parsed))
        end

        # The banner a resumed chat owes a human reopening a target an earlier
        # session left open, or nil ({EarlierRounds}). PUBLIC because
        # `ReviewRound` owes both commands the same banner and reads it from here. Asked before the new
        # round is journaled, so the answer is about the earlier sessions alone.
        #
        # @param env [Env] read for the chat's session file
        # @param target [String] what this round is being opened on
        # @param paths [Paths] finds an earlier file of the chain by basename
        # @return [String, nil]
        def self.not_carried_over(env, target, paths:) = EarlierRounds.new(env.journal_path, paths:).banner(target)

        private

        # One `/review` line, read. Its own value because "what did they type"
        # and "open a review of it" are separate questions.
        Parsed = Data.define(:target, :base, :since, :scope, :permissive, :critique)
        private_constant :Parsed

        # {Command::Args} splits the line, pairs a declared flag with its
        # value and refuses an unknown flag, a duplicated one, or an extra
        # positional by name -- {#refuse_unreadable!} is what is left this
        # command alone, because it names the THING each flag takes and only
        # this command knows that noun.
        def parse(text)
          critique = CRITIQUE_FLAG.match(text)
          line = critique ? critique.pre_match : text
          parsed = Lain::CLI::Command::Args.parse(line, name: "review", usage:, flags: FLAGS, switches: SWITCHES)
          refuse_unreadable!(parsed.pairs)
          Parsed.new(target: parsed.positionals.first, base: parsed.pairs["base"], since: parsed.pairs["since"],
                     scope: parsed.pairs["scope"], critique: critique && critique[:focus].to_s, **parsed.switches)
        end

        # The critique is prepared first, so what can be known up front refuses before the round
        # exists. It is run by the repl, not here: a command's call is outside the supervision a
        # /stop reaches, and the round is already open when the repl reads the line.
        def critiqued(parsed, env)
          refuse_ahead(parsed.critique)
          headline = opened(parsed, env, policy: policy_for(parsed))
          Lain::CLI::Repl::Followup.new(line: "/critique #{parsed.critique}".strip, said: headline)
        end

        def refuse_ahead(focus) = @critique.call(focus)

        # A flag at the end of the line has nil for a value, which read as
        # "absent" would silently review against the default base the human just
        # tried to override. A flag FOLLOWED BY A SWITCH has that switch for its
        # value: `--base --permissive` would resolve against a ref named
        # `--permissive` AND quietly enable the escape -- two wrong things from
        # one typo, neither of them the word that is actually missing.
        def refuse_unreadable!(pairs)
          missing = pairs.select { |_, value| value.nil? || value.start_with?("--") }.keys
          raise Error, "--#{missing.first} takes #{NEEDS_VALUE.fetch(missing.first)} -- #{usage}" if missing.any?
        end

        # The whole card: refuse, resolve, then open the round with `ReviewRound`.
        #
        # The surface is checked before the round is journaled: a surface that
        # cannot answer the port must not leave a round on record that nothing ever
        # drew. The HOLD comes before the draw, because a human fast enough to
        # answer between the two would send a verdict nothing could route.
        #
        # The refusal over a survey comes before the target resolves, so a tree
        # that is no repository answers the survey in the way, not the ref.
        def opened(parsed, env, policy:)
          env.replies.review_surface or raise Error, NO_EDITOR
          @outbox.refuse_other!(CHANGESET_SOURCE, sentence: SURVEY_OPEN)
          refuse_over_held_notes!(env)
          scope = Lain::Review::Session.scope!(parsed.scope || Lain::Review::Partition::DEFAULT_SCOPE)
          @round.open(opening(resolved_target(parsed), env, policy), env, scope:)
        end

        # `/review close`: whatever round the chat holds, let go without a
        # verdict. A headless chat holds none, so the null surface it falls back
        # to is never drawn on -- the outbox refuses first.
        def closed(parsed, env)
          raise Error, CLOSE_TAKES_NOTHING if [parsed.base, parsed.since, parsed.scope, parsed.permissive,
                                               parsed.critique].any?

          hinted(close_branch_hint) { closing_for(env, env.replies.review_surface || Lain::Review::Surface::Null.new).call }
        end

        # The close's own answer, or its refusal, with {CLOSE_BRANCH_HINT} beside
        # it when there is a branch the word shadowed.
        def hinted(hint)
          [yield, hint].compact.join("\n")
        rescue Lain::Error => e
          raise e if hint.nil?

          raise e.class, "#{e.message} -- #{hint}"
        end

        def close_branch_hint
          shell = Lain::Isolation::Checkout.of(@root, shell_out_factory: @shell_out_factory)
                                           .run("rev-parse", "--verify", "--quiet", "--end-of-options", CLOSE_REF)
          CLOSE_BRANCH_HINT if Shell::Out.ok?(shell)
        end

        def closing_for(env, surface)
          Lain::Review::Handover::Closing.new(outbox: @outbox, rails: env.replies, surface:)
        end

        def resolved_target(parsed) = targets.resolve(parsed.target, base: parsed.base, since: parsed.since)

        # Notes the editor still holds are not on the journal, and a new round
        # would leave them with no review to be handed back to. Asked only over
        # an open round: a first review has nothing to strand.
        def refuse_over_held_notes!(env)
          return unless @outbox.open?

          held = env.replies.held_review_notes
          raise Error, "#{held} #{"note".pluralize(held)} not handed back -- :LainNoteDone first" if held.positive?
        end

        def opening(resolved, env, policy)
          ReviewRound::Opening.new(
            source: resolved.source, source_name: resolved.name, target: target_of(resolved), label: resolved.label,
            number: resolved.number, bounds: @bounds, policy:, spawn: env.role_spawn,
            headline: lambda { |session, scope|
              changeset = session.changeset
              [format(Lain::Review::Target::HEADLINE, label: resolved.label, scope:,
                                                      base: changeset.base_ref, head: changeset.head_ref),
               resolved.note].compact.join("\n")
            }
          )
        end

        # The TARGET journaled is the label the human reads -- `branch feature`,
        # `pull request 12` -- which is what "the same review" means to them, with
        # a `refs/heads/` spelling of a branch read as the branch it names. The
        # headline keeps the spelling typed.
        def target_of(resolved) = resolved.label.sub(" #{BRANCH_REFS}", " ")

        # What `--permissive` means, asked of the class that owns both the word
        # and the rule it swaps -- the sentence offering the flag lives there.
        def policy_for(parsed) = Lain::Review::Verdict::Policy.strict_unless(permissive: parsed.permissive)

        # Unchanged from {Lain::Review::Target}: PR-vs-branch, the ambiguity refusal
        # and `--base`'s two rules are already that object's and already tested,
        # and a second resolver here would be a second set of answers.
        def targets
          Lain::Review::Target.new(repo_root: @root, shell_out_factory: @shell_out_factory,
                                   ledger: @ledger, account: @gh_account, secrets: @secrets)
        end
      end
    end
  end
end
