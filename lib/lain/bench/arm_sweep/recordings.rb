# frozen_string_literal: true

require "yaml"

module Lain
  module Bench
    class ArmSweep
      # Loads the committed recordings fixture and turns it into the two things
      # the sweep needs to run the real arms offline: a request-aware {Replay}
      # provider (one committed answer per prompt, replayed through
      # Provider::Mock), and the orchestrator-worker decomposition
      # ({#subtasks_for}). One {Recordings} builds ONE {#seam} object that drives
      # all three arms -- the base Arm duck `call(journal:, **spawn_opts)` -- so
      # the cross-arm proof the dual_ledger_spec pins holds here by construction.
      #
      # Every recorded task id must resolve to a real {Bench::ArmTasks} task (the
      # suite owns prompts, categories, and graders); a recording for an unknown
      # id, or a `whole` block missing its text/usage, is a malformed fixture
      # surfaced loudly, never a task silently skipped.
      class Recordings
        # A model call's committed answer: the assistant text (encoding produced
        # files as FILE...END blocks) and the token usage it is priced at.
        Entry = Data.define(:text, :usage)

        # The arms are priced through their own journal; a single fixed model
        # keeps that pricing deterministic and offline (PriceBook.default knows
        # the sonnet family). The dollar figure is never reported -- only tokens
        # are -- but a known model keeps {Ledger} from raising UnknownModel.
        MODEL = "claude-sonnet-4"

        # The Context every arm's agents render through. Small max_tokens: the
        # mock never streams a long completion, and a stable Context keeps the
        # rendered request bytes identical across repeats.
        def self.context = Context.new(model: "claude-opus-4-8", max_tokens: 256)

        # @param path [String] the committed recordings YAML
        # @param tasks [Bench::ArmTasks] the B0 suite the ids join against
        def initialize(path:, tasks:)
          @path = path
          @by_id = tasks.to_h { |task| [task.id, task] }
          @entries = {}
          @subtasks = {}
          index!
        end

        # Task ids in fixture order -- the sweep's deterministic run order.
        # @return [Array<String>]
        attr_reader :order

        # @param id [String]
        # @return [Bench::ArmTasks::Task]
        def task_for(id) = @by_id.fetch(id)

        # The orchestrator-worker decomposition for a task prompt: its committed
        # subtask prompts, or the whole prompt when a task has no independent
        # slices to hand out (a single-file edit).
        # @return [Array<String>]
        def subtasks_for(task_prompt) = @subtasks.fetch(task_prompt, [task_prompt])

        # The committed answer for a rendered prompt, matched by LONGEST
        # committed key the rendered text contains -- so a dual-ledger request
        # (its ledger reminder appended to the task prompt) still resolves to the
        # task's `whole` answer, while a worker's shorter subtask prompt resolves
        # to its own. A prompt no recording covers raises rather than fabricating
        # an empty answer and a wrong-guess score.
        # @return [Entry]
        def entry_for(rendered)
          key = @keys.find { |candidate| rendered.include?(candidate) }
          raise MalformedRecording, "no recording in #{@path} matches the asked prompt: #{rendered[0, 120].inspect}" \
            if key.nil?

          @entries.fetch(key)
        end

        # ONE spawn seam driving all three arms: a fresh Agent per call (the mock
        # is stateful) over a {Replay} provider and an empty toolset, mapping the
        # widened spawn tail every arm speaks -- `timeline:`/`base_timeline:` to
        # the Agent's root, `worker_env:` to its Session.
        # @return [#call]
        def seam
          recordings = self
          lambda do |journal:, workspace: Workspace.empty, timeline: nil, base_timeline: nil, worker_env: nil, **|
            # `Session` alone resolves to Bench::Session in this namespace; the
            # agent runtime wants the top-level one.
            session = worker_env ? Lain::Session.new(worker_env:) : Lain::Session.new
            Agent.new(provider: Replay.new(recordings), toolset: Toolset.new([]),
                      context: Recordings.context, journal:, workspace:,
                      timeline: timeline || base_timeline, session:)
          end
        end

        private

        # Build the prompt->answer index and per-task decomposition from the
        # fixture, in file order (the sweep's deterministic run order).
        def index!
          @order = raw.keys.map { |id| -id.to_s }
          @order.each { |id| ingest(id, raw.fetch(id)) }
          @keys = @entries.keys.sort_by { |key| [-key.length, key] }.freeze
        end

        def raw
          @raw ||= YAML.safe_load_file(existing!).fetch("recordings")
        rescue KeyError
          raise MalformedRecording, "recordings fixture at #{@path} is missing the top-level `recordings:` key"
        end

        def ingest(id, spec)
          task = @by_id.fetch(id) do
            raise MalformedRecording, "recording #{id.inspect} in #{@path} names no task in the suite"
          end
          whole = spec.fetch("whole")
          @entries[-(whole["prompt"] || task.prompt).to_s] = entry(whole)
          ingest_subtasks(task, spec.fetch("subtasks", []))
        rescue KeyError => e
          raise MalformedRecording, "recording #{id.inspect} in #{@path} is missing #{e.key.inspect}"
        end

        def ingest_subtasks(task, subtasks)
          prompts = subtasks.map do |sub|
            prompt = -sub.fetch("prompt").to_s
            @entries[prompt] = entry(sub)
            prompt
          end
          @subtasks[task.prompt] = prompts.freeze unless prompts.empty?
        end

        def entry(spec)
          usage = spec.fetch("usage")
          Entry.new(text: -spec.fetch("text").to_s,
                    usage: Usage.new(input_tokens: usage.fetch("input"), output_tokens: usage.fetch("output")))
        end

        def existing!
          raise MissingFixture, "no arm-sweep recordings fixture at #{@path}" unless File.file?(@path)

          @path
        end
      end

      # A Provider::Mock whose answer depends on WHICH prompt it is asked, not on
      # call order -- so one provider correctly serves a linear arm asking the
      # whole task and a worker asking one subtask, with no ordering assumptions
      # across the orchestrator's concurrent fan-out. Everything else (the
      # capability set, the stream-start signal) is Mock's, unchanged.
      class Replay < Provider::Mock
        def initialize(recordings)
          super()
          @recordings = recordings
        end

        def complete(request, on_stream_started: nil)
          @requests << request
          entry = @recordings.entry_for(rendered_prompt(request))
          emit_stream_started(request, on_stream_started) if on_stream_started && request.stream
          Response.new(content: [{ "type" => "text", "text" => entry.text }],
                       stop_reason: :end_turn, model: Recordings::MODEL, usage: entry.usage)
        end

        private

        def rendered_prompt(request)
          request.messages.flat_map { |message| message["content"] }.filter_map { |block| block["text"] }.join("\n")
        end
      end

      # Parses the FILE...END blocks an arm's assistant turns emit into the
      # `path => content` Trajectory ArmTasks' gold grader scores. The FILE
      # marker is matched ANYWHERE on a line, not just at its start, because the
      # orchestrator's synthesis fold prefixes each worker's text with
      # "worker N: " -- so the first block of a folded worker sits mid-line. END
      # is an all-caps sentinel on its own line, distinct from Ruby's lowercase
      # `end`, so method bodies never terminate a block early.
      module FileBlocks
        BLOCK = /FILE (.+?)\n(.*?)\nEND$/m
        private_constant :BLOCK

        def self.parse(text) = text.scan(BLOCK).to_h { |path, body| [path, body] }
      end
    end
  end
end
