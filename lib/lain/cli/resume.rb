# frozen_string_literal: true

module Lain
  module CLI
    # Resolves `lain chat --resume [SESSION]` into the pieces the thin exe
    # wires: the chain-verified Timeline the Agent is seeded with, the replayed
    # Session run-state and its memory recorder, the chained-header fields the
    # NEW journal opens with, and the notices the frontend renders. The recorded
    # tool schema in the old header is display-only: the live toolset always
    # comes from the current flags. The recorded run profile is what an untyped
    # backend field defaults to ({#recorded_profile}), and a typed field that
    # disagrees with it is LOUD-and-continue ({MismatchNotices}), never a silent
    # override in either direction.
    class Resume
      # A resume that cannot proceed: nothing to resume, an ambiguous or
      # unmatched selector, a corrupt or pre-scribe file, or a mid-tool head. A
      # {Lain::Error} so the exe maps it to a clean Thor::Error.
      class Refusal < Error; end

      Door = Data.define(:verb, :path)

      # What the current run resolved, carried together to the one place it is
      # compared against the recording.
      Mismatch = Data.define(:profile, :model)

      # WHICH door a human came through and WHICH file they named -- the two
      # facts every refusal needs. As two bare Strings riding seven frames as
      # positionals, `refusal("fork", path)` and `refusal(path, "fork")` both
      # type-checked, and one printed `cannot /sessions/f.ndjson fork:`. As a
      # value they cannot be swapped silently and `verb` is checked against a
      # closed set at construction rather than at the sentence.
      #
      # Reopened rather than written in the `Data.define` block because a
      # constant declared inside that block belongs to the ENCLOSING module, not
      # to the Data class -- {VERBS} would silently become `Resume::VERBS`.
      class Door
        VERBS = %w[resume fork].freeze

        def initialize(verb:, path:)
          raise ArgumentError, "unknown door #{verb.inspect}: expected #{VERBS.join(" or ")}" \
            unless VERBS.include?(verb)

          super
        end

        # The basename, because a refusal names the file the human typed and
        # never the absolute path the resolver built.
        def file = File.basename(path)

        # Every refusal either door raises reads "cannot <verb> <file>:
        # <reason>", so the shape lives here and a new refusal cannot forget
        # the file.
        def refuse(reason) = Refusal.new("cannot #{verb} #{file}: #{reason}")
      end

      # Everything a resumed chat starts from. `resumed_from`/`written` are
      # exactly {CLI::Chronicle#start}'s chaining keywords, derived here so
      # the exe never assembles wire-format hashes itself.
      Result = Data.define(:file, :timeline, :recorded, :session, :recorder, :open, :notices) do
        # `recorded` defaults to `timeline` so a caller with nothing to
        # distinguish -- every untorn session -- constructs exactly as before.
        def initialize(file:, timeline:, session:, recorder:, open:, notices:, recorded: timeline)
          super(file:, timeline:, recorded:, session:, recorder:, open:, notices: notices.freeze)
        end

        # Both are claims about the PRIOR FILE, so both read `recorded` and
        # never `timeline`, which may carry a projected cancellation turn
        # ({Cancellation}) no journal has ever held. Naming the projection here
        # would open a header whose `resumed_from.head` the prior file's own
        # fold cannot verify: the new session would refuse as
        # {Bench::Session::Corrupt} the first time IT was resumed -- a failure
        # one whole session away from its cause.
        def resumed_from = { "file" => file, "head" => recorded.head_digest }
        def written = recorded.to_a.map(&:digest)
        def open? = open

        # Whether {Resume#settled} projected a cancellation. Identity, not
        # digest comparison: the repair commits a NEW Timeline and leaves the
        # recorded one untouched, so no walk is needed.
        def repaired? = !recorded.equal?(timeline)
      end

      # A session file's header record, or an empty Hash for a file with none
      # (the Loader refuses that file by name once a door loads it).
      #
      # @param path [String]
      # @return [Hash{String=>Object}]
      def self.header(path)
        Journal.records(File.foreach(path), type: SessionRecord::HEADER_TYPE).first || {}
      end

      # @param paths [Paths] resolves this project's session directory
      # @param probe [Liveness::Probe] asks whether an open session's writer runs
      def initialize(paths: Paths.new, probe: Liveness::Probe.new)
        @paths = paths
        @probe = probe
      end

      # The two SELECTIONS, apart from the opens below, so a caller that must
      # read a session before opening it picks the file once: a bare
      # `--resume` answers whatever is newest when it looks, and two looks
      # can land on two files.
      #
      # @param selector [String, nil] nil or "" (a bare `--resume`) picks the
      #   newest session; otherwise a filename or unique prefix under this
      #   project's session dir
      # @return [String] the selected session's path
      # @raise [Refusal]
      def locate(selector) = Selector.new(dir:).call(selector)

      # @param selector [String] `<session>@<digest-prefix>`
      # @return [ForkPoint::Point]
      # @raise [Refusal]
      def fork_point(selector) = ForkPoint.new(dir:).call(selector)

      # The run profile a selected session recorded, read BEFORE the backend
      # exists so an untyped field can default to it. Reads the header and
      # nothing else: no load, no salvage, no write.
      #
      # @param path [String] a path {#locate} or {#fork_point} selected
      # @return [RunProfile]
      def recorded_profile(path)
        RunProfile.from_header(self.class.header(path))
      rescue Errno::ENOENT
        RunProfile::UNRECORDED
      end

      # {#resume_at} over a fresh {#locate}.
      def call(selector: nil, profile: RunProfile::UNRECORDED, model: nil)
        resume_at(locate(selector), profile:, model:)
      end

      # @param path [String] the session {#locate} selected
      # @param profile [RunProfile] what the current run resolved, compared
      #   against the recorded header for the mismatch notices
      # @param model [String, nil] the model the current run resolved to,
      #   compared against the recording for the mismatch notice
      # @return [Result]
      # @raise [Refusal]
      def resume_at(path, profile: RunProfile::UNRECORDED, model: nil)
        rebuild(path, Mismatch.new(profile:, model:))
      end

      # {#fork_at} over a fresh {#fork_point}.
      def fork(selector:, profile: RunProfile::UNRECORDED, model: nil)
        fork_at(fork_point(selector), profile:, model:)
      end

      # Fork mode: the new run starts at a recorded turn instead of the parent's
      # final head. READ-ONLY BY CONSTRUCTION: this path holds only
      # `File.foreach` enumerators and has no salvage step, so a {Salvager}
      # (whose #close! appends a close anchor) is never constructed against the
      # parent -- forking a LIVE session must leave its owner's journal exactly
      # as the owner is writing it. The checkout is pointer movement; the
      # verification is the load's re-commit fold, which proved every digest
      # {ForkPoint} can resolve.
      #
      # @param point [ForkPoint::Point] the fork point {#fork_point} selected
      # @param profile [RunProfile] as {#resume_at}'s, against the forked file's header
      # @param model [String, nil] as {#resume_at}'s, against the forked recording
      # @return [Result] whose `resumed_from` names `{file, fork digest}`
      # @raise [Refusal]
      def fork_at(point, profile: RunProfile::UNRECORDED, model: nil)
        recording = load_recording(point.path)
        forked = recording.timeline.checkout(point.digest)
        fork_result(point, recording, forked, Mismatch.new(profile:, model:))
      # The MissingObject arm is DEFENSIVE and kept deliberately: it is not
      # reachable from any journal we can construct, and the last time that was
      # believed it was false. The property lives in two classes a door cannot
      # see, so one uncovered escape there is a raw backtrace out of the exe.
      # {#rebuild} carries the identical pair -- a damaged journal must not
      # refuse differently depending on which door a user came through.
      rescue Bench::Session::Corrupt, Store::MissingObject => e
        raise fork_refusal(point, e.message)
      rescue Errno::ENOENT
        # The TOCTOU between ForkPoint's read and this load: a reap or rename
        # can win that race; refuse namedly, never a raw errno.
        raise fork_refusal(point, "it vanished before it could be loaded " \
                                  "(reaped or renamed underneath the fork); list and retry")
      end

      private

      def dir = @dir ||= @paths.sessions_dir

      # An OPEN recording gets one salvage attempt before anything else runs.
      # {Salvager#close!} retroactively turns a Recovered crash into an ordinary
      # closed file, so the reload below reuses the SAME
      # {Bench::Session::Loader}/{Bench::Session::Anchor} machinery every other
      # closed session already proves, rather than growing a parallel
      # "open-plus-salvaged" shape those classes would have to learn. It is also
      # what makes `resumed_from`/`written` correct unchanged: both derive from
      # `recording.timeline`, which now reflects a file that IS closed.
      def rebuild(path, current)
        recording = load_recording(path)
        outcome = salvage(path, recording)
        recording = load_recording(path) if outcome.recovered?
        resumed_result(path, recording, outcome, current)
      rescue Bench::Session::Corrupt, Store::MissingObject => e
        # Corrupt's own message names digests and reasons; only this layer still
        # holds the path. The MissingObject arm is {#fork}'s, and it was missing
        # here once at a real cost: the SAME damaged file refused namedly from
        # `--fork` and escaped as a raw store complaint, with no file on it,
        # from `--resume`.
        raise Door.new(verb: "resume", path:).refuse(e.message)
      rescue Provider::ResponseWal::CorruptFrame => e
        # The loud backstop. Salvage reads the WAL TOLERANTLY
        # ({Salvager#wal_frames}), so a CorruptFrame escaping is a bug in that
        # tolerant path -- refuse namedly rather than crash the whole resume
        # with a raw provider error the exe cannot map.
        raise Door.new(verb: "resume", path:).refuse("its response log is corrupt (#{e.message})")
      end

      def load_recording(path)
        Bench::Session::Loader.new(File.foreach(path), resolve: resolver).recording
      end

      # Both entry paths end in the same Result assembly. The difference is
      # exactly the timeline and the notices: resume ends on the rebuilt head
      # with the salvage/open notices, a fork on the checked-out fork point with
      # the mismatch notices alone.
      def resumed_result(path, recording, outcome, current)
        mismatched = mismatches(path, recording, current)
        result(Door.new(verb: "resume", path:), recording.timeline, replay(path),
               open: recording.open?, notices: notices(path, recording, outcome, mismatched))
      end

      def fork_result(point, recording, forked, current)
        result(Door.new(verb: "fork", path: point.path), forked, replay(point.path),
               open: recording.open?, notices: mismatches(point.path, recording, current))
      end

      def fork_refusal(point, reason) = Door.new(verb: "fork", path: point.path).refuse(reason)

      # Run-state and memory replay are chain-wide, where the Loader folds only
      # the Timeline and message events across `resumed_from` -- so the entries
      # come from {ChainWalk}, every file of the chain, oldest first.
      def replay(path) = SessionRecord::Replay.new(ChainWalk.new(dir:).entries(path))

      def mismatches(path, recording, current)
        MismatchNotices.new(recording:, path:).call(**current.to_h)
      end

      # Salvage only ever runs against an open session: a gracefully closed file
      # already flushed everything it could. A Recovered outcome closes the file
      # through {Salvager#close!}; {#rebuild} reloads it afterward.
      #
      # @return [SessionRecord::Salvage::Nothing, Recovered, Incomplete]
      def salvage(path, recording)
        return SessionRecord::Salvage::Nothing unless recording.open?

        salvager = Salvager.new(path:, timeline: recording.timeline)
        salvager.close!(head_before: recording.timeline.head_digest) if salvager.outcome.recovered?
        salvager.outcome
      end

      # `recording.memory` is file-scoped (the Loader's stated limit) and so
      # deliberately unused: the recorder must cover the WHOLE chain, so it is
      # `replay.memory` over the chain's concatenated records instead. The
      # timeline rides separately from the recording because fork mode's is a
      # checkout below the rebuilt head.
      #
      # The repair is disclosed, not silent: a session whose model sees a turn
      # the human never saw is the invisible mutation the Journal doctrine
      # exists against. The {Door} rides through for the REFUSAL alone -- the
      # repair and this disclosure are identical at both doors, and only what a
      # human is told when the repair CANNOT be made names which door they used.
      def result(door, timeline, replay, open:, notices:)
        built = Result.new(file: door.file, timeline: settled(door, timeline),
                           recorded: timeline, session: replay.session, recorder: replay.memory,
                           open:, notices:)
        built.repaired? ? built.with(notices: [*notices, repair_notice(built)]) : built
      end

      # Held to {Tool::Cancellation::NO_RESULT}'s standard, and for its reason:
      # "stopped with N unanswered" is an inference about the RUN and is false
      # on the fork-below-results door -- that file did not stop, and the call
      # it names returned. This side knows only what the CONTINUATION carries.
      def repair_notice(built)
        "#{built.file}: the conversation being continued carries no result for " \
          "#{built.timeline.head.content.length} tool call(s); they are reported to the model as " \
          "cancelled so the session can continue -- the journal is unchanged"
      end

      # The ONE place either door repairs a torn point: both {#resumed_result}
      # and {#fork_result} come through {#result}.
      #
      # Repairing HERE, at load, rather than at the tear is what makes it
      # trigger-agnostic. The interrupt that tore the session this was written
      # for was never identified, and SIGKILL, an OOM and a reactor teardown are
      # invisible to every in-process handler while being identical from this
      # side. (The in-process case a handler CAN see commits this same block
      # through {Cancellation}, so the two cannot disagree.)
      #
      # The journal is not rewritten: this commit lands on the rebuilt in-memory
      # Timeline the NEW session starts from, and its own record journals it as
      # its own first turn.
      #
      # Only the HEAD is repaired. An orphan with turns already recorded on top
      # of it is damaged history, and answering it would mean inventing a turn
      # between two the journal holds, so that shape is refused where it sits.
      def settled(door, timeline)
        refuse_buried_orphan(door, timeline)
        return timeline unless Event.pending_tool_use?(timeline.head)

        timeline.commit(role: :user, content: cancellation(door, timeline).blocks)
      end

      # The pairing rule is {Context::Conversation}'s, read over the recorded
      # turns as the messages they render to. Every unanswered call but the
      # head's is buried; the head's is the one {#settled} can still answer.
      def refuse_buried_orphan(door, timeline)
        turns = timeline.to_a
        messages = turns.map { |turn| { "role" => turn.role, "content" => turn.content } }
        buried = Context::Conversation.new(messages).violations.find do |violation|
          violation.rule == :unanswered_tool_use && violation.positions.first < turns.length - 1
        end
        raise buried_refusal(door, turns, buried) if buried
      end

      # Named by place and digest, because the remedy is a fork AT that turn:
      # there it is the head again, and the head is what the repair answers.
      def buried_refusal(door, turns, violation)
        position = violation.positions.first
        digest = turns.fetch(position).digest.delete_prefix("blake3:")[0, 12]
        later = turns.length - position - 1
        dropped = "#{later} #{later == 1 ? "turn" : "turns"}"
        door.refuse("its turn #{position + 1} of #{turns.length} (#{digest}) is an assistant tool_use whose call " \
                    "#{violation.subject.inspect} is never answered, and later turns were recorded on top of " \
                    "it, so it cannot be repaired without rewriting that history. Fork at that turn instead, " \
                    "where the call can be answered -- which drops the #{dropped} recorded after it: " \
                    "lain chat --fork #{door.file}@#{digest}")
      end

      # The rescue arm IS the knowledge: reaching it means the head is torn
      # ({#settled} proved it) AND that no result can be paired with it
      # ({Cancellation} mints eagerly, so construction is the one place
      # {Cancellation::Unpairable} surfaces). {MidTool} is handed that answer
      # and re-derives nothing, which is what lets it be a sentence, not a gate.
      def cancellation(door, timeline)
        Cancellation.new(timeline.head)
      rescue Cancellation::Unpairable
        raise MidTool.refusal(door)
      end

      # The Loader's injected filesystem duck (its contract is handed-records,
      # never paths): a chain basename resolves within THIS project's session
      # dir, nil for a file that is not there -- GuardedResolver turns that nil
      # into the Corrupt refusal naming the missing file.
      def resolver
        lambda do |basename|
          path = File.join(dir, basename)
          File.file?(path) ? File.foreach(path) : nil
        end
      end

      # `outcome.notice` is nil for {SessionRecord::Salvage::Nothing} (the Null
      # Object), so it drops out of `.compact` like every other absent notice; a
      # Recovered outcome also leaves `recording` closed by the time this runs
      # (see {#rebuild}'s reload), so `open_notice` correctly stops firing once
      # recovery lands.
      def notices(path, recording, outcome, mismatches)
        [open_notice(path, recording), outcome.notice, *mismatches].compact
      end

      # The header records the process writing the file, so an open session can
      # be asked about that process rather than only "it wasn't closed". Only a
      # writer found live is claimed to be writing it still.
      def open_notice(path, recording)
        return unless recording.open?

        writer = Liveness::Writer.from_header(self.class.header(path))
        return "#{File.basename(path)} is still open in process #{writer.pid}" if writer.verdict(@probe) == :live

        "#{File.basename(path)} was not gracefully closed; resuming from its last verified turn"
      end
    end
  end
end

# All six reopen Resume to nest themselves, and Resume sends each of them
# messages, so they are required here as the dependent units even though all six
# resolve at runtime -- the ordering note {Bench::Session}'s require block makes.
require_relative "resume/cancellation"
require_relative "resume/mid_tool"
require_relative "resume/salvager"
require_relative "resume/selector"
require_relative "resume/mismatch_notices"
require_relative "resume/chain_walk"
