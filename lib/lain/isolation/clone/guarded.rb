# frozen_string_literal: true

module Lain
  module Isolation
    class Clone
      # A checkout inside a clone lain cut: every git call runs pinned to the
      # clone's own git dir with fsmonitor off, and only after the clone is
      # checked again for a planted name, since a call may have planted one
      # after this checkout was taken.
      class Guarded < Checkout
        # @param dir [String] where each command runs, the clone or a directory inside it
        # @param clone [String] the clone lain cut
        # @param shell_out_factory [#call]
        def initialize(dir, clone:, shell_out_factory:)
          git = File.join(clone, ".git")
          super(dir, shell_out_factory:, pins: FSMONITOR_OFF,
                     env: { "GIT_DIR" => git, "GIT_COMMON_DIR" => git, "GIT_WORK_TREE" => clone })
          @clone = clone
        end

        def run(*, **)
          found = Guard.tampered(@clone)
          found.empty? ? super : Checkout::Done.refused(Tampered.refusal(found))
        end
      end
    end
  end
end
