# frozen_string_literal: true

require "async"

module Lain
  module Bench
    class ApprovalReplay
      # The tool stack a chat builds, over a place that exists only in a session's record: the
      # board comes from {Lain::CLI::Switchboard.for} and the guards from {Lain::CLI::ToolGuard}, as a chat's
      # do, and only what they stand on is the replay's. The path policy, the layout guard and the
      # queue read {FileFacts::Recorded}, the interpreter is a {Effect::Handler::Mock} that runs
      # nothing, and everything the stack journals is kept in memory, never written.
      #
      # What it does not rebuild, because the session never recorded it: the project's
      # `sensitivity` and `tests` tables (the built-in table and no layout stand in), and the
      # rule that approves a command by what its programs resolve to on disk.
      class Stack
        MODEL = "approval-replay"

        # Seconds a parked call may wait for the replay's approver, who answers at once or not at all:
        # a missed answer fails the replay rather than waiting out a chat's window.
        ANSWER_WINDOW = 5

        # What the replay's bash would run a command through, were the interpreter ever to reach it.
        # Built over nothing, so the tool asks the disk for no shell either.
        module Unrun
          def self.takes_term?(_term) = false

          def self.call(**) = raise(Error, "an approval replay runs no command")
        end

        # The tools a gated call can name that read or write a path or run a command, by name. The
        # interpreter never reaches one.
        TOOLS = { "bash" => -> { Tools::Bash.new(exec: Unrun) }, "read_file" => -> { Tools::ReadFile.new },
                  "write_file" => -> { Tools::WriteFile.new }, "edit_file" => -> { Tools::EditFile.new },
                  "list_files" => -> { Tools::ListFiles.new }, "glob" => -> { Tools::Glob.new },
                  "grep" => -> { Tools::Grep.new }, "ast_search" => -> { Tools::AstSearch.new },
                  "file_symbols" => -> { Tools::FileSymbols.new } }.freeze

        Dispatched = Data.define(:records, :guessed)

        # A session records its confine arm but never the list its mask list answered, so no replay
        # can say which secret the sandbox hid: the board is built with its default, no masks, the safe side.
        UNMASKED = "the workspace profile's masks, which no session records (git reads and walks past a " \
                   "masked secret replay unmasked, so the judge is not asked about them)"

        # What the board and the guards journal into: the records, as a reader parses them.
        class Capture
          attr_reader :records

          def initialize
            @records = []
          end

          def record(entry)
            @records << Journal.parse(Journal.hash_of(entry))
            self
          end

          alias << record
        end

        # The one thing the board and the guard builder ask a chronicle for: where to journal.
        Chronicle = Data.define(:record_journal) do
          def instrumentation = Agent::Instrumentation.new(journal: record_journal)
        end

        # @return [Toolset]
        def self.toolset = Toolset.new(TOOLS.values.map(&:call))

        # @param name [String]
        # @return [Boolean] whether a call of this tool can be replayed
        def self.tool?(name) = TOOLS.key?(name)

        # @param place [Place] where the session ran
        # @param arm [Arm] the approval level it is replayed at, and what a judge's deny does there
        # @param judge [#call, #prompt] what `auto` asks
        # @param rules [Array<Approval::Rule>] the remembered answers in force
        # @param denied_tools [Set<String>] the tools refused outright
        # @param window [Numeric] seconds a parked call waits for the approver
        def initialize(place:, arm:, judge:, rules: [], denied_tools: Set[].freeze, window: ANSWER_WINDOW)
          @place = place
          @facts = FileFacts::Recorded.new(places: [place.cwd, place.root, place.home])
          @journal = Capture.new
          @chronicle = Chronicle.new(record_journal: @journal)
          @toolset = self.class.toolset
          sensitivity = policy
          @board = ::Lain::CLI::Switchboard.for(chronicle: @chronicle, options: { approval: arm.approval },
                                                model: MODEL, toolset: @toolset, judge:, rules:, sensitivity:,
                                                test_layout: test_layout(sensitivity),
                                                classifiers: classifiers(sensitivity), denied_tools:,
                                                approval_timeout: window, memo: ::Lain::Approval::JudgeMemo.new,
                                                arms: ::Lain::CLI::Arms::OFF.with(judge_denials: arm.denials))
          @window = window
          # Built here for this session alone, so the replay's approver is its only consumer.
          @replay_queue = @board.approvals
          @stacks = {}
        end

        # Runs the block with a dispatcher, while `approver` answers whatever parks: as a sibling
        # fiber in the same reactor, which is how a chat's surfaces answer the queue.
        #
        # @param approver [#answer] given each parked {Approval::Parked::Queue::Pending}
        # @yieldparam dispatch [#call] `Call -> Dispatched`
        # @return [Object] what the block returns
        # @raise [Failed] when the approver raises, or leaves a parked call unanswered
        def session(approver:)
          Sync do |task|
            answering = task.async { loop { answer(approver, @replay_queue.dequeue) } }
            yield method(:dispatch)
          ensure
            answering&.stop
          end
        end

        # @param call [Call] joined, at this stack's place
        # @return [Dispatched] the records the call caused, and whether any file fact was a guess
        # @raise [Failed] as {#session}
        def dispatch(call)
          @broke = nil
          dispatched = ruled(call)
          raise Failed, "#{call.session} #{call.tool_use_id}: the approver failed: #{@broke}" if @broke
          if lapsed?(dispatched.records)
            raise Failed, "#{call.session} #{call.tool_use_id}: a parked call went unanswered for #{@window}s"
          end

          dispatched
        end

        private

        # A raise in the answering fiber would end it with the call still parked, so the broken
        # answer refuses the call to let the dispatch return and say what broke.
        def answer(approver, pending)
          approver.answer(pending)
        rescue StandardError => e
          @broke = "#{e.class}: #{e.message}"
          pending.deny(surface: Approver::SURFACE)
        end

        def lapsed?(records)
          records.any? { _1["type"] == "approval_decision" && _1["timed_out"] == true }
        end

        def ruled(call)
          start = @journal.records.size
          response = Response.new(content: [{ "type" => "tool_use", "id" => call.tool_use_id, "name" => call.tool,
                                              "input" => call.input }], stop_reason: :tool_use)
          runner = Agent::ToolRunner.new(handler: Effect::Handler::Mock.new(default: ""), middleware: stack_for(call),
                                         toolset: @toolset)
          guessed = @facts.observing(call.landings) { runner.run(response, context: session_context) }
          Dispatched.new(records: @journal.records.drop(start), guessed:)
        end

        # A child's calls go through the stack a child is given, asking as that child.
        def stack_for(call)
          return @stacks[nil] ||= ::Lain::CLI::ToolGuard.stack(@chronicle, @board) unless call.child

          @stacks[call.requester] ||= ::Lain::CLI::ToolGuard.child_stack(@chronicle, @board, worker_env,
                                                                         requester: call.requester)
        end

        def session_context = ::Lain::Session.new(worker_env:, root: @place.root)

        def worker_env = WorkerEnv.new(cwd: @place.cwd, env: {})

        def policy
          Sensitivity::Policy.new(sensitivity: Sensitivity.new(home: @place.home, cwd: @place.cwd, root: @place.root),
                                  home: @place.home, root: @place.root, file_facts: @facts)
        end

        def classifiers(sensitivity)
          ::Lain::CLI::Wiring::BoardBuild::Classifiers.new(home: @place.home, cwd: @place.cwd, root: @place.root,
                                                           facts: sensitivity.file_facts)
        end

        def test_layout(sensitivity)
          Middleware::GuardTestLayout::Run.new(layout: TestLayout::None, root: @place.root,
                                               file_facts: sensitivity.file_facts)
        end
      end
    end
  end
end
