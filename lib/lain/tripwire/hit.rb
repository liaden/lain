# frozen_string_literal: true

module Lain
  module Tripwire
    Hit = Data.define(:name, :weight, :tool_use_id, :count, :detail)

    # One thing a requester did that an honest call does not, read off a journal
    # record. Each reader takes a string-keyed record, the shape a session file
    # replays as, and answers the hits it holds, often none.
    #
    # Only what the model caused counts. A human's deny is not read at all,
    # since humans deny benign calls to test the surface, and neither is a
    # truncated exec record, whose lists are a prefix.
    class Hit
      LOADER = %r{\Ald(?:-linux[^/]*)?\.so(?:\.\d+)*\z}
      # A record holds every path it counted; the evidence names this many and the count.
      NAMED = 8

      # @param name [String]
      # @param weight [Symbol] one of {Rules::WEIGHTS}
      # @param tool_use_id [String, nil]
      # @param detail [Array<String>] the paths or reason behind it, each once
      # @param count [Integer] how many there were, though only the first {NAMED} are kept
      def initialize(name:, weight:, tool_use_id:, detail:, count: detail.size)
        super(name: -name, weight:, tool_use_id: tool_use_id&.then(&:-@), count:,
              detail: Ractor.make_shareable(detail.first(NAMED)))
      end

      # @return [Hash{String=>Object}] what a tripwire record's evidence holds
      def to_evidence
        { "signal" => name, "weight" => weight.to_s, "tool_use_id" => tool_use_id, "count" => count,
          "detail" => detail }
      end

      # The rungs' own refusals: a protected path is final whatever anyone
      # says, a remembered deny is a re-ask after a human's no, and the judge's
      # deny is weak because no session has yet shown one.
      #
      # @param record [Hash{String=>Object}] an `escalation` record
      # @return [Array<Hit>]
      def self.of_escalation(record)
        return [] unless record["verdict"] == "deny"

        named = escalation_hit(record)
        named ? [new(**named, tool_use_id: record["tool_use_id"], detail: [record["reason"].to_s])] : []
      end

      def self.escalation_hit(record)
        reason = record["reason"].to_s
        case record["rung"]
        when Approval::Escalation::Triage::NAME
          { name: "protected_path_deny", weight: :medium } if record["final"] && protected?(reason)
        when Middleware::RememberedDenials::RUNG then { name: "remembered_reask", weight: :medium }
        when Approval::Judged::NAME then { name: "judge_deny", weight: :weak } if reason == Approval::Judged::DENIED
        end
      end

      def self.protected?(reason) = reason.include?(Approval::Escalation::Triage::PROTECTED)

      # A plant: what a stage runs, or the script it hands an interpreter, was
      # written or changed during this lineage.
      #
      # @param record [Hash{String=>Object}] an `exec_resolution` record
      # @param resolution [Resolution] the same record's stages, read
      # @return [Array<Hit>]
      def self.of_resolution(record, resolution)
        id = record["tool_use_id"]
        [strong("fresh_program", id, resolution.fresh_programs),
         strong("fresh_run_file", id, resolution.fresh_run_files)].compact
      end

      # A loader or descriptor exec is a bypass shape under any trace, but any
      # process of the same user can write into a trace that does not confine,
      # so there it is medium. A refusal, and a program the call never
      # resolved, mean something only where the kernel confined the call.
      #
      # @param record [Hash{String=>Object}] an `exec_record` record
      # @param resolution [Resolution] what the same call resolved before it ran
      # @return [Array<Hit>]
      def self.of_exec_record(record, resolution)
        return [] if record["truncated"]

        id = record["tool_use_id"]
        confined = Confine::Profile.confines?(record["profile"])
        loaders = record["execs"].map { _1["path"] }.select { File.basename(_1).match?(LOADER) }
        bypass = [hit("fd_exec", id, record["fd_execs"].map { "#{_1["fd"]}:#{_1["path"]}" }, confined),
                  hit("loader_exec", id, loaders, confined)]
        return bypass.compact unless confined

        [*bypass, *confined_hits(record, resolution, loaders)].compact
      end

      # A refusal of a file the call's own unchanged toolchain resolves to is a
      # missing grant, and one its PATH search saw as not executable is the
      # shell trying a stray file; neither is probing.
      #
      # Only a confined trace starts at the fence, so only here is every stage's
      # first exec the launcher's own, the same program in each, and the
      # record's first names them all. A string command also runs under the
      # exec's own shell.
      def self.confined_hits(record, resolution, loaders)
        refused = refused(record).reject { resolution.toolchain?(_1) || resolution.skipped?(_1) }
        execs = record["execs"]
        expected = [execs.first&.fetch("path"), Exec::Local::SHELL, *loaders]
        ran = execs.select { _1["rc"].zero? }.map { _1["path"] } - expected
        [strong("refused_exec", record["tool_use_id"], refused),
         strong("unresolved_exec", record["tool_use_id"], ran.reject { resolution.ran?(_1) })]
      end

      # A bare descriptor's path is empty, and names no file.
      def self.refused(record) = record["refusals"].map { _1["path"] }.reject(&:empty?)

      def self.hit(name, id, detail, confined) = present(name, id, detail, confined ? :strong : :medium)

      def self.strong(name, id, detail) = present(name, id, detail, :strong)

      def self.present(name, id, detail, weight)
        new(name:, weight:, tool_use_id: id, detail: detail.uniq) unless detail.empty?
      end

      private_class_method :escalation_hit, :protected?, :confined_hits, :refused, :hit, :strong, :present
    end
  end
end
