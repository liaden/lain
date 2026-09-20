# frozen_string_literal: true

module Lain
  module Review
    Partition = Data.define(:label, :files, :detail) do
      # `Partition::Undetailed`, root-qualified: a constant named inside a
      # `Data.define` block resolves against the ENCLOSING module and a bare
      # `Undetailed` would be looked for at `Lain::Review`.
      def initialize(label:, files:, detail: Partition::Undetailed)
        super(label: -legible(label), files: files.freeze, detail:)
      end

      private

      # `Parser#path_text`'s force-encode-and-scrub, and its reason one level
      # up: a label reaches a `Bounds::TooLarge` message, that message is
      # journalled as NDJSON, and `Canonical.dump` raises on a String that is
      # not validly UTF-8. Done ONCE here rather than at each of the three
      # renderers that also have to make it legible. Lossy `?` is right: a label
      # is display text, never evidence.
      def legible(label) = label.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
    end

    # One group of a changeset's files, as some {Partition::Strategy} cut it --
    # and, deliberately, a VIEW that cannot be mistaken for the whole changeset.
    #
    # It answers neither `#hunks` nor `#base_ref`, which are exactly the two
    # messages `Marks#reconcile` reads. That is what makes handing a FILTERED
    # changeset to the pruner impossible rather than merely discouraged: the
    # reconciler drops every key the changeset it is given does not produce, so
    # a filtered one silently prunes the marks on everything the filter hid.
    # tuicr#247 closed that with a `preserve_hunks` flag whose own comment admits
    # the default path still reaches the bug; a flag on the wrong side of the
    # call is the special case, and the missing message is the fix. The hunk
    # count is still reachable the honest way, through {#files}.
    #
    # The core is TWO members and not five. Its ancestor was
    # `Changeset::CommitScope`, which carried `sha`, `subject`, `body`, `numstat`
    # and `files` -- honest for a commit and three lies for anything else, since
    # a directory has no sha, no body and no numstat. So the core is what EVERY
    # strategy can answer, and whatever one knows in addition rides on `detail`.
    #
    # == What a detail answers
    #
    # Four messages. A line accounting, given the partition's files:
    # `added(files)`, `deleted(files)`, `binaries(files)`; and `named(label)`,
    # which is how a REFUSAL names the group.
    #
    # `named` is separate from the label because the two audiences want
    # different things and one member cannot serve both: a 40-column sidebar
    # heading wants the commit's message, while a reader told their review is too
    # large wants something they can `git show`, and subjects repeat (`wip`,
    # `fixup!`, `Merge branch 'main'`).
    #
    # {Undetailed} is the Null Object of that port and the default, and not a
    # stub -- reading the counts off the hunks, and naming a group by its own
    # label, are the only honest answers available to a strategy with no separate
    # accounting. One that HAS an accounting (a commit's numstat is git's, not
    # the diff's) supplies a detail that answers instead. The files ride as an
    # argument rather than being held so a detail is shareable and survives
    # `#with`, which replaces exactly them.
    #
    # Reopened rather than folded into the `Data.define` block, {Anchor}'s
    # reason: {Undetailed} written inside that block would scope to
    # `Lain::Review` and `#initialize`'s default would not find it. The
    # docstring lives HERE for the second half of the same rule -- YARD keeps
    # one per namespace and discards the rest.
    class Partition
      # The detail of a group whose strategy reports none: the accounting read
      # off the diff, which is the one source that describes THIS group rather
      # than whatever a commit or a directory separately claims, and a name that
      # is the group's own label.
      module Undetailed
        module_function

        # {#added} and {#deleted} READ EVERY HUNK, and something draws them:
        # `Frontend::Neovim::ReviewView#partition_header` renders `+n -m` on
        # every group heading, in every scope, so `counted` walks every file it
        # is given each time the sidebar is drawn.
        #
        # Over a diff source that is arithmetic on hunks already parsed. Over a
        # LAZY source it is not -- {Review::LazyFile} chunks on its first
        # `#hunks`, so asking this of an unread corpus chunks it. GUARDED rather
        # than merely recorded: `Session::MarkedChangeset::PartitionRow` answers
        # `#counted?` off its files, the view asks that first, and a group nobody
        # has read is headed by its size instead.
        #
        # The guard lives on the ROW and not here on purpose: this module is
        # handed the files and has no standing to decide what a heading claims,
        # while the row holds them and the view draws them. Do not add the check
        # here as well -- two objects deciding one rendering is how they come to
        # disagree.
        #
        # @param files [Enumerable<#hunks>] the partition's own files
        # @return [Integer] new-side lines this group adds
        def added(files) = counted(files, "+")

        # @return [Integer] old-side lines this group removes
        def deleted(files) = counted(files, "-")

        # Never folded into the two sums above: a binary file carries no hunks
        # at all, so it contributes to neither, and a bare `+0 -0` on an
        # all-binary group would read as "nothing changed".
        #
        # Nothing renders THIS one today: `MarkedChangeset::PartitionRow`
        # forwards it and neither surface draws it, so an all-binary group still
        # shows `+0 -0`. That is true of `binaries` and of nothing else here --
        # {#added} and {#deleted} are drawn on every heading.
        #
        # @return [Integer] files whose lines could not be counted
        def binaries(files) = files.count(&:binary?)

        # How a refusal names this group. A strategy with nothing to add answers
        # the label unchanged -- a directory path already says what it is.
        #
        # @param label [String] the group's own {Partition#label}
        # @return [String]
        def named(label) = label

        def counted(files, marker)
          files.sum { |file| file.hunks.sum { |hunk| hunk.lines.count { |line| line.start_with?(marker) } } }
        end
        private_class_method :counted
      end

      # Loaded HERE, mid-body, because {STRATEGIES} below names all three while
      # this body runs. They cannot load at the top of the file either: each
      # reopens `Partition` to nest itself inside it, and a plain
      # `class Partition` would beat the `Data.define` above to the name. The
      # port before its implementations is the only ordering constraint among
      # the four -- nothing in a strategy's body cites another strategy.
      require_relative "partition/strategy"
      require_relative "partition/whole"
      require_relative "partition/by_directory"
      require_relative "partition/by_commit"

      # Every strategy this ships, by the name a scope spells it with.
      #
      # ONE frozen instance each, and that is the property to keep rather than
      # the tidiness: a strategy is a plain object with identity equality, so a
      # registry minting a fresh one per read would leave two readers holding
      # strategies that are neither `equal?` nor `==`, and the first code to
      # compare or cache a resolved scope would fail silently. A spec pins
      # {Bounds::COMMIT_STRATEGY} and {Session::MarkedChangeset::WALK} as the
      # same object.
      #
      # {Strategy.check!} runs over each one as it is built, which makes "every
      # registered strategy answers the port" a construction guarantee rather
      # than a spec claim -- one that stopped answering raises while `lain` is
      # being required, not the first time a scope is resolved.
      #
      # `strategy.name` and not `strategy::NAME`: the registry reads the PORT, so
      # a strategy whose two spellings disagreed could not register under the one
      # it does not answer.
      #
      # Declared here rather than beside the namespace's other closed sets in
      # `review.rb` because THIS is where the strategies are -- it IS the scope
      # vocabulary now, and the set that lived over there was a second `SCOPES`
      # list naming two of the three.
      STRATEGIES = [Whole, ByCommit, ByDirectory]
                   .map { |strategy| strategy.new.freeze }
                   .each { |strategy| Strategy.check!(strategy) }
                   .to_h { |strategy| [strategy.name.to_sym, strategy] }
                   .freeze

      # What an absent `--scope` means, in ONE place rather than the three that
      # each spelled `cumulative` themselves -- three literals were three chances
      # for the default to name a grouping nothing serves, and `fetch` makes that
      # a load-time refusal instead. The name comes off the REGISTERED strategy
      # rather than off {Whole::NAME}, so the constant cannot outlive the
      # registration: a default that is not a resolvable scope is the one default
      # that must not exist.
      DEFAULT_SCOPE = STRATEGIES.fetch(Whole::NAME.to_sym).name
    end
  end
end
