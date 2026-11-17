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
      # `--permissive` is its alone, because `qa-lain survey` judges no verdict.
      #
      # It refuses without an editor rather than coalescing to
      # {Lain::Review::Surface::Null}, {Command::Review}'s rule: a survey
      # nothing drew and no gesture could reach is the failure the whole review
      # surface was written against.
      #
      # A chat holds one `outbox:` and one set of gesture rails, so a survey
      # over an open changeset review would rebind them to a sidebar that
      # review's marks cannot reach -- {Lain::Review::Submit::Outbox#refuse_other!} refuses that.
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
                    "<socket>`) and run /survey there."

        # The refusal a second review SURFACE gets, naming the one already open.
        ALREADY_OPEN = "%<target>s is already open in this chat, and one chat draws one review at a time -- " \
                       "a survey opened over it would rebind the gesture rails to a sidebar that review's " \
                       "marks cannot reach. Run `/review close` to let it go without a verdict."

        # A flag it DOES declare, whose value is missing or is itself a flag.
        # Apart from {UNKNOWN_FLAG} because the remedy is the opposite one: a
        # human told `--scope` is unreadable deletes the word they got right.
        NEEDS_VALUE = "%<flags>s takes a value, and the next word is another flag or nothing at all -- %<usage>s"

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
        # @param paths [Paths] the state home an earlier session of the chain is found under
        def initialize(outbox:, ledger:, sensitivity:, paths:, cwd: Dir.pwd, bounds: Lain::Review::Bounds.new)
          @outbox = outbox
          @cwd = cwd
          @bounds = bounds
          @sensitivity = sensitivity
          @projection = Lain::Survey::Projection.new(ledger:)
          @round = ReviewRound.new(outbox:, paths:)
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

        # The whole card: refuse, resolve, walk, then open the round with `ReviewRound`.
        #
        # The scope resolves FIRST of the things that can fail on the tree:
        # resolution needs no collaborators, and a typo on an oversized tree must
        # answer the typo, not "narrow your tree".
        #
        # The HOLD is AFTER the draw: {Lain::Review::Session#present} can still
        # raise, and a round held through that would lock `/review` out over a
        # survey the human never saw. The outbox releases only that round -- which
        # it never held -- so a settled review the chat still holds stays held.
        #
        # The focus is the round's, and its refusal is DISCARDED alone among this
        # command's editor calls -- a single `gt` reaches the survey, and the banner
        # already says where.
        def opened(parsed, env, ceilings:, policy:)
          env.replies.review_surface or raise Error, NO_EDITOR
          @outbox.refuse_other!(Lain::Review::Submit::Outbox::CORPUS, sentence: ALREADY_OPEN)
          scope = scope_of(parsed)
          walk = Lain::Survey::Walk.new(root: parsed.path, sensitivity: @sensitivity)
          @round.open(opening(walk, env, ceilings, policy), env, scope:, hold_after_draw: true)
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

        # `named_from:` is the chat's CWD and never the surveyed tree, because a
        # name minted here is resolved elsewhere: the editor opens a row against
        # the directory it was started in, and a verdict's refusal is read by a
        # human standing in this one. Not the project root either -- that sits at
        # the repository top while a monorepo chat stands in a subtree, and
        # naming from it would break the `/survey .` that works today.
        #
        # The TARGET journaled is the walk root's REALPATH, so `big`, `big/`,
        # `./big` and a link to it are the one tree they name.
        def opening(walk, env, ceilings, policy)
          source = Lain::Review::Source::Corpus.new(walk:, projection: @projection, bounds: ceilings, named_from: @cwd)
          target = target_of(walk)
          ReviewRound::Opening.new(
            source:, source_name: Lain::Review::Submit::Outbox::CORPUS, target:, label: "survey of #{walk.root}",
            number: nil, bounds: ceilings, policy:, spawn: env.role_spawn.within(worker_env_at(target)),
            headline: ->(session, scope) { headline(walk, session, scope) }, name_for: from_root_of(walk),
            disclosure: disclosure(walk.withheld)
          )
        end

        def target_of(walk) = File.realpath(walk.root)

        def scope_of(parsed) = Lain::Review::Session.scope!(parsed.scope || Lain::Review::Partition::DEFAULT_SCOPE)

        # Notes are named from the chat's cwd for the human; the docent's child stands in the surveyed tree.
        def from_root_of(walk)
          ->(path) { Lain::Review::Source::Corpus::Prefix.between(walk.root, File.expand_path(path, @cwd)) }
        end

        # A tree outside the project is gated by names counted from ITS root, so
        # the docent's child works there.
        def worker_env_at(root) = Lain::WorkerEnv.new(cwd: root, env: {}, checkout: root)

        def headline(walk, session, scope)
          files = session.changeset.files
          format(Lain::CLI::Survey::HEADLINE, root: walk.root, scope:, count: files.size, noun: noun(files.size))
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
