# frozen_string_literal: true

module Lain
  class Project
    # The nearest git repository at or above a directory -- and, when there is
    # none, how far the search climbed and what stopped it.
    #
    # HELD HERE, not on a CLI class, because three layers ask the same
    # question: the chat's worktree backend, `lain worktrees gc`, and
    # `--isolation none` answering for a handback that still has to merge
    # somewhere. Two of those sit BELOW the CLI in the load manifest, so
    # publishing the search from there inverted the layering --
    # `lib/lain/isolation/` reached up into `lib/lain/cli/` for it, which was
    # the lesser of two evils only because the alternative was a second walk
    # that could disagree with the first.
    #
    # THE STOP RULE IS NOT DECORATION. This walk once had no ceiling, so on a
    # box whose `$HOME` is itself a git work-tree -- the `~/.cfg` dotfiles
    # convention -- a chat started anywhere under home resolved HOME as the
    # repository and branched worker checkouts off the dotfiles repo.
    # {Resolver::Walk} cuts the ancestry at the first refused directory, so a
    # repository BELOW one is still found and one AT or above it is not
    # reachable at all.
    #
    # WHAT IT DELIBERATELY DOES NOT DECIDE: which error a caller raises, or
    # what that caller says it was trying to do. Three commands have three
    # different remedies -- run from a repository, use `--isolation none`, give
    # the reaper a repository -- and the remedy is the half of a refusal a
    # human acts on. So each caller keeps its own error class and its own
    # sentence, and takes only {#searched} from here.
    Repository = Data.define(:path, :boundary, :reason) do
      # @param root [String] a resolved absolute directory
      # @param paths [Paths] supplies the XDG bases the stop rule names
      # @param home [String, nil] the user's home directory
      # @param filesystem [#exist?] injected so a spec needs no real ancestry
      # @return [Repository]
      # @raise [Resolver::UnusableHome] when `home` cannot bound the search
      def self.nearest(root, paths:, home:, filesystem: File)
        refusals = Resolver::Refusals.new(cwd: root, home: Resolver::Home.new(home, filesystem), paths:,
                                          filesystem:)
        walk = Resolver::Walk.new(cwd: root, refusals:)
        # `.git` is a FILE inside a linked worktree and a directory in a primary
        # one, and `exist?` covers both -- which is why {Resolver::GIT_ENTRY} is
        # shared rather than re-spelled: two walks looking for the same thing
        # must agree on what it looks like.
        found = walk.find { |dir| filesystem.exist?(File.join(dir, Resolver::GIT_ENTRY)) }
        new(path: found || "", boundary: walk.boundary, reason: walk.reason)
      end

      # "" for none, never nil, so no caller writes a nil guard.
      def found? = !path.empty?

      # The half of every refusal that reads the same whoever asks: what was
      # searched, and where the search stopped.
      # @param from [String] the directory the search started at
      # @return [String]
      def searched(from) = "#{from} is not inside a git repository up to #{boundary} (#{reason})"
    end
  end
end
