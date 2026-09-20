# frozen_string_literal: true

module Lain
  module Epic
    # The four members that identify a review, normalized to the bytes that get
    # stored. Both halves carry them and both must read them the same way, so
    # this is one declaration rather than two -- {Contracts::ReviewRecord} is the
    # same argument on the validation side.
    #
    # `generation` goes through {WireInteger} because it arrives off a wire as
    # msgpack or JSON, and a stored `"3"` beside a `3` would key a review
    # {Review#settle} -- which reads it the same way -- could never find.
    module ReviewClaim
      def self.interned(epic_slug:, path:, generation:, written_digest:)
        { epic_slug: -epic_slug.to_s, path: path(path), generation: generation(generation),
          written_digest: -written_digest.to_s }
      end

      def self.generation(value) = WireInteger.read(value, field: "generation")

      # PUBLIC because {Review} keys its live open set on the same string this
      # record stores, and the two normalizations must be one: when they
      # diverged, `open?` answered true live and false after a restart for one
      # path -- a guard that stops guarding without a word.
      def self.path(value) = -value.to_s.strip
    end
  end
end
