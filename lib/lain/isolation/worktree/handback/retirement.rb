# frozen_string_literal: true

module Lain
  module Isolation
    class Worktree
      class Handback
        # How an actor whose work is done gives its checkout up: rebased onto the
        # working branch while the actor can still be asked, then its commits
        # anchored under `refs/lain/worker/` -- and nothing more. The shape is
        # {WorkerHandoff#surrender}'s with the merge left out, because a
        # retired worker's work lands through a gate, never here: the ref is
        # written before the lease under it is released, and nothing that runs a
        # model is spawned.
        #
        # It lives HERE, under the handback, rather than under the {Supervisor}
        # that calls it: every outcome it answers is a {Handback::Outcome}, every
        # ref it writes is a {Handback::Naming} ref, and the git it shells to is
        # the handback's own. What the Supervisor holds is the decision to retire
        # a row; what happens to the checkout afterwards is worktree handback.
        class Retirement
          # ONE refusal, one sentence. {Supervisor#retirable!} raises it too --
          # formatting THIS constant, not a copy of it -- because the two guard
          # the same case a layer apart: a lease already given up has no
          # checkout left to anchor, whether the Supervisor noticed first or
          # this did.
          RELEASED = "%<worker>s's lease was already released, so nothing is left to anchor"

          # What a worker's ref holds before its sync, judged against the
          # checkout's own HEAD. `refusal` is the outcome that stops the
          # retirement when the ref already anchors work this checkout lacks.
          Standing = Data.define(:head, :refusal) do
            def taken? = !refusal.nil?
          end

          # Anchors a retired worker's commits under its ref, holding two lines a
          # bare compare-and-swap cannot:
          #
          # - COMMITTED NOTHING READS AS NOTHING, judged against the working
          #   branch's tip and never the parent checkout's HEAD. An epic branch
          #   runs ahead of the checkout a human stands in, so a worker cut from
          #   its tip that committed nothing would otherwise anchor that tip as
          #   its work.
          # - AN ANCHOR IS NEVER MOVED OFF WORK IT HOLDS. The ref moves only to a
          #   commit containing what it holds, or off the value this worker's own
          #   self-sync wrote before rebasing. Anything else is another run's only
          #   anchor, and the retirement is refused. The write is compare-and-
          #   swapped against the value judged.
          #
          # Every failure answers a `:failed` outcome rather than raising.
          class Anchor
            ANCHORED = "lain retirement: anchored"

            KEPT = "lain retirement: kept a commit its worker's ref could not take"

            TAKEN = "%<ref>s already anchors %<held>s, which %<head>s does not contain; an anchor is never moved " \
                    "off work it holds, so the refused commit %<head>s is %<kept>s"

            # @param parent [Checkout] the repository the refs live in
            # @param base [#tip, #name] the working branch the workers are cut from
            # @param shell_out_factory [#call] builds the subprocess runner for a
            #   worker's own checkout
            def initialize(parent:, base:, shell_out_factory: Lain::Shell::Out.public_method(:new))
              @parent = parent
              @base = base
              @shell_out_factory = shell_out_factory
            end

            # @return [Standing]
            def standing(lease, worker_id:)
              named = Naming.new(worker_id)
              head = head_of(lease)
              held = @parent.target(named.ref)
              free = held.empty? || nothing?(head) || within?(held, head)
              Standing.new(head:, refusal: (taken(named, held, head) unless free))
            rescue StandardError => e
              Standing.new(head: nil, refusal: broke(named, e))
            end

            # @param lease [#worker_env] the live lease whose checkout holds the
            #   commits
            # @param worker_id [Object] names the ref
            # @param from [String, nil] the HEAD {#standing} read, which the
            #   self-sync may have anchored before its rebase
            # @return [Outcome]
            def anchor(lease, worker_id:, from:)
              named = Naming.new(worker_id)
              commit = head_of(lease)
              return outcome(:nothing_to_do, named) if nothing?(commit)

              held = @parent.target(named.ref)
              return anchored(named, commit) if held == commit
              return taken(named, held, commit) unless held.empty? || held == from || within?(held, commit)

              written(named, commit, @parent.update_ref(named.ref, commit, held, reason: ANCHORED))
            rescue StandardError => e
              broke(named, e)
            end

            private

            def head_of(lease)
              head = Checkout.new(lease.worker_env.cwd, shell_out_factory: @shell_out_factory).head
              raise SelfSync::Failed, "git rev-parse HEAD failed in #{lease.worker_env.cwd}" unless
                head.exitstatus.zero?

              head.stdout.strip
            end

            # Everything the worker has, its working branch already has.
            def nothing?(commit) = @base.name.empty? ? @parent.ancestor?(commit) : within?(commit, @base.tip)

            # Whether `ancestor` is `commit` or reachable from it.
            def within?(ancestor, commit) = ancestor == commit || @parent.ancestor?(ancestor, commit)

            def written(named, commit, shell)
              return anchored(named, commit) if shell.exitstatus.zero?

              Outcome.git_failed(named.key, "update-ref #{named.ref}", shell)
            end

            def anchored(named, commit)
              outcome(:declined, named, ref: named.ref, sha: commit, detail: ANCHOR_ONLY)
            end

            def taken(named, held, head)
              kept = keep_refused(named, head)
              outcome(:failed, named, detail: format(TAKEN, ref: named.ref, held:, head:, kept:))
            end

            # The refused commit, on a ref of its own named for the worker and
            # the commit, so the report can say where an operator finds it.
            #
            # @return [String] where it was kept, as the end of the refusal
            def keep_refused(named, head)
              ref = Naming.new("#{named.key} refused #{head}").ref
              return "kept on #{ref}" if @parent.target(ref) == head

              written = @parent.update_ref(ref, head, "", reason: KEPT)
              return "kept on #{ref}" if written.exitstatus.zero?

              "not kept on a ref of its own (#{written.stderr.strip}); a release still keeps unreached commits"
            end

            def broke(named, error) = outcome(:failed, named, detail: "#{error.class}: #{error.message}")

            def outcome(kind, named, **) = Outcome.new(kind:, worker_key: named.key, **)
          end

          # No retirement wired: nothing is synced or anchored, so a retired actor
          # is stopped and its lease released exactly as {Supervisor#stop} would,
          # and the environment it is handed is the one it was leased. Its report
          # says exactly that, since whether anything was committed is not a
          # question it asked.
          module Null
            UNWIRED = "no retirement is wired, so nothing was synced or anchored"

            def self.editorless(worker_env) = worker_env
            def self.settled(_lease, **) = WorkerHandoff::Report.new(kind: :declined, detail: UNWIRED)
            def self.surrender(_lease, **) = settled(nil)
          end

          # One root for the anchor and for reading back what it holds, so the two
          # cannot name different repositories.
          #
          # @param isolation [#base, #repo_root] the backend the actors lease from
          # @param journal [#<<] where each retirement's handback record lands
          # @param strategy [MergeStrategy] the conflict style a rebase is spelled
          #   with, so an actor resolves the markers a merge would have shown it
          # @param retries [Integer] how often a conflicted actor is asked to
          #   rebase its own work; 0 rebases nothing
          def self.over(isolation:, journal: Channel::Null.instance, strategy: MergeStrategy::DEFAULT,
                        retries: 1)
            base = isolation.base
            new(sync: SelfSync.new(base:, strategy:, retries:), journal:, strategy:,
                anchor: Anchor.new(parent: Checkout.new(isolation.repo_root), base:))
          end

          # @param sync [#call, #editorless] {SelfSync}
          # @param anchor [#standing, #anchor] {Anchor}: what the worker's ref holds
          #   before any sync, and the anchoring after it
          # @param journal [#<<] where the {Telemetry::Handback} record lands
          # @param strategy [MergeStrategy] named on that record
          def initialize(sync:, anchor:, journal: Channel::Null.instance, strategy: MergeStrategy::DEFAULT)
            @sync = sync
            @anchor = anchor
            @journal = journal
            @strategy = strategy
          end

          # What an adopted actor's own shell runs under, so a rebase it is asked
          # to finish never opens an editor it has no terminal to show.
          def editorless(worker_env) = @sync.editorless(worker_env)

          # A settled actor: rebased, asking it through `worker` on a conflict,
          # then anchored.
          #
          # @return [WorkerHandoff::Report]
          def settled(lease, worker:, worker_id:)
            kept(lease, worker_id) { @sync.call(lease, worker:, worker_id:) }
          end

          # An actor that did not settle -- its turn raised, or it was stopped
          # mid-turn -- cannot be asked, so its checkout is anchored as it stands,
          # and `detail` carries why onto the report.
          #
          # @return [WorkerHandoff::Report]
          def surrender(lease, worker_id:, detail: "")
            kept(lease, worker_id, detail) { SelfSync::Result::NONE }
          end

          private

          # A ref already holding work this checkout lacks is refused BEFORE the
          # sync, whose own anchor-first write would move it too. A cancel landing
          # mid-sync still gets its anchor, from the `ensure`, because the release
          # after this reclaims the checkout.
          #
          # The refusal is the SUPERVISOR's, deliberately: {Supervisor#retire} is
          # the caller that owns the released-lease vocabulary, and a second name
          # for one refusal would let two callers disagree about what it means.
          def kept(lease, worker_id, detail = "")
            raise Supervisor::AlreadyReleased, format(RELEASED, worker: worker_id) if lease.released?

            standing = @anchor.standing(lease, worker_id:)
            return reported(standing.refusal, SelfSync::Result::NONE, detail) if standing.taken?

            outcome = nil
            synced = yield
            outcome = @anchor.anchor(lease, worker_id:, from: standing.head)
            reported(outcome, synced, detail)
          ensure
            unwound(lease, worker_id, standing) unless outcome || standing.nil? || standing.taken? || lease.released?
          end

          # Total, because it runs while a cancel climbs and a raise here would
          # replace it.
          def unwound(lease, worker_id, standing)
            journaled(@anchor.anchor(lease, worker_id:, from: standing.head), SelfSync::Result::NONE)
          rescue Exception # rubocop:disable Lint/RescueException
            nil
          end

          def reported(outcome, synced, detail)
            report = WorkerHandoff::Report.from(outcome)
            report.with(detail: [report.detail, detail, journaled(outcome, synced)].reject(&:empty?).join("; "))
          end

          # One record per retirement, the sync's facts riding the anchor's. Its
          # `sha` stays nil: on that record a SHA names what landed in the parent,
          # and nothing did. Landing reads this record, so a write that fails is
          # said on the report rather than swallowed.
          #
          # @return [String] empty once journaled, else what the report must carry
          def journaled(outcome, synced)
            @journal << Telemetry::Handback.new(worker_key: outcome.worker_key, outcome: outcome.kind,
                                                ref: outcome.ref, strategy: @strategy.to_s, **synced.to_record)
            ""
          rescue StandardError => e
            "the handback record was not journaled: #{e.class}: #{e.message}"
          end
        end
      end
    end
  end
end
