# frozen_string_literal: true

module Lain
  module CLI
    # Resolves `lain chat --resume [SESSION]` into the pieces the thin exe
    # wires: the chain-verified Timeline the Agent is seeded with (T15's
    # injection seam), the replayed Session run-state and its memory recorder
    # (T16, shared -- one index, three views), the chained-header fields the
    # NEW journal opens with (T14's `resumed_from` shape), and the notices the
    # frontend renders. The recorded tool schema and model in the old header
    # are display-only: the live toolset and provider always come from the
    # current flags, and a disagreement is LOUD-and-continue ({#notices}),
    # never a silent override in either direction.
    class Resume
      # A resume that cannot proceed, named: nothing to resume, an ambiguous
      # or unmatched selector, a corrupt or pre-scribe file, or a mid-tool
      # head. A {Lain::Error} so the exe maps it to a clean Thor::Error --
      # message, nonzero exit, no backtrace.
      class Refusal < Error; end

      # Everything a resumed chat starts from. `resumed_from`/`written` are
      # exactly {CLI::Chronicle#start}'s chaining keywords, derived here so
      # the exe never assembles wire-format hashes itself.
      Result = Data.define(:file, :timeline, :recorded, :session, :recorder, :open, :notices) do
        # `recorded` defaults to `timeline` so a caller with nothing to
        # distinguish -- every untorn session -- constructs exactly as before.
        def initialize(file:, timeline:, session:, recorder:, open:, notices:, recorded: timeline)
          super(file:, timeline:, recorded:, session:, recorder:, open:, notices: notices.freeze)
        end

        # Both are claims about the PRIOR FILE, so both read `recorded` -- the
        # timeline as that journal recorded it -- and never `timeline`, which
        # may carry a projected cancellation turn above it ({Cancellation}) that
        # no journal has ever held. Naming the projection here would open a
        # header whose `resumed_from.head` the prior file's own fold cannot
        # verify, and the new session would refuse as {Bench::Session::Corrupt}
        # the first time IT was resumed -- a failure one whole session away
        # from its cause.
        def resumed_from = { "file" => file, "head" => recorded.head_digest }
        def written = recorded.to_a.map(&:digest)
        def open? = open

        # Whether {Resume#settled} projected a cancellation. Identity, not
        # digest comparison: the repair commits a NEW Timeline and leaves the
        # recorded one untouched, so "these are the same object" is the whole
        # question and needs no walk.
        def repaired? = !recorded.equal?(timeline)
      end

      # The reason {.refuse_mid_tool!} states for the backstop: this is the
      # shape no projection can answer, and saying so is the whole of it.
      #
      # Declared on {Resume} rather than inside `class << self`, where it would
      # belong to the singleton class and resolve from nowhere an instance
      # method can see -- the same scoping trap CLAUDE.md records for constants
      # in a `Data.define` block.
      UNANSWERABLE = "and one of those calls names no tool_use id, so nothing can answer it"

      # The reason the parent-side `/fork` mirror states, being the one caller
      # T3 did not convert to a repair. It describes what that door does and
      # claims nothing more -- in particular it no longer says fabricating a
      # result would falsify the record, which T3 established is false: a
      # projection edits nothing and witnesses nothing.
      MIRRORED = "so no request can be built from it here"

      class << self
        # THE BACKSTOP, since T3. A torn head no longer refuses here: {#settled}
        # projects a cancellation onto the rebuilt timeline and the session
        # resumes. What still reaches this is the one shape that projection
        # cannot answer -- a stranded `tool_use` naming no id, which
        # {Tool::ResultBlock}'s gate 4 refuses to build a result for and which
        # no projection makes valid. It stays because deleting it would leave
        # that shape escaping as a raw ArgumentError with no file attached,
        # against a door whose whole doctrine is to refuse namedly.
        #
        # It is ALSO still the gate `/fork` mirrors parent-side
        # ({CLI::Command::Fork#anchor!}) against a LIVE timeline, which T3 does
        # not repair -- so that door refuses a head this one now resumes. T5
        # owns fork.rb and is where the two are reconciled.
        #
        # Takes the timeline (not the recording) so fork mode's checked-out
        # head faces the SAME refusal verbatim. A class method (T16 F1) for the
        # parent-side mirror -- one predicate, one wording, wherever the user
        # meets it.
        # @param path [String] the session file, named in the refusal
        # @param timeline [Lain::Timeline] the chain whose head is judged
        # @param reason [String] why THIS door refuses -- the shared predicate
        #   and verb, the caller's reason, because the two callers no longer
        #   refuse for the same reason
        def refuse_mid_tool!(path, timeline, reason: MIRRORED)
          return unless Event.pending_tool_use?(timeline.head)

          raise Refusal, "cannot resume #{File.basename(path)}: its head is an assistant tool_use turn " \
                         "still awaiting tool results, #{reason}"
        end
      end

      def initialize(paths: Paths.new)
        @paths = paths
      end

      # @param selector [String, nil] nil or "" (a bare `--resume`) picks the
      #   newest session; otherwise a filename or unique prefix under this
      #   project's session dir
      # @param model [String, nil] the model the current flags resolved to,
      #   compared against the recording for the mismatch notice
      # @param provider [String, nil] the provider name ({CLI::Backend}'s
      #   naming, e.g. "anthropic") the current `--provider` flag resolved to,
      #   compared against the recorded header for the mismatch notice (RES2)
      # @return [Result]
      # @raise [Refusal]
      def call(selector: nil, model: nil, provider: nil)
        rebuild(Selector.new(dir:).call(selector), model, provider)
      end

      # T3 fork mode: `--fork "<session>@<digest-prefix>"` via {ForkPoint} --
      # the new run starts at that recorded turn instead of the parent's final
      # head. READ-ONLY BY CONSTRUCTION: this path holds only `File.foreach`
      # enumerators and has no salvage step, so a {Salvager} (whose #close!
      # appends a close anchor) is never constructed against the parent --
      # forking a LIVE session must leave its owner's journal exactly as the
      # owner is writing it. The checkout is pointer movement, not
      # verification; the verification is the load's re-commit fold, which
      # proved every digest {ForkPoint} can resolve.
      #
      # @param selector [String] `<session>@<digest-prefix>`
      # @param model [String, nil] the model the current flags resolved to, compared
      #   against the forked file's recorded header for the mismatch notice (same
      #   check as {#call})
      # @param provider [String, nil] the provider name ({CLI::Backend}'s naming,
      #   e.g. "anthropic") the current `--provider` flag resolved to, compared
      #   against the forked file's recorded header for the mismatch notice (RES2)
      # @return [Result] whose `resumed_from` names `{file, fork digest}`
      # @raise [Refusal]
      def fork(selector:, model: nil, provider: nil)
        point = ForkPoint.new(dir:).call(selector)
        recording = load_recording(point.path)
        forked = recording.timeline.checkout(point.digest)
        fork_result(point, recording, forked, model, provider)
      # Corrupt is the fold's one currency: both halves of the Loader's fixpoint
      # translate the Store's refusal, and both shape-check the causal edge
      # before putting it. So the second arm is DEFENSIVE and is kept
      # deliberately -- it is not currently reachable from any journal we can
      # construct, and the last time that was believed it was false. The
      # property lives in two classes a door cannot see; one uncovered escape
      # there is a raw backtrace out of the exe, against one constant here.
      # Both name through the same formatter rather than either escaping raw
      # with no file attached, and {#rebuild} carries the identical pair -- a
      # damaged journal must not depend on which door a user came through.
      rescue Bench::Session::Corrupt, Store::MissingObject => e
        raise fork_refusal(point, e.message)
      rescue Errno::ENOENT
        # The TOCTOU between ForkPoint's read and this load (probe 5d): a
        # reap or rename can win that race; refuse namedly, never a raw errno.
        raise fork_refusal(point, "it vanished before it could be loaded " \
                                  "(reaped or renamed underneath the fork); list and retry")
      end

      private

      def dir = @dir ||= @paths.sessions_dir

      # T18: an OPEN recording gets one salvage attempt before anything else
      # runs. A {Salvager#close!} retroactively turns a Recovered crash into
      # an ordinary closed file, so the reload below reuses the SAME
      # {Bench::Session::Loader}/{Bench::Session::Anchor} machinery every
      # other closed session already proves, rather than growing a parallel
      # "open-plus-salvaged" shape those classes would have to learn. That
      # reload is also what makes `resumed_from`/`written` correct with no
      # changes to either class: both derive from `recording.timeline`, which
      # now legitimately reflects a file that IS closed, anchored at the
      # salvaged turn.
      def rebuild(path, model, provider)
        recording = load_recording(path)
        outcome = salvage(path, recording)
        recording = load_recording(path) if outcome.recovered?
        resumed_result(path, recording, outcome, model, provider)
      rescue Bench::Session::Corrupt, Store::MissingObject => e
        # Corrupt's own message names digests and reasons; only this layer
        # still holds the path (Bench::CLI#load_session's precedent). The
        # MissingObject arm is {#fork}'s, kept for the reason recorded there.
        # It was missing here once, and the cost was not theoretical: the SAME
        # damaged file refused namedly from `--fork` and escaped as a raw store
        # complaint, with no file on it, from `--resume`.
        raise Refusal, "cannot resume #{File.basename(path)}: #{e.message}"
      rescue Provider::ResponseWal::CorruptFrame => e
        # The response WAL should never raise here -- salvage reads it TOLERANTLY
        # ({Salvager#wal_frames}), so a mis-slotted region resyncs to a notice,
        # not an exception. This is the loud backstop: a CorruptFrame escaping
        # is a bug in the tolerant path, and it must refuse namedly rather than
        # crash the whole resume with a raw provider error the exe cannot map.
        raise Refusal, "cannot resume #{File.basename(path)}: its response log is corrupt (#{e.message})"
      end

      def load_recording(path)
        Bench::Session::Loader.new(File.foreach(path), resolve: resolver).recording
      end

      # Both entry paths end in the same Result assembly; named so {#rebuild}
      # and {#fork} read as their sequence of decisions, not their plumbing.
      # The difference is exactly the timeline and the notices: resume ends on
      # the rebuilt head with the salvage/open notices, a fork on the checked-
      # out fork point with the mismatch notices alone.
      def resumed_result(path, recording, outcome, model, provider)
        mismatched = mismatches(path, recording, model, provider)
        result(path, recording.timeline, replay(path),
               open: recording.open?, notices: notices(path, recording, outcome, mismatched))
      end

      def fork_result(point, recording, forked, model, provider)
        result(point.path, forked, replay(point.path),
               open: recording.open?, notices: mismatches(point.path, recording, model, provider))
      end

      def fork_refusal(point, reason)
        Refusal.new("cannot fork #{File.basename(point.path)}: #{reason}")
      end

      # Run-state and memory replay are chain-wide (the Loader folds only the
      # Timeline and message events across `resumed_from`, its stated limit),
      # so the entries come from {ChainWalk} -- every file of the chain,
      # oldest first.
      def replay(path) = SessionRecord::Replay.new(ChainWalk.new(dir:).entries(path))

      def mismatches(path, recording, model, provider)
        MismatchNotices.new(recording:, path:).call(model:, provider:)
      end

      # Salvage only ever runs against an open session: a gracefully closed
      # file already flushed everything it could -- its last `request_sent`,
      # if any, already has a `turn_usage` (T18's card, Scenario 3). A
      # Recovered outcome closes the file through {Salvager#close!}; {#rebuild}
      # is what reloads it afterward, so this stays a pure lookup either way.
      #
      # @return [SessionRecord::Salvage::Nothing, Recovered, Incomplete]
      def salvage(path, recording)
        return SessionRecord::Salvage::Nothing unless recording.open?

        salvager = Salvager.new(path:, timeline: recording.timeline)
        salvager.close!(head_before: recording.timeline.head_digest) if salvager.outcome.recovered?
        salvager.outcome
      end

      # `recording.memory` (file-scoped -- T14's stated Loader limit) is
      # deliberately unused: the recorder must cover the WHOLE chain, so it is
      # `replay.memory` over the chain's concatenated records instead. The
      # timeline rides separately from the recording because fork mode's is a
      # checkout below the rebuilt head.
      # The repair is disclosed, not silent: a session whose model sees a turn
      # the human never saw is the invisible mutation the Journal doctrine
      # exists against. (Open decision 5 defers the retry AFFORDANCE -- an
      # explicit "try that call again" prompt. Saying what happened is not
      # that.) Built through {Data#with} so {Result#repaired?} is the ONE
      # predicate, asked of the object that owns it.
      def result(path, timeline, replay, open:, notices:)
        built = Result.new(file: File.basename(path), timeline: settled(path, timeline), recorded: timeline,
                           session: replay.session, recorder: replay.memory, open:, notices:)
        built.repaired? ? built.with(notices: [*notices, repair_notice(built)]) : built
      end

      # Held to {Cancellation::NO_RESULT}'s standard, and for the same reason:
      # "stopped with N unanswered" is an inference about the RUN, and it is
      # false on the fork-below-results door -- that file did not stop, and the
      # call it names returned. What this side knows is what the CONTINUATION
      # carries.
      def repair_notice(built)
        "#{built.file}: the conversation being continued carries no result for " \
          "#{built.timeline.head.content.length} tool call(s); they are reported to the model as " \
          "cancelled so the session can continue -- the journal is unchanged"
      end

      # F46, and the ONE place either door repairs -- both {#resumed_result} and
      # {#fork_result} come through {#result}, so a fork of a torn point is
      # repaired exactly as a resume of one.
      #
      # Repairing HERE, at load, rather than at the tear is what makes it
      # trigger-agnostic: the interrupt that tore round 8's session was never
      # identified, and SIGKILL, an OOM and a reactor teardown are invisible to
      # every in-process handler while being identical from this side. (T6 adds
      # the in-process case it CAN see; the block it commits is {Cancellation}'s,
      # so the two repairs cannot come to disagree.)
      #
      # The journal is not rewritten. This commit lands on the rebuilt
      # in-memory Timeline, which is what the NEW session starts from -- and
      # what its OWN record then journals as its own first turn.
      def settled(path, timeline)
        return timeline unless Event.pending_tool_use?(timeline.head)

        timeline.commit(role: :user, content: cancellation(path, timeline).blocks)
      end

      # The bare `raise` is STRUCTURAL, not defensive. Without it this arm
      # returns whatever {.refuse_mid_tool!} returns, which is nil whenever its
      # own predicate disagrees -- and a nil timeline reaches the Agent as a
      # fresh chain, so the whole conversation would vanish with no error at
      # all. The two predicates do agree today (both read the same immutable
      # head), which is exactly why the failure would be silent if they ever
      # stopped: this arm cannot return.
      def cancellation(path, timeline)
        Cancellation.new(timeline.head)
      rescue Cancellation::Unpairable
        refuse_mid_tool!(path, timeline, reason: UNANSWERABLE)
        raise
      end

      # The Loader's injected filesystem duck (its contract is handed-records,
      # never paths): a chain basename resolves within THIS project's session
      # dir, nil for a file that is not there -- GuardedResolver turns that
      # nil into the Corrupt refusal naming the missing file.
      def resolver
        lambda do |basename|
          path = File.join(dir, basename)
          File.file?(path) ? File.foreach(path) : nil
        end
      end

      # The shared class-level gate (see its own comment), reachable from the
      # private instance flow. `reason:` forwards, or a door would state the
      # OTHER door's reason.
      def refuse_mid_tool!(path, timeline, reason: MIRRORED)
        self.class.refuse_mid_tool!(path, timeline, reason:)
      end

      # `outcome.notice` is nil for {SessionRecord::Salvage::Nothing} (the
      # Null Object), so it drops out of `.compact` like every other absent
      # notice here; a {SessionRecord::Salvage::Recovered} outcome also
      # leaves `recording` closed by the time this runs (see {#rebuild}'s
      # reload), so `open_notice` correctly stops firing once recovery lands.
      # `mismatches` is {MismatchNotices}'s already-compacted model/provider
      # pair, spread in rather than recomputed here.
      def notices(path, recording, outcome, mismatches)
        [open_notice(path, recording), outcome.notice, *mismatches].compact
      end

      def open_notice(path, recording)
        return unless recording.open?

        "#{File.basename(path)} was not gracefully closed; resuming from its last verified turn"
      end
    end
  end
end

# Cancellation, Salvager, Selector, MismatchNotices, and ChainWalk reopen Resume to nest
# themselves (see Salvager's own class comment for why separate files rather
# than a separate cop-loosening): #salvage, #call, #call, and #replay send
# them messages, so they read as the dependent units even though all four
# resolve at runtime, the same ordering note {Bench::Session}'s own require
# block makes.
require_relative "resume/cancellation"
require_relative "resume/salvager"
require_relative "resume/selector"
require_relative "resume/mismatch_notices"
require_relative "resume/chain_walk"
