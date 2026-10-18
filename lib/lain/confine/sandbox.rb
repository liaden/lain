# frozen_string_literal: true

module Lain
  module Confine
    # The sandbox a bash exec is built into, from what the box offers. A chat and a
    # bench arm build it the same way, so they cannot come to confine differently.
    class Sandbox
      LAYERS = %i[bwrap landlock].freeze

      # @param probe [Probe]
      # @return [Array<Symbol>] the layers the box does not offer
      def self.lacking(probe) = LAYERS.reject { probe.supports?(_1) }

      # A box without the layers cannot make a sandbox; the run says so, because the session
      # still records the reader arm.
      #
      # @param inner [Exec::Local, Exec::Docker]
      # @param journal [#<<]
      # @param requirer [String] who asked
      # @param because [String] why there is no sandbox
      # @return [Object] the inner exec, unchanged
      def self.degraded(inner, journal:, requirer:, because:)
        journal << Telemetry::CapabilityDegraded.new(capability: :sandbox, requirer:, provider: because)
        inner
      end

      # @param root [String] absolute; the project, for a call whose request names no root of its own
      # @param home [String] absolute; where the toolchain grants are looked for
      # @param masks [#masks] the {MaskList}, which may be one other sandboxes share
      # @param probe [Probe] what the box offers
      # @param fence [String] the lain-fence binary, read once for the probe and the launcher alike
      # @param journal [#<<] receives the sandbox's own records
      # @param notes [#<<] receives the degraded record; the journal unless a run says otherwise
      def initialize(root:, home:, masks:, probe:, fence:, journal:, notes: journal)
        @root = root
        @home = home
        @masks = masks
        @probe = probe
        @fence = fence
        @journal = journal
        @notes = notes
        @built = false
      end

      # @param inner [Exec::Local]
      # @param requirer [String] who asked, for the degraded record
      # @return [Exec::Sandboxed, Exec::Local] the inner exec itself when the box lacks a layer
      def wrap(inner, requirer:)
        lacking = self.class.lacking(@probe)
        return unsandboxed(inner, requirer, lacking) if lacking.any?

        @built = true
        Exec::Sandboxed.new(inner:, launcher:, profiles: Profiles.new(masks: @masks, probe: @probe, home: @home,
                                                                      root: @root),
                            journal: @journal)
      end

      # Starts the mask classification of a sandbox that was built.
      #
      # @return [self]
      def prime
        @masks.prime if @built
        self
      end

      private

      def unsandboxed(inner, requirer, lacking)
        self.class.degraded(inner, journal: @notes, requirer:, because: "the box lacks #{lacking.join(" and ")}")
      end

      # The probe finds both programs on PATH, so the launcher runs the ones it found.
      def launcher = Bwrap.new(fence: @fence, bwrap: on_path("bwrap"), strace: on_path("strace"))

      def on_path(program)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { File.join(_1, program) }
           .find { File.file?(_1) && File.executable?(_1) }
      end
    end
  end
end
