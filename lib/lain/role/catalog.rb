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
        Role.new(name: :court_clerk, only: %i[read_file list_files memory_read memory_write])
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
