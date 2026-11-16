# frozen_string_literal: true

module Lain
  module CLI
    # The Thor-facing helpers `exe/lain`'s commands include, extend and declare
    # flags through. They live in lib/ so specs and other commands reach them by
    # constant; the namespace is not named Thor because that would shadow
    # `::Thor` for every `< Thor` class inside {Lain::CLI}.
    module Exe
    end
  end
end
