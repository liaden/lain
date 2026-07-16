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

      def initialize(paths: Paths.new)
        @paths = paths
      end

      # @param selector [String, nil] nil or "" (a bare `--resume`) picks the
      #   newest session; otherwise a filename or unique prefix under this
      #   project's session dir
      # @param model [String, nil] the model the current flags resolved to,
      #   compared against the recording for the mismatch notice
      # @return [Result]
      # @raise [Refusal]
      def call(selector: nil, model: nil)
        rebuild(Selector.new(dir:).call(selector), model)
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
      def rebuild(path, model)
        recording = load_recording(path)
        outcome = salvage(path, recording)
        recording = load_recording(path) if outcome.recovered?
        refuse_mid_tool!(path, recording)
        result(path, recording, SessionRecord::Replay.new(chain_entries(path)), model, outcome)
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
      # `replay.memory` over the chain's concatenated records instead.
      def result(path, recording, replay, model, outcome)
        Result.new(file: File.basename(path), timeline: recording.timeline,
                   session: replay.session, recorder: replay.memory,
                   open: recording.open?, notices: notices(path, recording, model, outcome))
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

      # Committing synthetic tool_results would be a design decision, not an
      # implementation detail (T18 owns the response side): a head still
      # awaiting its tool results refuses with the re-ask shape rather than
      # resuming into a request the API must reject. A settled head --
      # assistant text, or tool_results already committed (then the head is
      # the user-role results turn) -- resumes fine.
      def refuse_mid_tool!(path, recording)
        head = recording.timeline.head
        return if head.nil? || !pending_tool_use?(head)

        raise Refusal, "cannot resume #{File.basename(path)}: its head is an assistant tool_use turn " \
                       "still awaiting tool results (the run stopped mid-tool); fabricating results " \
                       "would falsify the record -- re-ask the question in a new session"
      end

      def pending_tool_use?(head)
        head.role == "assistant" &&
          head.content.any? { |block| block.is_a?(Hash) && block["type"] == "tool_use" }
      end

      # Run-state and memory replay chain-wide, oldest first: the Loader folds
      # only the Timeline and message events across `resumed_from` (its stated
      # limit), but a resumed session's reads, todos, and memory writes live
      # in EVERY file of the chain.
      def chain_entries(path)
        chain_paths(path).flat_map { |file| File.foreach(file).to_a }
      end

      # Carries its OWN visited-set guard (ResumeChain::GuardedResolver's
      # idiom) rather than trusting that {#rebuild} ran the Loader -- which
      # also refuses cycles -- first: that would be an ordering invariant a
      # reorder of rebuild's statements silently breaks, reintroducing the
      # SystemStackError the guard exists to prevent (panel fix round).
      def chain_paths(path, visited = [])
        basename = File.basename(path)
        revisit!(basename, visited)
        prior = prior_basename(path)
        prior.nil? ? [path] : chain_paths(File.join(dir, prior), visited + [basename]) + [path]
      end

      def prior_basename(path)
        Journal.records(File.foreach(path), type: SessionRecord::HEADER_TYPE)
               .first&.dig("resumed_from", "file")
      end

      def revisit!(basename, visited)
        return unless visited.include?(basename)

        raise Refusal, "resumed_from revisits #{basename.inspect} " \
                       "(walk: #{[*visited, basename].join(" -> ")}); a resume chain must not cycle"
      end

      # `outcome.notice` is nil for {SessionRecord::Salvage::Nothing} (the
      # Null Object), so it drops out of `.compact` like every other absent
      # notice here; a {SessionRecord::Salvage::Recovered} outcome also
      # leaves `recording` closed by the time this runs (see {#rebuild}'s
      # reload), so `open_notice` correctly stops firing once recovery lands.
      def notices(path, recording, model, outcome)
        [open_notice(path, recording), outcome.notice, model_notice(recording, model)].compact
      end

      def open_notice(path, recording)
        return unless recording.open?

        "#{File.basename(path)} was not gracefully closed; resuming from its last verified turn"
      end

      # The mismatch policy is LOUD-and-continue (the card's ruling): name
      # both, run with the flags. The recorded header is display-only here.
      def model_notice(recording, model)
        recorded = recording.context.model
        return if model.nil? || model == recorded

        "recorded with model #{recorded}; continuing with #{model} (the current flags win)"
      end
    end
  end
end

# Salvager and Selector reopen Resume to nest themselves (see Salvager's own
# class comment for why separate files rather than a separate cop-loosening):
# #salvage and #call send them messages, so they read as the dependent units
# even though both resolve at runtime, the same ordering note
# {Bench::Session}'s own require block makes.
require_relative "resume/salvager"
require_relative "resume/selector"
