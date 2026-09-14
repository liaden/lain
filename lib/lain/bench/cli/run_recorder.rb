# frozen_string_literal: true

module Lain
  module Bench
    class CLI
      # One recorded live run. {CLI} resolves WHAT to record -- provider,
      # context, prompts, attribution -- and this owns HOW one run becomes one
      # loadable session file.
      class RunRecorder
        # @param provider [Lain::Provider] the recording client every run asks
        # @param context [Lain::Context] what every run renders through
        # @param attribution [Lain::Telemetry::SlotFills] the prompt slots this
        #   recording was taken under, written once per session file
        # @param prompts [Array<String>] the task file's lines, asked in order
        # @param tools [#call] `call(recorder:, journal:) -> Toolset`, asked once
        #   per recorded run; see {Bench::Harness}. TOOLLESS by default, the same
        #   answer {CLI#record} gives and for the same reason: this object takes
        #   no `worker_env:` and {#build_agent} spawns on {WorkerEnv.default}, so
        #   a writing toolset here acts in the caller's own cwd whatever the
        #   caller has leased. A second default saying otherwise would be a
        #   promise this class cannot keep.
        # @param instrumentation [#call] `call(journal:, recorder:, worker_env:)
        #   -> Agent::Instrumentation`, asked once per recorded run
        def initialize(provider:, context:, attribution:, prompts:,
                       tools: Harness::NO_TOOLS, instrumentation: Harness::INSTRUMENTATION)
          @provider = provider
          @context = context
          @attribution = attribution
          @prompts = prompts
          @tools = tools
          @instrumentation = instrumentation
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
            # One per session, at session start. {Session::Loader} reads by
            # record TYPE, not file position, so leading with it reorders
            # nothing downstream.
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

        # ONE recorder per run, shared by the two halves that must agree about
        # it: the `memory_write`/`memory_read` tools write into it, and
        # {Memory::JournalMemoryRoot} pairs each turn's digest with the root it
        # held when that turn rendered, so a later run's recall replays against
        # the exact snapshot. Building it here rather than inside either factory
        # is what makes that sharing a fact of this method rather than a
        # coincidence between two lambdas.
        #
        # The worker env is {WorkerEnv.default} and NOT a parameter, which is
        # what makes the toolless default above the only honest one: giving this
        # class an env to spawn into is the change that would let a recorded run
        # carry real capabilities safely.
        #
        # A recorded session with tools declared is not comparable with one
        # taken without them -- a different prompt, a different cache prefix and
        # a different task -- so which harness a run used is part of its record.
        def build_agent(journal)
          recorder = Memory::Recorder.new
          Agent.new(provider: @provider, toolset: @tools.call(recorder:, journal:), context: @context,
                    instrumentation: @instrumentation.call(journal:, recorder:, worker_env: WorkerEnv.default))
        end
      end
    end
  end
end
