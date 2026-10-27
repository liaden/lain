# frozen_string_literal: true

module Lain
  module Bench
    # Re-decides the gated calls a session journaled, through the production approval stack, once
    # per arm: an approval level, a rule set and who answers a parked call. Nothing runs and
    # nothing reads the disk: the interpreter is {Effect::Handler::Mock}, every path is judged
    # against {FileFacts::Recorded}, and the judge is {RecordedJudge}, which answers what the
    # session's judge answered.
    #
    # A call whose answer rested on a file fact the session never recorded is marked
    # "state unknown" rather than dropped: the rung that ruled it is still the one that would
    # have, for a tree where that path is plain.
    class ApprovalReplay
      Arm = Data.define(:approval, :rules_path, :approver)
      Row = Data.define(:session, :call_digest, :tool, :tool_use_id, :requester, :arm, :rung, :rule, :verdict,
                        :prompted, :unanswered, :state, :judge)
      Place = Data.define(:cwd, :root, :home)

      LEVELS = %i[ask auto bypass].freeze
      APPROVERS = %i[recorded perfect].freeze

      # What a row says of a call no rung decided.
      UNRULED = { "verdict" => "none" }.freeze

      # A replay that cannot finish: a parked call nobody answered, or an approver that broke.
      class Failed < Error; end

      # One way a call is re-decided.
      class Arm
        # @return [String] the level, the rule set's file name and the approver, as a report heads it
        def name = [approval, rules_path ? File.basename(rules_path) : "no rules", approver].join(" ")

        # The remembered answers and refused tools in the rule set, read once, before any call is
        # replayed. Evaluated as a project's `.lain/config.rb` is; naming the file is the trust.
        #
        # @return [Array(Array<Approval::Remembered>, Set<String>)]
        def rules
          return [[], Set[].freeze] unless rules_path

          built = Config::Builder.evaluate(File.read(rules_path), path: rules_path)
          [[Approval::Remembered.from(built)].reject(&:empty?), built.approval.deny_tools]
        end
      end

      # Where a session ran.
      class Place
        # @param project [Project] the project this process resolves
        # @param paths [Paths] the home it runs under
        # @return [Place] where a session that recorded no place is replayed
        def self.current(project: Project::Resolver.default_project, paths: Paths.new)
          new(cwd: project.cwd, root: project.root, home: paths.home)
        end

        # @param header [Hash, nil] a session header
        # @return [Place, nil] nil when the header recorded no provenance, or an unrecorded field
        def self.recorded(header)
          stamp = header&.fetch("provenance", nil)
          fields = stamp&.values_at("cwd", "root", "home")
          return nil if fields.nil? || fields.any? { _1.nil? || _1 == SessionRecord::Provenance::UNRECORDED }

          new(cwd: fields[0], root: fields[1], home: fields[2])
        end
      end

      # @param paths [Array<String>] session files
      # @param arms [Array<Arm>]
      # @param project [Place] where a session that recorded no place is replayed
      # @return [ApprovalReplay]
      def self.from_journals(paths, arms:, project:)
        read = paths.to_h { [_1, Journal.records(File.foreach(_1)).to_a] }
        new(calls: read.flat_map { |path, records| Call.joined(records, session: path) }, arms:, project:,
            sessions: read.transform_values { |records| records.find { _1["type"] == SessionRecord::HEADER_TYPE } })
      end

      # The replay `lain bench approval-replay` asks for: every approval level under every rule set.
      #
      # @param sessions [Array<String>] session files
      # @param approvals [Array<String, Symbol>] levels out of {LEVELS}
      # @param rules [Array<String>] rule set files; none means one arm per level with no rules
      # @param approver [String, Symbol] out of {APPROVERS}
      # @param project [Place]
      # @return [ApprovalReplay]
      # @raise [CLI::Refusal] on an unknown level or approver, an arm asked for twice, or a rule set that
      #   will not load
      def self.asked(sessions:, approvals:, rules:, approver:, project:)
        raise CLI::Refusal, "approval-replay needs at least one session file" if sessions.empty?

        unknown = approvals.map(&:to_s) - LEVELS.map(&:to_s)
        raise CLI::Refusal, "--approval is #{LEVELS.join(", ")}, not #{unknown.join(", ")}" if unknown.any?
        unless APPROVERS.include?(approver.to_sym)
          raise CLI::Refusal, "--approver is #{APPROVERS.join(" or ")}, not #{approver}"
        end

        from_journals(spelled_once(sessions), arms: once(arms_of(approvals, spelled_once(rules), approver)), project:)
      rescue Config::Refusal => e
        raise CLI::Refusal, e.message
      end

      # One file named two ways is the same file once.
      def self.spelled_once(paths) = paths.map { File.expand_path(_1) }.uniq

      def self.arms_of(approvals, rules, approver)
        approvals.product(rules.empty? ? [nil] : rules).map do |level, path|
          Arm.new(approval: level.to_sym, rules_path: path, approver: approver.to_sym)
        end
      end

      def self.once(arms)
        twice = arms.tally.find { |_, count| count > 1 }&.first
        raise CLI::Refusal, "#{twice.name} is asked for twice; each arm is replayed once" if twice

        arms
      end
      private_class_method :spelled_once, :arms_of, :once

      attr_reader :calls, :arms, :project, :sessions

      # @param calls [Array<Call>] in journal order, sessions one after another
      # @param arms [Array<Arm>] each once
      # @param project [Place]
      # @param sessions [Hash{String=>Hash, nil}] each session file read, by path, to its header
      # @raise [ArgumentError] on an arm given twice, whose rows no report could tell apart
      def initialize(calls:, arms:, project:, sessions: calls.to_h { [_1.session, nil] })
        twice = arms.tally.select { _2 > 1 }.keys.map(&:name)
        raise ArgumentError, "an arm is given twice: #{twice.join(", ")}" if twice.any?

        @calls = calls.freeze
        @arms = arms.freeze
        @project = project
        @sessions = sessions.freeze
        @rules = arms.to_h { [_1, _1.rules] }
      end

      # @return [Array<Call>] the ruled calls that can be replayed: joined, and of a tool the stack holds
      def replayable = calls.select { _1.joined? && Stack.tool?(_1.tool) }

      # @return [Enumerator::Lazy<Row>] one per replayable call per arm, arm by arm
      def rows = (@rows ||= arms.flat_map { |arm| by_session.flat_map { replayed(arm, _1) } }.freeze).lazy

      # @param arm [Arm]
      # @return [Array<Row>] that arm's, in journal order
      def rows_of(arm) = rows.select { _1.arm == arm }.to_a

      # @return [Array<Array(Row, Row)>] each call whose verdict differs between the two arms
      def diff(arm_a, arm_b)
        theirs = rows_of(arm_b).to_h { [key(_1), _1] }
        rows_of(arm_a).filter_map do |ours|
          other = theirs[key(ours)]
          [ours, other] if other && other.verdict != ours.verdict
        end
      end

      # @param row [Row]
      # @return [Array(String, String)] what a row is joined to its call, and to another arm's row, by
      def key(row) = [row.session, row.tool_use_id]

      # @return [String]
      def report = Report.new(self).to_s

      private

      def by_session = replayable.group_by(&:session).values

      def replayed(arm, calls)
        place = calls.first.place || project
        rules, denied_tools = @rules.fetch(arm)
        judge = RecordedJudge.new
        approver = Approver.for(arm.approver, calls)
        Stack.new(place:, arm:, judge:, rules:, denied_tools:).session(approver:) do |dispatch|
          calls.map { |call| row(arm, call.with(place:), judge, approver, dispatch) }
        end
      end

      def row(arm, call, judge, approver, dispatch)
        dispatched = judge.answering(call) { dispatch.call(call) }
        ruled = Call.ruling_of(dispatched.records.select { _1["tool_use_id"] == call.tool_use_id }) || UNRULED
        Row.new(session: call.session, call_digest: call.digest, tool: call.tool, tool_use_id: call.tool_use_id,
                requester: call.requester, arm:, rung: ruled["rung"], rule: ruled["rule"],
                verdict: ruled.fetch("verdict"), **asked(approver, call.tool_use_id),
                state: dispatched.guessed ? "unknown" : "recorded", judge: judge.state)
      end

      def asked(approver, id) = { prompted: approver.prompted?(id), unanswered: approver.unanswered?(id) }
    end
  end
end
