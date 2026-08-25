# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module CLI
    module Command
      # `/review <pull-request|branch>` at `you>`: draw a colleague's
      # changeset in the editor this chat is ALREADY attached to, and bind its
      # gesture rails to the review it opened.
      #
      # == Why it is a repl command and not a second process
      #
      # Everything waves 3-5 of the review chunk built -- the sidebar, the
      # extmark annotations, the thread pane, the docent -- was reachable only
      # from an epic's implementation stage, which most reviews never enter. The
      # first draft of the fix was `lain review --nvim=<socket>`, and it was
      # measured to be data destruction: the human's only socket is the
      # cockpit's, a second attach re-injects the runtime with its own channel
      # id and reassigns every `_G.__lain.*` function, and the parked chat then
      # loses `:LainReply` and every review verb with no sign that it has.
      #
      # Inside the chat there is no such question. The frontend is attached, the
      # process stays up, {HumanReplies} already routes the acked gestures, and
      # {Repl#run} has already bound the editor into the object this reads --
      # so the whole card is: resolve a target, open a round, bind the rails.
      #
      # == It refuses without an editor rather than drawing into a Null
      #
      # `review_surface` is nil exactly when no editor is attached
      # ({ReviewSeams::Unattached}), and coalescing that to
      # {Review::Surface::Null} here would report an opened review that nothing
      # drew and no gesture could ever reach -- the failure shape this whole
      # chunk was written against. So the nil is a refusal, not a default, and
      # this is the one place the question is asked: everything below the
      # refusal holds a live surface.
      #
      # == Spelling, and the two load-order traps it is between
      #
      # A bare `Review` inside `Lain::CLI::Command` resolves to THIS class, so
      # every reference below is spelled out -- {Lain::CLI::Review}'s own class
      # doc records the same hazard one namespace over. And `lain.rb` loads
      # `lain/cli` BEFORE `lain/review`, so every `Lain::Review::*` name is read
      # from a METHOD body; a constant in the class body would be a load-time
      # NameError. `Lain::CLI::Review::Target` is the exception and is safe
      # either way -- `cli.rb` requires `cli/review` well before `cli/command` --
      # but it is written in a method for one rule rather than two.
      class Review
        # The flags this command carries, each taking the word after it. Anything
        # else beginning with `--` is refused rather than read as a branch name:
        # `refs/heads/--squash` is not a ref anybody has, so silently resolving
        # it would answer a confusing UnknownRef instead of naming the typo.
        FLAGS = %w[--base --scope].freeze

        # The flags that take nothing, held apart from {FLAGS} because the parse
        # drops TWO words for one and ONE word for the other --
        # {Command::Survey::SWITCHES}' rule, and this command's first switch.
        #
        # It is here so the partial-review refusal is honest from a `/review`
        # round as well as a `/survey` one: that sentence
        # ({Review::Verdict::Policy::EveryHunk#refusal}) offers the word as the
        # way past a changeset nobody finished reading, and a command that could
        # not read it would name a remedy unreachable from the very review that
        # refused. Spelled rather than read from
        # {Review::Verdict::Policy::FLAG}, for the load-order reason the class
        # doc gives; {#policy_for} asks that constant what it MEANS.
        SWITCHES = %w[--permissive].freeze

        # A FORMAT rather than the sentence, because the scopes it offers come
        # off {Review::Partition::STRATEGIES} and this class body cannot name
        # anything under `Lain::Review` (see the class doc: `lain.rb` loads
        # `lain/cli` first). {#usage} fills it in from a method body, where the
        # registry exists.
        USAGE = "/review <pull-request|branch> [--base <ref>] [--scope %<scopes>s] [--permissive] -- " \
                "open a changeset review in the attached editor"

        # The refusal a headless chat gets. It names the flag that attaches an
        # editor, because "no editor" is a fact about how this chat was started
        # and the human can do something about it.
        NO_EDITOR = "no editor is attached to this chat, so a changeset review would be drawn nowhere and " \
                    "no gesture could reach it -- start the cockpit with `lain up --nvim` (or " \
                    "`lain chat --nvim <socket>`) and run /review there. `lain review open <target>` " \
                    "renders one as text without an editor."

        # The refusal a changeset review opened over an open SURVEY gets. The
        # mirror of {Command::Survey::ALREADY_OPEN}, and the same rule read from
        # the other side: one chat has one set of gesture rails, so a second
        # SURFACE over the first would rebind them to a sidebar the survey's
        # marks cannot reach. A second `/review` over a `/review` still rebinds
        # -- see {#drawn} for why that recovery has to stay open.
        SURVEY_OPEN = "%<target>s is already open in this chat, and one chat draws one review at a time -- " \
                      "a changeset review opened over it would rebind the gesture rails to a sidebar the " \
                      "survey's marks cannot reach. Run `lain review open <target>` for a text rendering " \
                      "outside this chat."

        # @param outbox [Review::Submit::Outbox] the run's ONE open review, so
        #   the round this opens is reachable from `/review-submit` once the
        #   human has finished with it. Required rather than defaulted: an
        #   outbox nothing else holds is a review that can never be posted, and
        #   nothing about the wiring would look wrong.
        # @param root [String] the repository every git call reads -- the
        #   project the chat was started in, threaded from {Command::Surface}
        #   exactly as {Meta}'s is
        # @param bounds [Lain::Review::Bounds] the sizes past which the sidebar
        #   refuses, handed to the round and enforced by
        #   {Lain::Review::Session#present}. Injected for {Lain::CLI::Review}'s
        #   reason and nothing more: the ceilings are a bench parameter, and a
        #   command that built its own could not be driven past one.
        # @param shell_out_factory [#call] builds the subprocess runner, injected
        #   as {Lain::CLI::Review} and both sources do
        # A default argument is evaluated in the METHOD body at call time, which
        # is why naming `Lain::Review::Bounds` here is safe where a constant in
        # the class body would be a load-time NameError -- {Lain::CLI::Review}'s
        # own constructor spells it the same way for the same reason.
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
        # and "open a review of it" are separate questions, and because the
        # flag/positional split is the only arithmetic here.
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
        # method and its reason: a membership test against the whole list says
        # only "some switch was typed", which stops being the same question as
        # soon as there are two of them.
        def switched(words) = SWITCHES.to_h { |switch| [switch.delete_prefix("--").to_sym, words.include?(switch)] }

        # The flag words, by the INDEX each sits at, carrying the word after it.
        # Keyed by position rather than by name because the rejection above has
        # to drop two words per flag -- the flag and its value -- and only the
        # position says which second word that is. Its own method because
        # Metrics said so, and it was naming the one piece of arithmetic here.
        def flagged(words)
          at = words.each_index.select { |index| FLAGS.include?(words[index]) }
          at.to_h { |index| [index, [words[index].delete_prefix("--"), words[index + 1]]] }
        end

        # A flag at the end of the line has nil for a value, which read as
        # "absent" would silently review against the default base the human just
        # tried to override. Refused with the usage, which is the whole of what
        # they need.
        #
        # A flag FOLLOWED BY A SWITCH has that switch for its value, which is
        # {Command::Survey#refuse_unreadable!}'s guard and became reachable here
        # the moment this command had a switch. `--base --permissive` would
        # otherwise resolve against a ref named `--permissive` AND quietly
        # enable the escape -- two wrong things from one typo, neither of them
        # the word that is actually missing.
        def refuse_unreadable!(values, rest)
          unreadable = values.select { |_, value| value.nil? || value.start_with?("--") }
                             .keys.map { |flag| "--#{flag}" } + rest.grep(/\A--/)
          return if unreadable.empty?

          raise Error, "#{unreadable.join(", ")} is not a flag /review can read -- #{usage}"
        end

        # The whole card: resolve, build, open, BIND, HOLD, draw.
        #
        # The bind comes before the draw, {Tools::RequestReview::Implementation#tell}'s
        # rule: a human fast enough to answer between the two would otherwise
        # send a verdict nothing could route. The surface is checked before the
        # round is journaled, {Lain::CLI::Review#opened}'s rule: a surface that
        # cannot answer the port must not leave a round on record that nothing
        # ever drew.
        #
        # The HOLD is beside the bind and for the bind's own reason, which is
        # why {#wired} is one step and not two.
        #
        # The FOCUS is last, and only if the draw returned: a review that raised
        # on a ceiling is not one to put anybody in front of. It happens ONCE,
        # here, and never on the render path -- {Lain::Review::Surface}'s class
        # doc carries the reason, which is that a redraw follows every gesture
        # and would move the human each time they marked a hunk. Its refusal is
        # discarded for {Command::Survey#drawn_and_held}'s reason: nothing was
        # lost, and the banner already says where the review is.
        #
        # The verdict rule arrives already resolved, {Command::Survey#call}'s
        # split: reading the line and answering what it asked for is one
        # sentence, and none of the six steps above is "decide the rule this
        # review is judged under".
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
        # `/review` rebinds, which is both what {#drawn} documents as the
        # recovery from a bounded refusal and what `command/review_spec.rb`
        # pins. What may not happen is a changeset review drawn over an open
        # SURVEY, because the two share one set of gesture rails.
        #
        # The word is asked of {Command::Survey}, which is the one place it is
        # derived -- a second spelling of `corpus` here, or an opinion about
        # kinds on the outbox, would each be a place for the two to disagree.
        # A SETTLED survey is not in the way. {SURVEY_OPEN}'s own rationale is
        # "a sidebar the survey's marks cannot reach", and marks handed back and
        # judged have nowhere left to reach -- so the verdict is the second half
        # of the question, asked of the round the outbox already holds. Without
        # it a chat that surveyed once could never review a branch again.
        def refuse_over_survey!
          return unless @outbox.held_source == Survey.source_name && @outbox.held_verdict.empty?

          raise Error, format(SURVEY_OPEN, target: @outbox.target)
        end

        # Everything that must be complete before a human can touch the sidebar:
        # the gesture rails, and the outbox a finished review leaves through.
        #
        # The number comes off the RESOLVED TARGET rather than out of the
        # source, so a branch round is held with nowhere to post rather than not
        # held at all -- {Review::Submit::Outbox::Nowhere} is what turns that
        # into a refusal naming the branch, and a round that was never held
        # would answer "no changeset review is open" about one that plainly is.
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
        # and the rule it swaps -- {Command::Survey#policy_for}'s reason, which
        # is that the sentence offering the flag lives on that same class.
        def policy_for(parsed) = Lain::Review::Verdict::Policy.strict_unless(permissive: parsed.permissive)

        # The view comes off the SAME editor the surface did, and it has to: a
        # rendering stamp is only resolvable by the view that issued it, so a
        # gesture resolved against a second view is a silently wrong row rather
        # than an error. {Frontend::Neovim} owns one pair for the life of the
        # session precisely so this is one read rather than an assembly.
        #
        # No `baton:`: nobody is holding one for a review opened outside an epic
        # ({Review::Handover::Unheld} is genuinely nothing). The DOCENT is here,
        # though, off the same editor and on the same line of wiring, assembled
        # from the three things only this object holds -- the round's changeset,
        # the run's role spawn and the chat's own journal. Whether there is a
        # docent at all is {Review::Docent.for}'s decision, and its comment
        # carries the reason.
        #
        # `reviewing` is what makes `<CR>` open anything: the view's diff
        # surface is built with the editor and holds no round, so the changeset
        # has to arrive from whoever opened one. Sent HERE, beside the bind, for
        # the bind's own reason -- both are wiring that must be complete before
        # the sidebar is drawn, because a human fast enough to press `<CR>`
        # between the two would otherwise be told this review opens nothing.
        # The SCOPE rides along for {Lain::Review::Handover::Redraw}: a gesture
        # that changed a row has to draw the sidebar again, and which grouping is
        # on screen is the one thing that rail cannot ask anybody for -- a session
        # takes it and forgets it. This is the caller that chose it.
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
        # the rails ARE bound, so the human needs to know both that and why they
        # cannot see it.
        #
        # A view past a {Lain::Review::Bounds} ceiling is the other outcome and
        # is NOT a String: {Lain::Review::Session#present} raises, so it leaves
        # this method rather than being reported through it, and the round it
        # refused stays open with its rails bound. That is the honest state --
        # the next `/review` rebinds them, and there is an example for it -- and
        # narrowing it would mean checking the ceiling here too, which is the
        # second caller the move of that guard onto `Session#present` deleted.
        def drawn(resolved, session, scope)
          refusal = session.present(scope:)
          [Lain::Review::OpenedBanner.call(headline(resolved, session, scope)),
           refusal.is_a?(String) ? refusal : nil].compact.join("\n")
        end

        def headline(resolved, session, scope)
          format(Lain::CLI::Review::HEADLINE, label: resolved.label, scope:,
                                              base: session.changeset.base_ref,
                                              head: session.changeset.head_ref)
        end

        # Unchanged from {Lain::CLI::Review}, which is what makes this card
        # cheap: PR-vs-branch, the ambiguity refusal and `--base`'s two rules are
        # already that object's, already tested, and a second resolver here would
        # be a second set of answers to the same question.
        def targets = Lain::CLI::Review::Target.new(repo_root: @root, shell_out_factory: @shell_out_factory)
      end
    end
  end
end
