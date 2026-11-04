# frozen_string_literal: true

module Lain
  module Tools
    # Has fresh read-only reviewers critique an epic's documents before they
    # reach a gate, so the question a human is asked can show their verdict.
    # `issue_plan` reads the issue files one wave to a reviewer; `epic_plan`
    # reads `epic.md` whole. It returns the merged findings, writes no document,
    # and journals an {Epic::ReviewResult} whose id epic_submit takes.
    class EpicReview < Tool
      STAGES = %w[epic_plan issue_plan].freeze

      # A third round on the same scope rarely finds what two missed, and each
      # one costs a reviewer per wave, so the gate's human judges what is left.
      ROUNDS = 2

      # An unparsed round spends no round, so a reviewer that never closes its
      # block, or a provider that keeps refusing, would otherwise run forever.
      ATTEMPTS = 2 * ROUNDS

      # Beside the documents under review, every reviewer reads whichever of
      # these the home holds.
      CONTEXT = { "epic_plan" => %w[research.md SPEC.md], "issue_plan" => %w[epic.md research.md SPEC.md] }.freeze

      INSTRUCTIONS = <<~TEXT.freeze
        # Review the epic documents

        You are a fresh reviewer. Read the documents below as an implementer who has never seen the conversation
        that wrote them. Report what is ambiguous, missing, contradicted by the shared context or impossible to
        test from outside the object, each with the path it is in.

        #{Epic::ReviewResult::Closing::INSTRUCTION}
      TEXT

      BRIEF = "the %<what>s of the %<slug>s epic, reviewed before its %<stage>s gate"

      # Findings from many clusters are arbitrary text, so the merged reply is held
      # to the common result ceiling.
      BOUND = Tool::Bounds::Fill.new(limit: Tool::Bounds::CEILINGS.fetch("epic_review"), unit: "paragraphs",
                                     narrower: ["review one wave at a time with `wave`"])

      # The skills quote these lines, so a cut keeps them whole.
      VERDICT = /\bVERDICT:/

      CUT = "... truncated, withholding %<bytes>d bytes over the %<limit>d-byte ceiling%<advice>s"

      WAVE_ADVICE = " -- instead, review one wave at a time with `wave`"

      NO_EPIC = "there is no epic named `%<slug>s`; create it with epic_write first"

      NO_FINDINGS = "the critique returned no findings for %<stage>s of %<slug>s"

      NO_WAVE = "wave %<wave>d does not exist: the epic has %<count>d wave%<plural>s"

      CAPPED = "epic_review has already run %<rounds>d rounds over %<ids>s of %<slug>s; review them no more -- " \
               "call epic_submit with review %<id>s and quote its open findings to the human:\n%<open>s%<unreviewed>s"

      FAILING = "epic_review's reviewers have failed to return a verdict in %<attempts>d rounds over %<ids>s of " \
                "%<slug>s; run no more -- call epic_submit and tell the human the reviewers kept failing on these"

      FAILING_SINCE = "epic_review's reviewers have failed to return a verdict in the %<later>d rounds after " \
                      "review %<id>s over %<ids>s of %<slug>s; run no more -- call epic_submit with review %<id>s, " \
                      "quote its open findings to the human and tell them the later reviewers kept failing:\n%<open>s"

      UNREVIEWED = "\nnever reviewed: %<ids>s -- tell the human at the gate that no reviewer read these"

      HANDLE = "\n\nreview id: %<id>s -- pass it as `review` on epic_submit, and the gate shows this review"

      # One stage, one slug, and an optional wave for an issue_plan.
      class Input < Tool::Input
        field :stage, :string, required: true, description: "The gate to review before: #{STAGES.join(" or ")}."
        field :slug, :string, required: true, description: "The epic's slug."
        field :wave, :integer, description: "issue_plan only: review just this wave; omitted, every wave."

        validates :stage, inclusion: { in: STAGES, message: "must be one of #{STAGES.join(", ")}" }
        validate :wave_is_for_issue_plan

        private

        def wave_is_for_issue_plan
          errors.add(:wave, "is for stage issue_plan only") if wave && stage != "issue_plan"
        end
      end

      input_model Input

      # @param homes [#for, #journal, #review_results] answers `for(slug)` with that epic's home,
      #   `journal` with where each round's {Epic::ReviewResult} lands, and
      #   `review_results` with the journaled records earlier rounds and answers are read from
      # @param critique [#call] `(subject:, instructions:) -> String`, running a
      #   {Review::Critique} over the {Review::Critique::Documents} given
      # @param critics [Integer] how many critics the critique runs per cluster, which the merged findings
      #   must show; the chat's own critique runs {Review::Critique::DEFAULT_CRITICS}
      def initialize(homes:, critique:, critics: Review::Critique::DEFAULT_CRITICS)
        super()
        @homes = homes
        @critique = critique
        @critics = critics
      end

      def name = "epic_review"

      def description
        "Has fresh read-only reviewers critique an epic's documents before its gate and returns their findings, " \
          "each ending in a verdict. issue_plan reviews the issue files, a reviewer per wave; epic_plan, epic.md."
      end

      protected

      def perform(input, _invocation)
        home = @homes.for(input.slug)
        return Tool::Result.error(format(NO_EPIC, slug: input.slug)) unless home.epic.exist?

        Tool::Result.ok(reviewed(home, input))
      rescue Lain::Error, SystemCallError => e
        Tool::Result.error(e.message)
      end

      private

      def reviewed(home, input)
        clusters = clusters(home, input)
        pack = pack(home, input)
        refuse_spent!(pack, input)
        refuse_exhausted!(pack, input)
        subject = subject(home, input, clusters, pack)
        findings = findings(input, subject)
        result = Epic::ReviewResult.parse(findings, epic_slug: input.slug, stage: input.stage, read: pack.diff.now,
                                                    documents: subject.shown, clusters: clusters.size,
                                                    critics: @critics)
        @homes.journal << result
        bounded(findings, input, format(HANDLE, id: result.id))
      end

      def pack(home, input)
        Epic::ReviewPack.for(home.read_epic, home, @homes.review_results, stage: input.stage, wave: input.wave)
      end

      def findings(input, subject)
        @critique.call(subject:, instructions: INSTRUCTIONS) ||
          raise(Review::Critique::Refused, format(NO_FINDINGS, stage: input.stage, slug: input.slug))
      end

      def refuse_spent!(pack, input)
        spent = pack.spent(ROUNDS)
        return if spent.empty?

        latest = pack.settled.last
        raise Review::Critique::Refused, format(CAPPED, rounds: ROUNDS, ids: spent.join(", "), slug: input.slug,
                                                        id: latest.id, open: open_findings(latest),
                                                        unreviewed: unreviewed(pack))
      end

      def refuse_exhausted!(pack, input)
        exhausted = pack.exhausted(ATTEMPTS)
        return if exhausted.empty?

        raise Review::Critique::Refused, failing(pack, exhausted.join(", "), input.slug)
      end

      # A verdict that did come back still reaches the gate through its id.
      def failing(pack, ids, slug)
        latest = pack.settled.last
        return format(FAILING, attempts: ATTEMPTS, ids:, slug:) if latest.nil?

        format(FAILING_SINCE, later: pack.prior.size - pack.prior.index(latest) - 1, id: latest.id, ids:, slug:,
                              open: open_findings(latest))
      end

      def open_findings(review) = review.must_fix.empty? ? "- none" : review.must_fix.map { "- #{_1}" }.join("\n")

      def unreviewed(pack)
        ids = pack.unreviewed
        ids.empty? ? "" : format(UNREVIEWED, ids: ids.join(", "))
      end

      # Whole paragraphs from the front while they fit, a hard cut when the first
      # does not, and the verdict lines and the review id after the note either way.
      def bounded(findings, input, handle)
        return "#{findings}#{handle}" if BOUND.admits?(findings.bytesize + handle.bytesize)

        verdicts = findings.lines.map(&:strip).grep(VERDICT)
        tail = "#{"\n\nVerdicts:\n#{verdicts.join("\n")}" unless verdicts.empty?}#{handle}"
        note = format(CUT, bytes: findings.bytesize, limit: BOUND.limit, advice: advice(input))
        room = [BOUND.limit - note.bytesize - tail.bytesize - 2, 0].max
        "#{head(findings, room)}\n\n#{note}#{tail}"
      end

      def advice(input) = input.stage == "issue_plan" && input.wave.nil? ? WAVE_ADVICE : ""

      def head(findings, room)
        used = -2
        kept = findings.split("\n\n").take_while { |paragraph| (used += paragraph.bytesize + 2) <= room }
        kept.empty? ? findings.byteslice(0, room).scrub("") : kept.join("\n\n")
      end

      def subject(home, input, clusters, pack)
        Review::Critique::Documents.new(corpus: corpus(home), clusters:, shared: shared(home, input.stage),
                                        brief: brief(input), notes: pack.to_s, known: pack.diff.shown)
      end

      def clusters(home, input)
        return [cluster("epic", ["epic.md"])] if input.stage == "epic_plan"

        waves(home, input.wave).map do |number, issues|
          cluster("wave #{number}", issues.map { home.issue(_1.id).path.delete_prefix("#{home.path}/") })
        end
      end

      def cluster(label, paths) = Review::Critique::Documents::Cluster.new(label:, paths:)

      def waves(home, wanted)
        numbered = home.read_epic.waves.each_with_index.map { |issues, index| [index + 1, issues] }
        return numbered unless wanted

        numbered.select { |number, _issues| number == wanted }.tap do |chosen|
          raise Review::Critique::Refused, no_wave(wanted, numbered.size) if chosen.empty?
        end
      end

      def no_wave(wave, count) = format(NO_WAVE, wave:, count:, plural: count == 1 ? "" : "s")

      def shared(home, stage) = CONTEXT.fetch(stage).select { File.file?(File.join(home.path, _1)) }

      def brief(input)
        format(BRIEF, what: input.stage == "epic_plan" ? "epic graph" : "issue files", slug: input.slug,
                      stage: input.stage)
      end

      def corpus(home)
        Review::Source::Corpus.new(
          walk: Survey::Walk.new(root: home.path, sensitivity: Sensitivity.new(home: Dir.home, cwd: home.path)),
          projection: Survey::Projection.new(ledger: Sensitivity::Ledger.new)
        )
      end
    end
  end
end
