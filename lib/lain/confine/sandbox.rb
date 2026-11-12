# frozen_string_literal: true

require "tmpdir"

module Lain
  module Confine
    # The sandbox a bash exec is built into, from what the box offers. A chat and a
    # bench arm build it the same way, so they cannot come to confine differently.
    class Sandbox
      LAYERS = %i[bwrap landlock].freeze
      NO_PRIVATE_NET = "the box cannot give a call a private network"

      Containment = Data.define(:state, :because, :grants, :ports)

      # Whether a plain approval of a call that reads secrets can run it
      # contained: under a confined profile with no network beyond a build
      # tool's granted ports. `:able` can,
      # `:unable` cannot, so such an approval is refused until the human
      # chooses network, and `:off` confines nothing, by the session's choice.
      # `:unstated` is a queue nobody told, which says nothing on the row.
      # `grants` is whether a contained call runs under the workspace profile,
      # whose build tools keep their ports, and `ports` the ones a parked call could earn.
      class Containment
        NETWORK_CHOICE = "network runs it unconfined, with network"
        ABLE_CHOICE = "y runs %<call>s contained, without network, where files lain masks cannot be read; " \
                      "#{NETWORK_CHOICE}".freeze
        PORTED_CHOICE = "y runs %<call>s contained, where files lain masks cannot be read, and its build tool may " \
                        "reach the host's network on TCP ports %<ports>s; #{NETWORK_CHOICE}".freeze
        UNABLE_CHOICE = "y will not run %<call>s; #{NETWORK_CHOICE}".freeze
        UNABLE_NOTE = "lain cannot contain it here (%<because>s)"
        OFF_NOTE = "it will run unconfined, with network, because %<because>s"
        CONFINEMENT_OFF = "confinement is off"

        # @param because [String] why the box cannot contain a call
        # @return [Containment]
        def self.unable(because) = new(state: :unable, because:)

        # @param because [String] why the session confines nothing
        # @return [Containment]
        def self.off(because) = new(state: :off, because:)

        # @param grants [Boolean] whether the session can grant a contained call its build tool's ports
        # @return [Containment]
        def self.able(grants:) = grants ? new(state: :able, grants: true) : ABLE

        def initialize(state:, because: nil, grants: false, ports: [])
          super(state:, because: because&.then { -_1.to_s }, grants: grants == true, ports: ports.dup.freeze)
        end

        # @param argvs [Array<Array<String>>] the parked call's stages as the term arm would run them
        # @return [Containment] this one, with the ports that call could be granted where the session grants any
        def over(argvs) = able? && grants ? with(ports: Profiles.grantable_ports(argvs)) : self

        # @return [Boolean] whether a plain approval of a secret-bearing call is meant to run contained
        def confines? = %i[able unable].include?(state)

        # @return [Boolean] whether it can
        def able? = state == :able

        # @return [String, nil] why the call does not run contained, for the row; nil when it does or nothing
        #   was stated, since {#choice} then says it
        def note
          case state
          when :unable then format(UNABLE_NOTE, because:)
          when :off then format(OFF_NOTE, because:)
          end
        end

        # @param call [String] how the answer names the call, which a list of several rows must spell out
        # @return [String, nil] what y and network do, where the network answer is offered
        def choice(call = "it")
          case state
          when :able then ports.empty? ? format(ABLE_CHOICE, call:) : ported(call)
          when :unable then format(UNABLE_CHOICE, call:)
          end
        end

        ABLE = new(state: :able)
        OFF = off(CONFINEMENT_OFF)
        NONE = new(state: :unstated)

        private

        def ported(call) = format(PORTED_CHOICE, call:, ports: ports.join(", "))
      end

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
      # @param masks [#masks, #classify] the {MaskList}, which may be one other sandboxes share; it also
      #   answers for the session's policy on a path
      # @param probe [Probe] what the box offers
      # @param fence [String] the lain-fence binary, read once for the probe and the launcher alike
      # @param journal [#<<] receives the sandbox's own records
      # @param notes [#<<] receives the degraded record; the journal unless a run says otherwise
      # @param workspace [Boolean] whether an automatic allow runs under the workspace profile
      # @param tmpdir [String] absolute; where each workspace call gets a dir of its own to write
      # @param fresh [#any_under?] the lineage's freshness; by default every root is fresh and no port is granted
      def initialize(root:, home:, masks:, probe:, fence:, journal:, notes: journal, workspace: false,
                     tmpdir: Dir.tmpdir, fresh: Profiles::Unread)
        @root = root
        @home = home
        @masks = masks
        @probe = probe
        @fence = fence
        @journal = journal
        @notes = notes
        @profiling = { workspace:, tmpdir:, fresh: }
        @built = false
      end

      # @param inner [Exec::Local]
      # @param requirer [String] who asked, for the degraded record
      # @return [Exec::Sandboxed, Exec::Local] the inner exec itself when the box lacks a layer
      def wrap(inner, requirer:)
        lacking = self.class.lacking(@probe)
        return unsandboxed(inner, requirer, lacking) if lacking.any?

        @built = true
        profiles = Profiles.new(masks: @masks, probe: @probe, home: @home, root: @root, classifier: @masks,
                                **@profiling)
        Exec::Sandboxed.new(inner:, launcher:, profiles:, journal: @journal, reaps: @probe.supports?(:reap))
      end

      # @return [Containment] whether this box can run a call contained, with no network beyond a build tool's ports
      def containment
        lacking = self.class.lacking(@probe)
        return Containment.unable(reason_for(lacking)) if lacking.any?

        return Containment.unable(NO_PRIVATE_NET) unless @probe.supports?(:private_net)

        Containment.able(grants: @profiling[:workspace])
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
        self.class.degraded(inner, journal: @notes, requirer:, because: reason_for(lacking))
      end

      def reason_for(lacking)
        return "the box lacks #{lacking.join(" and ")}" unless lacking.include?(:landlock)
        return "the box lacks #{lacking.join(" and ")} (#{@probe.fence_gap})" unless @probe.fence_unstartable?

        others = lacking - [:landlock]
        [("the box lacks #{others.join(" and ")}" if others.any?),
         "the lain-fence #{@probe.fence_gap}"].compact.join("; ")
      end

      # The probe finds both programs on PATH, so the launcher runs the ones it found.
      def launcher = Bwrap.new(fence: @fence, bwrap: on_path("bwrap"), strace: on_path("strace"))

      def on_path(program) = Shell::Path.find(program, path: ENV.fetch("PATH", ""))
    end
  end
end
