# frozen_string_literal: true

module Lain
  module Epic
    ReviewResult = Data.define(:id, :epic_slug, :stage, :read, :documents, :verdict, :must_fix, :minor,
                               :verdict_lines)

    # What one epic_review round found, bound to the digests its reviewers
    # read, journaled as `epic_reviewed` and named by {#id}. epic_submit takes
    # that id rather than an agent's quote, so the gate question shows what the
    # reviewers said and whether they read the bytes the gate is about to sign.
    #
    # `read` maps each reviewed partition (an issue id, or `epic_plan` for
    # epic.md) to the content digest {Submission} gives it, the address the
    # gate signs. `documents` maps each file the reviewers were shown, named
    # from the epic home, to the digest of the text they were shown (masked
    # where a secret was), so a later round shows an unchanged one by digest
    # alone. `verdict` is approve, revise or unparsed; an unparsed review
    # keeps its raw verdict lines, or a note of how many critics did not
    # answer, plus the findings of the critics who did. It keeps no verdict or
    # count, because one read off a block that did not parse would be a guess.
    class ReviewResult
      include Telemetry::Journalable

      JOURNAL_TYPE = "epic_reviewed"

      UNPARSED = "unparsed"

      ID = /\Areview-\h{12}\z/

      # Session files outlive the record's shape, and a fold that raised on an
      # older line would cost a chat its review and submit tools; anything not
      # named here still raises, so a torn record stays loud.
      UNRECORDED = { "documents" => {} }.freeze

      UNKNOWN = "no review was journaled under %<id>s; pass the id epic_review returned"

      # @param findings [String] the merged critique, every cluster's closing block in it
      # @param epic_slug [String]
      # @param stage [String] epic_plan or issue_plan
      # @param read [Hash{String=>String}] partition to the gated content digest the reviewers read
      # @param documents [Hash{String=>String}] each file the reviewers were shown to the digest of its shown text
      # @param clusters [Integer] how many clusters were critiqued, each critic of each owing 1 block
      # @param critics [Integer] how many critics read each cluster
      # @return [ReviewResult]
      def self.parse(findings, epic_slug:, stage:, read:, clusters:, critics:, documents: {})
        # A child's reply is bytes nobody vouched for, and the id digests what is kept of it.
        findings = Utf8.legible(findings)
        identified(epic_slug:, stage:, read:, documents:, **shape(findings, clusters, critics))
      end

      def self.shape(findings, clusters, critics)
        readers = Closing.each_reader(findings, clusters, critics).to_a
        blocks = readers.compact
        silent = readers.size - blocks.size
        return unparsed(Closing.verdict_lines(findings)) if blocks.empty? || (silent.positive? && critics < 2)
        return unparsed(silent_note(silent), blocks) if silent.positive?

        { verdict: blocks.any? { _1.fetch(:verdict) == "revise" } ? "revise" : "approve",
          must_fix: blocks.flat_map { _1.fetch(:must_fix) }, minor: blocks.flat_map { _1.fetch(:minor) },
          verdict_lines: [] }
      end
      private_class_method :shape

      # An unparsed round still keeps what the critics who did answer found.
      def self.unparsed(verdict_lines, blocks = [])
        { verdict: UNPARSED, must_fix: blocks.flat_map { _1.fetch(:must_fix) },
          minor: blocks.flat_map { _1.fetch(:minor) }, verdict_lines: }
      end
      private_class_method :unparsed

      def self.silent_note(count) = ["#{count} #{count == 1 ? "critic" : "critics"} did not answer"]
      private_class_method :silent_note

      def self.identified(**fields)
        new(id: "review-#{Canonical.abbreviate(Canonical.digest(fields), scheme: false)}", **fields)
      end
      private_class_method :identified

      # A record from before `documents` was journaled knows none, so a
      # later round shows every document whole.
      #
      # @param record [Hash{String=>Object}] an `epic_reviewed` journal line
      # @return [ReviewResult]
      def self.from_journal(record)
        new(**members.to_h { [_1, record.fetch(_1.to_s) { |key| UNRECORDED.fetch(key) }] })
      end

      # @param records [Enumerable<Hash>] journal lines, of any type
      # @param id [String] a review id
      # @return [ReviewResult] the newest review journaled under the id
      # @raise [Unknown]
      def self.find(records, id)
        found = records.select { _1["type"] == JOURNAL_TYPE && _1["id"] == id }.last
        found ? from_journal(found) : raise(Unknown, format(UNKNOWN, id:))
      end

      def initialize(id:, epic_slug:, stage:, read:, verdict:, must_fix:, minor:, verdict_lines:, documents: {})
        super(id: -id.to_s, epic_slug: -epic_slug.to_s, stage: -stage.to_s, read: digests(read),
              documents: digests(documents), verdict: -verdict.to_s,
              must_fix: interned(must_fix), minor: interned(minor), verdict_lines: interned(verdict_lines))
      end

      def journal_type = JOURNAL_TYPE

      def parsed? = verdict != UNPARSED

      # @param submissions [Array<Submission>] what the gate asks about now
      # @return [Array<String>] the review's lines for the gate question, each finding whole on its own line
      def gate_lines(submissions)
        [headline, *submissions.map { "  #{against(_1)}" }, *findings]
      end

      private

      def digests(named) = named.to_h { |key, digest| [-key.to_s, -digest.to_s] }.freeze

      def interned(lines) = lines.map { -_1.to_s }.freeze

      def headline
        return "Review #{id} by epic_review: #{UNPARSED}, its closing block did not read" unless parsed?

        "Review #{id} by epic_review: #{verdict}, #{must_fix.size} must-fix, #{minor.size} minor"
      end

      def against(submission)
        key = submission.issue_id || submission.stage
        label = submission.issue_id ? "#{key}: " : ""
        reviewed = read[key]
        return "#{label}not read by this review" if reviewed.nil?

        gating = submission.content_digest
        return "#{label}reviewed #{short(reviewed)}: current" if reviewed == gating

        "#{label}reviewed #{short(reviewed)}, gating #{short(gating)}: stale"
      end

      def short(digest) = Canonical.abbreviate(digest, scheme: false)

      def findings
        return unparsed_lines unless parsed?

        [*must_fix.map { "  must-fix: #{legible(_1)}" }, ("  #{minor.size} minor, not shown" unless minor.empty?)]
          .compact
      end

      def unparsed_lines
        [*verdict_lines.map { "  #{legible(_1)}" }, *must_fix.map { "  must-fix: #{legible(_1)}" }]
      end

      def legible(line) = Utf8.escaped(line)

      # An id epic_submit refused before reading anything named by it.
      class Unknown < Error; end

      # The block each reviewer closes with: a must-fix list, a minor list and
      # a verdict, revise exactly when something must be fixed.
      module Closing
        MUST_FIX = "MUST-FIX:"
        MINOR = "MINOR:"
        VERDICT = "VERDICT:"
        NONE = "none"

        INSTRUCTION = <<~TEXT.freeze
          End with this block and nothing after it. Each heading stands on its own line, each finding is one line
          starting `- ` and naming its path, an empty list is `- #{NONE}`, and the verdict is `revise` exactly when
          #{MUST_FIX} lists something. For example, a review with one minor finding ends:

          #{MUST_FIX}
          - #{NONE}
          #{MINOR}
          - epic.md: wave 2's criteria name no command a human can run
          #{VERDICT} approve
        TEXT

        BLANK = /^[ \t]*\n/
        LIST = /#{BLANK}*(?:^[ \t]*- .*\n#{BLANK}*)+/
        LISTS = /^[ \t]*#{MUST_FIX}[ \t]*\n(?<must>#{LIST})[ \t]*#{MINOR}[ \t]*\n(?<minor>#{LIST})/
        BLOCK = /#{LISTS}[ \t]*#{VERDICT}[ \t]*(?<verdict>approve|revise)[ \t]*$/
        VERDICT_LINE = /^[ \t]*#{VERDICT}.*$/

        # The headings {Review::Critique} merges its findings under: one per
        # cluster, and when several critics read a cluster, a count line then
        # one heading per critic.
        CLUSTER = /^## cluster (\d+) of (\d+) -- .*$/
        CRITICS = /\A\s*(?:files: [^\n]*\n)?\s*(\d+) critics read this chunk[ \t]*\n/
        CRITIC = /^### critic (\d+)[ \t]*$/
        COUNT_LINE = /^[ \t]*\d+ critics read this chunk/

        # Counted per reader rather than across the text, so a reader that
        # writes 2 blocks, or echoes the example, cannot stand in for one that
        # wrote none. The layout must be the one the run produced, so a reader
        # cannot forge headings that cut or multiply its own text.
        #
        # @param text [String] the merged findings
        # @param clusters [Integer] how many clusters were critiqued
        # @param critics [Integer] how many critics read each cluster
        # @return [Array<Hash, nil>, nil] each reader's block, nil for a reader that wrote no single agreeing
        #   one, and nil altogether when the layout is not the one the run produced
        def self.each_reader(text, clusters, critics)
          return unless critics.positive?

          headings = text.scan(CLUSTER).map { |pair| pair.map(&:to_i) }
          return unless headings == (1..clusters).map { [_1, clusters] }

          readers = text.split(CLUSTER).drop(1).each_slice(3).map(&:last).map { readers(_1, critics) }
          return if readers.any?(&:nil?)

          readers.flatten.map { sole_block(_1) }
        end

        # @return [Array<String>, nil] each critic's text, nil unless the section is laid out for exactly `critics`
        def self.readers(section, critics)
          return sole_reader(section) if critics == 1
          return unless section[CRITICS, 1]&.to_i == critics

          lead, *sections = section.sub(CRITICS, "").split(CRITIC)
          numbered = sections.each_slice(2).to_a
          return unless lead.to_s.strip.empty? && numbered.map { _1.first.to_i } == (1..critics).to_a

          numbered.map { _1[1].to_s }
        end

        def self.sole_reader(section) = section.match?(COUNT_LINE) || section.match?(CRITIC) ? nil : [section]

        def self.sole_block(reader)
          return unless verdict_lines(reader).one?

          blocks(reader).find { agrees?(_1) }
        end

        # @param text [String] one reader's findings
        # @return [Array<Hash>] each block's verdict and lists, a list nil where it misuses `- none`
        def self.blocks(text)
          text.to_enum(:scan, BLOCK).map do
            match = Regexp.last_match
            { verdict: match[:verdict], must_fix: items(match[:must]), minor: items(match[:minor]) }
          end
        end

        def self.items(list)
          lines = list.lines.map(&:strip).reject(&:empty?).map { _1.delete_prefix("- ").strip }
          return [] if lines == [NONE]

          lines.include?(NONE) ? nil : lines
        end

        def self.agrees?(block)
          must, minor = block.values_at(:must_fix, :minor)
          !must.nil? && !minor.nil? && (block.fetch(:verdict) == "revise") == !must.empty?
        end

        def self.verdict_lines(text) = text.scan(VERDICT_LINE).map(&:strip)
      end
    end
  end
end
