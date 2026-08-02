# frozen_string_literal: true

module Lain
  module Forge
    class Landing
      # What is already true before this run does anything: what this issue's
      # journal settled, and what the world says regardless.
      #
      # Gathered ONCE, at the top, and every {Unobservable} the gathering meets
      # is folded into a refusal HERE. {Reconcile} catches that exception only
      # inside the questions it asks itself ({Reconcile::Observer}'s `ask`), and
      # the head-ref lookup below is asked outside that fold -- a crashed
      # pr_create's outcome never recorded the number, so the head ref is the
      # only address that survives. Asking it deeper in the fold is how the
      # first version of this class let an exception escape `resume`.
      #
      # Pure, in {SessionRecord::Salvage}'s sense: it touches no file and opens
      # no socket of its own. It reads the two ducks it was handed -- entries and
      # a world -- and answers. Deciding what to DO about an answer is the
      # {Step}'s, and writing anything at all is the {Journaled} bracket's.
      class Evidence
        # The `--json` field a pull request record carries its number in.
        NUMBER = "number"

        # What the outside shows about one step. Two shapes rather than one
        # nullable answer, so a step picks its branch by SENDING a message
        # instead of testing for nil -- {Reconcile::Observer}'s Answer/Blocked
        # pair, same reason.
        Held = Data.define(:value) do
          def through(step, run) = step.held(run, value)
        end

        Missing = Data.define do
          def through(step, run) = step.missing(run)
        end

        # One shared empty answer; nothing distinguishes two of them.
        NOWHERE = Missing.new

        # @param entries [Enumerable<Hash, String>] this issue's journal records
        # @param world [#ref_exists?, #sha_of, #pr_state, #pr_for]
        # @param head [String] the ref a pull request would be opened from
        def self.gathered(entries:, world:, head:)
          new(report: Reconcile.new(entries:, world:).report, **located(world, head))
        end

        # The one question asked outside {Reconcile}'s own protection, with its
        # own catch. An ambiguous head ref -- {Reconcile::World#pr_for} refuses
        # more than one match -- is a journal no landing may continue from, not
        # a "no" this fold may act on.
        def self.located(world, head)
          record = world.pr_for(head:)
          { opened: record.nil? ? NOWHERE : Held.new(value: numbered(record)) }
        rescue Unobservable => e
          { opened: NOWHERE, unreadable: [e.message] }
        end
        private_class_method :located

        # S2: `fetch` that raises and NAMES the record beats three speculative
        # arms over `respond_to?(:value)` and a fallback that put a raw Hash into
        # `gh pr merge`'s argv. {Reconcile::World#pr_for} already promises a
        # document, so the type assertion is a canary for a `world` duck that
        # broke that promise, not a branch anyone is expected to take.
        def self.numbered(record)
          raise Unobservable, unnumbered(record) unless record.is_a?(Hash)

          record.fetch(NUMBER) { raise Unobservable, unnumbered(record) }
        end
        private_class_method :numbered

        def self.unnumbered(record)
          "cannot read a pull request number out of #{record.inspect} -- the merge step has no number to name"
        end
        private_class_method :unnumbered

        def initialize(report:, opened: NOWHERE, unreadable: [])
          @report = report
          @opened = opened
          @unreadable = unreadable.dup.freeze
          freeze
        end

        # The {Run} the fold starts from: a {Stopped} one when this journal is
        # inconsistent, so "no landing may continue from here" is expressed as
        # the same short-circuit every other refusal uses rather than as a guard
        # clause somebody can forget to write on the second path.
        def opening
          refusals = escalations
          refusals.empty? ? Running.new : Stopped.new(answer: inconsistent(refusals))
        end

        # @return [Held, Missing] whether this action's effect is already in
        #   place, and what the journal recorded it answered
        def about(action) = in_place?(action) ? Held.new(value: recorded_value(action)) : NOWHERE

        # The pull request a merge would name. The journal's own record wins --
        # it is what this landing's own pr_create ANSWERED -- and the head ref is
        # the fallback for the crash that left no outcome at all.
        def pull_request
          number = recorded_value(PR_CREATE)
          number.nil? ? @opened : Held.new(value: number)
        end

        # Nothing is known: no journal to fold and no world to ask. {Landing#call}
        # folds against this, which is what makes a fresh landing and a resumed
        # one ONE expression over one plan (CLAUDE.md's Null Object rule;
        # `Sink::Null` is the exemplar).
        #
        # Answering {Missing} to everything is the ABSENCE of evidence, not a
        # claim that nothing has happened -- and every performer in the plan is
        # idempotent by OBSERVATION rather than by memory ({Promotion}'s
        # already_promoted, {Gh#pr_create}'s already-exists refusal), so a fresh
        # run that meets an effect already in place still declines to duplicate
        # it.
        NONE = new(report: Reconcile::Report.new(settled: [], unsettled: [], orphans: [], unaddressable: []))

        private

        # B1b: settled-ness FOLDS ON `ok`. A settled-but-failed promote is a
        # promote that did not happen, and reading it as "already done" is what
        # let a resume open and merge a branch the promotion had refused to
        # write -- somebody else's commit landed as this issue's approved work.
        def settled_ok(action)
          @report.settled.select { |item| item.intent.action == action && item.outcome.ok? }
        end

        def in_place?(action)
          settled_ok(action).any? ||
            @report.unsettled.any? { |item| item.intent.action == action && item.completed_externally? }
        end

        # The LAST ok outcome's value: a re-land after a refusal journals a
        # second attempt, and the run being continued is the latest one.
        def recorded_value(action) = settled_ok(action).map { |item| item.outcome.detail["value"] }.last

        def escalations
          @report.orphans.map { |outcome| "an outcome answers no intent this journal holds (#{outcome.intent_id})" } +
            @report.unaddressable.map(&:reason) + @unreadable
        end

        # S4: every exit from a landing answers the same duck. A raw
        # {Reconcile::Report} handed back here is a Data inspect dump to the
        # human and a NoMethodError to a caller that sends `ok?`.
        def inconsistent(refusals)
          Gh::Answer.new(ok: false, detail: { "reason" => INCONSISTENT, "message" => refusals.join("; ") })
        end
      end
    end
  end
end
