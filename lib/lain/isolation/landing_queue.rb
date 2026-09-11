# frozen_string_literal: true

module Lain
  module Isolation
    # Lands finished workers' anchored commits onto the working branch, one at
    # a time and in the order they were handed in. On the epic path it is the
    # only thing that merges.
    #
    # LAND WHAT INTEGRATES, THEN ASK. Every commit is probed against the tip it
    # would land on, and re-probed after each landing, so nothing merges
    # against a tip it was not probed against. A stale worker is not asked to
    # re-sync while siblings are still landing: the tip it would rebase onto
    # is about to move again. Once nothing more lands, each stale worker is
    # asked once, against the tip the others produced.
    #
    # ONE RESOLVER, GIVEN THE ORDER. Whatever still conflicts goes to a single
    # resolver with the intended landing order, because merging A then B means
    # B integrates against A, and a resolution that satisfies each pair need
    # not satisfy the whole. Verification then runs once, over the result.
    #
    # ONE MERGER PER PARENT CHECKOUT, ACROSS PROCESSES. The run holds the
    # repository's {ParentLock}, the same lock a chat's handback takes, so `lain
    # epic land` and a live chat never merge into one checkout at once.
    class LandingQueue
      # A queue that cannot run at all: no branch to land onto, or a parent
      # checkout standing somewhere else.
      class Refused < Error; end

      NOTHING_LANDED = "nothing landed, so there was nothing to verify"

      # A finished worker: the commit to land, and the ref its commits are
      # anchored under. The ref is required: a worker's commits are never
      # optional, and one the queue could not name a ref for would be left
      # reachable from nothing if its conflict stood.
      Worker = Data.define(:id, :ref, :sha) do
        def initialize(id:, ref:, sha:)
          raise ArgumentError, "a worker's ref must name where its commits are anchored, got #{ref.inspect}" if
            ref.to_s.strip.empty?

          super(id: -id.to_s, ref: -ref.to_s, sha: -sha.to_s)
        end
      end

      # What one worker's turn in the queue came to, as the handback's own
      # {WorkerHandoff::Report}.
      Landed = Data.define(:worker, :report) do
        def moved? = %i[merged resolved].include?(report.kind)
        def stale? = false
      end

      # A worker whose commit conflicts with the tip, and the paths it
      # conflicts on.
      Stale = Data.define(:worker, :paths) do
        def stale? = true
      end

      # The one verification over the combined tree. `outcome` is `passed`,
      # `failed` or `skipped`.
      Verification = Data.define(:outcome, :tip, :detail) do
        def initialize(outcome:, tip:, detail: "")
          super(outcome: outcome.to_sym, tip: Freezable::Fields.pinned(tip), detail: -detail.to_s)
        end
      end

      Result = Data.define(:landed, :verification) do
        def initialize(landed:, verification:) = super(landed: landed.dup.freeze, verification:)

        # @raise [KeyError] for a worker that was never queued
        def report(id)
          entry = landed.find { |each| each.worker.id == id.to_s }
          raise KeyError, "no worker #{id.inspect} was queued" if entry.nil?

          entry.report
        end
      end

      # No worker to ask: a commit landed from the command line has no live
      # worker behind it.
      module Resync
        # @return [String, nil] a commit to land instead, or nil
        def self.call(_worker, **) = nil
      end

      # No suite wired: the result says so rather than claiming a pass.
      module Verify
        def self.call(tip) = Verification.new(outcome: :skipped, tip:, detail: "no verification is configured")
      end

      # @param repo_root [String] the parent checkout, which must stand on `base`
      # @param base [WorkingBranch] the branch every worker lands onto
      # @param journal [#<<] where each landing's {Telemetry::Handback} lands
      # @param strategy [MergeStrategy] how probes and merges are spelt
      # @param retries [Integer] `rebase_retries`: how many times a stale worker
      #   is asked to re-sync; 0 asks none
      # @param resolver [#call] `call(stale, desk)` answering one {Landed} per
      #   stale worker; called at most once per run, with every leftover in order
      # @param verify [#call] `call(tip)` answering a {Verification}; called
      #   once per run in which anything landed
      # @param notice [#call] told who holds the parent checkout's lock when a
      #   landing waits on it for long
      # @param shell_out_factory [#call] builds the subprocess runner
      def initialize(repo_root:, base:, journal: Channel::Null.instance, strategy: MergeStrategy::DEFAULT, retries: 1,
                     resolver: Resolver::Standing, verify: Verify, notice: ParentLock::Silent,
                     shell_out_factory: Shell::Out.public_method(:new))
        raise Refused, "a landing queue needs a named working branch to land onto; none was given" if base.name.empty?

        root = File.expand_path(repo_root)
        @desk = Desk.new(repo_root: root, base:, journal:, strategy:, shell_out_factory:)
        @probe = Probe.new(parent: Checkout.new(root, shell_out_factory:), strategy:)
        @lock = ParentLock.for(repo_root: root, shell_out_factory:)
        @retries = Integer(retries)
        @resolver = resolver
        @verify = verify
        @notice = notice
      end

      # @param workers [Array<Worker>] in landing order
      # @param resync [#call] `call(worker, tip:)` answering the full SHA of a
      #   re-synced commit to land instead, or nil. Whatever it answers lands
      #   as the worker's work, so a caller gating what may land gates it here.
      # @return [Result] one {Landed} per worker, in the order given
      # @raise [Refused] when the parent checkout is not on the working branch
      def call(workers, resync: Resync)
        @lock.hold(notice: @notice) { settle(workers.to_a, resync) }
      end

      private

      def settle(workers, resync)
        @desk.ensure_on_branch!
        landed, stale = integrate(workers)
        resynced, leftovers = resynced(stale, resync)
        resolved = leftovers.empty? ? [] : @resolver.call(leftovers, @desk)
        outcomes = landed + resynced + resolved
        Result.new(landed: ordered(workers, outcomes), verification: verified(outcomes))
      end

      # Passes over the waiting workers in order, for as long as a pass lands
      # something: a landing can make a worker that conflicted earlier clean.
      def integrate(workers)
        landed, waiting = workers.map { |worker| attempt(worker) }.partition { |each| !each.stale? }
        return [landed, waiting] if waiting.empty? || landed.none?(&:moved?)

        more, stale = integrate(waiting.map(&:worker))
        [landed + more, stale]
      end

      def resynced(stale, resync)
        return [[], stale] if @retries.zero?

        stale.map { |waiting| asked(waiting, resync, @retries) }.partition { |each| !each.stale? }
      end

      # Up to `rebase_retries` asks per worker, each against the tip as it is
      # then, stopping at the first re-sync that integrates.
      def asked(waiting, resync, asks)
        result = attempt(@desk.resynced(waiting.worker, resync.call(waiting.worker, tip: @desk.tip)))
        result.stale? && asks > 1 ? asked(result, resync, asks - 1) : result
      end

      def attempt(worker)
        probed = @probe.call(@desk.tip, worker.sha)
        case probed.verdict
        when :landed then @desk.already(worker)
        when :fast_forward, :clean then merged(worker)
        when :conflicted then Stale.new(worker:, paths: probed.paths)
        else @desk.failed(worker, probed.detail)
        end
      end

      # A probe that said clean and a merge that conflicted anyway disagree;
      # the merge is put back and the worker waits with the conflicted rest.
      def merged(worker)
        outcome = @desk.merge(worker)
        return @desk.landed(worker, outcome) unless outcome.kind == :conflicted

        @desk.abandon(worker)
        Stale.new(worker:, paths: outcome.paths)
      end

      def ordered(workers, outcomes) = workers.map { |worker| outcomes.find { |each| each.worker.id == worker.id } }

      def verified(outcomes)
        return Verification.new(outcome: :skipped, tip: @desk.tip, detail: NOTHING_LANDED) if outcomes.none?(&:moved?)

        @verify.call(@desk.tip)
      end
    end

    class LandingQueue
      # Whether a commit integrates with a tip, asked of git without touching
      # the parent's index or working tree.
      class Probe
        Probed = Data.define(:verdict, :paths, :detail)

        def initialize(parent:, strategy:)
          @parent = parent
          @strategy = strategy
        end

        # @return [Probed] `landed` when the tip already holds the commit,
        #   `fast_forward`, `clean`, `conflicted` with the paths, or `failed`
        def call(tip, commit)
          return probed(:landed) if ancestor?(commit, tip)
          return probed(:fast_forward) if ancestor?(tip, commit)

          written(@parent.run(*@strategy.probe(tip, commit)))
        end

        private

        def ancestor?(older, newer) = @parent.run("merge-base", "--is-ancestor", older, newer).exitstatus.zero?

        # Exit 1 is both "conflicted" and "could not merge at all"; only the
        # first writes a tree first, so the tree is what tells them apart.
        def written(shell)
          fields = shell.stdout.split("\0")
          return probed(:clean) if shell.exitstatus.zero?
          return probed(:conflicted, paths: conflicted(fields)) if WorkingBranch::FULL_SHA.match?(fields.first.to_s)

          probed(:failed, detail: "git merge-tree failed (exit #{shell.exitstatus}): #{shell.stderr.strip}")
        end

        def conflicted(fields) = fields.drop(1).reject(&:empty?).uniq.map { |path| path.force_encoding(Checkout::FILESYSTEM) }

        def probed(verdict, paths: [], detail: "") = Probed.new(verdict:, paths:, detail:)
      end

      # The parent checkout, as the queue and its resolver act on it: merge a
      # worker's commit, conclude or abandon that merge, and journal what each
      # landing came to.
      class Desk
        STANDS = "the conflict stands; the work waits on its ref"

        def initialize(repo_root:, base:, journal:, strategy:, shell_out_factory:)
          @repo_root = repo_root
          @base = base
          @journal = journal
          @strategy = strategy
          @parent = Checkout.new(repo_root, shell_out_factory:)
          @merge = Worktree::Handback::Merge.new(parent: @parent, strategy:, base:)
          # Its own records would name the commit as their ref; the desk
          # journals each outcome itself, under the anchor.
          @handback = Worktree::Handback.new(base:, repo_root:, journal: Channel::Null.instance, strategy:,
                                             shell_out_factory:)
        end

        attr_reader :repo_root

        def branch = @base.name

        def tip = @base.tip

        def ensure_on_branch!
          return if @base.current_in?(@parent)

          raise Refused, "#{@repo_root} is on #{standing}, not the working branch #{branch}; the landing queue " \
                         "lands only onto the branch the parent checkout stands on, so run `git switch #{branch}` " \
                         "there first"
        end

        # @return [Worktree::Handback::Outcome]
        def merge(worker) = journaled(worker, @merge.call(worker.sha, key(worker)))

        def continue(worker) = journaled(worker, @handback.continue(worker.sha, worker_id: worker.id))

        def abandon(worker) = journaled(worker, @handback.abandon(worker.sha, worker_id: worker.id))

        def landed(worker, outcome)
          Landed.new(worker:, report: WorkerHandoff::Report.from(outcome).with(ref: worker.ref))
        end

        def already(worker) = report(worker, :nothing_to_do, detail: "#{branch} already holds #{worker.sha}")

        def failed(worker, detail) = report(worker, :failed, detail:)

        # A conflict left standing, with the parent untouched and the work on
        # its ref.
        def stand(worker, paths, detail = STANDS)
          record(worker, :conflicted, detail:)
          report(worker, :conflicted, paths:, detail:)
        end

        # Moves the worker's anchor to a re-synced commit by compare-and-swap,
        # so the ref keeps what will land. A lost swap keeps the worker as it was.
        def resynced(worker, commit)
          return worker if commit.nil? || commit == worker.sha

          moved = @parent.update_ref(worker.ref, commit, worker.sha, reason: "lain landing queue: re-synced")
          moved.exitstatus.zero? ? worker.with(sha: commit) : worker
        end

        private

        def standing
          head = @parent.symbolic_head
          head.empty? ? "a detached HEAD" : head.delete_prefix("refs/heads/")
        end

        def key(worker) = Worktree::Handback::Naming.new(worker.id).key

        def report(worker, kind, **)
          Landed.new(worker:, report: WorkerHandoff::Report.new(kind:, ref: worker.ref, **))
        end

        def journaled(worker, outcome)
          record(worker, outcome.kind, fast_forward: outcome.fast_forward, sha: outcome.sha)
          outcome
        end

        # A journal reports a decision and never overturns one, so a sink that
        # raises costs the line, as it does in {Worktree::Handback}.
        def record(worker, outcome, **)
          @journal << Telemetry::Handback.new(worker_key: key(worker), outcome:, ref: worker.ref,
                                              strategy: @strategy.to_s, **)
        rescue StandardError
          nil
        end
      end

      module Resolver
        # No resolver: every leftover's conflict stands.
        module Standing
          def self.call(stale, desk) = stale.map { |waiting| desk.stand(waiting.worker, waiting.paths) }
        end

        # One `merge_resolver` child, spawned for the first leftover whose merge
        # conflicts and told the whole landing order. A leftover that still
        # conflicts after that stands: the one resolver is spent, and a second
        # spawn is exactly the per-worker cost the queue exists to avoid.
        class Spawned
          SPENT = "the one resolver this landing spawns was spent on an earlier leftover; the conflict stands"

          Pass = Data.define(:landed, :spent) do
            def add(entry) = with(landed: landed + [entry])
            def spend = with(spent: true)
          end

          # @param spawn [#call] `call(role, context_mode, prompt)` answering a
          #   {Tool::Result}: the seam {WorkerHandoff} spawns its resolver through
          def initialize(spawn:)
            @spawn = spawn
          end

          def call(stale, desk)
            order = stale.map(&:worker)
            stale.inject(Pass.new(landed: [], spent: false)) { |pass, waiting| step(pass, waiting.worker, desk, order) }
                 .landed
          end

          private

          def step(pass, worker, desk, order)
            outcome = desk.merge(worker)
            return pass.add(desk.landed(worker, outcome)) unless outcome.kind == :conflicted
            return pass.add(stood(worker, outcome, desk, SPENT)) if pass.spent

            pass.spend.add(resolved(worker, outcome, desk, order))
          end

          def resolved(worker, outcome, desk, order)
            reply = WorkerHandoff::Reply.from(@spawn.call(WorkerHandoff::ROLE, WorkerHandoff::CONTEXT_MODE,
                                                          prompt(worker, outcome, desk, order)))
            return stood(worker, outcome, desk, "the resolver never ran: #{reply.text}") if reply.refused?

            concluded(worker, outcome, desk, reply)
          rescue StandardError => e
            stood(worker, outcome, desk, "the resolver raised #{e.class}: #{e.message}")
          end

          # {Worktree::Handback#continue} decides whether the conflict is
          # settled, by re-reading the files, never the resolver's word.
          def concluded(worker, outcome, desk, reply)
            continued = desk.continue(worker)
            return stood(worker, outcome, desk, "#{continued.detail}; the resolver said: #{reply.text}") unless
              continued.kind == :merged

            Landed.new(worker:, report: WorkerHandoff::Report.new(kind: :resolved, ref: worker.ref,
                                                                  paths: outcome.paths, detail: reply.text,
                                                                  sha: continued.sha))
          end

          def stood(worker, outcome, desk, detail)
            desk.abandon(worker)
            desk.stand(worker, outcome.paths, detail)
          end

          # Absolute and quoted for {WorkerHandoff}'s reasons: the child does
          # not stand in the parent checkout, and a filename may hold a newline.
          def prompt(worker, outcome, desk, order)
            <<~PROMPT
              Workers' commits are landing on the working branch #{desk.branch}, in this order:

              #{order.each_with_index.map { |each, index| "#{index + 1}. #{each.ref || each.sha} (#{each.sha})" }.join("\n")}

              The merge of #{worker.ref || worker.sha} is in progress in this checkout and conflicted. These files
              carry conflict markers right now:

              #{outcome.paths.map { |path| "- #{File.join(desk.repo_root, path).inspect}" }.join("\n")}

              Each path above is absolute and quoted; open it exactly as written. Reconcile the two sides, keeping
              what each worker meant and knowing the workers after this one land next, in the order above. Write
              each file back with every marker gone. Edit nothing else, and run nothing.
            PROMPT
          end
        end
      end
    end
  end
end
