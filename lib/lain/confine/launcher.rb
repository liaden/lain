# frozen_string_literal: true

module Lain
  module Confine
    # Turns a term into the term that runs it under a {Profile}. A launcher
    # prefixes argv, so it composes with any exec that runs a {Shell::Term};
    # a backend that is not an argv prefix needs its own exec instead.
    module Launcher
      # @param term [Shell::Term]
      # @param profile [Profile]
      # @param trace_fd [Integer] the descriptor, 3 or above, the exec trace is written to
      # @return [Shell::Term]
      def wrap(term, profile, trace_fd:) = raise NotImplementedError, "#{self.class} must implement #wrap"
    end
  end
end
