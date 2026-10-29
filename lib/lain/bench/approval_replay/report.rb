# frozen_string_literal: true

module Lain
  module Bench
    class ApprovalReplay
      # The replay read out: what was and was not replayed, one line per call per arm, how many
      # agree with the live record, and the calls whose verdict an arm changed against the arm
      # before it.
      class Report
        GAP = "%<session>s: cwd, root and policy unrecorded: replayed under the current project"
        CONFIGURED = "%<session>s: recorded under project config %<policy>s, which the replay does not read; " \
                     "pass its approval table with --rules"

        # What no session records enough of to rebuild, said once whatever was replayed.
        NOT_REPLAYED = ["the project's sensitivity and tests tables (the built-in table and no layout stand in)",
                        "BoardBuild.approving, the rule approving a command by what its programs resolve to",
                        "the judge-facts arm (the judge is asked with no facts and no request)",
                        "whether a session ran non-interactive, which no header records " \
                        "(each is replayed with a human attached)"].freeze

        # The policy digest of a project and a user with no config at all.
        UNCONFIGURED = SessionRecord::Provenance.policy_of(
          Project::Trust.new(root: File::SEPARATOR, sources: {}, record: nil),
          Project::Trust.new(root: File::SEPARATOR, sources: {}, record: nil, domain: Project::Trust::USER_DOMAIN)
        )

        # @param replay [ApprovalReplay]
        def initialize(replay)
          @replay = replay
          @calls = replay.replayable.to_h { [[_1.session, _1.tool_use_id], _1] }
        end

        def to_s = "#{[*head, *@replay.arms.flat_map { arm(_1) }, *changes].join("\n")}\n"

        private

        def head
          sessions = @replay.sessions.size
          ["approval replay: #{@replay.calls.size} gated calls in #{sessions} #{"session".pluralize(sessions)}: " \
           "#{@replay.replayable.size} replayed",
           "not replayed: #{NOT_REPLAYED.join("; ")}", *places, *left]
        end

        def places
          @replay.sessions.flat_map do |path, header|
            policy = header&.then { _1.fetch("provenance").fetch("policy") }
            [(format(GAP, session: named(path)) unless ApprovalReplay::Place.recorded(header)),
             (format(CONFIGURED, session: named(path), policy:) if policy && policy != UNCONFIGURED)].compact
          end
        end

        def left
          (@replay.calls - @replay.replayable).map do |call|
            "#{why_left(call)}: #{named(call.session)} #{call.tool_use_id} (#{call.tool})"
          end
        end

        def why_left(call)
          return "ambiguous, the id is shared by calls no record tells apart" if call.ambiguous

          call.joined? ? "not replayable" : "unjoined"
        end

        def arm(arm)
          rows = @replay.rows_of(arm)
          ["", label(arm), *rows.map { line(_1) },
           "  agrees with the live record: #{rows.count { agrees?(_1) }} of #{rows.size}",
           "  prompted: #{rows.count(&:prompted)}, #{rows.count(&:unanswered)} with no recorded answer",
           "  state unknown: #{rows.count { _1.state == "unknown" }} of #{rows.size}",
           *Rerouting.lines(arm, rows, indent: "  "), *drifted(rows)]
        end

        def line(row)
          marks = [("prompted" if row.prompted), ("no recorded answer, refused" if row.unanswered),
                   ("state unknown" if row.state == "unknown"), ("judge #{row.judge}" if row.judge)].compact
          "  #{named(row.session)} #{row.tool_use_id} #{row.tool} #{row.requester}: " \
            "#{ruled(row)}#{marks.map { " [#{_1}]" }.join}"
        end

        def ruled(row) = "#{row.verdict} by #{row.rung || "no rung"}#{" (rule #{row.rule})" if row.rule}"

        def agrees?(row)
          live = @calls.fetch(@replay.key(row)).recorded
          !live.nil? && [live["rung"], live["verdict"]] == [row.rung, row.verdict]
        end

        def drifted(rows)
          drifted = rows.select { _1.judge == "drifted" }.map { "#{named(_1.session)} #{_1.tool_use_id}" }
          drifted.empty? ? [] : ["  judge input drifted: #{drifted.join(", ")}"]
        end

        # Only arms one coordinate apart, so every change has the one cause.
        def changes
          @replay.arms.combination(2).select { one_apart?(*_1) }.flat_map do |before, after|
            changed = @replay.diff(before, after)
            ["", "#{label(before)} -> #{label(after)}", *changed.map { |was, now| change(was, before, now, after) },
             "  unchanged: #{@replay.rows_of(before).size - changed.size}"]
          end
        end

        def change(was, before, now, after)
          "  #{named(was.session)} #{was.tool_use_id} #{was.tool}: #{ruled(was)} [#{rules(before)}] -> " \
            "#{ruled(now)} [#{rules(after)}]"
        end

        def one_apart?(one, other) = one.to_h.one? { |field, value| other.to_h.fetch(field) != value }

        def label(arm) = [arm.approval, rules(arm), arm.approver, *arm.denied].join(" ")

        def rules(arm) = arm.rules_path ? spelled(arm.rules_path, @replay.arms.filter_map(&:rules_path)) : "no rules"

        def named(path) = spelled(path, @replay.sessions.keys)

        # A file by its name, or by its whole path when another file in play shares the name.
        def spelled(path, among)
          name = File.basename(path)
          among.uniq.one? { File.basename(_1) == name } ? name : path
        end
      end
    end
  end
end
