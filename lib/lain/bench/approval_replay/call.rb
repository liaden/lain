# frozen_string_literal: true

module Lain
  module Bench
    class ApprovalReplay
      Call = Data.define(:session, :tool, :input, :tool_use_id, :requester, :child, :place, :rulings, :decisions,
                         :landings, :ambiguous)

      # One gated call out of a session file, joined to everything the file says about it: the
      # tool_use block that made it (in a main `turn` or a child's `child_turn`), every ruling a
      # rung journaled on it (`escalation`, and `read_refused` from the layer ahead of the gate),
      # the human's `approval_decision` verdicts in order, and where its `exec_resolution` says
      # each program landed.
      #
      # A ruled call whose block is missing is kept, with no input, so a report can say it was
      # not replayed rather than lose it; so is an id {Join} could not split between the calls
      # sharing it.
      class Call
        GATED = %w[escalation read_refused].freeze
        MAIN = Requester.main.name

        # @param records [Enumerable<Hash>] one session file's records, header first, as {Journal.records} reads them
        # @param session [String] the file's path
        # @return [Array<Call>] in the order the session first ruled each
        def self.joined(records, session:)
          records = records.to_a
          place = Place.recorded(records.find { _1["type"] == SessionRecord::HEADER_TYPE })
          Join.new(records).shares.map { of(_1, session:, place:) }
        end

        # The last ruling that was not an abstention: what decided the call.
        #
        # @param records [Enumerable<Hash>] in the order they were journaled
        # @return [Hash, nil] with `rung`, `rule` and `verdict`
        def self.ruling_of(records)
          records.filter_map { ruling(_1) }.reverse.find { _1["verdict"] != "abstain" }
        end

        def self.ruling(record)
          case record["type"]
          when "escalation" then record
          when "read_refused" then { "rung" => "read_refused", "rule" => record["reason"], "verdict" => "deny" }
          end
        end

        def self.of(share, session:, place:)
          said = share.records
          first = said.find { GATED.include?(_1["type"]) }
          block = share.block&.block
          new(session:, tool: block ? block["name"] : first["tool"], input: block&.fetch("input"),
              tool_use_id: share.id, requester: first["requester"] || MAIN, child: share.block&.child == true, place:,
              rulings: said.select { GATED.include?(_1["type"]) }, decisions: verdicts(said), landings: landings(said),
              ambiguous: share.ambiguous)
        end

        # A decision the clock or a stopped requester made is nobody's answer, so it is not replayed as one.
        def self.verdicts(said)
          said.select { _1["type"] == "approval_decision" && answered?(_1) }.map { _1["verdict"] }
        end

        def self.answered?(decision)
          decision["timed_out"] != true && decision["surface"] != Approval::Parked::Queue::ABANDONED_SURFACE
        end

        def self.landings(said)
          said.select { _1["type"] == "exec_resolution" }.flat_map { programs(_1["stages"]) }
              .select { _1["resolved"] && _1["realpath"] }.to_h { [_1["resolved"], _1["realpath"]] }
        end

        def self.programs(stages) = Array(stages).flat_map { [*programs(_1["wrappers"]), _1] }

        private_class_method :ruling, :of, :verdicts, :answered?, :landings, :programs

        def initialize(session:, tool:, input:, tool_use_id:, requester: MAIN, child: false, place: nil, rulings: [],
                       decisions: [], landings: {}, ambiguous: false)
          super
        end

        def joined? = !input.nil?

        # @return [String] what a label sidecar keys a call by
        def digest = Canonical.digest([tool, input, place&.cwd])

        # @return [Hash, nil] the ruling that decided the call live
        def recorded = self.class.ruling_of(rulings)

        # @return [Hash, nil] the judge's own ruling on the call, carrying the digests of what it read
        def judged = rulings.reverse.find { _1["rung"] == Approval::Judged::NAME }

        # @return [Float] seconds the judge took, from the ruling before its own; 0 when none came before
        #   or either carries no timestamp
        def judge_wait
          at = rulings.rindex { _1["rung"] == Approval::Judged::NAME }
          stamps = at&.positive? ? rulings.values_at(at - 1, at).map { _1["ts"] } : []
          stamps.size == 2 && stamps.all? ? Time.iso8601(stamps.last) - Time.iso8601(stamps.first) : 0.0
        end

        # @return [String, nil] the shell command a bash call ran
        def command = (input["command"] if tool == "bash" && input)
      end
    end
  end
end
