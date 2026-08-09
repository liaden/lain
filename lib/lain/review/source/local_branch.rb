# frozen_string_literal: true

require "mixlib/shellout"

module Lain
  module Review
    module Source
      # A changeset read from a local branch.
      #
      # == The merge base is resolved, never implied
      #
      # `git diff base..head` reports the base branch's OWN independent commits as
      # deletions, because it compares two tips. `git diff base...head` compares
      # against the merge base instead, which is what a review wants. The spike
      # found that getting this wrong shifts every old-side anchor, so this class
      # does not spell the three-dot form and hope: it resolves the merge base to
      # a SHA up front, records it as {#base_ref}, and diffs `merge_base head`
      # two-dot -- which is the same changeset, and is reproducible afterwards.
      #
      # That distinction is the whole reason `base_ref` exists as a message. A
      # source that kept "main" symbolically would answer a different diff the
      # next time main moved, and nothing downstream could tell.
      #
      # == Every subprocess is an argv array
      #
      # The `shell_out_factory` seam {Forge::Gh} and eight siblings use, spelled
      # the same way: an argv array, never a command string, so there is no place
      # to put one and no shell to reach.
      class LocalBranch
        # {#files} and {#identity}, over this class's own {#diff}. Included
        # rather than written out, because {GithubPr} owes the same two answers
        # over DIFFERENT bytes -- see the module's own note.
        include Diffed

        # git's own field separators inside `--format`: NUL starts a record (git
        # forbids NUL in a commit message, so it cannot collide), unit separator
        # divides sha/subject/body, and record separator ends the header so the
        # numstat block that follows is unambiguous. A newline-delimited format
        # could not survive a multi-line body.
        LOG_FORMAT = "%x00%H%x1f%s%x1f%b%x1e"

        # A textconv filter, an external diff driver, a forced colour setting or
        # a changed context width each rewrite the bytes the parser depends on.
        # None is a hypothetical: they are ordinary things to find in a
        # developer's git config. `diff.noprefix` is the sharpest of them --
        # it turns the header into `diff --git a.rb a.rb`, and every
        # `^diff --git a/… b/…` reader downstream, including this class's own
        # spec, stops matching.
        DIFF_HYGIENE = %w[
          --no-color --no-ext-diff --no-textconv
          --src-prefix=a/ --dst-prefix=b/ -U3
        ].freeze

        # Config that changes the BYTES rather than the content, pinned with `-c`
        # so the answer is the same however the setting arrives -- global,
        # repo-local, or `GIT_CONFIG_*`. Scrubbing the environment cannot reach
        # any of these, because they are configuration, not environment.
        #
        # `core.quotePath` defaults to ON, which renders `café.rb` as the literal
        # `"caf\303\251.rb"` -- not a filename any caller can open. It is quiet
        # rather than loud because the diff header quotes it too, so the numstat
        # and the diff agree with each other on the wrong answer. Paths carrying
        # a tab or a newline stay quoted regardless, so `split("\t", 3)` is
        # unaffected by turning this off.
        CONFIG_PINS = %w[-c core.quotePath=false].freeze

        # @param base [String] the ref the changeset is reviewed against; the
        #   MERGE BASE of this and `head` becomes {#base_ref}
        # @param head [String] the ref under review
        # @param repo_root [String] the repository to read
        # @param shell_out_factory [#call] builds the subprocess runner, injected
        #   as a factory exactly as {Forge::Gh} does, so a spec substitutes it
        # @raise [UnknownRef] if either ref does not resolve, or they share no
        #   history
        def initialize(base:, head: "HEAD", repo_root: Dir.pwd,
                       shell_out_factory: Mixlib::ShellOut.public_method(:new))
          @repo_root = File.expand_path(repo_root)
          @shell_out_factory = shell_out_factory
          @head_ref = resolve!("head", head)
          @base_ref = merge_base!(base, head, resolve!("base", base))
        end

        # @return [String] the merge base sha, frozen
        attr_reader :base_ref

        # @return [String] the head sha, frozen
        attr_reader :head_ref

        # @return [String] raw unified diff bytes. Binary-encoded on purpose: a
        #   diff carries whatever bytes the files carry, and a latin-1 hunk must
        #   not raise on its way to the parser.
        def diff = @diff ||= git("diff", *DIFF_HYGIENE, @base_ref, @head_ref).stdout.b.freeze

        # @return [Array<Commit>] oldest-first, each carrying its own numstat.
        #   One subprocess for the whole walk: at the 810-file changeset §3.7
        #   measured, a `git show` per commit would be the dominant cost.
        def commits = @commits ||= parse_log(log_output).freeze

        # One file, as one revision holds it -- the port's SIXTH message, and
        # the only one that answers about a single path rather than about the
        # whole changeset.
        #
        # It exists because a diff is not enough to DRAW one: an editor showing
        # the old side against the new needs the whole old file, and a unified
        # diff carries only the hunks and three lines around them. T32a's diff
        # opener is the caller, and reading the blob HERE rather than there is
        # what keeps every git invocation in this repository behind one method
        # -- the argv form, the config pins and the env scrub included.
        #
        # A path the revision does not carry answers nil rather than raising:
        # "this file did not exist yet" is an ordinary fact about an added file,
        # and the caller distinguishing an empty old side from a missing one is
        # what makes it a fact rather than an error.
        #
        # @param revision [String] a commit-ish; {#base_ref} and {#head_ref} are
        #   the two this port resolves
        # @param path [String] repository-relative, as the diff spells it
        # @return [String, nil] the file's bytes, binary-encoded for {#diff}'s
        #   reason -- a file carries whatever bytes it carries, and a latin-1
        #   one must not raise on its way to a buffer
        def file_at(revision, path)
          shell = git("show", "--end-of-options", "#{revision}:#{path}")
          shell.exitstatus.zero? ? shell.stdout.b.freeze : nil
        end

        # The port's fifth message, answered by the source that never asks
        # anyone: the objects are in the local database and nothing fell back to
        # them, which is exactly what {DiffOrigin.already_local} says.
        #
        # A Null Object, and its point is at the CONSUMER. Without it a renderer
        # asks `respond_to?(:diff_origin)` and branches on WHICH source it holds
        # -- a type test in duck costume -- and {Source}'s module doc records
        # what that conditional actually cost.
        #
        # @return [DiffOrigin] always `fell_back? == false`
        def diff_origin = DiffOrigin.already_local

        private

        # `--diff-merges=first-parent` is what stops a merge from silently losing
        # data: by default `git log --numstat` reports NOTHING for a merge, so a
        # file changed only by a hand resolution appears in {#diff} and in no
        # commit's numstat at all. First-parent is the reviewer's question --
        # "what did this merge bring onto the branch" -- and it also re-reports
        # what came in from the side, which is why the walk's line totals are a
        # lower bound on the diff's rather than equal to them.
        #
        # `--topo-order` because `--reverse` alone is DATE order: a commit whose
        # timestamp precedes its parent's would otherwise walk first, making
        # "oldest-first" a coincidence rather than a guarantee.
        #
        # Read as bytes, then decoded per field -- see {#text}.
        # `--encoding=UTF-8` makes git TRANSCODE a message from the encoding its
        # commit header declares, rather than handing over the original bytes for
        # {#text} to scrub into U+FFFD. A declared latin-1 `café` arrives as
        # proper UTF-8; scrubbing is then only the backstop for genuinely
        # undeclared or mislabelled bytes, which is what it should be.
        def log_output
          git("log", "--reverse", "--topo-order", "--numstat", "--no-ext-diff",
              "--encoding=UTF-8", "--diff-merges=first-parent", "--format=#{LOG_FORMAT}",
              "--end-of-options", "#{@base_ref}..#{@head_ref}").stdout.b
        end

        # mixlib tags stdout UTF-8 when the bytes HAPPEN to be valid and BINARY
        # when they are not, so without this a field's encoding depends on its
        # content. These fields are journalled as JSON, where a BINARY string
        # warns today and raises in json 3.0, and invalid bytes raise now -- into
        # NDJSON, where one bad line breaks the parse of the experiment record.
        # Only {#diff} stays raw, because a diff carries whatever the files do.
        def text(bytes) = bytes.to_s.dup.force_encoding(Encoding::UTF_8).scrub

        # Records are NUL-separated, so the leading empty split is dropped rather
        # than indexed around.
        def parse_log(output)
          output.split("\0").reject(&:empty?).map { |record| parse_record(record) }
        end

        def parse_record(record)
          header, numstat = record.split("\x1e", 2)
          sha, subject, body = header.split("\x1f", 3)
          Commit.new(sha: text(sha).freeze, subject: text(subject).freeze,
                     body: text(body).strip.freeze, numstat: parse_numstat(numstat.to_s))
        end

        def parse_numstat(block)
          block.each_line.map(&:chomp).reject(&:empty?)
               .map { |line| file_stat(line.split("\t", 3)) }
               .freeze
        end

        # git spells a binary file's counts as `-`, and that is preserved as nil
        # rather than coerced to 0 -- see {FileStat}.
        #
        # UNQUOTED before it is decoded, and {CONFIG_PINS}' `core.quotePath=false`
        # is not enough on its own: that setting governs NON-ASCII paths, while a
        # name carrying a quote, a backslash, a tab or a newline is C-quoted
        # regardless. Left encoded, this side reports `"we\"ird.rb"` while the
        # DIFF side (which does unquote) reports `we"ird.rb`, and any consumer
        # that JOINS the two answers breaks on an ordinary file --
        # {Review::Changeset} groups files by commit by doing exactly that, and
        # refused a whole changeset over it. One decoder, at the edge both sides
        # cross: {Wire.unquote}.
        def file_stat((added, deleted, path))
          FileStat.new(path: text(Wire.unquote(path)).freeze,
                       added: count(added), deleted: count(deleted))
        end

        def count(field) = field == "-" ? nil : Integer(field, 10)

        # `--verify --quiet` exits nonzero with no output when the ref names
        # nothing, which is the whole check. `^{commit}` is what refuses a ref
        # that resolves to a tree or a blob rather than something diffable, and
        # `--end-of-options` makes leading-dash safety STRUCTURAL rather than
        # relying on rev-parse happening to reject `--upload-pack=…` as an
        # unknown option.
        def resolve!(role, ref)
          shell = git("rev-parse", "--verify", "--quiet", "--end-of-options", "#{ref}^{commit}")
          raise UnknownRef.unresolved(role, ref, @repo_root, shell) unless shell.exitstatus.zero?

          text(shell.stdout).strip.freeze
        end

        # Two roots have no merge base. Diffing against the empty tree instead
        # would silently present the entire branch as additions, which reads as a
        # successful review of a changeset nobody wrote.
        def merge_base!(base, head, base_sha)
          shell = git("merge-base", "--end-of-options", base_sha, @head_ref)
          raise UnknownRef.no_merge_base(base, head, @repo_root) unless shell.exitstatus.zero?

          text(shell.stdout).strip.freeze
        end

        # {Isolation::Worktree}'s pinned scrub set, not a parallel copy: an
        # ambient GIT_DIR (a pre-commit hook sets one) would otherwise point every
        # call below at the hook's repository instead of `repo_root`. Read from a
        # METHOD body rather than the class body because `lain.rb` loads
        # isolation after review, so a class-body reference would be a load-time
        # NameError -- the same reasoning, and the same shape, as
        # {Forge::Promotion#run}, which carries the fuller note.
        def git(*)
          shell = @shell_out_factory.call("git", "-C", @repo_root, *CONFIG_PINS, *,
                                          environment: Isolation::Worktree::GIT_CONTEXT_SCRUB)
          shell.run_command
          shell
        end
      end
    end
  end
end
