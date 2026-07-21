# frozen_string_literal: true

module Lain
  module CLI
    # `lain improvements [--project <hash-or-path>] [--kind knob|bug|missing-feature|doc]`:
    # reads {Paths#improvements_path} -- the ONE cross-project file every
    # dogfood session's {Improvement::Sink} appends to -- and renders the
    # accumulated notes grouped by project then kind, so M6's offline pass
    # (and Joel, today) has a dogfood queue readable from any repo. Returns a
    # String; only the frontend prints (output discipline, {Bench::CLI}'s
    # precedent, {CLI::Friction}'s template).
    class Improvements
      # Kind-first canonical order within a project section, so the report
      # reads the same closed vocabulary every time regardless of which kind
      # a repo happened to log first -- {Improvement::KINDS} is already that
      # order.
      KIND_ORDER = Improvement::KINDS

      # {Paths#project_hash} is `sha256(expand_path)[0,12]` -- always exactly
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
        path = @paths.improvements_path
        records = filtered(read(path), project:, kind:)
        return empty_render(path) if records.empty?

        render(records)
      end

      private

      def read(path)
        return [] unless File.exist?(path)

        Journal.records(File.foreach(path), type: "improvement").to_a
      end

      def filtered(records, project:, kind:)
        by_project = project.nil? ? records : records.select { |r| r["project_hash"] == resolve_project(project) }
        kind.nil? ? by_project : by_project.select { |r| r["kind"] == kind }
      end

      def resolve_project(project)
        HASH_FORMAT.match?(project) ? project : @paths.project_hash(project)
      end

      def empty_render(path)
        "no improvements recorded yet -- looked for #{path}"
      end

      def render(records)
        by_project = records.group_by { |r| r["project_hash"] }
        sections = by_project.map { |project, project_records| project_section(project, project_records) }
        (["#{records.size} improvement(s) across #{by_project.size} project(s):"] + sections).join("\n\n")
      end

      def project_section(project, records)
        by_kind = records.group_by { |r| r["kind"] }
        ordered_kinds = KIND_ORDER.select { |kind| by_kind.key?(kind) }
        blocks = ordered_kinds.map { |kind| kind_block(kind, by_kind.fetch(kind)) }
        (["project #{project}:"] + blocks).join("\n")
      end

      def kind_block(kind, records)
        (["  #{kind}:"] + records.map { |record| note_line(record) }).join("\n")
      end

      def note_line(record)
        digests = record["evidence_digests"]
        evidence = digests.empty? ? "no evidence" : "evidence: #{digests.join(", ")}"
        "    - #{one_line(record["note"])} (#{evidence}) [session #{record["session"]}, #{record["at"]}]"
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
