# frozen_string_literal: true

require "active_support/core_ext/string/inflections"

module Lain
  module CLI
    module Command
      # `/survey <path> [--scope <strategy>] [--unbounded]` at `you>` (B14):
      # walk a directory, open a round over it AS IT STANDS in the editor this
      # chat is ALREADY attached to, and bind its gesture rails to the survey it
      # opened.
      #
      # == It is not a thinner {Lain::CLI::Survey}
      #
      # The editor is where a survey is read and marked, so this is the surface
      # the human actually works in and it carries the same two flags the
      # one-shot command does -- a cockpit that cannot open what the command line
      # can is a parity bug waiting to be filed. What differs is entirely what it
      # is wired TO: the chat's own journal rather than a fresh one, the editor's
      # own surface rather than a buffer, and the gesture rails a `<CR>` arrives
      # on, which a one-shot process has none of.
      #
      # It follows {Command::Review} in everything else, including the two rules
      # that cost the most to learn: it refuses without an editor rather than
      # coalescing to {Lain::Review::Surface::Null}, because a survey nothing
      # drew and no gesture could reach is the failure the whole review surface
      # was written against; and it BINDS before it DRAWS, because a human fast
      # enough to press `<CR>` between the two would otherwise send a gesture
      # nothing could route.
      #
      # == One review surface per chat
      #
      # A chat holds one `outbox:` and one set of gesture rails, so a survey
      # opened over an open changeset review would rebind those rails to a
      # sidebar the changeset's marks cannot reach. {#refuse_second_surface!}
      # names the one already open instead. It asks about the KIND rather than
      # merely `open?`: reopening a survey over a survey REBINDS, which is how a
      # human takes a second look at a tree and is {Command::Review}'s documented
      # behaviour for its own second call.
      #
      # Nothing in a chat lets go of a round, so the guard is only safe because
      # no refusal leaves one held -- see {#opened}, which takes the hold after
      # the draw for exactly that reason.
      #
      # There is no `/survey-submit` sibling: a corpus has no pull request under
      # it, and {Lain::Review::Submit::Outbox::Nowhere} already models "a
      # perfectly good review with nowhere to post". So a DRAWN round is held all
      # the same, and `/review-submit` names the survey rather than claiming
      # nothing is open.
      #
      # == Spelling, and the load-order trap it is between
      #
      # {Lain::CLI::Survey} and {Lain::Review} are both spelled out from `Lain`
      # and both read from METHOD bodies -- this class is named `Survey`, so a
      # bare `Survey::Walk` resolves HERE, and `lain.rb` loads `lain/cli` BEFORE
      # `lain/review` and `lain/survey`, so a constant in this class body naming
      # either would be a load-time NameError. {Command::Review}'s class doc
      # records the same pair of hazards one file over.
      class Survey
        # The flags that take the word after them. Anything else beginning with
        # `--` is refused rather than read as a path, {Command::Review}'s rule:
        # a directory literally named `--squash` is not one anybody has, so
        # silently surveying it would answer a confusing Walk::Refused instead of
        # naming the typo.
        FLAGS = %w[--scope].freeze

        # The flags that take nothing. Held apart from {FLAGS} because the parse
        # drops TWO words for one and ONE word for the other, and reading
        # `--scope --unbounded` as "scope is --unbounded" would refuse a flag the
        # human spelled correctly.
        SWITCHES = %w[--unbounded].freeze

        # A FORMAT rather than the sentence: the scopes it offers come off
        # {Lain::Review::Partition::STRATEGIES} and this class body cannot name
        # anything under `Lain::Review`. {#usage} fills it in from a method body,
        # where the registry exists.
        USAGE = "/survey <path> [--scope %<scopes>s] [--unbounded] -- " \
                "open a survey of a directory in the attached editor"

        # The refusal a headless chat gets. It names the flag that attaches an
        # editor, because "no editor" is a fact about how this chat was started
        # and the human can do something about it.
        NO_EDITOR = "no editor is attached to this chat, so a survey would be drawn nowhere and no gesture " \
                    "could reach it -- start the cockpit with `lain up --nvim` (or `lain chat --nvim " \
                    "<socket>`) and run /survey there. `lain survey <path>` renders one as text without " \
                    "an editor."

        # The refusal a second review SURFACE gets, naming the one already open.
        ALREADY_OPEN = "%<target>s is already open in this chat, and one chat draws one review at a time -- " \
                       "a survey opened over it would rebind the gesture rails to a sidebar that review's " \
                       "marks cannot reach. Run `lain survey <path>` for a text rendering outside this chat."

        # A word beginning with `--` that this command does not declare.
        UNKNOWN_FLAG = "%<flags>s is not a flag /survey can read -- %<usage>s"

        # A flag it DOES declare, whose value is missing or is itself a flag.
        # Held apart from {UNKNOWN_FLAG} because the remedy is the opposite one:
        # a human told `--scope` is unreadable deletes the word they got right,
        # when what is missing is the word after it.
        NEEDS_VALUE = "%<flags>s takes a value, and the next word is another flag or nothing at all -- %<usage>s"

        # The word this command's rounds are journaled under, and the one
        # {Command::Review} compares against to recognise an open survey.
        # PUBLIC so that comparison reads one derivation rather than a second
        # spelling of `corpus` -- {Lain::CLI::Survey#source_name}'s reason: a
        # literal is what goes on naming the source after the class it describes
        # is renamed, and {Lain::Review::ChangesetOpened} validates this field
        # for presence only, so nothing downstream would catch it.
        #
        # @return [String]
        def self.source_name = Lain::Review::Source::Corpus.name.split("::").last.underscore

        # @param outbox [Lain::Review::Submit::Outbox] the run's ONE open review.
        #   Required rather than defaulted, {Command::Review}'s rule: an outbox
        #   nothing else holds is a review the rest of the chat cannot see, and
        #   nothing about the wiring would look wrong.
        # @param root [String] the project this chat was started in -- what the
        #   classifier resolves a relative `[sensitivity]` rule against, threaded
        #   from {Command::Surface} exactly as {Meta}'s is. NOT the surveyed
        #   tree, which may point anywhere.
        # @param bounds [Lain::Review::Bounds] the sizes past which the sidebar
        #   refuses. Injected for {Lain::CLI::Survey}'s reason: the ceilings are
        #   a bench parameter, and a command that built its own could not be
        #   driven past one.
        # @param paths [Paths] supplies the HOME the classifier anchors its
        #   home-relative rules against. The round is journaled into the CHAT's
        #   journal, so no sessions directory is resolved here.
        # @param ledger [Lain::Sensitivity::Ledger] the run's ONE region ledger.
        #   REQUIRED, no default and no Null, which is
        #   {Lain::Sensitivity::Ledger}'s own rule stated as "a raise rather than
        #   a note" and repeated by {Lain::Survey::Projection}: a defaulted
        #   ledger lets a forgotten injection become a SECOND one whose releases
        #   nobody ever sees, so a region the human released would still render
        #   `<redacted:N>` here with every object present and nothing about the
        #   wiring looking wrong.
        # @param sensitivity [Lain::Sensitivity, nil] the run's path classifier;
        #   nil builds one from `root` and this project's own rules
        # @param cwd [String] where this chat is STANDING, which is a different
        #   question from `root` ({Lain::Project} splits the two: root is the
        #   authority boundary, cwd is where a relative path resolves). It is
        #   what the corpus names its files from, because it is the directory
        #   the attached editor was started in -- `lain up` pins both panes to
        #   one `-c`, and `47_diff.lua` freezes `getcwd(-1, -1)` at attach --
        #   and naming from `root` instead breaks `/survey .` for every chat
        #   opened below the repository top.
        def initialize(outbox:, ledger:, root: Dir.pwd, cwd: Dir.pwd, bounds: Lain::Review::Bounds.new,
                       paths: Paths.new, sensitivity: nil)
          @outbox = outbox
          @root = root
          @cwd = cwd
          @bounds = bounds
          @paths = paths
          @sensitivity = sensitivity
          @projection = Lain::Survey::Projection.new(ledger:)
          freeze
        end

        def name = "survey"

        # The offered scopes are the registered ones, so a strategy that ships is
        # advertised without a second list to edit -- and one that stops shipping
        # stops being advertised.
        def usage = format(USAGE, scopes: Lain::Review::Partition::STRATEGIES.each_key.to_a.join("|"))

        # @param args [String] the path, and this command's two flags
        # @param env [Env] read for the run's {HumanReplies} (the editor, and
        #   both rails) and its {Chronicle} (the journal this round lands in)
        # @return [String] the headline, whatever the walk would not hand over,
        #   and where to read the survey
        # @raise [Lain::Error] no editor, a review already open, an unknown flag,
        #   a path that is not a directory, an undeclared scope, a grouping a
        #   corpus cannot answer, a tree past a ceiling -- each already worded by
        #   whoever owns the refusal
        def call(args, env)
          parsed = parse(args.to_s.split)
          return usage if parsed.path.nil?

          opened(parsed, env)
        end

        private

        # One `/survey` line, read. Its own value because "what did they type"
        # and "open a survey of it" are separate questions, and because the
        # flag/switch/positional split is the only arithmetic here.
        Parsed = Data.define(:path, :scope, :unbounded)
        private_constant :Parsed

        def parse(words)
          flags = flagged(words)
          rest = words.reject.with_index do |word, index|
            flags.key?(index) || flags.key?(index - 1) || SWITCHES.include?(word)
          end
          values = flags.values.to_h
          refuse_unreadable!(values, rest)
          Parsed.new(path: rest.first, scope: values["scope"], unbounded: words.intersect?(SWITCHES))
        end

        # The flag words, by the INDEX each sits at, carrying the word after it.
        # Keyed by position rather than by name because the rejection above has
        # to drop two words per flag -- the flag and its value -- and only the
        # position says which second word that is.
        def flagged(words)
          at = words.each_index.select { |index| FLAGS.include?(words[index]) }
          at.to_h { |index| [index, [words[index].delete_prefix("--"), words[index + 1]]] }
        end

        # Two different mistakes, told apart because their remedies are
        # opposites. A flag at the end of the line has nil for a value and a
        # flag FOLLOWED BY A FLAG has the next flag for one -- `--scope
        # --unbounded` would otherwise survey at a scope named `--unbounded` --
        # and both of those are a MISSING VALUE, not an unreadable flag. Only a
        # word this command never declared gets {UNKNOWN_FLAG}.
        def refuse_unreadable!(values, rest)
          refuse!(NEEDS_VALUE, values.select { |_, value| value.nil? || value.start_with?("--") }.keys
                                     .map { |flag| "--#{flag}" })
          refuse!(UNKNOWN_FLAG, rest.grep(/\A--/))
        end

        def refuse!(sentence, flags)
          raise Error, format(sentence, flags: flags.join(", "), usage:) if flags.any?
        end

        # The whole card: refuse, resolve, walk, open, BIND, draw, HOLD.
        #
        # The scope is resolved FIRST of the things that can fail on the tree, so
        # a typo refuses before a directory is walked: resolution needs no
        # collaborators, and walking a tree to then reject the word the human
        # typed is work nobody asked for -- and a typo on an oversized tree must
        # answer the typo, not "narrow your tree".
        #
        # BIND BEFORE DRAW, and HOLD AFTER, and the two orderings answer
        # different questions. The bind is early because a human fast enough to
        # press `<CR>` between the two would otherwise send a gesture nothing
        # could route. The hold is late because {#refuse_second_surface!} reads
        # it and NOTHING in a chat lets go of a round: {Lain::Review::Session#present}
        # can still raise -- a line ceiling, a scope a corpus cannot answer --
        # and a round held through that would lock `/review` out of the cockpit
        # for the rest of the session over a survey the human never saw. Rails
        # left bound to it are harmless and honest; a claim that the review is
        # OPEN is neither.
        def opened(parsed, env)
          surface = env.replies.review_surface or raise Error, NO_EDITOR
          refuse_second_surface!
          Lain::Review::Surface.check!(surface)
          scope = Lain::Review::Session.scope!(parsed.scope || default_scope)
          walk = Lain::Survey::Walk.new(root: parsed.path, sensitivity: classifier)
          session = round(walk, ceilings_for(parsed), surface, env)
          bound(session, env, scope)
          drawn_and_held(walk, session, scope)
        end

        # The order {#opened}'s note argues for, in one method so it cannot be
        # read as two independent steps: the hold happens only if the draw
        # returned.
        def drawn_and_held(walk, session, scope) = drawn(walk, session, scope).tap { held(walk, session) }

        # What `--unbounded` means, asked of {Lain::CLI::Survey} rather than
        # answered here: TWO of the three ceilings lift and `max_critique_lines`
        # is carried through, and a second statement of that rule is a second
        # place for it to drift.
        def ceilings_for(parsed) = parsed.unbounded ? Lain::CLI::Survey.unbounded(@bounds) : @bounds

        # Asked about the KIND and not merely `open?`, per the class doc: a
        # survey reopened over a survey rebinds, which is how a human takes a
        # second look at a tree, and only a round opened over something ELSE is
        # a second surface.
        #
        # The comparison is against the word THIS command opens rounds under, so
        # the outbox stays a holder rather than acquiring an opinion about kinds.
        def refuse_second_surface!
          return unless @outbox.open? && @outbox.held_source != self.class.source_name

          raise Error, format(ALREADY_OPEN, target: @outbox.target)
        end

        # The flag's absence, not a second declaration of the vocabulary: the
        # word comes off {Lain::Review::Partition::DEFAULT_SCOPE}, which is read
        # out of the registry, and it still goes through
        # {Lain::Review::Session.scope!} on the same line every explicit scope
        # does.
        def default_scope = Lain::Review::Partition::DEFAULT_SCOPE

        # Anchored where the human is STANDING and not at the surveyed tree:
        # {Lain::Sensitivity} resolves a project's relative rules against a
        # working directory, and the table in force is the one belonging to the
        # project this chat was started in. Built lazily rather than in the
        # constructor because the constructor freezes, and a memo written after
        # that raises FrozenError at its first caller, mid-run.
        def classifier
          @sensitivity || Lain::Sensitivity.new(home: @paths.home, cwd: @root,
                                                rules: Config.sensitivity(root: @root))
        end

        # `named_from:` is the chat's CWD and never the surveyed tree, because
        # a name minted here is resolved somewhere else: the editor opens a row
        # against the directory it was started in (`47_diff.lua`'s frozen ROOT),
        # and a verdict's refusal is read by a human standing in this one. It is
        # not `@root` either -- that is the authority boundary, which sits at the
        # repository top while a monorepo chat stands in a subtree, and naming
        # from it would break the `/survey .` that works today.
        def round(walk, ceilings, surface, env)
          source = Lain::Review::Source::Corpus.new(walk:, projection: @projection, bounds: ceilings, named_from: @cwd)
          Lain::Review::Session.open(changeset: Lain::Review::Changeset.new(source:),
                                     journal: env.chronicle.record_journal, source: source_name, surface:,
                                     bounds: ceilings)
        end

        def source_name = self.class.source_name

        # The gesture rails, complete before a human can touch the sidebar.
        def bound(session, env, scope) = env.replies.bind_changeset_review(handover(session, env, scope))

        # The round, where the rest of the chat can see it -- taken only once
        # something was drawn, per {#opened}.
        #
        # `number:` is nil and always will be: there is no pull request under a
        # corpus, which is exactly what {Lain::Review::Submit::Outbox::Nowhere}
        # says instead of "no changeset review is open" about one plainly open.
        def held(walk, session) = @outbox.hold(session:, number: nil, label: label(walk))

        def label(walk) = "survey of #{walk.root}"

        # The view comes off the SAME editor the surface did, {Command::Review}'s
        # rule: a rendering stamp is only resolvable by the view that issued it,
        # so a gesture resolved against a second view is a silently wrong row
        # rather than an error.
        #
        # The SCOPE rides along because a gesture that changed a row has to draw
        # the sidebar again ({Lain::Review::Handover::Redraw}) and the grouping on
        # screen is the one thing the gesture rail cannot ask anybody for: a
        # session takes it and forgets it. This is the caller that chose it, on
        # the same line of wiring as the bind.
        def handover(session, env, scope)
          view = env.replies.review_view
          view.reviewing(session.changeset)
          Lain::Review::Handover.new(session:, view:, redraw: Lain::Review::Handover::Redraw.new(scope:))
        end

        def drawn(walk, session, scope)
          answer = session.present(scope:)
          files = session.changeset.files
          headline = format(Lain::CLI::Survey::HEADLINE, root: walk.root, scope:, count: files.size,
                                                         noun: noun(files.size))
          [Lain::Review::OpenedBanner.call(headline),
           disclosure(walk.withheld),
           answer.is_a?(String) ? answer : nil].compact.join("\n")
        end

        # Nothing withheld says nothing, {Lain::CLI::Survey#disclosure}'s rule
        # and its sentences: a listing short by one file with no word about why
        # is the silent narrowing the whole secret boundary is written against,
        # and a note on every ordinary survey is the noise that requirement was
        # written against.
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
