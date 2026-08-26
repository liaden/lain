# frozen_string_literal: true

module Lain
  module Isolation
    # A worker's completion point, as one object: hand its committed work back to
    # the parent checkout ({Worktree::Handback}), spawn a resolver when that
    # merge conflicts, and give the leased environment up. An {Arm} calls this
    # exactly where it already called `lease.release`, so only what happens in
    # the instant before the checkout is reclaimed changes.
    #
    # == The two invariants, and why they are one object's job
    #
    # THE LEASE IS RELEASED. Handback must run while the lease is STILL LIVE --
    # there is nothing to read from a reclaimed checkout -- and the release must
    # happen even when the resolver explodes, because a leaked worktree
    # silently defeats the next acquire.
    #
    # THE PARENT CHECKOUT IS LEFT USABLE. A `:conflicted` handback leaves the
    # parent mid-merge ON PURPOSE (the only form in which a resolver can see
    # both sides), and every LATER handback into a parent that is already
    # merging is declined. So a merge this object started and did not finish
    # poisons the checkout for every worker after it, and leaves `<<<<<<<`
    # markers in a real person's working tree. {#restore} therefore abandons an
    # unfinished merge from the same `ensure` that releases the lease.
    #
    # THAT `ensure` IS THE POINT, because `Async::Cancel` and `Interrupt` are
    # `< Exception`, NOT `< StandardError`, and a `rescue StandardError` does not
    # see either. {Arm::OrchestratorWorker}'s fan-out is
    # `Sync { ...map { Async { work } }.map(&:wait) }`, so ONE worker's `acquire`
    # raising cancels its siblings mid-resolve, and Ctrl-C does the same at any
    # moment. Both climb past every rescue here, and must: an `ensure` restores
    # the parent and releases the lease, then the exception continues.
    #
    # NOTHING IS RELEASED WITHOUT FIRST TRYING TO ANCHOR. {Worktree} releases
    # with `--force` on a `--detach`ed checkout, so the instant a worktree is
    # reclaimed an unanchored commit is unreachable and gc-able. {#surrender} is
    # the unwinding path's version -- hand back, release, spawn NOTHING -- and an
    # arm's `ensure` calls it, so no exception class can route around the
    # ATTEMPT. {#reclaim} is the same sequence with the resolver in it. Both
    # no-op on an already-released lease, so calling one then the other costs a
    # boolean.
    #
    # THE ATTEMPT IS THE GUARANTEE. The `update-ref` lives inside
    # {Worktree::Handback#call}, so an exception raised THERE -- mid-`rev-parse`,
    # mid-`update-ref`, mid-merge -- used to reclaim with no ref written, and by
    # the time anything noticed, the lease was released and the checkout gone.
    # {Worktree::Handback#anchor} closes it, and {#complete}'s `ensure` calls it
    # whenever the body left nothing anchored, so no path reaches
    # `lease.release` until either a ref holds the worker's commits or git
    # itself refused to write one. ONE attempt, never a loop: this runs while an
    # exception is climbing, and an unbounded retry would hold the worktree for
    # as long as git kept failing.
    #
    # NO MODEL CALL WHILE UNWINDING. A resolver is an unbounded provider round
    # trip with no deadline anywhere in the chain, and running one inside an
    # `ensure` while a `Timeout::Error` or a Ctrl-C climbs would hold the lease,
    # and the worktree, for as long as the provider hangs. A conflict met while
    # unwinding is anchored, abandoned, and reported.
    #
    # A MARKER REFUSAL IS NOT RETRIED. {Worktree::Handback#continue} answers
    # `:conflicted` again when markers survive, and that is a real second chance
    # -- but taking it would loop a model on an unattended path with no bound
    # and no budget owner, against a prompt that already stated the marker rule
    # and produced this. So one attempt, then abandon: the parent goes back to
    # clean and the work stays anchored on its ref for a human to take. The cost
    # of not retrying is one deferred merge; the cost of retrying is unbounded
    # spend nobody is watching.
    class WorkerHandoff
      ROLE = :merge_resolver

      # `:fresh` is what keeps the conflict transcript out of the orchestrator's
      # context: the child gets its own Timeline root over the shared Store.
      CONTEXT_MODE = :fresh

      # The one state a person has to fix by hand. Unwinding a merge needs git,
      # and git is the thing that just failed, so all that is left is to SAY it
      # in the sentence that names the fix. A parent left mid-merge declines
      # every later handback into it, forever.
      STRANDED = "the parent checkout is STILL MID-MERGE and could not be unwound -- " \
                 "run `git merge --abort` there before any further handback"

      Report = Data.define(:kind, :ref, :paths, :detail)

      # What a worker's completion did, and -- the part its caller folds into the
      # worker's own result -- what a human has to do next.
      #
      # `kind` is `:nothing_to_do` (no lease, an already-finished one, or nothing
      # the parent did not already have), `:merged`, `:resolved` (it conflicted,
      # the resolver settled it, `paths` names the files it settled and `detail`
      # carries what it said), `:conflicted` (the conflict STANDS -- the merge
      # was abandoned and `ref` still holds the work), `:declined`, or `:failed`.
      # `paths` is always an Array and `detail` always a String, so no caller
      # writes a nil guard; `ref` is nil only when nothing was ever anchored.
      #
      # Reopened rather than declared in a `Data.define ... do` block: a
      # constant there is lexically scoped to the enclosing module, not the Data
      # class.
      class Report
        KINDS = %i[nothing_to_do merged resolved conflicted declined failed].freeze

        def self.nothing = new(kind: :nothing_to_do)

        # A {Worktree::Handback::Outcome} that needed no resolver, carried
        # through unchanged -- the kinds line up one for one.
        def self.from(outcome)
          new(kind: outcome.kind, ref: outcome.ref, paths: outcome.paths, detail: outcome.detail)
        end

        def initialize(kind:, ref: nil, paths: [], detail: "")
          kind = kind.to_sym
          raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}" unless KINDS.include?(kind)

          super(kind:, ref: ref&.dup&.freeze,
                paths: paths.map { |path| -path.to_s }.freeze, detail: -detail.to_s)
        end

        # The one line a caller folds into the worker's result. It names the
        # PATHS on a resolved conflict and the REF on every outcome that left
        # work behind, because those are the two things a human acts on, and
        # carries no conflict transcript, which is the child's business alone.
        # Empty when there is nothing to report, so a caller appends it blind.
        def summary
          case kind
          when :nothing_to_do then ""
          when :merged then "handback merged the worker's commits#{at_ref}"
          when :resolved then detailed("handback conflict resolved in #{paths.join(", ")}, then merged#{at_ref}")
          when :conflicted then detailed("the handback conflict STANDS unresolved; the work is on #{ref}")
          else detailed("handback #{kind}#{at_ref}")
          end
        end

        private

        # A nil ref is a legitimate answer -- a lost CAS, an already-released
        # lease, a raise before the write -- and rendering it as literal empty
        # parens made a `:failed` read as "the work is gone" when there was
        # never anything to name. Empty rather than "(none)": the sentence
        # should not mention a ref it has no ref to mention.
        def at_ref = ref.nil? ? "" : " (#{ref})"

        def detailed(sentence) = detail.empty? ? sentence : "#{sentence} -- #{detail}"
      end

      Reply = Data.define(:text, :refused)

      # The resolver's own answer, normalized. A spawn that was REFUSED and never
      # ran -- the depth ceiling, a Null resolver -- comes back as an ERROR
      # {Tool::Result} rather than a raise, and the two are told apart because
      # "never ran" and "ran and mis-edited" are different failures a human
      # fixes differently. The text rides onto the {Report} because the role
      # template PROMISES the child somewhere to say what it had to drop.
      # Squeezed and truncated: a Report summary is one line folded into a
      # worker's result, not a transcript.
      #
      # Reopened for the same reason {Report} is: a constant declared inside a
      # `Data.define ... do` block scopes to the enclosing module.
      class Reply
        LIMIT = 400
        ELLIPSIS = "..."

        # `Tool::Result#error?` is already a strict Boolean, so it rides through
        # untouched.
        def self.from(result)
          new(text: squeeze(flatten(result.content)), refused: result.error?)
        end

        # `content` is a String or an Array of provider content blocks -- the two
        # shapes {Tool::Result} accepts -- so both flatten to the text a human
        # would read.
        def self.flatten(content)
          return content.to_s unless content.is_a?(Array)

          content.filter_map { |block| block.is_a?(Hash) ? block["text"] || block[:text] : block }.join(" ")
        end

        def self.squeeze(text)
          squeezed = text.gsub(/\s+/, " ").strip
          squeezed.length <= LIMIT ? squeezed : "#{squeezed[0, LIMIT]}#{ELLIPSIS}"
        end

        def refused? = refused
      end

      # The spawn seam's Nulls. Neither edits anything, so a conflict falls down
      # the SAME path a resolver that changed nothing takes -- and, because both
      # answer an ERROR result, the {Report} says WHICH of them declined to run.
      module Resolver
        # No resolver wired at all.
        Null = Class.new do
          def call(_role_name, _context_mode, _prompt) = Tool::Result.error("no merge resolver is wired")
        end.new.freeze

        # A resolver deliberately not run: see the class doc on why an unbounded
        # provider round trip has no business inside an unwinding `ensure`.
        Skipped = Class.new do
          def call(_role_name, _context_mode, _prompt)
            Tool::Result.error("no resolver is spawned while a worker is unwinding")
          end
        end.new.freeze
      end

      # THE WAY TO BUILD ONE. `repo_root` is what the conflicted paths are
      # relative to and what the prompt absolutizes against, and it must be the
      # SAME checkout the handback merges into -- two roots would name files
      # that are not the ones on disk. Building both halves from one argument is
      # what makes that impossible to get wrong.
      #
      # @param repo_root [String] the parent checkout work comes back to
      # @param journal [#<<] where {Telemetry::Handback} records land
      # @param resolver [#call] the spawn seam -- see {#initialize}
      def self.over(repo_root:, journal: Channel::Null.instance, resolver: Resolver::Null)
        new(handback: Worktree::Handback.new(repo_root:, journal:), repo_root:, resolver:)
      end

      # @param handback [#call, #anchor, #continue, #abandon] {Worktree::Handback}
      # @param repo_root [String] the checkout `handback` merges into -- prefer
      #   {.over}, which derives both from one root so they cannot disagree
      # @param resolver [#call] the `call(role_name, context_mode, prompt)` spawn
      #   seam answering a {Tool::Result} -- {Skill::RoleSpawn} is the one that
      #   exists
      def initialize(handback:, repo_root:, resolver: Resolver::Null)
        @handback = handback
        @repo_root = File.expand_path(repo_root)
        @resolver = resolver
      end

      # The SETTLED completion: hand the worker's work back, resolve a conflict
      # if there is one, restore the parent, release the lease.
      #
      # @param lease [#worker_env, #release, #released?, nil] the live lease; nil
      #   when the acquire itself never happened, which is nothing to hand back
      # @param worker_id [Object] names the ref and the journal's join key
      # @return [Report] always -- no `StandardError` escapes, because this runs
      #   inside a gathered fiber where a raise would take the worker's own
      #   result with it. An `Exception` (a cancel, a Ctrl-C) DOES climb, after
      #   the parent is restored and the lease released.
      def reclaim(lease, worker_id:) = complete(lease, worker_id:, resolver: @resolver)

      # The UNWINDING completion: try to anchor the worker's commits to a ref
      # before the reclaim destroys them, restore the parent, release the lease
      # -- and spawn nothing. An arm calls this from its `ensure`, which is what
      # keeps any exception class from skipping the attempt.
      #
      # @return [Report] with the same totality contract as {#reclaim}
      def surrender(lease, worker_id:) = complete(lease, worker_id:, resolver: Resolver::Skipped)

      private

      # `anchored` and `restoration` are read in the `ensure`, and a local the
      # parser has SEEN assigned is nil rather than undefined even when the
      # assignment never ran -- so the unwind below is reachable however the
      # body ended. `restoration.nil?` is precisely "no reported path got
      # there", which is the `Exception` case.
      def complete(lease, worker_id:, resolver:)
        return Report.nothing if lease.nil? || lease.released?

        restoration = nil
        anchored = @handback.call(lease, worker_id:)
        told(resolve(anchored, worker_id:, resolver:), restoration = restore(anchored, worker_id:))
      rescue StandardError => e
        told(broke(anchor(lease, anchored, worker_id:), e), restoration = restore(anchored, worker_id:))
      ensure
        unwind(lease, anchored, worker_id:) if restoration.nil?
        lease&.release
      end

      # Anchor first: the ref is the thing that survives the release under it.
      def unwind(lease, anchored, worker_id:)
        anchor(lease, anchored, worker_id:)
        restore(anchored, worker_id:)
      end

      # Write the ref the body did not get to. {Worktree::Handback#anchor} merges
      # nothing and touches no working tree, which is what makes it callable
      # from here, and it is idempotent, so the guard below is an optimization
      # rather than a correctness condition.
      #
      # TOTAL and UNREPEATED, for the reasons {#restore} is total: this runs from
      # an `ensure` where a raise would REPLACE the exception already climbing
      # and skip the `lease&.release` under it, and a retry with no bound would
      # hold the worktree for as long as git kept failing.
      #
      # THE RESCUE IS FOR THE DUCK, NOT FOR GIT. {Worktree::Handback#anchor}
      # answers every failure with a journalled `:failed` Outcome and raises
      # nothing, so against the real collaborator this rescue never fires. It
      # stays because `handback` is INJECTED: a substitute that raises would
      # otherwise replace the climbing exception with its own and skip the
      # release -- measured, not assumed, by the one-attempt example.
      #
      # A lease that is nil or ALREADY RELEASED is refused rather than asked:
      # there is nothing to read from a reclaimed checkout.
      def anchor(lease, anchored, worker_id:)
        return anchored if lease.nil? || lease.released? || anchored&.ref

        @handback.anchor(lease, worker_id:)
      rescue Exception # rubocop:disable Lint/RescueException
        anchored
      end

      # Leave the parent checkout usable, and MEASURE whether that worked.
      # `:untouched` when there was no merge of ours to unwind, `:restored` once
      # the parent is clean again, `:stranded` when it is not.
      #
      # Only a merge THIS handback started is unwound -- `merge_in_progress?`
      # is false when this class declined because SOMEONE ELSE was already
      # merging, and aborting a sibling worker's merge would be real damage.
      #
      # TOTAL, and that is the whole point of the cop being off. This runs from
      # an `ensure`: an exception leaving here REPLACES the one already climbing
      # through it and skips the `lease&.release` under it, so the object's own
      # guarantee would depend on a caller's paired {#surrender} to rescue it.
      # `Async::Cancel` and `Interrupt` are `< Exception`, so a `rescue
      # StandardError` here is the original blocker one level down. Every raise
      # becomes `:stranded`, the loudest thing this method can honestly say, and
      # {#told} escalates it onto the Report with the command that fixes it. A
      # swallowed cancel is not lost: `async` re-raises it at the task's next
      # suspension point.
      def restore(anchored, worker_id:)
        return :untouched if anchored.nil? || anchored.ref.nil? || !anchored.merge_in_progress?

        @handback.abandon(anchored.ref, worker_id:).merge_in_progress? ? :stranded : :restored
      rescue Exception # rubocop:disable Lint/RescueException
        :stranded
      end

      # Escalated onto the Report rather than left to be discovered when the
      # NEXT handback declines.
      def told(report, restoration)
        return report unless restoration == :stranded

        report.with(kind: :failed, detail: [report.detail, STRANDED].reject(&:empty?).join("; "))
      end

      # The resolver is the only thing here that runs a model, so it is the only
      # thing that can raise a `StandardError`; a raise from it must not leave
      # the parent mid-merge, so it falls through to the same stand-down a
      # resolver that changed nothing gets.
      def resolve(outcome, worker_id:, resolver:)
        return Report.from(outcome) unless outcome.kind == :conflicted

        reply = Reply.from(resolver.call(ROLE, CONTEXT_MODE, prompt_for(outcome)))
        return stand_down(outcome, detail: "the resolver never ran: #{reply.text}") if reply.refused?

        conclude(outcome, worker_id:, reply:)
      rescue StandardError => e
        stand_down(outcome, detail: "the resolver raised #{e.class}: #{e.message}")
      end

      # {Worktree::Handback#continue} is the only thing that decides a conflict
      # is settled: it re-reads the files and refuses while markers survive, so
      # a resolver that merely CLAIMED success cannot commit corruption. Either
      # way the resolver's own words ride back, because a `:resolved` that says
      # nothing and a `:conflicted` that says nothing are the two reports a
      # human cannot act on.
      def conclude(outcome, worker_id:, reply:)
        continued = @handback.continue(outcome.ref, worker_id:)
        if continued.kind == :merged
          return Report.new(kind: :resolved, ref: outcome.ref, paths: outcome.paths, detail: reply.text)
        end

        stand_down(outcome, detail: "#{continued.detail}; the resolver said: #{reply.text}")
      end

      # The merge itself is unwound by {#restore}, which runs on every path
      # including the ones that never reach here, so this only says WHY.
      def stand_down(outcome, detail:)
        Report.new(kind: :conflicted, ref: outcome.ref, paths: outcome.paths, detail:)
      end

      # A failure AFTER the ref was written still has to name the ref: "say where
      # the work is" is the whole contract, and this is the path where a human
      # most needs it.
      def broke(anchored, error)
        Report.new(kind: :failed, ref: anchored&.ref, detail: "#{error.class}: #{error.message}")
      end

      # The per-call facts, on top of the standing framing the `merge_resolver`
      # role slot carries: WHICH files and WHERE the work is anchored.
      #
      # ABSOLUTE, because the child does not stand where these paths are from.
      # Git reports them relative to the parent checkout, but a spawned resolver
      # resolves a relative path against its OWN `session.worker_env.cwd`, which
      # is never the parent -- so a repo-relative path reads some other file, or
      # none.
      #
      # QUOTED, because a filename may contain a newline, and the listing goes to
      # the trouble of `-z` and an encoding re-tag precisely so those paths open:
      # a bare `- #{path}` shears one across two bullets and names a file that
      # does not exist.
      def prompt_for(outcome)
        <<~PROMPT
          A worker's commits were merged into this checkout and the merge conflicted. The
          worker's work is anchored on the ref #{outcome.ref}, the merge is still in
          progress, and these files carry conflict markers right now:

          #{outcome.paths.map { |path| "- #{absolute(path).inspect}" }.join("\n")}

          Each path above is absolute and quoted; open it exactly as written, unescaped.
          Read each one, reconcile the two sides, and write it back with every marker gone.
          Edit nothing else, and run nothing -- you hold no shell, and the merge concludes
          itself the moment those files are clean.
        PROMPT
      end

      def absolute(path) = File.join(@repo_root, path)
    end

    class WorkerHandoff
      # No handoff wired means release and nothing else, so every arm that does
      # not inject one behaves exactly as it did before this existed.
      Null = Class.new do
        def reclaim(lease, **)
          lease&.release
          Report.nothing
        end
        alias_method :surrender, :reclaim
      end.new.freeze
    end
  end
end
