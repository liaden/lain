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
      Result = Data.define(:file, :timeline, :session, :recorder, :open, :notices) do
        def initialize(file:, timeline:, session:, recorder:, open:, notices:)
          super(file:, timeline:, session:, recorder:, open:, notices: notices.freeze)
        end

        def resumed_from = { "file" => file, "head" => timeline.head_digest }
        def written = timeline.to_a.map(&:digest)
        def open? = open
      end

      class << self
        # Committing synthetic tool_results would be a design decision, not an
        # implementation detail (T18 owns the response side): a head still
        # awaiting its tool results refuses with the re-ask shape rather than
        # resuming into a request the API must reject. A settled head --
        # assistant text, or tool_results already committed (then the head is
        # the user-role results turn) -- resumes fine. Takes the timeline (not
        # the recording) so fork mode's checked-out head faces the SAME
        # refusal verbatim -- a fork point mid-tool never auto-picks a
        # neighboring head. A class method (T16 F1) because /fork mirrors
        # this exact gate PARENT-SIDE, before opening a window whose child
        # would only die on it -- one predicate, one wording, wherever the
        # user meets it.
        def refuse_mid_tool!(path, timeline)
          head = timeline.head
          return if head.nil? || !pending_tool_use?(head)

          raise Refusal, "cannot resume #{File.basename(path)}: its head is an assistant tool_use turn " \
                         "still awaiting tool results (the run stopped mid-tool); fabricating results " \
                         "would falsify the record -- re-ask the question in a new session"
        end

        private

        def pending_tool_use?(head)
          head.role == "assistant" &&
            head.content.any? { |block| block.is_a?(Hash) && block["type"] == "tool_use" }
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
      # @return [Result] whose `resumed_from` names `{file, fork digest}`
      # @raise [Refusal]
      def fork(selector:, model: nil, provider: nil)
        point = ForkPoint.new(dir:).call(selector)
        recording = load_recording(point.path)
        forked = recording.timeline.checkout(point.digest)
        refuse_mid_tool!(point.path, forked)
        fork_result(point, recording, forked, model, provider)
      rescue Bench::Session::Corrupt => e
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
        refuse_mid_tool!(path, recording.timeline)
        resumed_result(path, recording, outcome, model, provider)
      rescue Bench::Session::Corrupt => e
        # Corrupt's own message names digests and reasons; only this layer
        # still holds the path (Bench::CLI#load_session's precedent).
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
      def result(path, timeline, replay, open:, notices:)
        Result.new(file: File.basename(path), timeline:,
                   session: replay.session, recorder: replay.memory, open:, notices:)
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
      # private instance flow.
      def refuse_mid_tool!(path, timeline) = self.class.refuse_mid_tool!(path, timeline)

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

# Salvager, Selector, MismatchNotices, and ChainWalk reopen Resume to nest
# themselves (see Salvager's own class comment for why separate files rather
# than a separate cop-loosening): #salvage, #call, #call, and #replay send
# them messages, so they read as the dependent units even though all four
# resolve at runtime, the same ordering note {Bench::Session}'s own require
# block makes.
require_relative "resume/salvager"
require_relative "resume/selector"
require_relative "resume/mismatch_notices"
require_relative "resume/chain_walk"
