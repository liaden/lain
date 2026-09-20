# frozen_string_literal: true

require "json"

module Lain
  module CLI
    # `lain improvements [--project <hash-or-path>] [--kind knob|bug|missing-feature|doc]`:
    # reads {Paths#improvements_path} -- the ONE cross-project file every
    # dogfood session's {Improvement::Sink} appends to -- and renders the
    # accumulated notes grouped by project then kind, so a later offline pass
    # (and Joel, today) has a dogfood queue readable from any repo. Returns a
    # String; only the frontend prints (output discipline, {Bench::CLI}'s
    # precedent, {CLI::Friction}'s template).
    class Improvements
      # A `--kind` outside {Improvement::KINDS}. Refused rather than filtered
      # on, because a filter that matches nothing renders the friendly "no
      # improvements recorded yet" line -- so a typo would report an EMPTY
      # STORE for a store that is not empty. Per the error-taxonomy
      # convention it subclasses {Lain::Error} beside the object that raises
      # it, so `LainCLI::Boundary#render` maps it to a clean nonzero exit with
      # no backtrace.
      class UnknownKind < Error; end

      # A `--project` this process cannot turn into a project hash at all --
      # SYNTACTICALLY unusable, which is a different question from whether the
      # directory exists. Held apart from {UnknownKind} because there is no
      # closed vocabulary to name back at the operator, only the two accepted
      # shapes.
      class UnusableProject < Error; end

      # A journaled record this report must read whole and cannot. Held apart
      # from the two above the way {EpicQueue::UnreadableRecord} is held apart
      # from its sibling: those say "you named the wrong thing", this one says
      # "the file is damaged", and the remedies are nothing alike.
      class UnreadableRecord < Error; end

      # What a `--project` narrowed the report to, and how to say it back.
      # The operator typed a path or a hash and the message says both, so a
      # refusal can be read without recomputing a sha256.
      Scope = Data.define(:given, :resolved) do
        def covers?(record) = record["project_hash"] == resolved

        def named = given == resolved ? given : "#{given} (project #{resolved})"
      end

      # No `--project` at all. A Null object rather than a nil, so neither the
      # filter nor the empty-store wording carries a `project.nil?` branch
      # somebody can forget on one of the two paths.
      module EveryProject
        def self.covers?(_record) = true

        def self.named = nil
      end

      # Kind-first canonical order within a project section, so the report
      # reads the same closed vocabulary every time regardless of which kind
      # a repo happened to log first -- {Improvement::KINDS} is already that
      # order.
      KIND_ORDER = Improvement::KINDS

      # {Paths#project_hash} is `sha256(realpath)[0,12]` (lexical expansion
      # only when the path does not exist to resolve) -- always exactly
      # 12 lowercase hex characters. A `--project` value that shape IS a
      # hash; anything else is a path this process resolves the same way
      # {Paths#project_hash} would for a live session in that repo.
      HASH_FORMAT = /\A[0-9a-f]{12}\z/

      def initialize(paths: Paths.new)
        @paths = paths
      end

      # @param project [String, nil] an explicit project hash, or a path
      #   resolved to one via {Paths#project_hash}
      # @param kind [String, nil] one of {Improvement::KINDS}
      # @return [String] the rendered report; never printed here
      def report(project: nil, kind: nil)
        assert_known_kind!(kind)
        scope = resolve_project(project)
        path = @paths.improvements_path
        scoped = read(path).select { |record| scope.covers?(record) }
        records = kind.nil? ? scoped : scoped.select { |r| r["kind"] == kind }
        return empty_render(path, scope:, scoped:, kind:) if records.empty?

        render(records)
      end

      private

      # Echoes {Improvement}'s own write-path wording, so the
      # kind a `improvement_write` refused and the kind this report refuses
      # read as one vocabulary rather than two.
      def assert_known_kind!(kind)
        return if kind.nil? || KIND_ORDER.include?(kind)

        raise UnknownKind, "--kind must be one of #{KIND_ORDER.inspect}, got #{kind.inspect}"
      end

      # Resolved ONCE, before the file is read. It used to resolve inside the
      # `select` block below: a SHA-256 and a `realpath` syscall per record for
      # a value that cannot vary, and -- worse -- that made this refusal
      # store-dependent, silent against an empty store and raising against a
      # populated one.
      #
      # `File.expand_path` raises ArgumentError on `~nosuchuser` and on a NUL
      # byte, and `HASH_FORMAT.match?` raises it on invalid UTF-8 before any
      # expansion is attempted. None of those is the SystemCallError {Paths}
      # rescues, so all three used to escape {Lain::Error} entirely. Whether
      # the directory EXISTS is deliberately not asked: a nonexistent path is
      # legal input here, and there is a spec pinning `--project /some/repo`.
      def resolve_project(project)
        return EveryProject if project.nil?

        raise UnusableProject, empty_project_message if project.empty?

        Scope.new(given: project, resolved: HASH_FORMAT.match?(project) ? project : @paths.project_hash(project))
      rescue ArgumentError => e
        raise UnusableProject, unusable_project_message(project, e)
      end

      def empty_project_message
        "--project was given an empty string, which would silently mean this process's working " \
          "directory. Pass a 12-hex-char project hash, or the path of the repo you mean."
      end

      def unusable_project_message(project, cause)
        "--project #{project.inspect} is not a usable project: #{cause.message}. " \
          "Pass a 12-hex-char project hash, or a path this process can expand."
      end

      # {Improvement::Sink} appends one whole line per record under O_APPEND,
      # so the only line a writer can be mid-way through is the LAST one, and
      # that one is tolerated: it is what a crash between the bytes and their
      # newline leaves, and the next append lands after it.
      #
      # Any line that is not JSON AT ALL with a whole record after it was
      # damaged by something else, and skipping it drops a dogfood note while
      # the report still reads as complete -- {Bench::Session::Lineages}'
      # torn-line rule, for its reason.
      def read(path)
        return [] unless File.exist?(path)

        lines = File.readlines(path)
        lines.each_with_index
             .filter_map { |line, index| record_in(path, line, index + 1, torn: index == lines.size - 1) }
             .select { |record| record["type"].to_s == "improvement" }
      end

      def record_in(path, line, number, torn:) = Journal.parse(line) || skipped(path, line, number, torn:)

      # nil for a blank line, for somebody else's record and for the torn
      # tail -- all three skipped, {Bench::Session::Lineages.refuse_torn}'s
      # shape. A blank line is the commonest accidental hand-edit to a file
      # whose own refusal invites the operator to repair a line in it, and no
      # note was lost to one. A valid-JSON NON-OBJECT is another writer's
      # record: {Journal.parse} answers nil for it exactly as it does for
      # damage, so only re-parsing tells the two apart.
      def skipped(path, line, number, torn:)
        return nil if line.strip.empty? || (torn && !line.end_with?("\n"))

        JSON.parse(line)
        nil
      rescue JSON::ParserError
        raise UnreadableRecord, damaged_line_message(path, number)
      end

      def damaged_line_message(path, number)
        "line #{number} of #{path} is not JSON, and it is a complete line -- " \
          "so no crash mid-append left it, and a dogfood note may have been lost. " \
          "Repair or delete that line in #{path}."
      end

      # Three emptinesses, three different places to send a reader. An empty
      # STORE says where it looked. A `--project` that matched nothing NAMES
      # the project: "no improvements recorded yet" over a store holding two
      # other projects' notes answers a question nobody asked, and is how a
      # mistyped `--project` passes for a clean dogfood queue. An empty KIND
      # against a non-empty scope says how many the filter passed over.
      def empty_render(path, scope:, scoped:, kind:)
        return "no #{kind} improvements among #{scoped.size} recorded" unless scoped.empty?
        return "no improvements recorded yet -- looked for #{path}" if scope.named.nil?

        "no improvements are recorded for #{scope.named} -- looked for #{path}"
      end

      def render(records)
        by_project = records.group_by { |r| r["project_hash"] }
        sections = by_project.map { |project, project_records| project_section(project, project_records) }
        (["#{records.size} improvement(s) across #{by_project.size} project(s):"] + sections).join("\n\n")
      end

      def project_section(project, records)
        by_kind = records.group_by { |r| r["kind"] }
        ordered_kinds = KIND_ORDER.select { |kind| by_kind.key?(kind) }
        assert_every_kind_known!(by_kind, ordered_kinds)
        blocks = ordered_kinds.map { |kind| kind_block(kind, by_kind.fetch(kind)) }
        (["project #{project}:"] + blocks).join("\n")
      end

      # `ordered_kinds` keeps only what the closed vocabulary knows, so a
      # damaged `kind` was dropped from the body while the header above had
      # already COUNTED it -- a project heading with no bullet under it, and
      # exit zero. That is exactly the "reports an empty store when it was
      # handed something it could not use" this class exists to refuse, so
      # guarding one damaged field and silently discarding another would be
      # worse than guarding neither: the loud refusal implies the report
      # validates records.
      def assert_every_kind_known!(by_kind, ordered_kinds)
        unknown = by_kind.keys - ordered_kinds
        return if unknown.empty?

        raise UnreadableRecord,
              damaged_record_message(by_kind.fetch(unknown.first).first,
                                     "carries kind #{unknown.first.inspect}, which is not one of " \
                                     "#{KIND_ORDER.inspect} -- the report cannot place it.")
      end

      def kind_block(kind, records)
        (["  #{kind}:"] + records.map { |record| note_line(record) }).join("\n")
      end

      def note_line(record)
        "    - #{one_line(record["note"])} (#{evidence(record)}) " \
          "[session #{record["session"]}, #{record["at"]}]"
      end

      def evidence(record)
        digests = record["evidence_digests"]
        assert_digest_list!(record, digests)

        digests.empty? ? "no evidence" : "evidence: #{digests.join(", ")}"
      end

      # {Improvement} always writes a list of digest Strings here, so anything
      # else was damaged after it was written. The element check is not
      # fussiness: `is_a?(Array)` alone let `[nil]` render as `(evidence: )`
      # and `[{"a" => 1}]` render as inspected Ruby inside the bullet -- both
      # silent, where the missing key at least announced itself as a
      # `NoMethodError` on `nil.empty?`.
      def assert_digest_list!(record, digests)
        return if digests.is_a?(Array) && digests.all?(String)

        raise UnreadableRecord,
              damaged_record_message(record, "carries #{digests.inspect} where its `evidence_digests` list of " \
                                             "digest strings must be -- the report cannot say what evidence " \
                                             "backs it.")
      end

      # `session` and `at` are what address ONE line in a cross-project file
      # thousands of records long -- the note may be 2048 bytes and repeat.
      # The fault clause says what the record CARRIES rather than what it
      # lacks, so a wrong-typed field cannot produce "carries no list (...)".
      def damaged_record_message(record, fault)
        "the improvement journaled at #{record["at"].inspect} in session #{record["session"].inspect} " \
          "(project #{record["project_hash"].inspect}) #{fault} " \
          "Repair or delete that line in #{@paths.improvements_path}."
      end

      # A note is free-form model/user prose (see {Improvement}'s own comment
      # on `note`) -- nothing stops it carrying `\n`/`\r\n`. This report's
      # bullet format is one record per physical line, so an embedded
      # newline is flattened to a space rather than left to split one
      # record's bullet across several report lines.
      def one_line(note)
        note.to_s.gsub(/\r\n|\r|\n/, " ")
      end
    end
  end
end
