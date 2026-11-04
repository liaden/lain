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

      # @param homes [#for, #journal] answers `for(slug)` with that epic's home, and
      #   `journal` with where each round's {Epic::ReviewResult} lands
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
        read = gated(home, input)
        findings = findings(home, input, clusters)
        result = Epic::ReviewResult.parse(findings, epic_slug: input.slug, stage: input.stage, read:,
                                                    clusters: clusters.size, critics: @critics)
        @homes.journal << result
        bounded(findings, input, format(HANDLE, id: result.id))
      end

      def findings(home, input, clusters)
        @critique.call(subject: documents(home, input, clusters), instructions: INSTRUCTIONS) ||
          raise(Review::Critique::Refused, format(NO_FINDINGS, stage: input.stage, slug: input.slug))
      end

      # The content digest each reviewed document's gate signs, built the way
      # epic_submit builds its {Epic::Submission}, so the two compare.
      def gated(home, input)
        if input.stage == "epic_plan"
          return { input.stage => Epic::Submission.epic_plan(graph: home.read_epic, slug: home.slug).content_digest }
        end

        waves(home, input.wave).flat_map(&:last).to_h do |issue|
          view = Epic::IssueView.read(home, issue.id)
          [issue.id, Epic::Submission.issue_plan(view:, slug: home.slug, issue_id: issue.id).content_digest]
        end
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

      def documents(home, input, clusters)
        Review::Critique::Documents.new(corpus: corpus(home), clusters:,
                                        shared: shared(home, input.stage), brief: brief(input))
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
