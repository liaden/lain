# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module CLI
    module Command
      # `/review <pull-request|branch>` at `you>`: draw a colleague's changeset
      # in the editor this chat is ALREADY attached to, and bind its gesture
      # rails to the review it opened.
      #
      # A repl command rather than a second process, because the first draft --
      # `lain review --nvim=<socket>` -- was measured to be data destruction:
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
        FLAGS = %w[--base --scope].freeze

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
        NEEDS_VALUE = { "base" => "a ref", "scope" => "a scope" }.freeze

        # A FORMAT rather than the sentence: the scopes come off
        # {Review::Partition::STRATEGIES}, and {#usage} fills them in, so a
        # strategy registered there cannot leave this line advertising a stale set.
        USAGE = "/review <pull-request|branch> [--base <ref>] [--scope %<scopes>s] [--permissive] -- " \
                "open a changeset review in the attached editor; /review close lets the open round go " \
                "without a verdict (a branch named close is refs/heads/close)"

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
          def initialize(journal_path)
            @journal_path = journal_path
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

            Lain::CLI::Resume::ChainWalk.new(dir: File.dirname(@journal_path)).paths(@journal_path)[0...-1]
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
                    "`lain chat --nvim <socket>`) and run /review there. `lain review open <target>` " \
                    "renders one as text without an editor."

        # The refusal a changeset review opened over an open SURVEY gets -- the
        # mirror of {Command::Survey::ALREADY_OPEN}: one chat has one set of
        # gesture rails, so a second SURFACE would rebind them to a sidebar the
        # survey's marks cannot reach. A second `/review` over a `/review` still
        # rebinds, and `/review close` is the way past an open survey.
        SURVEY_OPEN = "%<target>s is already open in this chat, and one chat draws one review at a time -- " \
                      "a changeset review opened over it would rebind the gesture rails to a sidebar the " \
                      "survey's marks cannot reach. Run `/review close` to let it go without a verdict, " \
                      "or `lain review open <target>` for a text rendering outside this chat."

        # @param outbox [Review::Submit::Outbox] the run's ONE open review, so
        #   the round this opens is reachable from `/review-submit`. Required
        #   rather than defaulted: an outbox nothing else holds is a review that
        #   can never be posted, and nothing about the wiring would look wrong.
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
        def initialize(outbox:, ledger:, root: Dir.pwd, bounds: Lain::Review::Bounds.new,
                       shell_out_factory: Mixlib::ShellOut.public_method(:new))
          @outbox = outbox
          @ledger = ledger
          @root = root
          @bounds = bounds
          @shell_out_factory = shell_out_factory
          freeze
        end

        def name = "review"

        # The offered scopes are the registered ones, so a strategy that ships
        # is advertised without a second list to edit -- and one that stops
        # shipping stops being advertised.
        def usage = format(USAGE, scopes: Lain::Review::Partition::STRATEGIES.each_key.to_a.join("|"))

        # @param args [String] the target, and this command's three flags
        # @param env [Env] read for the run's {HumanReplies} (the editor, and
        #   both rails) and its {Chronicle} (the journal this round lands in)
        # @return [String] the headline and where to read the review, or what
        #   a close let go of
        # @raise [Lain::Error] no editor, an unknown flag, an unresolvable ref,
        #   an ambiguous target, an undeclared scope, a changeset past a
        #   ceiling, nothing open to close -- each already worded by whoever
        #   owns the refusal
        def call(args, env)
          parsed = parse(args.to_s)
          return usage if parsed.target.nil?
          return closed(parsed, env) if parsed.target == CLOSE

          opened(parsed, env, policy: policy_for(parsed))
        end

        # The banner a resumed chat owes a human reopening a target an earlier
        # session left open, or nil ({EarlierRounds}). PUBLIC because
        # {Command::Survey} owes the same banner and reads it from here,
        # {Survey.source_name}'s reason one command over. Asked before the new
        # round is journaled, so the answer is about the earlier sessions alone.
        #
        # @param env [Env] read for the chat's session file
        # @param target [String] what this round is being opened on
        # @return [String, nil]
        def self.not_carried_over(env, target) = EarlierRounds.new(env.journal_path).banner(target)

        private

        # One `/review` line, read. Its own value because "what did they type"
        # and "open a review of it" are separate questions.
        Parsed = Data.define(:target, :base, :scope, :permissive)
        private_constant :Parsed

        # {Command::Args} splits the line, pairs a declared flag with its
        # value and refuses an unknown flag, a duplicated one, or an extra
        # positional by name -- {#refuse_unreadable!} is what is left this
        # command alone, because it names the THING each flag takes and only
        # this command knows that noun.
        def parse(text)
          parsed = Lain::CLI::Command::Args.parse(text, name: "review", usage:, flags: FLAGS, switches: SWITCHES)
          refuse_unreadable!(parsed.pairs)
          Parsed.new(target: parsed.positionals.first, base: parsed.pairs["base"], scope: parsed.pairs["scope"],
                     **parsed.switches)
        end

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

        # The whole card: resolve, build, open, BIND, HOLD, draw.
        #
        # The bind comes before the draw because a human fast enough to answer
        # between the two would send a verdict nothing could route; the HOLD is
        # beside it for the same reason, which is why {#wired} is one step. The
        # surface is checked before the round is journaled: a surface that cannot
        # answer the port must not leave a round on record that nothing ever
        # drew. A draw that refuses lets go of both again
        # ({Lain::Review::Handover::Closing#drawing}).
        #
        # The FOCUS is last, and only if the draw returned: a review that raised
        # on a ceiling is not one to put anybody in front of. It happens ONCE
        # here and never on the render path, because a redraw follows every
        # gesture and would move the human each time they marked a hunk. Its
        # refusal is discarded -- nothing was lost, and the banner already says
        # where the review is.
        def opened(parsed, env, policy:)
          surface = env.replies.review_surface or raise Error, NO_EDITOR
          refuse_over_survey!
          Lain::Review::Surface.check!(surface)
          scope = Lain::Review::Session.scope!(parsed.scope || Lain::Review::Partition::DEFAULT_SCOPE)
          resolved = resolved_target(parsed)
          banner = self.class.not_carried_over(env, target_of(resolved))
          session = round(resolved, surface, env, policy:)
          closing = closing_for(env, surface)
          wired(resolved, session, env, handover(session, env, scope, surface, closing))
          closing.drawing(session) { drawn(resolved, session, scope, banner) }.tap { surface.focus }
        end

        # `/review close`: whatever round the chat holds, let go without a
        # verdict. A headless chat holds none, so the null surface it falls back
        # to is never drawn on -- the outbox refuses first.
        def closed(parsed, env)
          raise Error, CLOSE_TAKES_NOTHING if [parsed.base, parsed.scope, parsed.permissive].any?

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
          shell = @shell_out_factory.call("git", "-C", @root, "rev-parse", "--verify", "--quiet", "--end-of-options",
                                          CLOSE_REF, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
          shell.run_command
          CLOSE_BRANCH_HINT if shell.exitstatus.zero?
        end

        def closing_for(env, surface)
          Lain::Review::Handover::Closing.new(outbox: @outbox, rails: env.replies, surface:)
        end

        # {Lain::CLI::Review::Target}'s own words, reached rather than
        # restated -- EXCEPT for the one case only this command can tell
        # apart from a typo'd branch: a `base` that failed to resolve because
        # NOTHING was named for it, which means the target resolved a DEFAULT
        # this repository does not have. That case names the flag that would
        # fix it; an explicit `--base` that fails to resolve is the human's
        # own typo and keeps the target resolver's plain words.
        def resolved_target(parsed)
          targets.resolve(parsed.target, base: parsed.base)
        rescue Lain::Review::Source::UnknownRef => e
          raise e unless parsed.base.nil? && e.role == "base"

          raise Error, "#{e.message} -- this repository has no default base to review a branch against; " \
                       "name one with --base <ref>"
        end

        # The KIND is the question, not `open?`: a second `/review` over a
        # `/review` rebinds, which is how a human takes a second look at a
        # branch. What may not happen is a changeset review drawn over an open
        # SURVEY, because the two share one set of gesture rails.
        #
        # The word is asked of {Command::Survey}, the one place it is derived. A
        # SETTLED survey is not in the way: {SURVEY_OPEN}'s rationale is "a
        # sidebar the survey's marks cannot reach", and marks handed back and
        # judged have nowhere left to reach -- without that second half a chat
        # that surveyed once could never review a branch again.
        def refuse_over_survey!
          return unless @outbox.held_source == Survey.source_name && @outbox.held_verdict.empty?

          raise Error, format(SURVEY_OPEN, target: @outbox.target)
        end

        # Everything that must be complete before a human can touch the sidebar:
        # the gesture rails, and the outbox a finished review leaves through.
        #
        # The number comes off the RESOLVED TARGET rather than out of the source,
        # so a branch round is held with nowhere to post rather than not held at
        # all -- a round that was never held would answer "no changeset review is
        # open" about one that plainly is.
        def wired(resolved, session, env, handover)
          env.replies.bind_changeset_review(handover)
          @outbox.hold(session:, number: resolved.number, label: resolved.label)
        end

        def round(resolved, surface, env, policy:)
          Lain::Review::Session.open(changeset: Lain::Review::Changeset.new(source: resolved.source),
                                     journal: env.chronicle.record_journal, source: resolved.name, surface:,
                                     bounds: @bounds, policy:, target: target_of(resolved))
        end

        # The TARGET journaled is the label the human reads -- `branch feature`,
        # `pull request 12` -- which is what "the same review" means to them, with
        # a `refs/heads/` spelling of a branch read as the branch it names. The
        # headline keeps the spelling typed.
        def target_of(resolved) = resolved.label.sub(" #{BRANCH_REFS}", " ")

        # What `--permissive` means, asked of the class that owns both the word
        # and the rule it swaps -- the sentence offering the flag lives there.
        def policy_for(parsed) = Lain::Review::Verdict::Policy.strict_unless(permissive: parsed.permissive)

        # The view comes off the SAME editor the surface did, and it has to: a
        # rendering stamp is only resolvable by the view that issued it, so a
        # gesture resolved against a second view is a silently wrong row rather
        # than an error.
        #
        # No `baton:`: nobody is holding one for a review opened outside an epic.
        # The DOCENT is assembled here from the three things only this object
        # holds -- the round's changeset, the run's role spawn and the chat's own
        # journal; {Review::Docent.for} decides whether there is one at all.
        #
        # `reviewing` is what makes `<CR>` open anything: the view's diff surface
        # is built with the editor and holds no round. Sent HERE, beside the
        # bind, because both are wiring that must be complete before the sidebar
        # is drawn. The SCOPE rides along because a gesture that changed a row
        # has to redraw, and the grouping on screen is the one thing that rail
        # cannot ask anybody for -- a session takes it and forgets it.
        def handover(session, env, scope, surface, closing)
          view = env.replies.review_view
          view.reviewing(session.changeset)
          docent = Lain::Review::Docent.for(changeset: session.changeset, surface:, spawn: env.role_spawn,
                                            journal: env.chronicle.record_journal, supervisor: env.supervisor)
          Lain::Review::Handover.new(session:, view:, docent:, closing:,
                                     redraw: Lain::Review::Handover::Redraw.new(scope:))
        end

        # A String answer is the surface's REFUSAL (`spec/support/shared_examples/
        # review_surface.rb`, law #5) and anything else means the editor took it.
        # An editor that refused still gets the headline: the round IS open and
        # the rails ARE bound.
        #
        # A view past a {Lain::Review::Bounds} ceiling is the other outcome and
        # is NOT a String -- {Lain::Review::Session#present} raises -- which
        # {Lain::Review::Handover::Closing#drawing} answers by letting the round
        # go.
        def drawn(resolved, session, scope, banner)
          refusal = session.present(scope:)
          [Lain::Review::OpenedBanner.call(headline(resolved, session, scope), sides: session.changeset.sides),
           banner,
           refusal.is_a?(String) ? refusal : nil].compact.join("\n")
        end

        def headline(resolved, session, scope)
          format(Lain::CLI::Review::HEADLINE, label: resolved.label, scope:,
                                              base: session.changeset.base_ref,
                                              head: session.changeset.head_ref)
        end

        # Unchanged from {Lain::CLI::Review}: PR-vs-branch, the ambiguity refusal
        # and `--base`'s two rules are already that object's and already tested,
        # and a second resolver here would be a second set of answers.
        def targets
          Lain::CLI::Review::Target.new(repo_root: @root, shell_out_factory: @shell_out_factory,
                                        ledger: @ledger)
        end
      end
    end
  end
end
