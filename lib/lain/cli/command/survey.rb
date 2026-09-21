# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Lain
  module CLI
    module Command
      # `/survey <path> [--scope <strategy>] [--unbounded] [--permissive]` at
      # `you>`: walk a directory and open a round over it in the editor this
      # chat is ALREADY attached to, binding the gesture rails to it.
      #
      # Not a thinner {Lain::CLI::Survey}: what differs is what it is wired TO
      # -- the chat's own journal, the editor's surface, and the gesture rails
      # a `<CR>` arrives on, which a one-shot process has none of.
      # `--permissive` is its alone, because `lain survey` judges no verdict.
      #
      # It refuses without an editor rather than coalescing to
      # {Lain::Review::Surface::Null}, {Command::Review}'s rule: a survey
      # nothing drew and no gesture could reach is the failure the whole review
      # surface was written against.
      #
      # A chat holds one `outbox:` and one set of gesture rails, so a survey
      # over an open changeset review would rebind them to a sidebar that
      # review's marks cannot reach -- {#refuse_second_surface!} refuses that.
      # There is no `/survey-submit`: a corpus has no pull request under it,
      # and {Lain::Review::Submit::Outbox::Nowhere} already models "a perfectly
      # good review with nowhere to post".
      #
      # This class is named `Survey`, so a bare `Survey::Walk` resolves HERE and
      # dies -- every name from the review and survey tiers is therefore
      # qualified from `Lain`, in the class body and in a method body alike.
      class Survey
        # The flags that take the word after them. Anything else beginning with
        # `--` is refused rather than read as a path: a directory named
        # `--squash` is nobody's, so surveying it would hide the typo.
        FLAGS = %w[--scope].freeze

        # The flags that take nothing. Held apart from {FLAGS} because the parse
        # drops TWO words for one and ONE for the other, and reading
        # `--scope --unbounded` as "scope is --unbounded" would refuse a flag
        # spelled correctly. `--permissive` is spelled here rather than read
        # from {Lain::Review::Verdict::Policy::FLAG}, which {#policy_for} asks
        # what the word MEANS.
        SWITCHES = %w[--unbounded --permissive].freeze

        # A FORMAT rather than the sentence: the scopes come off
        # {Lain::Review::Partition::STRATEGIES}, and {#usage} fills them in, so a
        # strategy registered there cannot leave this line advertising a stale set.
        USAGE = "/survey <path> [--scope %<scopes>s] [--unbounded] [--permissive] -- " \
                "open a survey of a directory in the attached editor"

        # The refusal a headless chat gets. It names the flag that attaches an
        # editor, because that is a fact the human can act on.
        NO_EDITOR = "no editor is attached to this chat, so a survey would be drawn nowhere and no gesture " \
                    "could reach it -- start the cockpit with `lain up --nvim` (or `lain chat --nvim " \
                    "<socket>`) and run /survey there. `lain survey <path>` renders one as text without " \
                    "an editor."

        # The refusal a second review SURFACE gets, naming the one already open.
        ALREADY_OPEN = "%<target>s is already open in this chat, and one chat draws one review at a time -- " \
                       "a survey opened over it would rebind the gesture rails to a sidebar that review's " \
                       "marks cannot reach. Run `/review close` to let it go without a verdict, or " \
                       "`lain survey <path>` for a text rendering outside this chat."

        # A flag it DOES declare, whose value is missing or is itself a flag.
        # Apart from {UNKNOWN_FLAG} because the remedy is the opposite one: a
        # human told `--scope` is unreadable deletes the word they got right.
        NEEDS_VALUE = "%<flags>s takes a value, and the next word is another flag or nothing at all -- %<usage>s"

        # The word this command's rounds are journaled under, and what
        # {Command::Review} compares against to recognise an open survey.
        # PUBLIC so that comparison reads one derivation rather than a second
        # spelling of `corpus`: {Lain::Review::ChangesetOpened} validates this
        # field for presence only, so nothing downstream would catch a drift.
        #
        # @return [String]
        def self.source_name = Lain::Review::Source::Corpus.name.split("::").last.underscore

        # @param outbox [Lain::Review::Submit::Outbox] the run's ONE open
        #   review. Required rather than defaulted: an outbox nothing else
        #   holds is a review the rest of the chat cannot see, and nothing
        #   about the wiring would look wrong.
        # @param bounds [Lain::Review::Bounds] the sizes past which the sidebar
        #   refuses. Injected because the ceilings are a bench parameter, and a
        #   command that built its own could not be driven past one.
        # @param ledger [Lain::Sensitivity::Ledger] the run's ONE region ledger.
        #   REQUIRED, no default and no Null: a defaulted one lets a forgotten
        #   injection become a SECOND ledger whose releases nobody ever sees, so
        #   a region the human released would still render `<redacted:N>` with
        #   every object present and nothing about the wiring looking wrong.
        # @param sensitivity [#classify] the run's path boundary -- the board's
        #   own {Lain::Sensitivity::Policy}, whose table was compiled once at
        #   startup. REQUIRED for the ledger's reason one boundary over
        #   (ARCHITECTURE.md, "The secret boundary"), and it is the reason the
        #   project root is no longer a parameter here.
        # @param cwd [String] where this chat is STANDING, a different question
        #   from the project ROOT the board was built at ({Lain::Project}
        #   splits the authority boundary from where a relative path resolves).
        #   The corpus names its files from it because it is the directory the
        #   attached editor was started in; naming from the root breaks
        #   `/survey .` for every chat opened below the repository top.
        def initialize(outbox:, ledger:, sensitivity:, cwd: Dir.pwd, bounds: Lain::Review::Bounds.new)
          @outbox = outbox
          @cwd = cwd
          @bounds = bounds
          @sensitivity = sensitivity
          @projection = Lain::Survey::Projection.new(ledger:)
          freeze
        end

        # PUBLIC so a wiring spec can assert IDENTITY, {Surface#outbox}'s reason.
        attr_reader :sensitivity

        def name = "survey"

        # The offered scopes are the registered ones, so a strategy that ships is
        # advertised without a second list to edit -- and one that stops shipping
        # stops being advertised.
        def usage = format(USAGE, scopes: Lain::Review::Partition::STRATEGIES.each_key.to_a.join("|"))

        # The switches resolve here rather than inside {#opened}: reading the
        # line and answering what it asked for is one sentence.
        #
        # It sits ABOVE the tags deliberately: YARD reads a tag's text as running
        # to the next tag or to the end of the comment, so a paragraph written
        # under `@raise` is published as part of that exception's description.
        # yard-lint does not catch it.
        #
        # @param args [String] the path, and this command's three flags
        # @param env [Env] read for the run's {HumanReplies} (the editor, and
        #   both rails) and its {Chronicle} (the journal this round lands in)
        # @return [String] the headline, whatever the walk would not hand over,
        #   and where to read the survey
        # @raise [Lain::Error] no editor, a review already open, an unknown
        #   flag, a path that is not a directory, an undeclared scope, a
        #   grouping a corpus cannot answer, a tree past a ceiling -- each
        #   already worded by whoever owns the refusal
        def call(args, env)
          parsed = parse(args.to_s)
          return usage if parsed.path.nil?

          opened(parsed, env, ceilings: ceilings_for(parsed), policy: policy_for(parsed))
        end

        private

        # One `/survey` line, read. Its own value because "what did they type"
        # and "open a survey of it" are separate questions.
        Parsed = Data.define(:path, :scope, :unbounded, :permissive)
        private_constant :Parsed

        # {Command::Args} splits the line, pairs a declared flag with its
        # value and refuses an unknown flag, a duplicated one, or an extra
        # positional by name -- {#refuse_unreadable!} is what is left this
        # command alone, because "takes a value" is a noun only this command
        # knows to use.
        def parse(text)
          parsed = Lain::CLI::Command::Args.parse(text, name: "survey", usage:, flags: FLAGS, switches: SWITCHES)
          refuse_unreadable!(parsed.pairs)
          Parsed.new(path: parsed.positionals.first, scope: parsed.pairs["scope"], **parsed.switches)
        end

        # A flag at the end of the line has nil for a value, and a flag
        # FOLLOWED BY A FLAG has the next flag for one -- `--scope --unbounded`
        # would otherwise survey at a scope named `--unbounded` -- and both are
        # a MISSING VALUE, which is the one refusal {Command::Args} leaves to
        # the caller.
        def refuse_unreadable!(pairs)
          missing = pairs.select { |_, value| value.nil? || value.start_with?("--") }.keys
          raise Error, format(NEEDS_VALUE, flags: missing.map { |flag| "--#{flag}" }.join(", "), usage:) if
            missing.any?
        end

        # The whole card: refuse, resolve, walk, open, BIND, draw, HOLD.
        #
        # The scope resolves FIRST of the things that can fail on the tree:
        # resolution needs no collaborators, and a typo on an oversized tree must
        # answer the typo, not "narrow your tree".
        #
        # BIND BEFORE DRAW, because a human fast enough to press `<CR>` between
        # the two would send a gesture nothing could route. HOLD AFTER, because
        # {#refuse_second_surface!} reads the hold: {Lain::Review::Session#present}
        # can still raise, and a round held through that would lock `/review` out
        # over a survey the human never saw. A draw that refuses lets go of the
        # bind again ({Lain::Review::Handover::Closing#drawing}), and the outbox
        # releases only that round -- which it never held -- so a settled review
        # the chat still holds stays held.
        #
        # FOCUS IS LAST and only if the draw returned: somebody yanked into a
        # tabpage holding nothing is worse off than left reading the refusal. It
        # happens ONCE here, never on the render path, because a redraw follows
        # every gesture and would take the human out of the chat each time they
        # marked a hunk. Its refusal is DISCARDED alone among this command's
        # editor calls -- a single `gt` reaches the survey, and the banner already
        # says where. Every refusal meaning work was LOST still travels.
        def opened(parsed, env, ceilings:, policy:)
          surface = env.replies.review_surface or raise Error, NO_EDITOR
          refuse_second_surface!
          Lain::Review::Surface.check!(surface)
          # The flag's absence, not a second declaration of the vocabulary: the
          # default is read out of the strategy registry, so a scope that stops
          # shipping stops being the default, and it goes through `scope!` on
          # this one line whether the human named it or not.
          scope = Lain::Review::Session.scope!(parsed.scope || Lain::Review::Partition::DEFAULT_SCOPE)
          walk = Lain::Survey::Walk.new(root: parsed.path, sensitivity: @sensitivity)
          banner = Review.not_carried_over(env, target_of(walk))
          session = round(walk, ceilings, surface, env, policy:)
          closing = Lain::Review::Handover::Closing.new(outbox: @outbox, rails: env.replies, surface:)
          # The gesture rails, complete before a human can touch the sidebar.
          env.replies.bind_changeset_review(handover(session, env, scope, surface, closing))
          closing.drawing(session) { drawn_and_held(walk, session, scope, banner) }.tap { surface.focus }
        end

        # One method so it cannot be read as two independent steps: the hold
        # happens only if the draw returned.
        def drawn_and_held(walk, session, scope, banner)
          drawn(walk, session, scope, banner).tap { held(walk, session) }
        end

        # What `--unbounded` means, asked of {Lain::CLI::Survey} rather than
        # answered here: TWO of the three ceilings lift and `max_critique_lines`
        # is carried through, and a second statement of that rule would drift.
        def ceilings_for(parsed) = parsed.unbounded ? Lain::CLI::Survey.unbounded(@bounds) : @bounds

        # What `--permissive` means, asked of the class that owns both the word
        # and the rule it swaps: the sentence that OFFERS the flag lives there,
        # so a survey resolving the word itself would be free to disagree with
        # the refusal that named it.
        def policy_for(parsed) = Lain::Review::Verdict::Policy.strict_unless(permissive: parsed.permissive)

        # Asked about the KIND and not merely `open?`: a survey reopened over a
        # survey rebinds, which is how a human takes a second look at a tree, so
        # only a round opened over something ELSE is a second surface. And asked
        # of a LIVE round only -- {ALREADY_OPEN}'s rationale is "a sidebar that
        # review's marks cannot reach", and marks handed back and judged have
        # nowhere left to reach, so a chat that has settled a changeset review
        # may survey again.
        def refuse_second_surface!
          return unless @outbox.open? && @outbox.held_verdict.empty? && @outbox.held_source != self.class.source_name

          raise Error, format(ALREADY_OPEN, target: @outbox.target)
        end

        # `named_from:` is the chat's CWD and never the surveyed tree, because a
        # name minted here is resolved elsewhere: the editor opens a row against
        # the directory it was started in, and a verdict's refusal is read by a
        # human standing in this one. Not the project root either -- that sits at
        # the repository top while a monorepo chat stands in a subtree, and
        # naming from it would break the `/survey .` that works today.
        #
        # The TARGET journaled is the walk root's REALPATH, so `big`, `big/`,
        # `./big` and a link to it are the one tree they name.
        def round(walk, ceilings, surface, env, policy:)
          source = Lain::Review::Source::Corpus.new(walk:, projection: @projection, bounds: ceilings, named_from: @cwd)
          Lain::Review::Session.open(changeset: Lain::Review::Changeset.new(source:),
                                     journal: env.chronicle.record_journal, source: self.class.source_name,
                                     surface:, bounds: ceilings, policy:, target: target_of(walk))
        end

        def target_of(walk) = File.realpath(walk.root)

        # The round, where the rest of the chat can see it -- taken only once
        # something was drawn, per {#opened}. `number:` is nil and always will
        # be: there is no pull request under a corpus, which is what
        # {Lain::Review::Submit::Outbox::Nowhere} says instead of "no changeset
        # review is open" about one plainly open.
        def held(walk, session) = @outbox.hold(session:, number: nil, label: label(walk))

        def label(walk) = "survey of #{walk.root}"

        # The view comes off the SAME editor the surface did: a rendering stamp
        # is only resolvable by the view that issued it, so a gesture resolved
        # against a second view is a silently wrong row rather than an error.
        #
        # The SCOPE rides along because a gesture that changed a row has to
        # redraw, and the grouping on screen is the one thing the gesture rail
        # cannot ask anybody for -- a session takes it and forgets it. The DOCENT
        # is assembled here for the same reason: this is the one place holding
        # the round's changeset, the run's role spawn and the chat's own journal.
        def handover(session, env, scope, surface, closing)
          view = env.replies.review_view
          view.reviewing(session.changeset)
          docent = Lain::Review::Docent.for(changeset: session.changeset, surface:, spawn: env.role_spawn,
                                            journal: env.chronicle.record_journal)
          Lain::Review::Handover.new(session:, view:, docent:, closing:,
                                     redraw: Lain::Review::Handover::Redraw.new(scope:))
        end

        def drawn(walk, session, scope, banner)
          answer = session.present(scope:)
          files = session.changeset.files
          headline = format(Lain::CLI::Survey::HEADLINE, root: walk.root, scope:, count: files.size,
                                                         noun: noun(files.size))
          [Lain::Review::OpenedBanner.call(headline, sides: session.changeset.sides),
           banner,
           disclosure(walk.withheld),
           answer.is_a?(String) ? answer : nil].compact.join("\n")
        end

        # Nothing withheld says nothing, {Lain::CLI::Survey#disclosure}'s rule:
        # a listing short by one file with no word about why is the silent
        # narrowing the secret boundary exists against, and a note on every
        # ordinary survey is the noise it exists against too.
        def disclosure(withheld)
          return nil if withheld.empty?

          [format(Lain::CLI::Survey::WITHHELD, count: withheld.size, noun: noun(withheld.size, "path")),
           *withheld.map { |held| "#{Lain::CLI::Survey::INDENT}#{held}" }].join("\n")
        end

        def noun(count, word = "file") = word.pluralize(count)
      end
    end
  end
end
