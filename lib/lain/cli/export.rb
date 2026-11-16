# frozen_string_literal: true

module Lain
  module CLI
    # `lain export <session>`: the conversation a session holds, as one HTML
    # document over its whole resume chain, or as the one file's applied record
    # stream. Returns a String and only the frontend prints, the way {Friction}
    # does. Nothing is re-scanned: the files already hold placeholders where a
    # read was masked, and this reads them.
    class Export
      FORMATS = %i[html jsonl].freeze

      # @param selector [String] resolved through {SessionFile}
      # @param paths [Paths]
      # @param project [Project]
      # @param records [#call] the Journal reader, given raw lines, of the one file or of the whole chain
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
      # @raise [Lain::Error] for an html export of no turns, of released reads without `include_released`,
      #   or to an existing `out`
      # @raise [SessionFile::SessionNotFound]
      def call(format: :html, out: nil, include_released: false, force: false)
        raise ArgumentError, "unknown export format #{format.inspect}, expected one of #{FORMATS.join(", ")}" \
          unless FORMATS.include?(format)

        document = format == :html ? html_document(include_released) : render_jsonl
        out.nil? ? document : write(out, document, force)
      end

      # @return [Integer] regions the model was shown in clear after a release
      def released = redactions.released

      # @return [Integer] regions masked as placeholders, the count the html footer shows
      def masked = redactions.masked

      private

      def html_document(include_released)
        page = html
        raise Lain::Error, "this session has no turns; nothing was exported or shared" if page.empty?

        refuse_released unless include_released || released.zero?
        page.render
      end

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

      def html = Html.new(records: chain_applied, redactions:, home: Dir.home, root: @project.root.to_s)

      def render_jsonl
        kept = file_applied.to_h { |record| [record, true] }.compare_by_identity
        Jsonl.new(lines: parseable.zip(parsed).filter_map { |line, record| line if kept.key?(record) }).render
      end

      def parseable = lines.select { |line| Journal.parse(line) }

      def lines = @lines ||= File.foreach(file, chomp: true).to_a

      def file = @file ||= SessionFile.resolve(@selector, paths: @paths, project: @project)

      # The html and its counts read every file of the chain: a resumed session's turns and
      # released reads sit in the earlier files, and the jsonl stays the one file `qa-lain verify` checks.
      def chain_lines
        @chain_lines ||= Resume::ChainWalk.new(paths: @paths, dir: File.dirname(file)).entries(file).map(&:chomp)
      rescue Errno::ENOENT => e
        raise Lain::Error, "an earlier file of the resume chain is missing (#{e.message[/ - (.+)\z/, 1]}), so the " \
                           "released count cannot be read across the chain; nothing was exported or shared"
      end

      def parsed = @parsed ||= @records.call(lines).to_a

      def chain_parsed = @chain_parsed ||= @records.call(chain_lines).to_a

      def redactions
        @redactions ||= Journal::Projection::Redactions.over(chain_applied.map { |record| counted(record) })
      end

      def counted(record)
        Telemetry.read(record, strict: Journal::Projection::Redactions::COUNTED.include?(record["type"]))
      end

      def chain_applied = @chain_applied ||= SessionRecord.applied(chain_parsed)

      def file_applied = SessionRecord.applied(parsed)
    end
  end
end
