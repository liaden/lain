# frozen_string_literal: true

module Lain
  module Epic
    ReviewPack = Data.define(:layout, :scope_ids, :answers, :prior, :diff)

    # What an epic_review reviewer is told beside the documents: where its
    # wave sits among the epic's, what the human has already answered, and
    # what earlier rounds over the same scope found and read.
    #
    # `scope_ids` are the partitions a round's {ReviewResult#read} is keyed
    # by: the reviewed wave's issue ids, every issue id for an issue_plan of
    # no wave, and `epic_plan` for epic.md. `prior` holds, oldest first, every
    # earlier round of the epic that read any of them, and rounds are counted
    # per id, so neither a wider review nor a grown wave starts a count afresh.
    # No stage filter is needed: an issue id cannot contain the underscore in
    # `epic_plan` ({Home::NAME}), so the two stages never share a key.
    class ReviewPack
      Wave = Data.define(:number, :ids, :written)

      Answer = Data.define(:question, :answer)

      # `now` is each partition's gated digest as it stands. `shown` is the
      # digest of each document the latest round showed its reviewers, empty
      # unless that round parsed: a refused reviewer read nothing a later
      # round may lean on. `deleted` names those documents gone since.
      Diff = Data.define(:now, :shown, :deleted)

      EPIC_PLAN = "epic_plan"

      KNOWN = "A document unchanged since the previous round read it is shown below by its digest alone; every " \
              "other one in full."

      UNKNOWN = "What the previous round's reviewers read is not known, so every document below is shown in full."

      DELETED = "Deleted since the previous round: %<paths>s"

      # QuestionAnswered declares no type constant, so its type is read off the
      # class once, the way {Telemetry::Readers} reads every record's.
      ANSWERED = Telemetry::QuestionAnswered.allocate.journal_type

      UNWRITTEN = "An issue marked not written has no file yet, because its wave is written later: judge a " \
                  "reference to one against epic.md, and do not report it missing."

      # @param graph [Graph] the epic as it stands
      # @param home [Home] where its issue files live
      # @param journal [Enumerable<Hash>] journal records of any type, oldest first
      # @param stage [String] epic_plan or issue_plan
      # @param wave [Integer, nil] the reviewed wave, nil for every wave
      # @return [ReviewPack]
      def self.for(graph, home, journal, stage:, wave:)
        layout = layout(graph, home)
        scope = scope(layout, stage, wave)
        records = journal.to_a
        prior = rounds(records, home.slug, scope)
        shown = prior.last&.then { _1.parsed? ? _1.documents : nil } || {}
        new(layout:, scope_ids: scope, answers: answers(records, home.slug), prior:,
            diff: Diff.new(now: gated(graph, home, stage, scope), shown:,
                           deleted: shown.keys.reject { File.file?(File.join(home.path, _1)) }))
      end

      def self.layout(graph, home)
        graph.waves.each_with_index.map do |issues, index|
          ids = issues.map(&:id)
          Wave.new(number: index + 1, ids:, written: ids.select { home.issue(_1).exist? })
        end
      end

      def self.scope(layout, stage, wave)
        return [EPIC_PLAN] if stage == EPIC_PLAN

        layout.select { wave.nil? || _1.number == wave }.flat_map(&:ids)
      end

      def self.rounds(records, slug, scope)
        records.select { _1["type"] == ReviewResult::JOURNAL_TYPE }.map { ReviewResult.from_journal(_1) }
               .select { _1.epic_slug == slug && _1.read.keys.intersect?(scope) }
      end

      def self.answers(records, slug)
        records.select { _1["type"] == ANSWERED && _1["epic_slug"] == slug }
               .map { Answer.new(question: _1.fetch("question"), answer: _1.fetch("answer")) }
      end

      # Built the way epic_submit builds each {Submission}, so a review's
      # digests compare with the gate's.
      def self.gated(graph, home, stage, scope)
        return { stage => Submission.epic_plan(graph:, slug: home.slug).content_digest } if stage == EPIC_PLAN

        scope.to_h do |id|
          view = IssueView.new(issue: graph.fetch(id), graph:, authored: home.issue(id).read)
          [id, Submission.issue_plan(view:, slug: home.slug, issue_id: id).content_digest]
        end
      end

      private_class_method :layout, :scope, :rounds, :answers, :gated

      def initialize(layout:, scope_ids:, answers:, prior:, diff:)
        super(layout: layout.freeze, scope_ids: scope_ids.map { -_1.to_s }.freeze, answers: answers.freeze,
              prior: prior.freeze, diff:)
      end

      # A round whose closing blocks did not parse is a refused or broken
      # reviewer, which reviewed nothing, so it spends no round.
      #
      # @return [Hash{String=>Integer}] each scope id to how many earlier parsed rounds read it
      def rounds = scope_ids.to_h { |id| [id, settled.count { _1.read.key?(id) }] }

      # @return [Hash{String=>Integer}] each scope id to how many earlier rounds read it, parsed or not
      def attempts = scope_ids.to_h { |id| [id, prior.count { _1.read.key?(id) }] }

      # @param limit [Integer] the rounds of any outcome an id may have had
      # @return [Array<String>] the scope ids already read in that many rounds
      def exhausted(limit) = attempts.select { |_id, count| count >= limit }.keys

      # @return [Array<ReviewResult>] the earlier rounds that parsed, oldest first
      def settled = prior.select(&:parsed?)

      # @return [Array<String>] the scope ids no earlier parsed round read
      def unreviewed = rounds.select { |_id, count| count.zero? }.keys

      # @param limit [Integer] the rounds an id may have had
      # @return [Array<String>] the scope ids already read in that many rounds
      def spent(limit) = rounds.select { |_id, count| count >= limit }.keys

      # @return [String] the notes every reviewer reads before the documents
      def to_s = [where, *answered, *previous].join("\n\n")

      private

      def where
        lines = layout.map { |wave| "wave #{wave.number}: #{wave.ids.map { marked(wave, _1) }.join(", ")}" }
        ["# Where this review sits", covers, *lines, UNWRITTEN].join("\n")
      end

      def marked(wave, id) = "#{id} (#{wave.written.include?(id) ? "written" : "not written"})"

      def covers
        return "This review is of epic.md, and its verdict covers the epic graph." if scope_ids == [EPIC_PLAN]

        number = layout.find { _1.ids == scope_ids }&.number
        under = number ? "wave #{number} of #{layout.size}" : "every wave"
        "This review is of #{under}, and its verdict covers #{scope_ids.join(", ")} only."
      end

      def answered
        return [] if answers.empty?

        ["# What the human has answered\n\n#{answers.map { "Q: #{_1.question}\nA: #{_1.answer}" }.join("\n\n")}"]
      end

      def previous
        latest = prior.last
        return [] if latest.nil?

        ["# What the previous round found (#{latest.id}, #{latest.verdict})\n\n#{findings(latest)}",
         "# What changed since the previous round\n\n#{changes}"]
      end

      def findings(review)
        return [*review.verdict_lines, *review.must_fix.map { "- #{_1}" }].join("\n") unless review.parsed?

        "MUST-FIX:\n#{listed(review.must_fix)}\nMINOR:\n#{listed(review.minor)}"
      end

      def listed(lines) = lines.empty? ? "- none" : lines.map { "- #{_1}" }.join("\n")

      def changes
        return UNKNOWN if diff.shown.empty?

        [KNOWN, *(format(DELETED, paths: diff.deleted.join(", ")) unless diff.deleted.empty?)].join("\n")
      end
    end
  end
end
