# frozen_string_literal: true

module Lain
  module Isolation
    # A worker's own commits, rebased onto its working branch's tip before
    # they are handed back. The handback then fast-forwards instead of
    # merging, and a conflict is met first by the one party who knows what the
    # work meant: the worker, still live, asked to resolve it.
    #
    # ANCHORED FIRST. Before any rebase runs, lain's or the worker's, the
    # worker's HEAD is written to the ref its handback will use, so the commits
    # survive whatever a rebase does to the checkout. The handback's own
    # compare-and-swap then moves that ref to whatever it hands back.
    #
    # LAIN TRIES FIRST, AND GIVES BACK WHAT IT TRIED. `git rebase <tip>` runs in
    # the worktree with the handback's own {MergeStrategy}. A conflicted
    # attempt is counted and aborted, so the checkout is exactly as the worker
    # left it, and only then is the worker asked -- up to `retries` times, each
    # ask measured by lain's next look rather than by what the worker said.
    #
    # LEVEL IS NOT LANDED. A worker that could not resolve a conflict may
    # `rebase --skip` or `reset --hard` onto the tip, which leaves its checkout
    # level with the tip and its own commits gone. So every end after a
    # worker's attempt checks that each original commit is on the new HEAD --
    # by its patch, or, only for a commit that touched a path that conflicted,
    # by the author, author date and subject a rebase keeps and a skip or a
    # reset does not. Otherwise the checkout is put back where the sync found it.
    #
    # A DIRTY TREE IS NOT REBASED. A rebase refuses one or stashes it, and
    # uncommitted work must not be moved under a worker. The result names the
    # checkout; what becomes of it once the lease is released is the release's
    # decision, not this object's.
    #
    # NO EDITOR, ANYWHERE. `git rebase --continue` is the step that opens one,
    # and a model's shell has no terminal to show it in: the command would
    # hang until it timed out. So lain's own git calls and the environment the
    # worker is handed ({#editorless}) both carry `GIT_EDITOR=true`, which
    # outranks every other editor setting git reads.
    #
    # NO StandardError ESCAPES, AND NOTHING IS LEFT HALF-DONE. This runs between
    # a child's answer and its handback, where a raise would surrender work
    # already paid for. A cancel still climbs, past every rescue, so the
    # checkout is put back from an `ensure`: mid-rebase, HEAD is the tip, and
    # the surrender under it would anchor that.
    class SelfSync
      # The one tool that lets a child run git, so the only child worth asking.
      SHELL = "bash"

      # `GIT_SEQUENCE_EDITOR` too, so a worker that reaches for `rebase -i`
      # is not stranded in a todo list it cannot see.
      EDITORLESS = { "GIT_EDITOR" => "true", "GIT_SEQUENCE_EDITOR" => "true" }.freeze

      # What the still-live worker is told when lain's own rebase conflicted.
      ASK = <<~PROMPT
        Your commits in %<dir>s could not be rebased cleanly onto the working branch %<branch>s, now at
        %<tip>s: %<conflicts>d file(s) conflicted, so lain aborted the attempt and your checkout is as you
        left it.

        Rebase them yourself, in that directory: run `git rebase %<tip>s`, resolve each conflict, `git add`
        the files you resolved, then run `GIT_EDITOR=true git rebase --continue` until the rebase finishes.
        Keep both what your work meant and what the branch now holds. Commit nothing else, and leave the
        tree clean. If you cannot resolve it, run `git rebase --abort` and say why.
      PROMPT

      # Stamped into the anchor's reflog, so a ref written before any handback
      # ran still says who wrote it.
      ANCHORED = "lain self-sync: anchored before a rebase"

      # A git step that failed with nothing a worker could resolve: a signing
      # failure, an unwritable index, an anchor git would not write.
      class Failed < Error; end

      Result = Data.define(:outcome, :attempts, :dirty, :path, :detail)

      # What the self-sync did to one worker's checkout, carried onto the record
      # of the handback that follows it. `outcome` is one of:
      #
      # - `current`: nothing to rebase -- the worker already stands on the
      #   tip, or has no commits of its own;
      # - `synced`: every commit of the worker's now sits on the tip;
      # - `conflicted`: every attempt conflicted, so the handback takes the
      #   commits as they were;
      # - `lost`: a worker's attempt dropped commits, and the checkout was put
      #   back where the sync found it;
      # - `dirty`: uncommitted work, not rebased, and `path` names its checkout;
      # - `disabled`: `rebase_retries = 0`;
      # - `failed`: git or the working branch refused.
      #
      # `attempts` holds one entry per rebase, `{"by", "conflicts", "outcome"}`:
      # whose attempt it measured, how many files conflicted, and whether it
      # `landed`, `conflicted`, was `lost`, or was `abandoned` -- a rebase the
      # worker's own turn left in progress. `detail` says why the sync ended
      # as it did, and is empty once it synced.
      #
      # Reopened rather than declared in a `Data.define ... do` block: a
      # constant there is lexically scoped to the enclosing class.
      class Result
        OUTCOMES = %i[current synced conflicted lost dirty disabled failed].freeze

        NOT_HANDED_BACK = "the worker left uncommitted changes at %<path>s; they were not handed back"

        def initialize(outcome:, attempts: [], dirty: false, path: nil, detail: "")
          super(outcome: known(outcome), attempts: Ractor.make_shareable(attempts),
                dirty: Freezable::Fields.boolean!(dirty, "dirty"), path: Freezable::Fields.pinned(path),
                detail: -detail.to_s)
        end

        # @return [String] what the parent is told, empty when nothing is owed
        def note = dirty ? format(NOT_HANDED_BACK, path:) : ""

        # @return [Hash] the handback record's sync fields
        def to_record = { sync: outcome, attempts:, dirty:, path:, detail: }

        private

        def known(outcome)
          return outcome if outcome.nil? || OUTCOMES.include?(outcome)

          raise ArgumentError, "outcome must be one of #{OUTCOMES.inspect}, got #{outcome.inspect}"
        end
      end

      class Result
        # No sync ran: the result a lease with no checkout gets, and the one a
        # handback is given when nothing synced before it.
        NONE = new(outcome: nil)
      end

      # A child lain may ask to rebase its own work.
      Asking = Data.define(:agent) do
        def askable? = true
        def ask(text) = agent.ask(text)
      end

      # A child lain does not ask, because it could not run git if it were.
      module Unaskable
        def self.askable? = false
      end

      # No working branch, so no checkout: nothing to sync, and the child's
      # environment left exactly as it was leased.
      module Null
        def self.call(_lease, **) = Result::NONE
        def self.editorless(worker_env) = worker_env
      end

      # @param agent [#ask] the still-live child
      # @param tools [Enumerable<#to_s>] the names the child was granted
      # @return [Asking, Unaskable]
      def self.worker(agent, tools:) = tools.map(&:to_s).include?(SHELL) ? Asking.new(agent:) : Unaskable

      # @param base [#tip, #name] the working branch a worker is rebased onto
      # @param strategy [MergeStrategy] the handback's own conflict style and
      #   diff algorithm, so a worker resolves the markers a resolver would see
      # @param retries [Integer] how many times a conflicted worker is asked;
      #   0 disables the self-sync
      # @param shell_out_factory [#call] builds the subprocess runner
      def initialize(base:, strategy: MergeStrategy::DEFAULT, retries: 1,
                     shell_out_factory: Shell::Out.public_method(:new))
        @base = base
        @strategy = strategy
        @retries = Integer(retries)
        @shell_out_factory = shell_out_factory
      end

      # @param worker_env [WorkerEnv] as leased
      # @return [WorkerEnv] the same, with no editor for git to open
      def editorless(worker_env) = worker_env.with(env: worker_env.env.merge(EDITORLESS))

      # Call it while the lease is live and the child can still be asked, and
      # hand what it answers to the handback that follows.
      #
      # @param lease [#origin] the worker's lease; its checkout is the one rebased
      # @param worker [#askable?, #ask] from {.worker}
      # @param worker_id [Object] names the ref the commits are anchored under,
      #   the same one the handback uses
      # @return [Result] {Result::NONE} when the lease cut no checkout
      def call(lease, worker:, worker_id:)
        path = lease.origin.path
        return Result::NONE if path.nil?

        Run.new(tree: Tree.new(path, shell_out_factory: @shell_out_factory), worker:, base: @base,
                strategy: @strategy, retries: @retries, anchor: Worktree::Handback::Naming.new(worker_id).ref).call
      end

      # One sync of one checkout, and the state that takes: the attempts so
      # far, the HEAD it found, every path a rebase conflicted on, and whether
      # that HEAD is anchored yet.
      class Run
        def initialize(tree:, worker:, base:, strategy:, retries:, anchor:)
          @tree = tree
          @worker = worker
          @base = base
          @strategy = strategy
          @retries = retries
          @anchor = anchor
          @attempts = []
          @conflicted = []
          @detail = ""
          @kept = false
        end

        # Every outcome `#sync` returns leaves the checkout in a state it has
        # vouched for. Every other exit -- a StandardError, a cancel -- puts the
        # checkout back as it was found.
        def call
          outcome = sync
          @kept = true
          result(outcome)
        rescue StandardError => e
          @detail = squeezed("#{e.class}: #{e.message}")
          result(:failed)
        ensure
          put_back unless @kept
        end

        private

        def sync
          leftover
          return :dirty if @tree.dirty?
          return :disabled if @retries.zero?

          @original = @tree.head
          attempt(asks: @retries, by: "lain")
        end

        # Mid-rebase, the worker's commits live only in the rebase's own state
        # and HEAD is on the tip; aborting puts the commits back.
        def leftover
          return unless @tree.rebasing?

          tried("worker", conflicting(@tree.conflicted), :abandoned)
          @tree.abandon
        end

        # The tip is read per attempt, because it may move while the worker works.
        def attempt(asks:, by:)
          tip = @base.tip
          return level(by) if @tree.level_with?(tip)

          anchor
          conflicts = conflicting(@tree.rebase(@strategy, tip))
          conflicts.zero? ? kept(by) : conflicted(asks:, by:, tip:, conflicts:)
        end

        # A conflicted attempt is put to the worker while asks remain. Ended
        # here, it still goes through the loss check, since an earlier attempt
        # by the worker may have dropped a commit before leaving the conflict.
        def conflicted(asks:, by:, tip:, conflicts:)
          tried(by, conflicts, :conflicted)
          return unless_lost(:conflicted) if asks.zero? || !@worker.askable?

          ask(tip, conflicts)
          @tree.dirty? ? unless_lost(:dirty) : attempt(asks: asks - 1, by: "worker")
        end

        # Only a commit that touched a path some rebase here conflicted on can
        # have been rewritten by a resolution, so those paths are kept.
        #
        # @return [Integer] how many paths this attempt conflicted on
        def conflicting(paths)
          @conflicted |= paths
          paths.size
        end

        # Level with the tip at lain's first look is nothing to do. After an
        # ask it is either the worker's own rebase landing or its commits gone.
        def level(by) = by == "lain" ? :current : kept(by)

        def kept(by)
          return lost(by) if lost?

          tried(by, 0, :landed)
          :synced
        end

        # Every end after a worker's attempt comes through here: an attempt
        # that left the conflict for lain may still have dropped a commit.
        def unless_lost(outcome) = lost? ? lost("worker") : outcome

        def lost? = @tree.lost?(@original, @conflicted)

        def lost(by)
          @tree.restore(@original)
          tried(by, 0, :lost)
          :lost
        end

        def anchor
          @tree.anchor(@anchor, @original) unless @anchored
          @anchored = true
        end

        # An ask that failed resolved nothing, and lain's next look measures
        # that the same way as an ask that answered. What neither may do is
        # leave the checkout mid-rebase, whoever started the rebase.
        def ask(tip, conflicts)
          reply = @worker.ask(format(ASK, dir: @tree.dir, branch: @base.name, tip:, conflicts:))
          @detail = squeezed(reply.text.to_s)
        rescue StandardError => e
          @detail = squeezed("the follow-up ask raised #{e.class}: #{e.message}")
        ensure
          @tree.abandon
        end

        def tried(by, conflicts, outcome)
          @attempts << { "by" => by, "conflicts" => conflicts, "outcome" => outcome.to_s }
        end

        def result(outcome)
          dirty = outcome == :dirty
          Result.new(outcome:, attempts: @attempts, dirty:, path: (@tree.dir if dirty),
                     detail: outcome == :synced ? "" : @detail)
        end

        def squeezed(text) = WorkerHandoff::Reply.squeeze(text)

        # Best-effort, because it runs on the way out of a failure or a cancel.
        def put_back
          @tree.restore(@original) unless @original.nil?
        rescue StandardError
          nil
        end
      end

      # The worker's checkout, as the self-sync questions and moves it.
      class Tree
        attr_reader :dir

        def initialize(dir, shell_out_factory:)
          @dir = dir
          @checkout = Checkout.new(dir, shell_out_factory:)
          @shell_out_factory = shell_out_factory
        end

        def head = run!("rev-parse", "HEAD")

        # Untracked files count: a file the worker made and never committed
        # is its work as much as an edit is.
        def dirty? = !run!("status", "--porcelain").empty?

        # Git keeps a stopped rebase's state in one of two directories of this
        # worktree's own git dir.
        def rebasing?
          %w[rebase-merge rebase-apply].any? do |state|
            File.directory?(run!("rev-parse", "--path-format=absolute", "--git-path", state))
          end
        end

        # @return [Array<String>] the paths a stopped rebase left unmerged
        def conflicted = @checkout.unmerged

        # Already on the tip, or nothing of its own to put there.
        def level_with?(tip) = @checkout.contains?(tip) || ancestor?("HEAD", tip)

        # Compare-and-swapped against whatever the ref holds now, so a racing
        # writer fails loudly instead of being overwritten.
        def anchor(ref, commit)
          held = @checkout.target(ref)
          return if held == commit

          written = @checkout.update_ref(ref, commit, held, reason: ANCHORED)
          raise Failed, "#{ref} could not be anchored at #{commit}: #{written.stderr.strip}" unless ok?(written)
        end

        # The abort sits in an `ensure`, so a cancel landing mid-rebase still
        # gives the checkout back rather than leaving HEAD on the tip.
        #
        # @return [Array<String>] the paths that conflicted; empty once it landed
        # @raise [Failed] when it failed with no conflict to count
        def rebase(strategy, tip)
          landed = false
          shell = git(*strategy.rebase(tip))
          landed = ok?(shell)
          landed ? [] : conflicts_in(shell, tip)
        ensure
          abandon unless landed
        end

        def restore(commit)
          abandon
          run!("reset", "--hard", "--quiet", commit) unless head == commit
        end

        # Whether any commit of `original` is missing from HEAD. `git cherry`
        # finds each one whose patch HEAD does not carry. A resolution rewrites
        # the patch of a commit that touched a conflicted path, so only those
        # are looked for again, by the author, author date and subject a rebase
        # keeps; every other commit must survive by its patch.
        # The limit: a resolved commit gutted in place reads as a resolution.
        def lost?(original, conflicted)
          return false if head == original

          missing = run!("cherry", "HEAD", original).split("\n").grep(/\A\+ /).map { |line| line.split.last }
          return false if missing.empty?

          rewrites = authorship("#{original}..HEAD")
          missing.any? { |commit| !resolved?(commit, conflicted, rewrites) }
        end

        # Exits nonzero when no rebase is in progress, which is the usual case.
        # Best-effort, because it runs on the way out of a failure.
        def abandon
          git("rebase", "--abort")
        rescue StandardError
          nil
        end

        private

        def conflicts_in(shell, tip)
          paths = conflicted
          return paths unless paths.empty?

          raise Failed, "git rebase #{tip} failed in #{dir} (exit #{shell.exitstatus}): #{shell.stderr.strip}"
        end

        def resolved?(commit, conflicted, rewrites)
          touched(commit).intersect?(conflicted) && rewrites.include?(authorship("--no-walk", commit).first)
        end

        # `-z` and the re-tag, so these compare equal to the unmerged paths
        # {Checkout#unmerged} reads the same way.
        def touched(commit)
          paths = run!("diff-tree", "--no-commit-id", "--name-only", "-r", "-z", commit).split("\0")
          paths.map { |path| path.force_encoding(Checkout::FILESYSTEM) }
        end

        def authorship(*revisions) = run!("log", "--format=%an%x1f%ae%x1f%at%x1f%s", *revisions).split("\n")

        def ancestor?(commit, of) = ok?(git("merge-base", "--is-ancestor", commit, of))

        def run!(*args)
          shell = git(*args)
          return shell.stdout.strip if ok?(shell)

          raise Failed, "git #{args.first} failed in #{dir} (exit #{shell.exitstatus}): #{shell.stderr.strip}"
        end

        def git(*)
          shell = @shell_out_factory.call("git", "-C", dir, *, environment: Worktree::GIT_CONTEXT_SCRUB.merge(EDITORLESS))
          shell.run_command
          shell
        end

        def ok?(shell) = shell.exitstatus.zero?
      end
    end
  end
end
