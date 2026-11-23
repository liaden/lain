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
      # Landlock bounds a TCP port only from this ABI; below it a confined call can still connect anywhere.
      NET_ABI = 4
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

      Containment = Data.define(:state, :because, :grants, :ports, :unmasks)

      # Whether a plain approval of a call that reads secrets can run it
      # contained: under a confined profile with no network beyond a build
      # tool's granted ports. `:able` can,
      # `:unable` cannot, so such an approval is refused until the human
      # chooses network, and `:off` confines nothing, by the session's choice.
      # `:unstated` is a queue nobody told, or a call that reads no secrets: a plain approval of one runs it
      # unconfined, which {UNSTATED_CHOICE} says where a surface shows it.
      # `grants` is whether a contained call runs under the workspace profile,
      # whose build tools keep their ports, and `ports` the ones a parked call could earn.
      # `unmasks` names the project files a secrets answer would let a parked call read.
      class Containment
        NETWORK_CHOICE = "network runs it unconfined, with network"
        ABLE_CHOICE = "y runs %<call>s contained, without network, where files lain masks read as empty or as a " \
                      "decoy; #{NETWORK_CHOICE}".freeze
        PORTED_CHOICE = "y runs %<call>s contained, where files lain masks read as empty or as a decoy, and its " \
                        "build tool may reach the host's network on TCP ports %<ports>s; #{NETWORK_CHOICE}".freeze
        UNABLE_CHOICE = "y will not run %<call>s; #{NETWORK_CHOICE}".freeze
        UNSTATED_CHOICE = "y runs %<call>s unconfined, with network"
        SECRETS_CHOICE = "secrets runs %<call>s cut off from the network, with lain's masks lifted from %<files>s, " \
                         "and gates any file it writes that holds a secret"
        NOTHING_MASKED_CHOICE = "secrets runs %<call>s cut off from the network, where the project holds no file " \
                                "lain masks, and gates any file it writes that holds a secret"
        SHOWN = 5
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
        def self.able(grants:) = new(state: :able, grants:)

        # The one spelling of a list of files on a row or in a note: the first {SHOWN}, then how many more, with
        # "and" before the last, each escaped so a name cannot move the terminal's cursor.
        #
        # @param names [Array<String>] in the order to show them
        # @return [String]
        def self.listed(names)
          shown = names.first(SHOWN).map { Utf8.escaped(_1) }
          more = names.size - shown.size
          items = more.positive? ? [*shown, "#{more} more"] : shown
          items.size > 1 ? "#{items[0...-1].join(", ")} and #{items.last}" : items.first.to_s
        end

        def initialize(state:, because: nil, grants: false, ports: [], unmasks: [])
          super(state:, because: because&.then { -_1.to_s }, grants: grants == true, ports: ports.dup.freeze,
                unmasks: unmasks.map(&:-@).freeze)
        end

        # A value already names its files; only {Deferred} lists them, under the call's own root.
        #
        # @param argvs [Array<Array<String>>] the parked call's stages as the term arm would run them
        # @return [Containment] this one, with the ports that call could be granted where the session grants any
        def over(argvs, **) = able? && grants ? with(ports: Profiles.grantable_ports(argvs)) : self

        # @param _ruling [Approval::Escalation::Ruling]
        # @return [nil] a value knows no sandbox, so it says nothing of what one would refuse to run, and plans nothing
        def unrunnable(_ruling) = nil

        # @return [Boolean] whether a plain approval of a secret-bearing call is meant to run contained
        def confines? = %i[able unable].include?(state)

        # @return [Boolean] whether it can
        def able? = state == :able

        # @return [Boolean] whether the session chose to confine nothing
        def off? = state == :off

        # @return [Boolean] whether nothing was stated, so a plain approval runs the call unconfined
        def unstated? = state == :unstated

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
          when :able then "#{ports.empty? ? format(ABLE_CHOICE, call:) : ported(call)}; #{unmasking(call)}"
          when :unable then format(UNABLE_CHOICE, call:)
          when :unstated then format(UNSTATED_CHOICE, call:)
          end
        end

        ABLE = new(state: :able)
        OFF = off(CONFINEMENT_OFF)
        NONE = new(state: :unstated)

        # A containment the box answers when first read. Asking whether it gives a private network spawns
        # bwrap, about 3 ms, which a chat launch should not pay before any call reads secrets. Off is the
        # session's choice, never the box's answer, so {#off?} needs no answer.
        class Deferred
          delegate :state, :because, :grants, :ports, :unmasks, :confines?, :able?, :unstated?, :note, :choice,
                   :to_h, :with,
                   :members, :deconstruct, :deconstruct_keys, :==, :eql?, :hash, to: :resolved

          # @param unmasks [#call] `(root)` to the files a secrets answer would lift the masks from under that root,
          #   relative and in order; read on each park, since the project's files change
          # @param unrunnable [#call] `(ruling, &plan)` to why the call's sandbox would refuse to run it, or nil;
          #   asked before an automatic allow settles, and never of the box's own answer
          # @yieldreturn [Containment] able or unable, asked for once
          def initialize(unmasks: ->(_root) { [] }, unrunnable: ->(_ruling, &) {}, &answer)
            @unmasks = unmasks
            @unrunnable = unrunnable
            @answer = answer
            @mutex = Mutex.new
          end

          # @return [false]
          def off? = false

          # @param argvs [Array<Array<String>>]
          # @param root [String, nil] the call's own root; the session's when nil
          # @return [Containment] as {Containment#over}, naming the files a secrets answer would lift where it can
          def over(argvs, root: nil)
            over = resolved.over(argvs)
            over.able? ? over.with(unmasks: @unmasks.call(root)) : over
          end

          # @param ruling [Approval::Escalation::Ruling] the allow the call would run under
          # @yieldreturn [Array(Request, Array<Shell::Executable>), nil] the request the run will carry, and every
          #   program the call is read to exec; nil when the tool plans none
          # @return [String, nil] the clause saying what the call's sandbox cannot do, such as "cannot run ~/bin/x"
          def unrunnable(ruling, &plan) = @unrunnable.call(ruling, &plan)

          private

          def resolved = @resolved || @mutex.synchronize { @resolved ||= answered }

          def answered
            @answer.call.tap { raise ArgumentError, "the box answered off, which only a session chooses" if _1.off? }
          end
        end

        private

        def ported(call) = format(PORTED_CHOICE, call:, ports: ports.join(", "))

        def unmasking(call)
          return format(NOTHING_MASKED_CHOICE, call:) if unmasks.empty?

          format(SECRETS_CHOICE, call:, files: Containment.listed(unmasks))
        end
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
      # @param fresh [#any_under?, #fresh?] the lineage's freshness; by default every root and file is fresh, so no
      #   port is granted, nor a linter by name
      # @param phone_answered [Boolean] whether a call that would run unconfined is refused rather than run,
      #   unless a human approved it and it runs traced
      # @param taint [#call] returns the {Sensitivity::Taint} an unmasked call's writes are scanned into
      # @param secrets [#call] returns the known values that scan looks for
      # @param snapshots [#call] answers the round's {Agent::SnapshotSlot}, which the exec primes
      def initialize(root:, home:, masks:, probe:, fence:, journal:, notes: journal, workspace: false,
                     tmpdir: Dir.tmpdir, fresh: Profiles::Unread, phone_answered: false,
                     taint: Sensitivity::Taint.new.then { |own| -> { own } },
                     secrets: -> { Sensitivity::Secrets::Source::DEFAULT },
                     snapshots: -> { Agent::SnapshotSlot::Null })
        @scanning = { taint:, secrets:, classifier: masks }
        @snapshots = snapshots
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
        Exec::Sandboxed.new(inner:, launcher:, profiles:, journal: @journal, reaps: @probe.supports?(:reap),
                            net_enforced: @probe.abi >= NET_ABI, masks: @masks, **@scanning)
      end

      # @return [Containment::Deferred] whether this box can run a call contained, with no network beyond a build
      #   tool's ports
      def containment
        Containment::Deferred.new(unmasks: ->(root) { readable(root) },
                                  unrunnable: ->(ruling, &plan) { unrunnable(ruling, &plan) }) { contained_here }
      end

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

      def readable(root) = Profiles.readable(@masks.masks, root || @root)

      # Planned only for a ruling that earns a confined profile, since a plan resolves every program. A sandbox that
      # wrapped no exec, as on a box lacking a layer, runs the call bare, so nothing would refuse it; the probe's
      # answer is read once, so a box cannot lose a layer after the wrap.
      # A profile that cannot be built is refused by the run in its own words and journaled there, so it is left to
      # the run rather than made a fault. Named in the clause, since naming them as this class loads loops
      # back through the approval ladder, which reads this class's own constants.
      def unrunnable(ruling)
        return if !@built || !checking.confines?(ruling)

        request, programs = yield
        refused = request ? checking.unrunnable(request, programs) : []
        "cannot run #{Containment.listed(refused.map { shown(_1) })}" unless refused.empty?
      rescue Profiles::Overmasked, Profiles::Uncontainable, Profile::Unsealable, Profile::HomeTmpdir,
             Profile::HoldsState, Profile::Tampered
        nil
      end

      def shown(path) = path.start_with?("#{@home}/") ? File.join("~", path.delete_prefix("#{@home}/")) : path

      def checking
        @checking ||= Profiles.new(masks: @masks, probe: @probe, home: @home, root: @root, classifier: @masks,
                                   **@profiling)
      end

      def profiles
        built = Profiles.new(masks: @masks, probe: @probe, home: @home, root: @root, classifier: @masks, **@profiling)
        chosen = @phone_answered ? PhoneAnswered.new(built, reaps: @probe.supports?(:reap)) : built
        Exec::Priming::ByProfile.new(chosen, snapshots: @snapshots)
      end

      # A box can lose a layer after the launch checked it, and a phone's session never runs a call bare.
      def unsandboxed(inner, requirer)
        bare = self.class.degraded(inner, journal: @notes, requirer:, because: self.class.gap(@probe))
        return bare unless @phone_answered

        Exec::Sandboxed.new(inner: bare, launcher:, profiles: Unsandboxed, journal: @journal)
      end

      def launcher = Bwrap.on_path(fence: @fence)
    end
  end
end
