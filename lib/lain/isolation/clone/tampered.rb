# frozen_string_literal: true

module Lain
  module Isolation
    class Clone
      # A clone's lock as lain reads it once the clone was tampered with: held
      # against everything, whatever its lock file says.
      Tampered = Data.define(:found) do
        def held?(_table) = true

        def abandoned?(_table) = false

        def why(_table) = "git dir holds #{found.join(", ")}; lain runs no git here, so a human must look"

        def aged_from(created) = created
      end
    end
  end
end
