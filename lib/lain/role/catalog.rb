# frozen_string_literal: true

module Lain
  class Role
    # The shipped built-in roles (OM-5). Each names the tools it attenuates to;
    # its framing ships as a default slot at `prompt/templates/role/<name>.md`
    # and is user-overridable at `.lain/slots/role/<name>.md`. The reviewers hold
    # read-and-inspect capabilities but never {Tools::EditFile} -- a review does
    # not touch the tree. `court_clerk` is the memory writer OM-5 names; the
    # `friction_observer` role is parked by the plan and not shipped here.
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
        Role.new(name: :researcher, only: %i[read_file list_files web_fetch web_search]),
        Role.new(name: :court_clerk, only: %i[read_file list_files memory_read memory_write]),
        Role.new(name: :auto_approver, only: %i[read_file list_files glob grep]),
        # {Approval::Gate::Adjudicator}'s sibling of `auto_approver`: the same
        # read-only capabilities and the same one-word verdict contract, but it
        # judges an ARTIFACT against gathered evidence rather than one waiting
        # tool call. The two personas differ, so they are two roles -- reusing
        # auto-approver.md would tell the model a tool call is pending on every
        # artifact gate it ever sees.
        Role.new(name: :gate_adjudicator, only: %i[read_file list_files glob grep]),
        Role.new(name: :harness_improver, only: %i[read_file list_files glob grep improvement_write]),
        Role.new(name: :meta_harness, only: %i[read_file list_files glob grep]),
        Role.new(name: :meta_summarizer, only: %i[read_file list_files glob grep]),
        # Spawned UNATTENDED by {Isolation::WorkerHandoff} when a worker's
        # handback conflicts, so it deliberately holds no `bash`: every git call
        # belongs to {Isolation::Worktree::Handback}, this role only edits the
        # conflicted files, and without a tier-3 tool it never reaches the
        # approval gate that would hang the spawn waiting for a human.
        Role.new(name: :merge_resolver, only: %i[read_file edit_file write_file grep]),
        # {Review::Docent}'s answerer (T24): spawned per question on a review
        # thread, to explain ONE hunk to the human standing on it. Read-only for
        # the reviewers' reason -- explaining a change does not touch the tree --
        # and without `bash` for `merge_resolver`'s: it answers while a human is
        # mid-review and a tier-3 tool would park it at the approval gate.
        #
        # DELETABLE with the docent, and it does not travel alone: this entry,
        # `prompt/templates/role/diff-docent.md` and `role_spec.rb`'s roll call
        # are pinned to each other in both directions (see `review.rb`).
        Role.new(name: :diff_docent, only: %i[read_file list_files glob grep])
      ].to_h { |role| [role.name, role] }.freeze

      class << self
        # The role for +name+, raising a loud, catalog-listing error rather than
        # returning nil: asking for a role that does not exist is a wiring error,
        # and the message names the whole catalog so the fix is one glance away.
        def fetch(name)
          BUILT_INS.fetch(name.to_sym) do
            raise Unknown, "unknown role #{name.inspect}, expected one of #{names.inspect}"
          end
        end
        alias [] fetch

        # The catalog's role names, in declaration order.
        def names = BUILT_INS.keys

        # Every built-in role.
        def all = BUILT_INS.values
      end
    end
  end
end
