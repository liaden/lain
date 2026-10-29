# frozen_string_literal: true

module Lain
  module Bench
    # Re-decides the gated calls a session journaled, through the production approval stack, once
    # per arm: an approval level, a rule set and who answers a parked call. Nothing runs and
    # nothing reads the disk: the interpreter is {Effect::Handler::Mock}, every path is judged
    # against {FileFacts::Recorded}, and the judge is {RecordedJudge}, which answers what the
    # session's judge answered.
    #
    # An arm may also re-route the judge's denials ({Approval::DenialBreaker}): its row then says
    # the call was re-routed, and whether it cost a prompt the same arm with the judge's denials
    # applied would not have made, for which that arm is replayed beside it.
    #
    # A call whose answer rested on a file fact the session never recorded is marked
    # "state unknown" rather than dropped: the rung that ruled it is still the one that would
    # have, for a tree where that path is plain.
    class ApprovalReplay
      Arm = Data.define(:approval, :rules_path, :approver, :denials)
      Row = Data.define(:session, :call_digest, :tool, :tool_use_id, :requester, :arm, :rung, :rule, :verdict,
                        :prompted, :unanswered, :state, :judge, :rerouted, :extra_prompt)
      Place = Data.define(:cwd, :root, :home)

      LEVELS = %i[ask auto bypass].freeze
      APPROVERS = %i[recorded perfect approve_all].freeze
      # The judged rung's reasons for handing down a call the judge refused, or would have been asked about.
      REROUTED = [Approval::Judged::ESCALATED, Approval::Judged::BROKEN].freeze

      # What a row says of a call no rung decided.
      UNRULED = { "verdict" => "none" }.freeze

      # A replay that cannot finish: a parked call nobody answered, or an approver that broke.
      class Failed < Error; end

      # One way a call is re-decided.
      class Arm
        # @param approval [Symbol] one of {LEVELS}
        # @param rules_path [String, nil] a rule set's file; none when nil
        # @param approver [Symbol] one of {APPROVERS}
        # @param denials [Symbol, String] one of {CLI::Arms::JUDGE_DENIALS}; off by default
        def initialize(approval:, rules_path:, approver:, denials: :off)
          super(approval:, rules_path:, approver:, denials: denials.to_sym)
        end

        # @return [String] the level, the rule set's file name, the approver and any judge-denial arm, as a
        #   report heads it
        def name = [approval, rules_path ? File.basename(rules_path) : "no rules", approver, *denied].join(" ")

        # @return [Array<Symbol>] the judge-denial arm, when it is not off
        def denied = denials == :off ? [] : [denials]

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
        # @return [Place, nil] nil for no header, or when a place field is unrecorded
        def self.recorded(header)
          stamp = header&.fetch("provenance")
          fields = stamp&.values_at("cwd", "root", "home")
          return nil if fields.nil? || fields.any? { _1.nil? || _1 == SessionRecord::Provenance::UNRECORDED }

          new(cwd: fields[0], root: fields[1], home: fields[2])
        end
      end

      # @param paths [Array<String>] session files
      # @param arms [Array<Arm>]
      # @param project [Place] where a session that recorded no place is replayed
      # @param labels [Labels] when labelled, {#report} scores the arms against it
      # @param tripwire [Array<Lain::Tripwire::Rules>] when any, {#report} ends with the tripwire
      #   replay under each
      # @return [ApprovalReplay]
      def self.from_journals(paths, arms:, project:, labels: Labels::NONE, tripwire: [])
        read = paths.to_h { [_1, Journal.records(File.foreach(_1)).to_a] }
        sessions = read.to_h { |path, records| [path, current_header(path, records)] }
        calls = read.flat_map { |path, records| Call.joined(records, session: path) }
        new(calls:, arms:, project:, labels:, tripwire:, sessions:)
      end

      # @raise [CLI::Refusal] for a header recording another session format
      def self.current_header(path, records)
        header = records.find { _1["type"] == SessionRecord::HEADER_TYPE }
        return header if header.nil? || SessionRecord.current_format?(header)

        raise CLI::Refusal, "#{path} is #{::Lain::CLI::Resume::Selector::OTHER_FORMAT}"
      end
      private_class_method :current_header

      # The replay `lain bench approval-replay` asks for: every approval level under every rule set.
      #
      # @param sessions [Array<String>] session files
      # @param approvals [Array<String, Symbol>] levels out of {LEVELS}
      # @param rules [Array<String>] rule set files; none means one arm per level with no rules
      # @param approver [String, Symbol] out of {APPROVERS}
      # @param project [Place]
      # @param labels [String, nil] a call-label sidecar; the report then scores each arm against it
      # @param denials [Array<String, Symbol>] judge-denial arms out of {CLI::Arms::JUDGE_DENIALS}, each
      #   replayed under every level and rule set; off by default
      # @param tripwire [Boolean] end the report with what the tripwire would have done to the sessions
      # @param tripwire_rules [Array<String>] `key=value` overrides of the default tripwire rules, one
      #   extra row each; naming any asks for the tripwire section
      # @return [ApprovalReplay]
      # @raise [CLI::Refusal] on an unknown level, approver or judge-denial arm, an arm asked for twice, a
      #   rule set that will not load, a labels file that will not, or a tripwire rule that does not parse
      def self.asked(sessions:, approvals:, rules:, approver:, project:, labels: nil, denials: %i[off],
                     tripwire: false, tripwire_rules: [])
        raise CLI::Refusal, "approval-replay needs at least one session file" if sessions.empty?

        checked(approvals, approver, labels)
        refuse_unknown(denials, ::Lain::CLI::Arms::JUDGE_DENIALS, "--judge-denials")
        from_journals(spelled_once(sessions), arms: once(arms_of(approvals, spelled_once(rules), approver, denials)),
                                              project:, labels: sidecar(labels),
                                              tripwire: armed(tripwire, tripwire_rules))
      rescue Config::Refusal => e
        raise CLI::Refusal, e.message
      end

      def self.armed(asked, specs) = asked || specs.any? ? Tripwire.rules_from(specs) : []

      # One file named two ways is the same file once.
      def self.spelled_once(paths) = paths.map { File.expand_path(_1) }.uniq

      def self.arms_of(approvals, rules, approver, denials)
        approvals.product(rules.empty? ? [nil] : rules, denials).map do |level, path, denied|
          Arm.new(approval: level.to_sym, rules_path: path, approver: approver.to_sym, denials: denied)
        end
      end

      def self.checked(approvals, approver, labels)
        refuse_unknown(approvals, LEVELS, "--approval")
        unless APPROVERS.include?(approver.to_sym)
          raise CLI::Refusal, "--approver is #{APPROVERS.join(", ")}, not #{approver}"
        end
        return unless approver.to_sym == :perfect && !labels

        raise CLI::Refusal, "--approver perfect answers by label: pass --labels"
      end

      def self.refuse_unknown(given, allowed, flag)
        unknown = given.map(&:to_s) - allowed.map(&:to_s)
        raise CLI::Refusal, "#{flag} is #{allowed.join(", ")}, not #{unknown.join(", ")}" if unknown.any?
      end

      def self.sidecar(path) = path ? Score.labels_from(path) : Labels::NONE

      def self.once(arms)
        twice = arms.tally.find { |_, count| count > 1 }&.first
        raise CLI::Refusal, "#{twice.name} is asked for twice; each arm is replayed once" if twice

        arms
      end
      private_class_method :armed, :spelled_once, :arms_of, :once, :sidecar, :checked, :refuse_unknown

      attr_reader :calls, :arms, :project, :sessions, :labels

      # @param calls [Array<Call>] in journal order, sessions one after another
      # @param arms [Array<Arm>] each once
      # @param project [Place]
      # @param sessions [Hash{String=>Hash, nil}] each session file read, by path, to its header
      # @param labels [Labels]
      # @param tripwire [Array<Lain::Tripwire::Rules>]
      # @raise [ArgumentError] on an arm given twice, whose rows no report could tell apart
      def initialize(calls:, arms:, project:, sessions: calls.to_h { [_1.session, nil] },
                     labels: Labels::NONE, tripwire: [])
        twice = arms.tally.select { _2 > 1 }.keys.map(&:name)
        raise ArgumentError, "an arm is given twice: #{twice.join(", ")}" if twice.any?

        @calls = calls.freeze
        @arms = arms.freeze
        @project = project
        @sessions = sessions.freeze
        @labels = labels
        @tripwire = tripwire
        raise ArgumentError, "a perfect arm answers by label and needs labels" if unlabelled_perfect?(arms, labels)

        @rules = arms.uniq(&:rules_path).to_h { [_1.rules_path, _1.rules] }
      end

      # @return [Array<Call>] the ruled calls that can be replayed: joined, and of a tool the stack holds
      def replayable = calls.select { _1.joined? && Stack.tool?(_1.tool) }

      # @return [Enumerator::Lazy<Row>] one per replayable call per arm, arm by arm
      def rows = (@rows ||= arms.flat_map { |arm| by_session.flat_map { rows_for(arm, _1) } }.freeze).lazy

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

      # @return [String] the replay, then each arm's score when labels were given, then the tripwire's
      #   when it was asked for
      def report
        "#{Report.new(self)}#{Score.new(rows:, labels:).table if labels.labelled?}" \
          "#{Tripwire.new(journals: sessions.keys, labels:, rules: @tripwire).report unless @tripwire.empty?}"
      end

      private

      def unlabelled_perfect?(arms, labels) = !labels.labelled? && arms.any? { _1.approver == :perfect }

      def by_session = replayable.group_by(&:session).values

      def rows_for(arm, calls)
        own = replayed(arm, calls)
        return own if arm.denied.empty?

        applied = replayed(arm.with(denials: :off), calls).to_h { [_1.tool_use_id, _1.prompted] }
        own.map { _1.with(extra_prompt: _1.prompted && !applied.fetch(_1.tool_use_id)) }
      end

      # Once per arm and session, since a judge-denial arm's rows are read against its off twin's.
      def replayed(arm, calls)
        (@replayed ||= {})[[arm, calls.first.session]] ||= replay(arm, calls)
      end

      def replay(arm, calls)
        place = calls.first.place || project
        rules, denied_tools = @rules.fetch(arm.rules_path)
        judge = RecordedJudge.new
        approver = Approver.for(arm.approver, calls, labels:)
        Stack.new(place:, arm:, judge:, rules:, denied_tools:).session(approver:) do |dispatch|
          calls.map { |call| row(arm, call.with(place:), judge, approver, dispatch).with(call_digest: call.digest) }
        end
      end

      def row(arm, call, judge, approver, dispatch)
        dispatched = judge.answering(call) { dispatch.call(call) }
        own = dispatched.records.select { _1["tool_use_id"] == call.tool_use_id }
        ruled = Call.ruling_of(own) || UNRULED
        Row.new(session: call.session, call_digest: call.digest, tool: call.tool, tool_use_id: call.tool_use_id,
                requester: call.requester, arm:, rung: ruled["rung"], rule: ruled["rule"],
                verdict: ruled.fetch("verdict"), **asked(approver, call.tool_use_id),
                state: dispatched.guessed ? "unknown" : "recorded", judge: judge.state, rerouted: rerouted?(own),
                extra_prompt: false)
      end

      def rerouted?(records)
        records.any? { _1["type"] == "escalation" && _1["rung"] == Approval::Judged::NAME && REROUTED.include?(_1["reason"]) }
      end

      def asked(approver, id) = { prompted: approver.prompted?(id), unanswered: approver.unanswered?(id) }
    end
  end
end
