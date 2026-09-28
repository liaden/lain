# frozen_string_literal: true

module Lain
  class Role
    # The shipped built-in roles. Each names the tools it attenuates to; its
    # framing ships as a default slot at `prompt/templates/role/<name>.md` and
    # is user-overridable at `.lain/slots/role/<name>.md`, `<name>` spelled as
    # the catalog key is. The reviewers hold
    # read-and-inspect capabilities but never {Tools::EditFile} -- a review does
    # not touch the tree.
    #
    # Attenuation is expressed against tool NAMES, resolved at spawn time against
    # whatever union the seam supplies; a name the union lacks fails loudly then
    # (through {Toolset#only}), which is the honest place for it -- the catalog
    # states intent, the spawn supplies the union.
    module Catalog
      class Unknown < Error; end

      # Keyed by catalog name. Values are frozen {Role}s (deeply immutable Data),
      # so the catalog is a shareable constant, not a mutable registry.
      BUILT_INS = [
        Role.new(name: :dev, only: %i[read_file list_files glob grep edit_file write_file todo_write bash]),
        Role.new(name: :test_engineer,
                 only: %i[read_file list_files glob grep edit_file write_file todo_write bash]),
        Role.new(name: :reviewer_sre, only: %i[read_file list_files bash]),
        Role.new(name: :reviewer_security, only: %i[read_file list_files bash]),
        Role.new(name: :reviewer_dba, only: %i[read_file list_files bash]),
        # The reviewer an issue orchestrator hands its reviewing to. It reads
        # and SEARCHES the code it judges, and holds nothing that writes or
        # reaches the network: a review must not edit the tree under it, and
        # the three reviewers above hold `bash`, which writes.
        Role.new(name: :reviewer_code, only: %i[read_file list_files glob grep]),
        Role.new(name: :researcher, only: %i[read_file list_files web_fetch web_search]),
        Role.new(name: :court_clerk, only: %i[read_file list_files memory_read memory_write]),
        # {Approval::AutoSurface}'s judge. Unattended because the sweep that
        # asked it waits on its answer with the judged call still parked: a
        # question of its own would hold that call until the queue's clock
        # denied it.
        Role.new(name: :auto_approver, only: %i[read_file list_files glob grep], unattended: true),
        # {Approval::Gate::Adjudicator}'s sibling of `auto_approver`, judging an
        # ARTIFACT rather than one waiting tool call. Two roles because reusing
        # auto_approver.md would tell the model a tool call is pending on every
        # artifact gate. Unattended for `auto_approver`'s reason: the gate is
        # already waiting on its answer.
        Role.new(name: :gate_adjudicator, only: %i[read_file list_files glob grep], unattended: true),
        Role.new(name: :harness_improver, only: %i[read_file list_files glob grep improvement_write]),
        Role.new(name: :meta_harness, only: %i[read_file list_files glob grep]),
        Role.new(name: :meta_summarizer, only: %i[read_file list_files glob grep]),
        # Spawned UNATTENDED by {Isolation::WorkerHandoff} when a worker's
        # handback conflicts, so it deliberately holds no `bash`: every git call
        # belongs to {Isolation::Worktree::Handback}, and without a tier-3 tool
        # it never reaches the approval gate that would hang the spawn. The path
        # is unbounded, and {Isolation::WorkerHandoff#complete} runs the resolve
        # BEFORE the restore, so a resolver parked on a question strands the
        # parent mid-merge still holding the lease -- the STRANDED state, the
        # one a person has to fix by hand.
        Role.new(name: :merge_resolver, only: %i[read_file edit_file write_file grep], unattended: true),
        # {Review::Docent}'s answerer, explaining ONE hunk to the human standing
        # on it. Read-only for the reviewers' reason, and without `bash` for
        # `merge_resolver`'s. `unattended` is the half `only:` could never say:
        # the human is STANDING on the hunk waiting for the PENDING line to
        # become an answer, so a child that parked on a question would hang the
        # very thing being waited for -- and the grant that could do it
        # ({Tools::Subagent::ChildBuilder#granted}) happens outside this list.
        #
        # DELETABLE with the docent, and not alone: this entry,
        # `prompt/templates/role/diff_docent.md` and `role_spec.rb`'s roll call
        # are pinned to each other in both directions (see `review.rb`).
        Role.new(name: :diff_docent, only: %i[read_file list_files glob grep], unattended: true),
        # {Review::Critique}'s reviewer, one per chunk of a held review. Read-only
        # and unattended for `diff_docent`'s reasons. The critique lends it a
        # detached checkout of the reviewed head as its working directory, so a
        # RELATIVE read lands on committed bytes; the read tools confine no path,
        # so an absolute one can still reach the project's working tree.
        Role.new(name: :diff_critic, only: %i[read_file list_files glob grep], unattended: true),
        # {QA::Ladder}'s rungs, judging landed work against its acceptance
        # criteria. "Reports, never fixes" is a CAPABILITY here and not a
        # promise in the prompt: without `edit_file` or `write_file` it cannot
        # repair what it judges, which is what lets QA run against the same
        # checkout the work landed in rather than needing a throwaway one.
        #
        # No `bash`, for `merge_resolver`'s reason: nothing watches a ladder -- a
        # pass is dozens of asks the human waits out -- so a tier-3 call parking
        # at the approval gate under `ask` would stall every criterion behind it.
        #
        # THE COST IS ASYMMETRIC, AND IN THE UNSAFE DIRECTION. A rung cannot run
        # anything, so `executed` is false for every honest answer this role
        # gives, and the only two rows of {QA::Escalation::RULES} whose action is
        # `report` require it. Every other row climbs. So a criterion this role
        # judges can be CLEARED on words alone -- `unanimous-pass` sits at the
        # bottom of the table and a strong rung's inferred pass reaches it -- and
        # can never be FILED, because `unconfirmed-fail` sits above
        # `no-strong-voice` and sends an inferred fail up a ladder with nothing
        # above it. The measured hazard the ladder was built against is models
        # wrongly PASSING real violations, which is the one direction an
        # unexecuted answer is still allowed to settle.
        #
        # So the only route to a filed blocker today is a model that disobeys:
        # `executed` is a self-report nothing audits, and both the role framing
        # and the `qa` skill tell it in writing that the field is false. The
        # structural repair is a rung that declares whether it can execute, with
        # {QA::Escalation} discounting the self-report against it; until then the
        # hooks run the tests and this role reads.
        Role.new(name: :qa, only: %i[read_file list_files glob grep], unattended: true),
        # Runs a whole issue's plan in one ask: dev's tools, a spawner for the
        # implementers and reviewers, and the renderer that puts the plan's
        # skill in front of it. No chat floor holds either extra name, so only
        # the epic's own Subagent can build this role; everywhere else it
        # refuses at spawn, naming the tool the union lacks.
        Role.new(name: :issue_orchestrator,
                 only: %i[read_file list_files glob grep edit_file write_file todo_write bash subagent run_skill])
      ].to_h { |role| [role.name, role] }.freeze

      class << self
        # Raises rather than returning nil: asking for a role that does not
        # exist is a wiring error, and naming the whole catalog in the message
        # puts the fix one glance away.
        def fetch(name)
          BUILT_INS.fetch(name.to_sym) do
            raise Unknown, "unknown role #{name.inspect}, expected one of #{names.inspect}"
          end
        end
        alias [] fetch

        # In declaration order.
        def names = BUILT_INS.keys

        def all = BUILT_INS.values
      end
    end
  end
end
