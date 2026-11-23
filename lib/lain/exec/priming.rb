# frozen_string_literal: true

require "delegate"
require "fileutils"

module Lain
  module Exec
    # An exec no sandbox profile bounds, so any call through it may write under
    # the root: it primes the round's snapshot before every call. That covers
    # `--confine off`, the docker backend, and a box whose sandbox degraded.
    class Priming < SimpleDelegator
      # The profiles a {Sandboxed} chooses from, priming the round once a call's
      # profile is chosen and before it runs, so a refusal stages nothing. It
      # skips the prime only for a confined profile whose write dirs miss the
      # root: an unconfined one names none because it writes anywhere, and the
      # reader writes /tmp, which can hold the project.
      class ByProfile < SimpleDelegator
        # @param profiles [#for] chooses a `Confine::Profile` for a {Confine::Request}
        # @param snapshots [#call] answers the round's {Agent::SnapshotSlot}, read at each call
        def initialize(profiles, snapshots:)
          super(profiles)
          @snapshots = snapshots
        end

        # @param request [Confine::Request]
        # @return [Confine::Profile] the wrapped profiles' choice
        def for(request) = __getobj__.for(request).tap { primed(_1) }

        private

        # The call's own tmpdir is made with the profile, and the exec removes it only once the call runs, so a
        # stage that raises, a stop among them, removes it here.
        def primed(profile)
          done = false
          slot = @snapshots.call
          slot.prime unless profile.confined? && slot.unwritable_by?(profile.write_dirs)
          done = true
        ensure
          FileUtils.rm_rf(profile.call_tmpdir) unless done || profile.call_tmpdir.nil?
        end
      end

      # A {Sandboxed} primes by the profile it applies, so it is left bare.
      #
      # @param exec [#call]
      # @param snapshots [#call] answers the round's {Agent::SnapshotSlot}
      # @return [#call] the exec, primed unless it is sandboxed
      def self.over(exec, snapshots:) = exec.is_a?(Sandboxed) ? exec : new(exec, snapshots:)

      # @param inner [#call] the exec that runs the call
      # @param snapshots [#call] answers the round's {Agent::SnapshotSlot}, read at each call, since the toolset
      #   holding this exec is built before the slot
      def initialize(inner, snapshots:)
        super(inner)
        @snapshots = snapshots
      end

      # @return [Capture] the inner exec's
      def call(**)
        @snapshots.call.prime
        __getobj__.call(**)
      end
    end
  end
end
