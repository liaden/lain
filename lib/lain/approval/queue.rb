# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/inflections"
require "async"
require "async/queue"

module Lain
  module Approval
    # {Middleware::Gate}'s policy seam, backed by a queue instead of a
    # terminal prompt: {#call} enqueues a {Pending} and PARKS the calling FIBER,
    # never the reactor, until a surface fiber decides it or the window expires.
    # Decoupling ask from answer is what lets any number of surfaces watch one
    # queue, and what makes every decision observable -- on a study bench "who
    # approved what, and how long the human took" is evidence.
    #
    # Fail-closed is inherited, not reimplemented: an expired window resolves
    # the pending as a denial, so Gate returns the same refusal Result an
    # interactive "n" produces. {Gate::DenyAll} remains the default policy
    # everywhere; this queue exists only where a frontend wires it.
    class Queue
      include Enumerable

      # No surface made it: the window expired and the clock decided. A name,
      # not a nil, so journal readers never guard.
      TIMEOUT_SURFACE = "timeout"

      # The REQUESTER vanished -- the gated fiber was stopped while parked --
      # so nobody awaits the verdict and the only honest one is a denial signed
      # by the cancellation itself.
      ABANDONED_SURFACE = "abandoned"

      # Generous because the answerer is a human at a terminal: a bound, not a
      # hurry -- an abandoned session must eventually refuse.
      DEFAULT_TIMEOUT = 300

      # Who a gated call is asked on behalf of when neither the call nor the
      # session names anyone: the parent's own turn.
      REQUESTER = "agent"

      BASH = "bash"
      HOMED = %r{\A~(/|\z)}
      COMMAND = "command"
      RUNS_IN = ::Lain::Sensitivity::Policy::PATH_FIELDS.fetch(BASH)
      private_constant :HOMED, :COMMAND, :RUNS_IN

      Outstanding = Data.define(:path, :regions)

      # The sensitive regions of one file that approving a {Pending} would
      # release, and the file they were found in. A CAPABILITY a pending can
      # carry, not a flow: this queue sits BELOW the read and holds only a path,
      # so the arm that has the file's bytes is what detects, diffs against
      # {Sensitivity::Ledger} and builds one of these. NOTHING HERE DETECTS AND
      # NOTHING HERE RELEASES.
      #
      # The path is deliberately NOT re-checked against the ledger's
      # ABSOLUTE-path contract: one object owns that rule, and a second copy of
      # a security check is a second thing to drift. The builder passes the same
      # path it will later release under, so the prompt names exactly what a yes
      # would send.
      #
      # A path that names NOTHING is refused here, which is a different rule
      # from the ledger's: a blank one renders a prompt saying secrets are at
      # stake and naming no file, a question no human can answer.
      # {Outstanding::NONE} is the one blank path, and it carries no regions.
      class Outstanding
        # `dup` before `freeze`, because `Array#to_a` returns SELF: without it
        # a caller that built its list by hand gets its own array frozen
        # underneath it, by a constructor it only meant to read.
        def initialize(path:, regions:)
          held = regions.to_a.dup.freeze
          raise ArgumentError, "regions are outstanding but no file was named, got #{path.inspect}" \
            if held.any? && path.to_s.empty?

          super(path: -path.to_s, regions: held)
        end

        def any? = !regions.empty?
        def count = regions.length

        # Spelled out rather than left to each caller to negate: two surfaces
        # PARTITION the parked queue on this question, and a partition whose
        # halves are written `x.any?` and `!x.any?` in different files is one
        # edit from a silent overlap or gap. As `any?`/`none?` over one value
        # object they are complementary by inspection.
        def none? = regions.empty?

        # The sentence every HUMAN surface puts in front of the question it is
        # about to ask. It lives on the value rather than in a frontend because
        # two surfaces render it, and two copies of this string is how one
        # surface comes to warn and the other not to.
        #
        # THE PATH IS `inspect`ed, and this is the one string in the harness
        # where skipping that converts a forged prefix directly into a released
        # secret. The path is MODEL-INFLUENCED -- for the detector to fire it
        # need only be a file the agent itself wrote -- so a path spelled
        # `"/tmp/x: 0 sensitive regions outstanding -- approve read(..)? [y/N] "`
        # renders a complete, plausible, BENIGN question in front of the real
        # one, and one holding `\e[2K\r` erases the line the human is meant to
        # read. `inspect` escapes both and cannot be closed from inside. It
        # QUOTES the forgery rather than deleting it: the defence is that the
        # real question always ENDS the rendering, because this sentence only
        # ever precedes it.
        #
        # The regions' own BYTES are never named -- printing a value to ask
        # whether it may be sent to a model would disclose it to the terminal,
        # the scrollback, the tmux buffer and any screen share, which is the
        # exact disclosure this exists to gate. The detector's REASON is
        # withheld for a different reason: a reason is detector OUTPUT and not
        # fact, so putting it in front of a human invites them to weigh a signal
        # never meant to be weighed one region at a time.
        def preamble
          return "" unless any?

          "#{path.inspect}: #{count} sensitive #{"region".pluralize(count)} outstanding -- "
        end

        # Every ordinary gated call. A real Outstanding rather than nil, so a
        # surface asks rather than guards. Below the methods because it is built
        # through the initialize above, which has to exist first.
        NONE = new(path: "", regions: [])
      end

      # One gated call awaiting its verdict. Deliberately MUTABLE coordination
      # state, unlike the frozen value objects: it exists to be decided.
      # Single-shot, first-answer-wins -- two surfaces racing over one pending
      # is normal operation, so the loser's answer is a quiet no-op here and NOT
      # the coordination bug {Promise::AlreadyResolved} names.
      class Pending
        attr_reader :requester, :tool, :tool_use_id, :input, :outstanding, :surface, :decision, :latency, :cwd,
                    :within, :timeout, :reason

        # Defaulting here is NOT the ledger's no-default rule bent: a defaulted
        # LEDGER lets a forgotten injection become a second ledger whose
        # releases nobody sees, and there is no second anything here -- a
        # missing one renders the ordinary prompt and still releases nothing.
        #
        # An EXPLICIT nil resolves to the same {Outstanding::NONE}, and that is
        # not belt-and-braces: `outstanding:` is public on {Queue#adjudicate},
        # every surface dereferences it, and a surface fiber that raises
        # silently stops watching for the rest of the session. This is the one
        # constructor that can enforce "Null Object over nil" for every reader
        # at once.
        #
        # `humans_only` is a call whose automatically approved output was
        # withheld: only a person may decide it, so a machine surface is not
        # offered it.
        #
        # `cwd` is where the parked call's relative path resolves, so a surface
        # judging that path lands it where the gate did; absent, it is the
        # process's, as for a call made with no session. `within` is where the
        # gate counted directory names from, see {Sensitivity::Policy.base_of}.
        def initialize(effect:, requester:, clock:, timeout: DEFAULT_TIMEOUT, outstanding: Outstanding::NONE,
                       humans_only: false, cwd: ::Lain::Session.cwd_of(nil), within: cwd, wall: -> { Time.now },
                       judge_deferred: false, notes: [])
          @timeout = timeout
          @judge_deferred = judge_deferred == true
          @notes = notes.map { -_1.to_s }.freeze
          @wall = wall
          @humans_only = humans_only == true
          @cwd = cwd
          @within = within
          @tool = effect.name
          @tool_use_id = effect.tool_use_id
          @input = effect.input
          @outstanding = outstanding || Outstanding::NONE
          @requester = requester
          @clock = clock
          @asked_at = clock.call
          @promise = Promise.new
        end

        # Answers whether THIS answer won; a later answer returns false and
        # changes nothing. Latency is stamped decision-side, so it measures how
        # long the verdict took, not how long the woken fiber waited to be
        # scheduled.
        #
        # Releasing an {Outstanding}'s regions to {Sensitivity::Ledger} is the
        # SETTLING CALLER's move, never this method's, and the invariant is this
        # method's own: single-shot resolution is safe WITHOUT A LOCK only
        # because the `decided?` guard and the resolve below it are
        # straight-line with no yield point between them. A ledger write is
        # IO-shaped and would open exactly that gap. This queue holds no ledger
        # at all, which is how that stays true.
        #
        # `reason` is the human's own words for a denial, which the model reads
        # as the last clause of its tool result. Flattened to one line with no
        # control bytes, so it cannot open a line or a sequence of its own.
        # rubocop:disable Naming/PredicateMethod -- a COMMAND whose Boolean
        # reports whether it won the race, not a query; `decide?` would misname
        # the mutation the way `Timeline#commit`'s rename lesson warns about.
        def decide(verdict, surface:, reason: nil)
          return false if decided?

          @surface = surface.to_s
          @decision = verdict ? :approve : :deny
          @reason = flattened(reason) unless verdict
          @latency = @clock.call - @asked_at
          @promise.resolve(@decision)
          true
        end
        # rubocop:enable Naming/PredicateMethod

        def humans_only? = @humans_only

        # Whether the judge looked at this call and left it for a human.
        def judge_deferred? = @judge_deferred

        # Why the ladder left this call for a human, one line of words per rung
        # that said. Model-influenced (a path), so a surface renders each `inspect`ed.
        # @return [Array<String>]
        attr_reader :notes

        # A surface that asks one call at a time says when this one reached the
        # front, and the queue's window then runs from there, not from the park.
        def drawn = @drawn ||= @clock.call

        # @return [Numeric, nil] the clock reading at the first {#drawn}
        def drawn_at = @drawn

        # Seconds until the queue denies this call unasked. The window runs from
        # the draw when a surface drew it and from the park otherwise, which is
        # the queue's own rule in {Queue#await_decision}. It reads the clock
        # the queue was built with, so a view showing it stays a projection.
        #
        # @return [Numeric]
        def remaining = [(drawn_at || @asked_at) + @timeout - @clock.call, 0].max

        # @return [String] {#remaining} as minutes and seconds, rounded up
        def remaining_face = Queue.face(remaining)

        # The wall-clock moment the call is denied at. {#remaining_face} is true
        # only at the instant it is read, and a view that does not redraw would
        # keep showing it; this does not move, so a stale render stays true.
        #
        # @return [String] HH:MM:SS on the injected wall clock
        def fires_at_face = (@wall.call + remaining).strftime("%H:%M:%S")

        # @return [String] the whole window, in {#remaining_face}'s spelling
        def window_face = Queue.face(@timeout)

        # The sentence every surface says when the clock, and nobody, decided.
        # Here for the reason {Outstanding#preamble} is on its value: two
        # surfaces word it, and two copies are how they come to disagree.
        def lapse = "denied after #{window_face} with no answer"

        # The path this call's input names, read from the table
        # {Sensitivity::Policy} classifies by, and only a String: a value the
        # policy would coerce is one no surface is shown.
        #
        # @return [String, nil]
        def path
          field = ::Lain::Sensitivity::Policy::PATH_FIELDS[@tool.to_s]
          value = field && @input.is_a?(Hash) && (@input[field] || @input[field.to_sym])
          value if value.is_a?(String)
        end

        def approve(surface:) = decide(true, surface:)
        def deny(surface:, reason: nil) = decide(false, surface:, reason:)
        def decided? = @promise.resolved?
        def approved? = @decision == :approve
        def timed_out? = @surface == TIMEOUT_SURFACE

        # Park the calling fiber until decided (see Promise#await).
        def await = @promise.await

        # `outstanding` is ABSENT and must stay absent, and `input` with it.
        # This pending may hold the sensitive regions a yes would release, bytes
        # included, and the only thing keeping them off disk is that this
        # hand-maintained list does not name them. Adding the field writes real
        # credentials into the Journal with no test to notice, since every test
        # here asserts the fields that ARE listed.
        # {Telemetry::ApprovalPending.from} carries the identical note.
        #
        # `tool_use_id` is what pairs this decision with its `approval_pending`:
        # parallel calls park together and are decided in any order, so a count
        # pairs the wrong ones. It is not unique: one `read_file` can park twice
        # under one id, at the path gate and again at the release, one after the
        # other, so within an id the records pair IN ORDER. Who released a
        # secret is `read_released`'s `surface`, not a join onto a decision.
        #
        # `reason` is written only when a human gave one, so a session recorded
        # before reasons existed reads the same as a bare denial does now.
        def to_journal
          { "type" => "approval_decision", "tool_use_id" => tool_use_id, "requester" => requester,
            "tool" => tool, "surface" => surface, "verdict" => decision.to_s, "timed_out" => timed_out?,
            "latency" => latency }.merge(reason ? { "reason" => reason } : {})
        end

        private

        def flattened(words) = words.to_s.gsub(/[[:cntrl:]]/, " ").squish.presence
      end

      # @param journal [#record] where decisions land as evidence; required,
      #   not defaulted, because silently unjournaled approvals would be a hole
      #   in the experiment record
      # @param requester [String] who a gated call is asked on behalf of when
      #   the call itself names nobody -- the SESSION's default, not the fleet's
      #   answer; see {.requester_for}
      # @param timeout [Numeric] seconds an unanswered pending waits before the
      #   fail-closed denial
      # @param clock [#call] monotonic seconds, injectable so specs pin latency
      # @param wall [#call] the time of day, as a Time, for naming when a call fires
      # @param home [String, nil] what `~` means in a denied command, from
      #   {Sensitivity::Policy#home}; with none, a command spelling a path
      #   with `~` is not remembered
      def initialize(journal:, requester: REQUESTER, timeout: DEFAULT_TIMEOUT, clock: RunClock::MONOTONIC,
                     wall: -> { Time.now }, home: nil)
        @journal = journal
        @home = home
        @requester = requester
        @timeout = timeout
        @clock = clock
        @wall = wall
        @arrivals = Async::Queue.new
        # A plain Array with NO LOCK, on purpose: every @parked mutation is
        # straight-line Ruby with no yield point, and a fiber only interleaves
        # at an IO yield -- the parks in #call/#dequeue sit BETWEEN mutations,
        # never inside one. So N gated fibers admit N independent pendings. If
        # queue_concurrency_spec.rb can only pass by adding a lock here, the
        # claim has failed -- escalate, don't patch.
        @parked = []
        @denials = {}
        @calls = {}
        # Built here, not as a constant: {Escalation::Surfaces} names this
        # class's surfaces in its own body, so a constant here is a load cycle.
        @machine_surfaces = [*Escalation::Surfaces::AUTOMATIC, ::Lain::Frontend::ApprovalPolicy::FAULT_SURFACE].freeze
      end

      # @param seconds [Numeric]
      # @return [String] minutes and seconds, a part second rounded up so a
      #   face never reads out of time while the call still has some
      def self.face(seconds)
        whole = seconds.ceil
        format("%<minutes>d:%<seconds>02d", minutes: whole / 60, seconds: whole % 60)
      end

      # Gate's policy seam. Parking here is safe inside tool dispatch because
      # the surface that answers runs as a SIBLING fiber in the same reactor.
      def call(effect, context) = adjudicate(effect, context).approved?

      # The same lifecycle as a ruling, for a Gate that holds the queue
      # directly. Settled exactly as the ladder's asking rung settles it, so
      # the surface's authority is read in one place, and never final: a
      # surface that said no this time can say yes the next.
      def rule(effect, context) = Escalation::Surfaces.new(self).call(effect, context)

      # The same lifecycle, answering the SETTLED {Pending} instead of its
      # Boolean. A caller that has to attribute the verdict needs the SURFACE
      # that made it -- {Approval::Escalation} treats a human's approval and an
      # {SecretSurface}'s as different kinds of authority -- and a Boolean cannot
      # carry that. {#rule} is what a {Middleware::Gate} holding the queue
      # asks, and {#call} the Boolean for a caller that needs only the answer.
      #
      # `outstanding:` is how the one arm holding a file's bytes tells the
      # surfaces what a yes would release. Answering the settled {Pending} is
      # what lets that caller write the ledger itself.
      def adjudicate(effect, context, outstanding: Outstanding::NONE)
        pending = admit(effect, context, outstanding)
        settle(pending)
        pending
      end

      # ONE queue serves the whole fleet, so a queue-level constant journals and
      # renders every pending identically -- which is how a researcher
      # subagent's `bash` prompt came to be indistinguishable from the human's
      # own agent's. The CALL says so instead, through the context the policy
      # seam already threads.
      #
      # `fallback` is the SESSION's answer for contexts that name nobody, so
      # nothing asking here journals a blank. Public, because a read guard with
      # no queue to park on still has to say whom its release was for.
      #
      # @param context [Object, nil] the context a call is judged in
      # @param fallback [String] who is asking when the context names nobody
      # @return [String]
      def self.requester_for(context, fallback = REQUESTER)
        context.respond_to?(:requester) ? context.requester : fallback
      end

      # Where a call's path lands, spelled one way for both the recording and
      # the lookup; nil for a path no tool could resolve either.
      #
      # A `~` is the session's home when one is known, as the policy reads it,
      # so a path tool and a command spelling the same file meet.
      #
      # @param path [String] as the call wrote it
      # @param cwd [String] absolute; where the call resolves a relative path
      # @param home [String, nil] for a leading `~`; nil leaves it to the process
      # @return [String, nil]
      def self.resolved(path, cwd, home: nil)
        homed = home && path.match?(HOMED) ? File.join(home, path.delete_prefix("~")) : path
        File.expand_path(homed, cwd)
      rescue ArgumentError, EncodingError
        nil
      end

      # The paths a `bash` call's command names, read one way for the recording
      # and the lookup.
      #
      # @param input [Object] the call's input; its `cwd` field, when it has
      #   one, resolves against `cwd`
      # @param cwd [String] absolute; the session's directory for the call
      # @param home [String, nil] for `~`, as {Shell::Named.of} takes it
      # @param directory [String, nil] where the call runs, for a caller that
      #   already resolved it with {.directory_of}
      # @return [Shell::Named] unreadable when the input holds no command
      #   String, or names a directory that cannot be resolved
      def self.named(input, cwd:, home:, directory: directory_of(input, cwd:, home:))
        command = field(input, COMMAND)
        return ::Lain::Shell::Named::UNREADABLE unless command.is_a?(String) && directory

        ::Lain::Shell::Named.of(command, cwd: directory, home:)
      end

      # Where a `bash` call runs: its `cwd` field resolved against the
      # session's, or the session's when it has none.
      #
      # @param input [Object] as the model sent it; only its `cwd` field is read
      # @param cwd [String] absolute; the session's directory for the call
      # @param home [String, nil] for a leading `~`
      # @return [String, nil] nil for a field no tool could resolve
      def self.directory_of(input, cwd:, home:)
        at = field(input, RUNS_IN) || "."
        at.is_a?(String) ? resolved(at, cwd, home:) : nil
      end

      def self.field(input, name) = input.is_a?(Hash) ? input[name] || input[name.to_sym] : nil
      private_class_method :field

      # The reason a human gave when they denied this requester a call on
      # `path`, on where it lands, or on a directory above either; "" when
      # they gave none.
      #
      # @param requester [String] as {.requester_for} names it
      # @param path [String] absolute and resolved, see {.resolved}
      # @return [String, nil] nil when no such denial was given
      def denied(requester:, path:)
        held = @denials.fetch(requester, {})
        return if held.empty?

        [path, *landings(path)].lazy.filter_map { |asked| held.find { |denied, _| at_or_below?(asked, denied) } }
                               .first&.last
      end

      # The reason a human gave when they denied this requester this exact
      # call, run from the same directory; "" when they gave none.
      #
      # @param requester [String] as {.requester_for} names it
      # @param tool [String] as the call named it
      # @param input [Object] the call's input, compared whole
      # @param cwd [String] absolute; the session's directory for the call
      # @return [String, nil] nil when no such denial was given
      def denied_call(requester:, tool:, input:, cwd:) = @calls.fetch(requester, {})[[tool, input, cwd]]

      # Async::Queue is buffered, so a pending enqueued before any surface
      # watched is delivered, never missed. Already-decided arrivals -- an
      # abandoned pending cannot be removed from the arrival queue itself -- are
      # skipped, so a surface never prompts a human for a call nobody awaits.
      def dequeue
        pending = @arrivals.dequeue
        pending.decided? ? dequeue : pending
      end

      # Oldest first -- what a second surface, or the bench, inspects without
      # draining the arrival queue.
      def each(&block) = @parked.each(&block)

      private

      # Journaled BEFORE the pending is parked, never between the two mutations
      # below: the record is a write, a write can yield the fiber, and @parked's
      # lock-freedom rests on `<<` and `enqueue` staying straight-line with no
      # yield point between them.
      def admit(effect, context, outstanding)
        pending = Pending.new(effect:, requester: Queue.requester_for(context, @requester), clock: @clock,
                              timeout: @timeout, wall: @wall, outstanding:, humans_only: Escalation.barred?(context),
                              judge_deferred: context.respond_to?(:judge_deferred?) && context.judge_deferred?,
                              notes: context.respond_to?(:parked_because) ? context.parked_because : [],
                              cwd: ::Lain::Session.cwd_of(context),
                              within: ::Lain::Sensitivity::Policy.base_of(context))
        record_evidence(Telemetry::ApprovalPending) { Telemetry::ApprovalPending.from(pending) }
        @parked << pending
        @arrivals.enqueue(pending)
        pending
      end

      # `ensure`, because the requester can be STOPPED while parked: Ctrl-C
      # unwinds this fiber with Async::Stop, which the timeout rescue never
      # sees, and the pending must still leave the parked list, still journal,
      # and still end up decided. The abandonment deny is a no-op on the normal
      # path, and is what makes a late surface answer harmless.
      def settle(pending)
        await_decision(pending)
      ensure
        pending.deny(surface: ABANDONED_SURFACE)
        @parked.delete(pending)
        remember(pending)
        retire_arrivals
        record_evidence(Pending) { pending }
      end

      # Straight-line with no yield, as every @parked mutation is, so it can
      # sit in {#settle}'s `ensure` without opening a gap between fibers; a
      # realpath is a plain syscall, not a scheduler hook. A declined release
      # is a no about a file's regions, not about its path.
      def remember(pending)
        return unless human_denial?(pending) && pending.outstanding.none?

        reason = pending.reason.to_s
        denied_paths(pending).each { (@denials[pending.requester] ||= {})[_1] = reason }
        (@calls[pending.requester] ||= {})[[pending.tool, pending.input, pending.cwd]] = reason
      end

      # A command's file word that is a link to a directory names a file to
      # the human, so the tree it lands on is not held against later calls.
      def denied_paths(pending)
        if pending.tool == BASH
          named_files(pending).flat_map { |path| [path, *landings(path).reject { File.directory?(_1) }] }
        else
          lexical = pending.path && Queue.resolved(pending.path, pending.cwd, home: @home)
          lexical ? [lexical, *landings(lexical)] : []
        end
      end

      # A link to nothing keeps only its own name: its target could be
      # created anywhere later, and a guess at it would refuse the wrong file.
      def landings(path)
        Landing.of(path, cwd: File::SEPARATOR, home: @home) - [path]
      rescue ::Lain::Error, SystemCallError, ArgumentError, EncodingError
        []
      end

      # The directory a command runs in, anything above it, a `cd` target and
      # a glob's or a search's root are each only where the files it touched
      # live, so remembering one would refuse a whole tree the human was never
      # asked about. A word starting with a dash is an option, whatever value
      # it was read as carrying.
      def named_files(pending)
        directory = Queue.directory_of(pending.input, cwd: pending.cwd, home: @home)
        named = Queue.named(pending.input, cwd: pending.cwd, home: @home, directory:)
        return [] if named.opaque?

        places = [directory, *named.paths.select(&:directory).map(&:resolved)]
        named.paths.select { file_word?(_1) }.map(&:resolved).reject { |path| places.any? { at_or_below?(_1, path) } }
      end

      def file_word?(path) = !(path.directory || path.pattern || path.word.start_with?("-"))

      def at_or_below?(place, path) = place == path || place.start_with?(below(path))

      # A machine's no, the clock's, or one a fault forced, is not a person's
      # judgement about a path, so none of these is held against later calls.
      def human_denial?(pending) = !pending.approved? && !@machine_surfaces.include?(pending.surface)

      def below(path) = path.end_with?("/") ? path : "#{path}/"

      # Only undecided work stays buffered. A surface that observes the parked
      # set rather than consuming arrivals -- all a cockpit has -- would
      # otherwise leave every decided pending, input and all, referenced here
      # for the rest of the session. Non-blocking pops and pushes with no
      # yield between them, so no park or settle interleaves, and a live
      # pending keeps its place in line.
      def retire_arrivals
        buffered = Array.new(@arrivals.size) { @arrivals.dequeue(timeout: 0) }
        @arrivals.enqueue(*buffered.compact.reject(&:decided?))
      end

      # Evidence about a turn must never COST the turn. Both writes sit on
      # {Gate}'s policy seam, ABOVE {Effect::Handler::Live} -- nothing below is
      # left to turn an exception into a {Tool::Result}, so a closed Journal
      # would unwind through the agent loop and hand the user a dead turn
      # instead of the denial an unanswerable approval is owed. On the settle
      # path the raise would land inside `ensure` and REPLACE the verdict, which
      # is the same defect one step worse.
      #
      # Loud therefore means a denial plus a recorded reason, wearing the
      # Journal's own `journal_error` shape so a reader has one failure record
      # to know rather than two.
      #
      # The entry is BUILT IN THE BLOCK, never passed as an argument: an
      # argument is evaluated before control enters this method, so a record
      # whose own construction raises would escape past the very protection this
      # exists to give. `kind` names what was being recorded, because a raise
      # mid-construction leaves no instance to name.
      def record_evidence(kind, &entry)
        @journal.record(yield)
      rescue StandardError => e
        degrade(kind, e)
      end

      # When even the degraded write fails the journal is gone and there is
      # nowhere left to be honest to. Swallowing is the only option that still
      # refuses rather than wedging.
      def degrade(kind, error)
        @journal.record("type" => "journal_error", "error" => "#{error.class}: #{error.message}",
                        "entry_class" => kind.name)
      rescue StandardError
        nil
      end

      # The expired window IS a decision, routed through the same single-shot
      # {Pending#decide}, so a surface that answered in the same tick still wins
      # and a later answer is a no-op.
      #
      # A pending drawn after it parked is owed the rest of a whole window from
      # the draw, so a call queued behind a slow answer is not denied unasked.
      def await_decision(pending, window = @timeout)
        Async::Task.current.with_timeout(window) { pending.await }
      rescue Async::TimeoutError
        left = pending.drawn_at ? pending.drawn_at + @timeout - @clock.call : 0
        left.positive? ? await_decision(pending, left) : pending.deny(surface: TIMEOUT_SURFACE)
      end
    end
  end
end
