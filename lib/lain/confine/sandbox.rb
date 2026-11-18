# frozen_string_literal: true

require "active_support"
require "active_support/core_ext/module/delegation"
require "tmpdir"

module Lain
  module Confine
    # The sandbox a bash exec is built into, from what the box offers. A chat and a
    # bench arm build it the same way, so they cannot come to confine differently.
    class Sandbox
      LAYERS = %i[bwrap landlock].freeze
      NO_PRIVATE_NET = "the box cannot give a call a private network"

      # A session whose phone answers its calls runs outside the sandbox only what a human approved, traced.
      class Unconfined < Error
        attr_reader :profile

        # @param profile [Symbol] the unconfined profile the call would have run under
        def initialize(profile:)
          @profile = profile
          super("a #{profile} call runs outside the sandbox")
        end
      end

      # The profiles of a session a phone answers. A human's approval runs traced, as at the terminal (user
      # ruling 2026-11-17); any other call outside the sandbox could pair itself as a phone and approve itself.
      class PhoneAnswered
        # @param profiles [Profiles]
        # @param reaps [Boolean] whether the fence can run an unconfined call traced; without it the call runs bare
        def initialize(profiles, reaps:)
          @profiles = profiles
          @reaps = reaps
        end

        # @param request [Request]
        # @return [Profile] a confining one, or the traced one for a human's approval
        # @raise [Unconfined] when the call would run unconfined without a human's approval, or untraced
        def for(request)
          profile = @profiles.for(request)
          return profile if profile.confined? || (watched?(profile) && request.ruling.human?)

          raise Unconfined.new(profile: watched?(profile) ? profile.name : Profile::NONE.name)
        end

        private

        def watched?(profile) = @reaps && profile.trace
      end

      # The profiles of a session a phone answers, on a box that can build no sandbox:
      # every call would run bare, so each is refused.
      module Unsandboxed
        # @param _request [Request]
        # @raise [Unconfined] always
        def self.for(_request) = raise(Unconfined.new(profile: Profile::NONE.name))
      end

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

        # @return [Boolean] whether the session chose to confine nothing
        def off? = state == :off

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

        # A containment the box answers when first read. Asking whether it gives a private network spawns
        # bwrap, about 3 ms, which a chat launch should not pay before any call reads secrets. Off is the
        # session's choice, never the box's answer, so {#off?} needs no answer.
        class Deferred
          delegate :state, :because, :grants, :ports, :over, :confines?, :able?, :note, :choice, :to_h, :with,
                   :members, :deconstruct, :deconstruct_keys, :==, :eql?, :hash, to: :resolved

          # @yieldreturn [Containment] able or unable, asked for once
          def initialize(&answer)
            @answer = answer
            @mutex = Mutex.new
          end

          # @return [false]
          def off? = false

          private

          def resolved = @resolved || @mutex.synchronize { @resolved ||= answered }

          def answered
            @answer.call.tap { raise ArgumentError, "the box answered off, which only a session chooses" if _1.off? }
          end
        end

        private

        def ported(call) = format(PORTED_CHOICE, call:, ports: ports.join(", "))
      end

      # @param probe [Probe]
      # @return [Array<Symbol>] the layers the box does not offer
      def self.lacking(probe) = LAYERS.reject { probe.supports?(_1) }

      # @param probe [Probe]
      # @return [String, nil] why the box cannot build a sandbox; nil when it can
      def self.gap(probe)
        lacking = lacking(probe)
        return if lacking.empty?
        return "the box lacks #{lacking.join(" and ")}" unless lacking.include?(:landlock)
        return "the box lacks #{lacking.join(" and ")} (#{probe.fence_gap})" unless probe.fence_unstartable?

        others = lacking - [:landlock]
        fence = "the lain-fence #{probe.fence_gap}"
        others.empty? ? fence : "the box lacks #{others.join(" and ")}; #{fence}"
      end

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
      # @param phone_answered [Boolean] whether a call that would run unconfined is refused rather than run,
      #   unless a human approved it and it runs traced
      def initialize(root:, home:, masks:, probe:, fence:, journal:, notes: journal, workspace: false,
                     tmpdir: Dir.tmpdir, fresh: Profiles::Unread, phone_answered: false)
        @root = root
        @home = home
        @masks = masks
        @probe = probe
        @fence = fence
        @journal = journal
        @notes = notes
        @profiling = { workspace:, tmpdir:, fresh: }
        @phone_answered = phone_answered
        @built = false
      end

      # @param inner [Exec::Local]
      # @param requirer [String] who asked, for the degraded record
      # @return [Exec::Sandboxed, Exec::Local] the inner exec itself when the box lacks a layer, unless a
      #   phone answers the session
      def wrap(inner, requirer:)
        return unsandboxed(inner, requirer) if self.class.lacking(@probe).any?

        @built = true
        Exec::Sandboxed.new(inner:, launcher:, profiles:, journal: @journal, reaps: @probe.supports?(:reap))
      end

      # @return [Containment::Deferred] whether this box can run a call contained, with no network beyond a build
      #   tool's ports
      def containment = Containment::Deferred.new { contained_here }

      # Starts the mask classification of a sandbox that was built.
      #
      # @return [self]
      def prime
        @masks.prime if @built
        self
      end

      private

      def contained_here
        gap = self.class.gap(@probe)
        return Containment.unable(gap) if gap

        return Containment.unable(NO_PRIVATE_NET) unless @probe.supports?(:private_net)

        Containment.able(grants: @profiling[:workspace])
      end

      def profiles
        built = Profiles.new(masks: @masks, probe: @probe, home: @home, root: @root, classifier: @masks, **@profiling)
        @phone_answered ? PhoneAnswered.new(built, reaps: @probe.supports?(:reap)) : built
      end

      # A box can lose a layer after the launch checked it, and a phone's session never runs a call bare.
      def unsandboxed(inner, requirer)
        bare = self.class.degraded(inner, journal: @notes, requirer:, because: self.class.gap(@probe))
        return bare unless @phone_answered

        Exec::Sandboxed.new(inner: bare, launcher:, profiles: Unsandboxed, journal: @journal)
      end

      # The probe finds both programs on PATH, so the launcher runs the ones it found.
      def launcher = Bwrap.new(fence: @fence, bwrap: on_path("bwrap"), strace: on_path("strace"))

      def on_path(program) = Shell::Path.find(program, path: ENV.fetch("PATH", ""))
    end
  end
end
