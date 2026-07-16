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
        rebuild(select(selector), model)
      end

      private

      def dir = @dir ||= @paths.sessions_dir

      def rebuild(path, model)
        recording = Bench::Session::Loader.new(File.foreach(path), resolve: resolver).recording
        refuse_mid_tool!(path, recording)
        result(path, recording, SessionRecord::Replay.new(chain_entries(path)), model)
      rescue Bench::Session::Corrupt => e
        # Corrupt's own message names digests and reasons; only this layer
        # still holds the path (Bench::CLI#load_session's precedent).
        raise Refusal, "cannot resume #{File.basename(path)}: #{e.message}"
      end

      # `recording.memory` (file-scoped -- T14's stated Loader limit) is
      # deliberately unused: the recorder must cover the WHOLE chain, so it is
      # `replay.memory` over the chain's concatenated records instead.
      def result(path, recording, replay, model)
        Result.new(file: File.basename(path), timeline: recording.timeline,
                   session: replay.session, recorder: replay.memory,
                   open: recording.open?, notices: notices(path, recording, model))
      end

      def select(selector)
        names = session_names
        raise Refusal, "no sessions to resume under #{dir}" if names.empty?

        File.join(dir, chosen(names, selector.to_s))
      end

      # Bench::CLI's discovery idiom: Dir.children (a name carrying glob
      # metacharacters must not parse as a pattern), sorted -- the filenames
      # are UTC-timestamped, so lexicographic IS chronological and `.last` is
      # the newest. That is also what makes resume idempotent: an
      # exited-immediately resumed session is itself the newest file, so a
      # second `--resume` continues the head of the CHAIN, never forking the
      # original.
      def session_names
        Dir.children(dir).select { |name| name.end_with?(".ndjson") }.sort
      end

      def chosen(names, selector)
        return names.last if selector.empty?
        return selector if names.include?(selector)

        matched(names, selector)
      end

      def matched(names, selector)
        matches = names.select { |name| name.start_with?(selector) }
        return matches.first if matches.size == 1

        raise Refusal, "no session matching #{selector.inspect} under #{dir}" if matches.empty?

        raise Refusal, "#{selector.inspect} is ambiguous under #{dir}: #{matches.join(", ")}"
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

      def notices(path, recording, model)
        [open_notice(path, recording), model_notice(recording, model)].compact
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
