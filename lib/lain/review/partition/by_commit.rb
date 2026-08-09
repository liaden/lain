# frozen_string_literal: true

module Lain
  module Review
    class Partition
      # Group a changeset by the commits that produced it -- the walk, one
      # {Partition} per commit in the source's own order, including a commit
      # whose every file was later superseded, which gets an empty `files`
      # rather than disappearing from the sidebar.
      #
      # The files are PARTITIONED, not replicated: a file two commits touched
      # appears under the LAST of them, because the cumulative diff shows its
      # hunks once and the last commit is the one that left the content now on
      # screen. Handing it to both would double-count, and "groups whose hunks
      # sum to the cumulative hunk count" is precisely that conservation law.
      #
      # Attribution is at FILE granularity because that is the finest the port
      # answers: {Source::Commit} carries a numstat, not a per-commit diff. Real
      # hunk-level provenance would need a fifth message on the port.
      #
      # == What a consumer may and may not claim about a group
      #
      # A group means "this commit is the LAST in the range to touch these files,
      # and here are their net hunks". It does not mean "this commit did this",
      # and one case makes the difference stark rather than academic: with a
      # merge in the range, `--diff-merges=first-parent` re-reports everything
      # the merge brought in, so the merge's numstat names the side branch's
      # files too and last-writer-wins hands them ALL to the merge. The commit
      # that actually authored a side-branch file then shows an EMPTY group.
      #
      # Empty groups for an empty commit or an add-then-delete pair are honest.
      # An empty group for real work absorbed by a merge is not, and it cannot be
      # fixed from inside this object: telling a merge from an ordinary commit
      # needs a parent count, and {Source::Commit} carries sha, subject, body and
      # numstat with no parents. That is a port change. Until then {Commit}
      # keeps `numstat` -- the commit's OWN figure, which a merge does not steal
      # -- so a sidebar that needs "what did this commit do" has something true
      # to read. There is a spec pinning the behaviour, not endorsing it.
      class ByCommit
        NAME = "commits"

        # `.freeze` by hand, {Whole::ADVICE}'s reason: this interpolates.
        ADVICE = "present it per commit (scope: #{NAME}) instead".freeze

        # What a commit knows that the diff does not: which commit this is, and
        # what git reported IT changed.
        #
        # The line accounting comes off the numstat and ignores the files it is
        # handed, which is the whole reason a detail may answer at all: a
        # commit's own figure is not its share of the cumulative diff, and
        # {Partition::Undetailed}'s hunk count would quietly replace one with the
        # other. `numstat` stays the frozen `Array<Source::FileStat>` it is --
        # shadowing that name with an aggregate is the defect a review panel
        # found, since a double would read as satisfied and the real object
        # would raise.
        #
        # A binary file's stats are nil rather than 0 -- git spells it `-` for
        # exactly that reason -- so they are skipped in the sums, and
        # {#binaries} says how many were. Nothing RENDERS that count yet, so an
        # all-binary commit still shows `+0 -0`; the number is honest and the
        # card that draws it has not been written.
        #
        # {#named} is what a refusal calls the group, and it is deliberately
        # LONGER than the heading: a sidebar has 40 columns and wants the
        # message, while a reader told their review is too large needs something
        # they can `git show`. Subjects repeat (`wip`, `fixup!`,
        # `Merge branch 'main'`) and `--allow-empty-message` makes one blank, so
        # a subject alone is neither lookup-able nor always non-empty.
        Commit = Data.define(:sha, :subject, :body, :numstat) do
          def added(_files) = total(:added)
          def deleted(_files) = total(:deleted)
          def binaries(_files) = numstat.count(&:binary?)

          # @param label [String] the group's own label, this commit's subject
          # @return [String] the subject and the sha, or the sha alone for a
          #   commit made with an empty message -- which is legal, and which
          #   would otherwise open a refusal on a bare space
          def named(label)
            abbreviated = "commit #{sha[0, 12]}"
            label.empty? ? abbreviated : "#{label} (#{abbreviated})"
          end

          private

          def total(field) = numstat.filter_map(&field).sum
        end

        # @return [String]
        def name = NAME

        # @return [String] what a refusal at another strategy recommends
        def advice = ADVICE

        # The one strategy that declines a source, and the reason `#supports?`
        # is on the port at all: a source with no history has nothing to group
        # by, and saying so at presentation beats dying on a missing message
        # halfway through a partition.
        #
        # @param source [Object]
        # @return [Boolean]
        def supports?(source) = source.respond_to?(:commits)

        # @param changeset [#files, #commits]
        # @return [Array<Partition>] one per commit in the walk's own order
        # @raise [Changeset::Unattributed] if a file in the diff reaches no commit
        def partition(changeset)
          owners = ownership(changeset)
          grouped = changeset.files.group_by { |file| owner_of(file, owners) }
          changeset.commits.map do |commit|
            Partition.new(label: commit.subject, files: grouped.fetch(commit.sha, []),
                          detail: Commit.new(sha: commit.sha, subject: commit.subject,
                                             body: commit.body, numstat: commit.numstat))
          end
        end

        private

        # `Changeset::Unattributed`, root-qualified through its own namespace
        # rather than redeclared here: `Tools::RequestReview` rescues that exact
        # class, so a second one under this namespace would be a refusal nobody
        # catches.
        #
        # The new path first: for a rename, that is the commit that performed
        # it, while the old path would name whoever last touched the file
        # beforehand.
        def owner_of(file, owners)
          owners[file.new_path] || owners[file.old_path] ||
            raise(Changeset::Unattributed,
                  "#{file.path.inspect} is in the diff but in no commit's numstat, so grouping it " \
                  "by commit would either drop the file or invent an owner for it")
        end

        # name => the LAST commit in the walk that named it. Oldest-first order
        # is the source's contract, so a later write is a later commit.
        def ownership(changeset)
          changeset.commits.each_with_object({}) do |commit, owner|
            commit.numstat.each do |entry|
              rename_sides(entry.path).each { |name| owner[name] = commit.sha }
            end
          end
        end

        # A rename reaches a numstat path as `old => new` or `pre/{old => new}/post`,
        # and BOTH sides count as named -- the cumulative diff may have detected the
        # rename where a single commit did not, or the reverse.
        def rename_sides(path)
          braced = path.match(/\A(?<pre>.*)\{(?<old>.*) => (?<new>.*)\}(?<post>.*)\z/m)
          return %i[old new].map { |side| "#{braced[:pre]}#{braced[side]}#{braced[:post]}" } if braced

          arrow = path.match(/\A(?<old>.*) => (?<new>.*)\z/m)
          arrow ? [arrow[:old], arrow[:new]] : [path]
        end
      end
    end
  end
end
