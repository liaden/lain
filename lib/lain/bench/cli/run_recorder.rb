# frozen_string_literal: true

module Lain
  module Bench
    class CLI
      # One recorded live run. {CLI} resolves WHAT to record -- provider,
      # context, prompts, attribution -- and this owns HOW one run becomes one
      # loadable session file.
      class RunRecorder
        # What a run the provider refused leaves in place of `N.ndjson`: a
        # name {CLI#variance_report} lists apart rather than loads, since the
        # partial file has no session header to rebuild a context from.
        FAILED = ".failed.ndjson"

        # Where the records a shared provider writes about its own round trips
        # land: the file of whichever run is recording, and nowhere between
        # runs. One provider serves every run, so a destination handed to it
        # at construction would put every run's records into the first file.
        class CurrentRun
          def initialize
            @journal = Channel::Null.instance
          end

          def <<(event) = @journal << event

          # @param journal [#<<] the recording run's own file
          # @yield while that run records
          def into(journal)
            @journal = journal
            yield
          ensure
            @journal = Channel::Null.instance
          end
        end

        # @param path [String]
        # @return [Boolean] whether the file is a run set aside as failed
        def self.failed?(path) = path.end_with?(FAILED)

        # A connection that dropped, timed out or stalled, a stream that could
        # not be read, an endpoint too busy to take the call, a rate limit, or a
        # server-side failure: the one classification a stopped ask's
        # `transport` reason is read from. Any other status is the request's own
        # fault -- a bad key, a model the server does not have, a prompt over
        # the window -- and every later run would fail the same way.
        #
        # @param error [Exception]
        # @return [Boolean]
        def self.round_trip?(error) = Agent::StopReason.transport?(error)

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
        # @param current_run [CurrentRun] the destination `provider` was built
        #   over, pointed at each run's file while it records
        def initialize(provider:, context:, attribution:, prompts:,
                       tools: Harness::NO_TOOLS, instrumentation: Harness::INSTRUMENTATION, current_run: CurrentRun.new)
          @provider = provider
          @context = context
          @attribution = attribution
          @prompts = prompts
          @tools = tools
          @instrumentation = instrumentation
          @current_run = current_run
          freeze
        end

        # One run, one journal, one file (Session's format contract), with
        # JournalRequests INNERMOST so the baseline is the bytes the provider
        # actually received. An occupied path REFUSES rather than replaces:
        # Journal.open appends, a second header in one file would destroy both
        # sweeps' loadability, and the existing bytes cost real money.
        #
        # A run whose round trip failed is renamed aside, and the caller goes
        # on to the next: one dropped connection costs that run, not the sweep.
        # Anything else that stops a run -- a refused configuration, a bug,
        # Ctrl-C -- still sets its partial file aside, so the directory stays
        # readable and a re-run is not refused over it, and then propagates.
        #
        # @return [String] the written path, or the set-aside path and why
        # @raise [Refusal] on an occupied path, or a set-aside name already taken
        def record(path)
          raise Refusal, "#{path} already exists; refusing to overwrite a recorded session" if File.exist?(path)

          recorded(path)
        end

        private

        def recorded(path)
          settled = false
          failure = write(path)
          settled = true
          failure.nil? ? path : "#{move_aside(path)} (set aside: #{failure.class.name}: #{failure.message})"
        ensure
          move_aside(path) unless settled || !File.exist?(path)
        end

        # Never over another file: a name taken since the run began is somebody
        # else's recording, and a link fails where a rename would replace it.
        def move_aside(path)
          failed = path.delete_suffix(".ndjson") + FAILED
          File.link(path, failed)
          File.unlink(path)
          failed
        rescue Errno::EEXIST
          raise Refusal, "cannot set #{path} aside: #{failed} already exists, so both are left as they are"
        end

        # @return [Exception, nil] the failed round trip the run ended on
        def write(path)
          journal = Journal.open(path)
          # One per session, at session start. {Session::Loader} reads by
          # record TYPE, not file position, so leading with it reorders
          # nothing downstream.
          journal << @attribution
          @current_run.into(journal) { run_and_write(journal) }
          nil
        rescue StandardError, SignalException => e
          journal&.<<(Telemetry::RecordingFailed.of(e))
          raise unless self.class.round_trip?(e)

          e
        ensure
          journal&.close
        end

        # A fresh Agent per run, so no Timeline state leaks between samples.
        # Each file is a session of its own, so each carries the capabilities
        # its context asked for and this provider could not give.
        def run_and_write(journal)
          Capability::Policy.for(:degrade, journal:).resolve(@context, @provider)
          agent = build_agent(journal)
          ask_each(agent)
          Session.write(journal, timeline: agent.timeline, context: @context, toolset: agent.toolset)
        end

        # A budget stop is the harness ending the run where it stood, which is
        # a measurement of the run and not a failure of it: what it produced is
        # recorded, and dropping it would leave only the cheap runs in the
        # distribution.
        def ask_each(agent)
          @prompts.each { |prompt| agent.ask(prompt) }
        rescue Agent::Budget::Exceeded
          agent
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
