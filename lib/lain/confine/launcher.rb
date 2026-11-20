# frozen_string_literal: true

module Lain
  module Confine
    # Turns a term into the term that runs it under a {Profile}. A launcher
    # prefixes argv, so it composes with any exec that runs a {Shell::Term};
    # a backend that is not an argv prefix needs its own exec instead.
    #
    # A mask is bound from a descriptor the spawn hands over, so the exec
    # asks for the masks first, opens their descriptors for every stage, and
    # hands the same bound masks to the wrap and to the spawn.
    module Launcher
      # @param profile [Profile]
      # @return [#files, #bind] the profile's masks, read for what each shows the call
      def masked(profile) = raise NotImplementedError, "#{self.class} must implement #masked"

      # @param term [Shell::Term]
      # @param profile [Profile]
      # @param trace_fd [Integer] the descriptor, 3 or above, the exec trace is written to
      # @param bound [#argv, #fds] what {#masked} bound for every stage of the term
      # @return [Shell::Term]
      def wrap(term, profile, trace_fd:, bound:) = raise NotImplementedError, "#{self.class} must implement #wrap"
    end
  end
end
