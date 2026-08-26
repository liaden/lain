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
      # Spelling, between two load-order traps: a bare `Review` inside
      # `Lain::CLI::Command` resolves to THIS class, so every reference below is
      # spelled out; and `lain.rb` loads `lain/cli` BEFORE `lain/review`, so
      # every `Lain::Review::*` name is read from a METHOD body -- a constant in
      # the class body would be a load-time NameError.
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
        # remedy unreachable from the very review that refused. Spelled rather
        # than read from {Review::Verdict::Policy::FLAG} for the class doc's
        # load-order reason; {#policy_for} asks that constant what it MEANS.
        SWITCHES = %w[--permissive].freeze

        # A FORMAT rather than the sentence: the scopes come off
        # {Review::Partition::STRATEGIES}, which this class body cannot name
        # (see the class doc). {#usage} fills it in from a method body.
        USAGE = "/review <pull-request|branch> [--base <ref>] [--scope %<scopes>s] [--permissive] -- " \
                "open a changeset review in the attached editor"

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
        # rebinds; see {#drawn} for why that recovery has to stay open.
        SURVEY_OPEN = "%<target>s is already open in this chat, and one chat draws one review at a time -- " \
                      "a changeset review opened over it would rebind the gesture rails to a sidebar the " \
                      "survey's marks cannot reach. Run `lain review open <target>` for a text rendering " \
                      "outside this chat."

        # A default argument is evaluated in the METHOD body at call time, which
        # is why naming `Lain::Review::Bounds` below is safe where a constant in
        # the class body would be a load-time NameError.
        #
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
        def initialize(outbox:, root: Dir.pwd, bounds: Lain::Review::Bounds.new,
                       shell_out_factory: Mixlib::ShellOut.public_method(:new))
          @outbox = outbox
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
        # @return [String] the headline and where to read the review
        # @raise [Lain::Error] no editor, an unknown flag, an unresolvable ref,
        #   an ambiguous target, an undeclared scope, a changeset past a
        #   ceiling -- each already worded by whoever owns the refusal
        def call(args, env)
          parsed = parse(args.to_s.split)
          return usage if parsed.target.nil?

          opened(parsed, env, policy: policy_for(parsed))
        end

        private

        # One `/review` line, read. Its own value because "what did they type"
        # and "open a review of it" are separate questions.
        Parsed = Data.define(:target, :base, :scope, :permissive)
        private_constant :Parsed

        def parse(words)
          flags = flagged(words)
          rest = words.reject.with_index do |word, index|
            flags.key?(index) || flags.key?(index - 1) || SWITCHES.include?(word)
          end
          values = flags.values.to_h
          refuse_unreadable!(values, rest)
          Parsed.new(target: rest.first, base: values["base"], scope: values["scope"], **switched(words))
        end

        # Each switch by the name it declares, {Command::Survey#switched}'s
        # reason: a membership test against the whole list says only "some
        # switch was typed", which stops being the same question at two.
        def switched(words) = SWITCHES.to_h { |switch| [switch.delete_prefix("--").to_sym, words.include?(switch)] }

        # The flag words, by the INDEX each sits at, carrying the word after it.
        # Keyed by position because the rejection above drops two words per flag
        # -- the flag and its value -- and only the position says which second
        # word that is.
        def flagged(words)
          at = words.each_index.select { |index| FLAGS.include?(words[index]) }
          at.to_h { |index| [index, [words[index].delete_prefix("--"), words[index + 1]]] }
        end

        # A flag at the end of the line has nil for a value, which read as
        # "absent" would silently review against the default base the human just
        # tried to override. A flag FOLLOWED BY A SWITCH has that switch for its
        # value: `--base --permissive` would resolve against a ref named
        # `--permissive` AND quietly enable the escape -- two wrong things from
        # one typo, neither of them the word that is actually missing.
        def refuse_unreadable!(values, rest)
          unreadable = values.select { |_, value| value.nil? || value.start_with?("--") }
                             .keys.map { |flag| "--#{flag}" } + rest.grep(/\A--/)
          return if unreadable.empty?

          raise Error, "#{unreadable.join(", ")} is not a flag /review can read -- #{usage}"
        end

        # The whole card: resolve, build, open, BIND, HOLD, draw.
        #
        # The bind comes before the draw because a human fast enough to answer
        # between the two would send a verdict nothing could route; the HOLD is
        # beside it for the same reason, which is why {#wired} is one step. The
        # surface is checked before the round is journaled: a surface that cannot
        # answer the port must not leave a round on record that nothing ever
        # drew.
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
          resolved = targets.resolve(parsed.target, base: parsed.base)
          session = round(resolved, surface, env, policy:)
          wired(resolved, session, env, scope, surface)
          drawn(resolved, session, scope).tap { surface.focus }
        end

        # The KIND is the question, not `open?`: a second `/review` over a
        # `/review` rebinds, which is {#drawn}'s documented recovery from a
        # bounded refusal. What may not happen is a changeset review drawn over
        # an open SURVEY, because the two share one set of gesture rails.
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
        def wired(resolved, session, env, scope, surface)
          env.replies.bind_changeset_review(handover(session, env, scope, surface))
          @outbox.hold(session:, number: resolved.number, label: resolved.label)
        end

        def round(resolved, surface, env, policy:)
          Lain::Review::Session.open(changeset: Lain::Review::Changeset.new(source: resolved.source),
                                     journal: env.chronicle.record_journal, source: resolved.name, surface:,
                                     bounds: @bounds, policy:)
        end

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
        def handover(session, env, scope, surface)
          view = env.replies.review_view
          view.reviewing(session.changeset)
          docent = Lain::Review::Docent.for(changeset: session.changeset, surface:, spawn: env.role_spawn,
                                            journal: env.chronicle.record_journal)
          Lain::Review::Handover.new(session:, view:, docent:, redraw: Lain::Review::Handover::Redraw.new(scope:))
        end

        # A String answer is the surface's REFUSAL (`spec/support/shared_examples/
        # review_surface.rb`, law #5) and anything else means the editor took it.
        # An editor that refused still gets the headline: the round IS open and
        # the rails ARE bound.
        #
        # A view past a {Lain::Review::Bounds} ceiling is the other outcome and
        # is NOT a String -- {Lain::Review::Session#present} raises -- so the
        # round it refused stays open with its rails bound. That is the honest
        # state, and the next `/review` rebinds them; narrowing it would mean
        # checking the ceiling here too, which is the second caller that moving
        # the guard onto `Session#present` deleted.
        def drawn(resolved, session, scope)
          refusal = session.present(scope:)
          [Lain::Review::OpenedBanner.call(headline(resolved, session, scope), sides: session.changeset.sides),
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
        def targets = Lain::CLI::Review::Target.new(repo_root: @root, shell_out_factory: @shell_out_factory)
      end
    end
  end
end
