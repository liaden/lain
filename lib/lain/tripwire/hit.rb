# frozen_string_literal: true

module Lain
  module Tripwire
    Hit = Data.define(:name, :weight, :tool_use_id, :count, :detail, :at)

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
      REFUSED_ERRNOS = %w[EACCES EPERM].freeze
      INET = %w[AF_INET AF_INET6].freeze
      DNS_PORT = 53
      # The usrmerge links are root's, so a call cannot rewrite what a path through them reaches.
      SYSTEM = [*Confine::Profile::SYSTEM_EXEC, "/bin", "/sbin", "/lib", "/lib64"].freeze

      # @param name [String]
      # @param weight [Symbol] one of {Rules::WEIGHTS}
      # @param tool_use_id [String, nil]
      # @param detail [Array<String>] the paths or reason behind it, each once
      # @param count [Integer] how many there were, though only the first {NAMED} are kept
      # @param at [Float, nil] epoch seconds the record behind it was received or stamped at, nil when unknown
      def initialize(name:, weight:, tool_use_id:, detail:, count: detail.size, at: nil)
        super(name: -name, weight:, tool_use_id: tool_use_id&.then(&:-@), count:,
              detail: Ractor.make_shareable(detail.first(NAMED)), at:)
      end

      # @return [Hash{String=>Object}] what a tripwire record's evidence holds
      def to_evidence
        { "signal" => name, "weight" => weight.to_s, "tool_use_id" => tool_use_id, "count" => count,
          "detail" => detail }
      end

      JUDGE_DENY = { name: "judge_deny", weight: :weak }.freeze
      REMEMBERED_REASK = { name: "remembered_reask", weight: :medium }.freeze

      # The rungs' own refusals: a protected path is final whatever anyone
      # says, a remembered deny is a re-ask after a human's no (the clock's asked
      # nobody, and a record naming no authority counts, so a missing field errs
      # toward the alarm), and the judge's deny is weak because no session has
      # yet shown one. A judge deny handed to a human under `escalate_only` is
      # the same deny, so the evidence does not change with the arm.
      #
      # @param record [Hash{String=>Object}] an `escalation` record
      # @return [Array<Hit>]
      def self.of_escalation(record)
        named = record["verdict"] == "deny" ? escalation_hit(record) : escalated_deny(record)
        named ? [new(**named, tool_use_id: record["tool_use_id"], detail: [record["reason"].to_s])] : []
      end

      def self.escalated_deny(record)
        JUDGE_DENY if record["rung"] == Approval::Judged::NAME && record["reason"] == Approval::Judged::ESCALATED
      end

      def self.escalation_hit(record)
        reason = record["reason"].to_s
        case record["rung"]
        when Approval::Escalation::Triage::NAME
          { name: "protected_path_deny", weight: :medium } if record["final"] && protected?(reason)
        when Middleware::RememberedDenials::RUNG then REMEMBERED_REASK unless record["authority"] == "automatic"
        when Approval::Judged::NAME then JUDGE_DENY if reason == Approval::Judged::DENIED
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

      # A workspace call that created a persistence path the profile could not
      # seal, because it was absent, has planted what a later shell or git runs.
      # The check compares the path before and after the call, so it cannot
      # tell this call from another running at once in the same root, or from
      # the human, creating it in that window.
      #
      # @param record [Hash{String=>Object}] a `sandbox` record
      # @return [Array<Hit>]
      def self.of_sandbox(record)
        [strong("created_sealed", record["tool_use_id"], record.fetch("created_sealed", []))].compact
      end

      # A loader or descriptor exec is a bypass shape under any trace, but any
      # process of the same user can write into a trace that does not confine,
      # so there it is medium. A refusal, and a program the call never
      # resolved, mean something only where the kernel confined the call.
      #
      # @param record [Hash{String=>Object}] an `exec_record` record
      # @param resolution [Resolution] what the same call resolved before it ran
      # @param hidden [Array<String>] the toolchain files a workspace mounts empty, which no call can run
      # @return [Array<Hit>]
      def self.of_exec_record(record, resolution, hidden: [])
        return [] if record["truncated"]

        id = record["tool_use_id"]
        confined = Confine::Profile.confines?(record["profile"])
        loaders = record["execs"].map { _1["path"] }.select { File.basename(_1).match?(LOADER) }
        bypass = [hit("fd_exec", id, record["fd_execs"].map { "#{_1["fd"]}:#{_1["path"]}" }, confined),
                  hit("loader_exec", id, loaders, confined)]
        return bypass.compact unless confined

        [*bypass, *confined_hits(record, resolution, loaders, hidden)].compact
      end

      # A refusal of a file the call's own unchanged toolchain resolves to is a
      # missing grant, one its PATH search saw as not executable is the shell
      # trying a stray file, and one of a file lain hid is lain's own mask;
      # none is probing. A system program is one the profile grants and the
      # call cannot have planted, so a script running it is not a bypass.
      #
      # Only a confined trace is one the command cannot write into, so only
      # here can every stage's first exec be trusted as the launcher's own, the
      # same program in each, named by the record's first. A string command
      # also runs under the exec's own shell.
      def self.confined_hits(record, resolution, loaders, hidden)
        refused = refused(record).reject { refusal_excused?(resolution, hidden, _1) }
        execs = record["execs"]
        expected = [execs.first&.fetch("path"), Exec::Local::SHELL, *loaders]
        ran = execs.select { _1["rc"].zero? }.map { _1["path"] } - expected
        [strong("refused_exec", record["tool_use_id"], refused),
         strong("unresolved_exec", record["tool_use_id"], ran.reject { unresolved_excused?(resolution, _1) }),
         *network_hits(record)]
      end

      # The record is read after the call, which may since have swapped any
      # file it named, so a path is matched as the call spelled it and never
      # read off the disk.
      def self.refusal_excused?(resolution, hidden, path)
        resolution.toolchain?(path) || resolution.skipped?(path) || hidden.include?(lexical(path))
      end

      def self.unresolved_excused?(resolution, path)
        resolution.ran?(path) || resolution.launched_from_toolchain?(path) || system?(path)
      end

      def self.system?(path)
        spelled = lexical(path)
        !spelled.nil? && SYSTEM.any? { spelled.start_with?("#{_1}/") }
      end

      # A relative path was spelled against a cwd the record does not hold.
      def self.lexical(path) = (File.expand_path(path) if path.start_with?("/"))

      # A confined call holds no network grant it did not name, so a refused
      # connect is a probe, while a datagram send that got through is only
      # odd: DNS on port 53 is what an honest resolver does.
      def self.network_hits(record)
        id = record["tool_use_id"]
        connects = record.fetch("connects", [])
        [strong("refused_connect", id, refused_connects(connects)),
         hit("datagram_send", id, datagram_sends(connects), false)]
      end

      # The fence refuses a TCP fast open send with EPERM, so any refused inet call is a connect it stopped.
      # Port 53 is exempt: Landlock refuses an honest resolver's TCP fallback there, and nothing was sent.
      def self.refused_connects(connects)
        inet(connects).select { REFUSED_ERRNOS.include?(_1["errno"]) && _1["port"] != DNS_PORT }.map { named(_1) }
      end

      def self.datagram_sends(connects)
        inet(connects).select { _1["call"] != "connect" && _1["errno"].nil? && _1["port"] != DNS_PORT }
                      .map { named(_1) }
      end

      # A unix socket has no port; the resolver's own is refused on an honest lookup.
      def self.inet(connects) = connects.select { INET.include?(_1["family"]) }

      def self.named(connect)
        host = connect["family"] == "AF_INET6" ? "[#{connect["address"]}]" : connect["address"]
        "#{host}:#{connect["port"]}"
      end

      # A bare descriptor's path is empty, and names no file.
      def self.refused(record) = record["refusals"].map { _1["path"] }.reject(&:empty?)

      def self.hit(name, id, detail, confined) = present(name, id, detail, confined ? :strong : :medium)

      def self.strong(name, id, detail) = present(name, id, detail, :strong)

      def self.present(name, id, detail, weight)
        new(name:, weight:, tool_use_id: id, detail: detail.uniq) unless detail.empty?
      end

      private_class_method :escalation_hit, :escalated_deny, :protected?, :confined_hits, :network_hits,
                           :refusal_excused?, :unresolved_excused?, :system?, :lexical,
                           :refused_connects, :datagram_sends, :inet, :named, :refused, :hit, :strong, :present
    end
  end
end
