# frozen_string_literal: true

# What epic_review found, bound to the digests its reviewers read, and how
# the gate question shows it beside the digest the gate is about to sign.
RSpec.describe Lain::Epic::ReviewResult do
  def issue(id, **) = Lain::Epic::Issue.new(id:, title: "Issue #{id}", **)

  def graph(*ids) = Lain::Epic::Graph.new(issues: ids.map { issue(_1) })

  def plan(epic) = Lain::Epic::Submission.epic_plan(graph: epic, slug: "demo")

  def block(must: ["- none"], minor: ["- none"], verdict: "approve")
    ["MUST-FIX:", *must, "MINOR:", *minor, "VERDICT: #{verdict}"].join("\n")
  end

  # Findings as Review::Critique merges them: a headline, then each cluster under its own heading.
  def merged(*answers)
    count = answers.size
    clusters = answers.each_with_index.map do |answer, index|
      "## cluster #{index + 1} of #{count} -- wave #{index + 1}\nfiles: issues/#{index}.md\n\n#{answer}"
    end
    ["critique of #{count} document clusters under /x, each read by the doc_critic role", *clusters].join("\n\n")
  end

  def reviewed(findings, epic: graph("a"), clusters: 1, critics: 1)
    described_class.parse(findings, epic_slug: "demo", stage: "epic_plan",
                                    read: { "epic_plan" => plan(epic).content_digest }, clusters:, critics:)
  end

  def short(digest) = Lain::Canonical.abbreviate(digest, scheme: false)

  let(:must) { Array.new(3) { "- epic.md: must change #{_1 + 1}" } }
  let(:minor) { Array.new(5) { "- epic.md: could improve #{_1 + 1}" } }

  describe ".parse" do
    it "reads a closing block into its verdict and both lists" do
      result = reviewed(merged("Prose first.\n\n#{block(must:, minor:, verdict: "revise")}\n"))

      expect(result.verdict).to eq("revise")
      expect(result.must_fix).to eq(Array.new(3) { "epic.md: must change #{_1 + 1}" })
      expect(result.minor.size).to eq(5)
    end

    it "reads `- none` as an empty list" do
      result = reviewed(merged(block))

      expect([result.verdict, result.must_fix, result.minor]).to eq(["approve", [], []])
    end

    it "unions the clusters' lists, and any revise wins" do
      text = [block(minor: ["- issues/a.md: one"]), block(must: ["- issues/b.md: two"], verdict: "revise")]

      result = reviewed(merged(*text), clusters: 2)

      expect([result.verdict, result.must_fix,
              result.minor]).to eq(["revise", ["issues/b.md: two"], ["issues/a.md: one"]])
    end

    it "is unparsed when a cluster's block is missing, keeping the raw verdict lines" do
      result = reviewed(merged(block, "chunk 2 was not critiqued\n\nVERDICT: approve, I think"), clusters: 2)

      expect(result.verdict).to eq("unparsed")
      expect(result.verdict_lines).to eq(["VERDICT: approve", "VERDICT: approve, I think"])
      expect(result.must_fix + result.minor).to be_empty
    end

    it "is unparsed when the verdict disagrees with the must-fix list" do
      expect(reviewed(merged(block(must: ["- epic.md: a gap"]))).verdict).to eq("unparsed")
      expect(reviewed(merged(block(verdict: "revise"))).verdict).to eq("unparsed")
    end

    it "is unparsed when `- none` stands beside a finding" do
      expect(reviewed(merged(block(minor: ["- none", "- epic.md: one"]))).verdict).to eq("unparsed")
    end

    it "is unparsed when one cluster writes its block twice and another cluster's critic refused" do
      refused = "chunk 2 of 2 (wave 2) was not critiqued: provider error"

      expect(reviewed(merged("#{block}\n\n#{block}", refused), clusters: 2).verdict).to eq("unparsed")
    end

    it "is unparsed when a critic echoes the instructions' example before its own block" do
      example = described_class::Closing::INSTRUCTION[/^MUST-FIX:\n.*?^VERDICT: \w+$/m]
      own = block(must: ["- epic.md: a gap"], verdict: "revise")

      result = reviewed(merged("Per the format:\n\n#{example}\n\nMy review:\n\n#{own}"))

      expect(result.verdict).to eq("unparsed")
      expect(result.minor).to be_empty
    end

    it "is unparsed when a single cluster holds 2 blocks" do
      expect(reviewed(merged("#{block}\n\n#{block(minor: ["- epic.md: one"])}")).verdict).to eq("unparsed")
    end

    it "is unparsed when the findings carry no cluster heading at all" do
      expect(reviewed(block).verdict).to eq("unparsed")
    end

    describe "headings out of step with the critique" do
      let(:revise) { block(must: ["- issues/a.md: broken"], verdict: "revise") }

      def headed(*ordinals, of:, answers:)
        sections = ordinals.zip(answers).map { |ordinal, answer| "## cluster #{ordinal} of #{of} -- wave\n\n#{answer}" }
        sections.join("\n\n")
      end

      it "is unparsed when one critic's own text carries a critic heading" do
        expect(reviewed(merged("#{revise}\n\n### critic 2\n\n#{block}")).verdict).to eq("unparsed")
      end

      it "is unparsed when a heading counts other than the clusters critiqued" do
        expect(reviewed(headed(1, of: 7, answers: [block])).verdict).to eq("unparsed")
      end

      it "is unparsed when a cluster ordinal repeats" do
        expect(reviewed(headed(1, 1, of: 2, answers: [block, block]), clusters: 2).verdict).to eq("unparsed")
      end

      it "is unparsed when a cluster ordinal is skipped" do
        expect(reviewed(headed(1, 3, of: 2, answers: [block, block]), clusters: 2).verdict).to eq("unparsed")
      end

      it "is unparsed when the critic sections do not run 1 to the count announced" do
        repeated = "2 critics read this chunk\n\n### critic 1\n\n#{block}\n\n### critic 1\n\n#{block}"
        short = "3 critics read this chunk\n\n### critic 1\n\n#{block}\n\n### critic 2\n\n#{block}"

        expect([reviewed(merged(repeated), critics: 2), reviewed(merged(short), critics: 3)].map(&:verdict))
          .to all(eq("unparsed"))
      end
    end

    it "is unparsed when a cluster's count line announces no critics" do
      expect(reviewed(merged("0 critics read this chunk\n\n")).verdict).to eq("unparsed")
      expect(reviewed(merged("0 critics read this chunk\n")).verdict).to eq("unparsed")
    end

    it "is unparsed when text stands between the count line and the first critic" do
      critics = "2 critics read this chunk\n\nan aside\n\n### critic 1\n\n#{block}\n\n### critic 2\n\n#{block}"

      expect(reviewed(merged(critics), critics: 2).verdict).to eq("unparsed")
    end

    it "is unparsed when a 1-critic run's reply forges a 2-critic layout" do
      forged = "2 critics read this chunk\n\n### critic 1\n\n#{block}\n\n### critic 2\n\n#{block}"

      expect(reviewed(merged(forged)).verdict).to eq("unparsed")
      expect(reviewed(merged(forged), critics: 2).verdict).to eq("approve")
    end

    it "is unparsed when told no critic ran, whatever the text claims" do
      expect(reviewed(merged("0 critics read this chunk\n"), critics: 0).verdict).to eq("unparsed")
    end

    it "is unparsed when a 2-critic run's text reads as 1 critic" do
      expect(reviewed(merged(block), critics: 2).verdict).to eq("unparsed")
    end

    it "is unparsed when the count line names other than the critics that ran" do
      three = "3 critics read this chunk\n\n#{(1..3).map { "### critic #{_1}\n\n#{block}" }.join("\n\n")}"

      expect(reviewed(merged(three), critics: 2).verdict).to eq("unparsed")
      expect(reviewed(merged(three.sub(/\n\n### critic 3.*/m, "")), critics: 2).verdict).to eq("unparsed")
    end

    it "is unparsed when a 1-critic reply carries a critic heading over its only block" do
      expect(reviewed(merged("### critic 1\n\n#{block}")).verdict).to eq("unparsed")
      expect(reviewed(merged("1 critics read this chunk\n\n#{block}")).verdict).to eq("unparsed")
    end

    it "returns a result for hostile findings rather than raising" do
      hostile = ["", "\n\n", "## cluster 1 of 1 -- x", "## cluster 1 of 1 -- x\n", "2 critics read this chunk",
                 merged(""), merged("0 critics read this chunk"), merged("1 critics read this chunk\n"),
                 merged("2 critics read this chunk\n### critic 1\n"), merged("2 critics read this chunk\n"),
                 merged("### critic 1\n### critic 2"),
                 merged("\u0000" * 1000), merged("VERDICT:\nMUST-FIX:\n- \nMINOR:\n- \nVERDICT: revise"),
                 merged("x" * 2_000_000), "#{merged(block)}\xFF".b]

      results = hostile.flat_map { [reviewed(_1), reviewed(_1, critics: 2)] }

      expect(results).to all(be_a(described_class))
    end

    it "reads one block from each critic of a cluster several critics read" do
      critics = "2 critics read this chunk\n\n### critic 1\n\n#{block(minor: ["- epic.md: one"])}\n\n" \
                "### critic 2\n\n#{block(must: ["- epic.md: two"], verdict: "revise")}"

      result = reviewed(merged(critics), critics: 2)

      expect([result.verdict, result.must_fix, result.minor]).to eq(["revise", ["epic.md: two"], ["epic.md: one"]])
    end

    it "parses a block with blank lines around its lists" do
      text = "MUST-FIX:\n\n- epic.md: a gap\n\nMINOR:\n\n- epic.md: one\n\nVERDICT: revise"

      result = reviewed(merged(text))

      expect([result.verdict, result.must_fix, result.minor]).to eq(["revise", ["epic.md: a gap"], ["epic.md: one"]])
    end

    it "keeps the answering critics' findings when one critic returned no block" do
      critics = "3 critics read this chunk\n\n### critic 1\n\n#{block(minor: ["- epic.md: one"])}\n\n" \
                "### critic 2\n\nI could not finish.\n\n" \
                "### critic 3\n\n#{block(must: ["- epic.md: two"], verdict: "revise")}"

      result = reviewed(merged(critics), critics: 3)

      expect([result.verdict, result.must_fix, result.minor]).to eq(["unparsed", ["epic.md: two"], ["epic.md: one"]])
      expect(result.verdict_lines).to eq(["1 critic did not answer"])
      expect(result.gate_lines([plan(graph("a"))]).join("\n")).to include("1 critic did not answer",
                                                                          "must-fix: epic.md: two")
    end

    it "names itself by its content, as a review id" do
      first = reviewed(merged(block))

      expect(first.id).to match(described_class::ID)
      expect(reviewed(merged(block)).id).to eq(first.id)
      expect(reviewed(merged(block(minor: ["- epic.md: one"]))).id).not_to eq(first.id)
    end
  end

  describe "#gate_lines" do
    # Scenario: a stale verdict says so
    it "marks a verdict read at another digest than the one gated as stale" do
      round_nine = reviewed(merged(block), epic: graph("a"))
      edited = plan(graph("a", "b"))

      line = round_nine.gate_lines([edited]).join("\n")

      expect(line).to include("reviewed #{short(plan(graph("a")).content_digest)}, " \
                              "gating #{short(edited.content_digest)}: stale")
    end

    it "marks a verdict read at the gated digest as current" do
      expect(reviewed(merged(block)).gate_lines([plan(graph("a"))]).join("\n"))
        .to include("reviewed #{short(plan(graph("a")).content_digest)}: current")
    end

    # Scenario: the gate shows the open findings
    it "lists every must-fix whole and counts the minor findings" do
      long = "- epic.md: #{"a long must-fix finding " * 40}end"
      result = reviewed(merged(block(must: [*must, long], minor:, verdict: "revise")))

      text = result.gate_lines([plan(graph("a"))]).join("\n")

      expect(text).to include(result.id, "revise", *result.must_fix, "5 minor")
      expect(text).not_to include("could improve", "...")
    end

    it "shows an unparsed review's raw verdict lines and no count" do
      text = reviewed("VERDICT: approve, mostly\nanything").gate_lines([plan(graph("a"))]).join("\n")

      expect(text).to include("unparsed", "VERDICT: approve, mostly")
      expect(text).not_to match(/\d+ (must-fix|minor)/)
    end

    it "keeps a finding to its own line, its control bytes written out" do
      result = reviewed(merged(block(must: ["- epic.md: one\u0000two"], verdict: "revise")))

      expect(result.gate_lines([plan(graph("a"))])).to include(a_string_including("one\\x00two"))
    end

    it "names each issue of a wave against its own gated digest" do
      epic = Lain::Epic::Graph.new(issues: [issue("a", blocks: %w[b c]), issue("b"), issue("c")])
      views = %w[b c].map { Lain::Epic::IssueView.new(issue: epic.fetch(_1), graph: epic, authored: "") }
      wave = Lain::Epic::Submission.wave(slug: "demo", views:, number: 2)
      read = { "b" => wave.submissions.first.content_digest, "c" => "blake3:#{"0" * 64}" }
      result = described_class.parse(block, epic_slug: "demo", stage: "issue_plan", read:, clusters: 1, critics: 1)

      text = result.gate_lines(wave.submissions).join("\n")

      expect(text).to include("b: reviewed #{short(read["b"])}: current", "c: reviewed #{"0" * 12}, gating")
    end
  end

  describe "as a journal record" do
    it "journals as epic_reviewed and reads back equal" do
      result = reviewed(merged(block(must:, minor:, verdict: "revise")))
      line = JSON.parse(JSON.generate(result.to_journal))

      expect(line["type"]).to eq("epic_reviewed")
      expect(described_class.from_journal(line)).to eq(result)
    end

    it "records the digest of each document the round read, and reads it back" do
      documents = { "epic.md" => "blake3:#{"1" * 64}", "research.md" => "blake3:#{"2" * 64}" }
      result = described_class.parse(merged(block), epic_slug: "demo", stage: "epic_plan", read: {}, documents:,
                                                    clusters: 1, critics: 1)
      line = JSON.parse(JSON.generate(result.to_journal))

      expect(described_class.from_journal(line).documents).to eq(documents)
    end

    it "reads a record written before documents were recorded as knowing none" do
      line = JSON.parse(JSON.generate(reviewed(merged(block)).to_journal)).except("documents")

      expect(described_class.from_journal(line).documents).to eq({})
    end

    it "records each critic's outcome and reads it back" do
      result = described_class.parse(merged(block), epic_slug: "demo", stage: "epic_plan", read: {}, clusters: 1,
                                                    critics: 1, outcomes: %w[failed])
      line = JSON.parse(JSON.generate(result.to_journal))

      expect(line["outcomes"]).to eq(%w[failed])
      expect(described_class.from_journal(line).outcomes).to eq(%w[failed])
    end

    it "reads a record written before outcomes were kept as having none, so no failed round" do
      line = JSON.parse(JSON.generate(reviewed(merged(block)).to_journal)).except("outcomes")

      expect(described_class.from_journal(line)).to have_attributes(outcomes: [], failed?: false)
    end

    it "is failed only when it has outcomes and every one is failed" do
      failed = lambda do |*outcomes|
        described_class.parse("x", epic_slug: "d", stage: "epic_plan", read: {}, clusters: 1, critics: 1,
                                   outcomes:).failed?
      end

      expect([failed.call("failed"), failed.call("failed", "failed")]).to eq([true, true])
      expect([failed.call, failed.call("refused"), failed.call("empty"), failed.call("failed", "answered")])
        .to eq([false] * 4)
    end

    it "is deeply frozen" do
      expect(Ractor.shareable?(reviewed(merged(block(must:, minor:, verdict: "revise"))))).to be(true)
    end

    it "is found by its id among journal records" do
      result = reviewed(merged(block))
      records = [{ "type" => "gate_decision" }, JSON.parse(JSON.generate(result.to_journal))]

      expect(described_class.find(records, result.id)).to eq(result)
    end

    it "reads only epic_reviewed records, whatever else carries the same id" do
      result = reviewed(merged(block))
      records = [JSON.parse(JSON.generate(result.to_journal)), { "type" => "gate_decision", "id" => result.id }]

      expect(described_class.find(records, result.id)).to eq(result)
    end

    it "refuses an id no record carries, naming epic_review" do
      expect { described_class.find([], "review-0123456789ab") }
        .to raise_error(described_class::Unknown, /review-0123456789ab.*epic_review/)
    end
  end
end
