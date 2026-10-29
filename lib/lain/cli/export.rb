# frozen_string_literal: true

module Lain
  module CLI
    # `lain export <session>`: the conversation a session file holds, as one HTML
    # document or as its applied record stream. Returns a String and only the
    # frontend prints, the way {Friction} does. Nothing is re-scanned: the file
    # already holds placeholders where a read was masked, and this reads that file.
    class Export
      FORMATS = %i[html jsonl].freeze

      # @param selector [String] resolved through {SessionFile}
      # @param paths [Paths]
      # @param project [Project]
      # @param records [#call] the Journal reader, given the file's raw lines
      def initialize(selector:, paths:, project:, records: Journal.method(:records))
        @selector = selector
        @paths = paths
        @project = project
        @records = records
      end

      # @param format [Symbol] :html or :jsonl
      # @param out [String, nil] a path to write instead of returning the document
      # @param include_released [Boolean] let an html export carry a session that released reads
      # @param force [Boolean] overwrite an existing `out`
      # @return [String] the document, or `out` when it was written there
      # @raise [ArgumentError] for a format that is not exported
      # @raise [Lain::Error] for an html export of released reads without `include_released`, or an existing `out`
      # @raise [SessionFile::SessionNotFound]
      def call(format: :html, out: nil, include_released: false, force: false)
        raise ArgumentError, "unknown export format #{format.inspect}, expected one of #{FORMATS.join(", ")}" \
          unless FORMATS.include?(format)

        refuse_released if format == :html && !include_released && released.positive?
        document = send(:"render_#{format}")
        out.nil? ? document : write(out, document, force)
      end

      # @return [Integer] regions the model was shown in clear after a release
      def released
        applied.sum { |record| record["type"] == "read_released" ? record.fetch("regions") : 0 }
      end

      # @return [Integer] regions masked as placeholders, the count the html footer shows
      def masked = applied.sum { |record| Html::REDACTIONS.include?(record["type"]) ? record.fetch("regions") : 0 }

      private

      def refuse_released
        raise Lain::Error, "#{released} regions were released to the model in this session and appear in clear; " \
                           "pass --include-released to export them in the html"
      end

      def write(out, document, force)
        File.unlink(out) if force && (File.symlink?(out) || File.exist?(out))
        File.open(out, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(document) }
        out
      rescue Errno::EEXIST
        raise Lain::Error, "#{out} exists; pass --force to overwrite it"
      end

      def render_html = Html.new(records: applied, released:, home: Dir.home, root: @project.root.to_s).render

      def render_jsonl
        kept = applied.to_h { |record| [record, true] }.compare_by_identity
        Jsonl.new(lines: parseable.zip(parsed).filter_map { |line, record| line if kept.key?(record) }).render
      end

      def parseable = lines.select { |line| Journal.parse(line) }

      def lines
        @lines ||= File.foreach(SessionFile.resolve(@selector, paths: @paths, project: @project), chomp: true).to_a
      end

      def parsed = @parsed ||= @records.call(lines).to_a

      def applied = @applied ||= SessionRecord.applied(parsed)
    end
  end
end
