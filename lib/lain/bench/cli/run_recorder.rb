# frozen_string_literal: true

module Lain
  module Bench
    class CLI
      # One recorded live run, extracted from {CLI#record} because writing a
      # session is its own responsibility: the journal lifecycle, the middleware
      # stack, and the one-run-one-journal-one-file format contract. {CLI}
      # resolves WHAT to record (provider, context, prompts, attribution);
      # this object owns HOW one run becomes one loadable session file.
      class RunRecorder
        def initialize(provider:, context:, attribution:, prompts:)
          @provider = provider
          @context = context
          @attribution = attribution
          @prompts = prompts
          freeze
        end

        # One run, one journal, one file (Session's format contract), with
        # JournalRequests INNERMOST so the baseline is the bytes the provider
        # actually received. An occupied path REFUSES rather than replaces:
        # Journal.open appends, a second header in one file would destroy both
        # sweeps' loadability, and the existing bytes cost real money.
        #
        # @return [String] the written path
        def record(path)
          raise Refusal, "#{path} already exists; refusing to overwrite a recorded session" if
            File.exist?(path)

          journal = Journal.open(path)
          begin
            # One slot_fills record per session, at session start (Loader reads
            # by record TYPE, not file position, so leading with it reorders
            # nothing downstream).
            journal << @attribution
            run_and_write(journal)
          ensure
            journal.close
          end
          path
        end

        private

        # A fresh Agent per run, so no Timeline state leaks between samples.
        def run_and_write(journal)
          agent = build_agent(journal)
          @prompts.each { |prompt| agent.ask(prompt) }
          Session.write(journal, timeline: agent.timeline, context: @context, toolset: agent.toolset)
        end

        # The memory stack the chunk built, wired even though these synthetic
        # tasks carry no memory_write tool yet: a Recorder holds the live root,
        # JournalMemoryRoot pairs each turn's digest with the root in force when
        # it rendered (so a later run's recall replays against the exact
        # snapshot), and RefuseSecretWrites guards the write seam. The raw
        # `journal` -- not the wrapped one -- backs JournalRequests and
        # WriteRefused, so those land unpaired; JournalMemoryRoot only decorates
        # the Agent's own turn_usage stream.
        def build_agent(journal)
          recorder = Memory::Recorder.new
          Agent.new(provider: @provider, toolset: Toolset.new([]), context: @context,
                    journal: Memory::JournalMemoryRoot.new(journal:, recorder:),
                    model_middleware: Middleware::Stack.new([Middleware::JournalRequests.new(journal:)]),
                    tool_middleware: Middleware::Stack.new([Middleware::RefuseSecretWrites.new(journal:)]))
        end
      end
    end
  end
end
