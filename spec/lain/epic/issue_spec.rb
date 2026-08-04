# frozen_string_literal: true

# One issue in an epic's graph, as a deeply frozen content-addressed value. The
# laws that matter here are totality (every constructible Issue either survives
# the epic-markdown round-trip or is refused loudly at construction) and digest
# stability (edge insertion order is not meaning, so it cannot move the digest;
# prose and criteria source ARE meaning, so they must).
RSpec.describe Lain::Epic::Issue do
  def issue(**overrides)
    described_class.new(id: "a", title: "Do the thing", **overrides)
  end

  let(:criteria_source) do
    <<~GHERKIN
      ```gherkin
      Scenario: the fold is deterministic
        Given a journal
        Then the fold is deterministic
      ```
    GHERKIN
  end

  let(:other_criteria_source) do
    <<~GHERKIN
      ```gherkin
      Scenario: the fold is loud
        Given a journal naming an unknown issue
        Then the fold raises
      ```
    GHERKIN
  end

  describe "defaults" do
    it "starts pending with no criteria, no edges, and no provenance" do
      value = issue

      expect(value).to have_attributes(status: "pending", criteria: nil, description: "",
                                       blocks: [], related: [], discovered_from: nil)
    end
  end

  # AC: construction refuses reserved characters loudly.
  describe "loud construction guards -- the reserved epic-markdown grammar" do
    it "refuses an id containing a backtick, naming the field, the value, and the grammar" do
      expect { issue(id: "bad`id") }
        .to raise_error(Lain::Epic::MalformedIssue, /issue id.*"bad`id".*reserved.*backtick/m)
    end

    it "refuses an id containing a line break" do
      expect { issue(id: "one\ntwo") }
        .to raise_error(Lain::Epic::MalformedIssue, /issue id.*reserved/m)
    end

    it "refuses a blocks edge whose id breaks the grammar, naming the value" do
      expect { issue(blocks: ["ok", "bad`id"]) }
        .to raise_error(Lain::Epic::MalformedIssue, /"bad`id".*reserved/m)
    end

    it "refuses a discovered_from id that breaks the grammar" do
      expect { issue(discovered_from: "bad`id") }
        .to raise_error(Lain::Epic::MalformedIssue, /"bad`id".*reserved/m)
    end

    # NIT (panel): the message blamed the backtick delimiters for a line break,
    # which is half the pattern and the wrong half.
    it "names the grammar the offending character actually breaks" do
      expect { issue(id: "one\ntwo") }
        .to raise_error(Lain::Epic::MalformedIssue, /one-line/)
      expect { issue(id: "bad`id") }
        .to raise_error(Lain::Epic::MalformedIssue, /backtick/)
    end

    it "refuses an empty title" do
      expect { issue(title: "") }.to raise_error(Lain::Epic::MalformedIssue, /empty/)
    end

    it "refuses a title containing a line break, naming the value" do
      expect { issue(title: "line1\nline2") }
        .to raise_error(Lain::Epic::MalformedIssue, /line1.*line2/m)
    end

    it "refuses a title with leading or trailing whitespace (the grammar trims it)" do
      expect { issue(title: "  indented") }.to raise_error(Lain::Epic::MalformedIssue, /whitespace/)
      expect { issue(title: "trailing ") }.to raise_error(Lain::Epic::MalformedIssue, /whitespace/)
    end

    it "refuses a title ending in a brace group, which the grammar reserves" do
      expect { issue(title: "Do the thing {digest}") }
        .to raise_error(Lain::Epic::MalformedIssue, /\{/)
    end
  end

  # AC: stored status "ready" is refused.
  describe "the stored status set" do
    it "excludes ready, which the graph derives" do
      expect(Lain::Epic::STORED_STATUSES).to eq(%w[pending in_flight done abandoned])
    end

    it "refuses ready, listing the stored statuses and naming ready as derived" do
      expect { issue(status: "ready") }
        .to raise_error(Lain::Epic::MalformedIssue,
                        /ready.*derived.*pending.*in_flight.*done.*abandoned/m)
    end

    it "refuses an unknown status, listing the stored statuses" do
      expect { issue(status: "wip") }
        .to raise_error(Lain::Epic::MalformedIssue,
                        /"wip".*pending.*in_flight.*done.*abandoned/m)
    end

    it "accepts every stored status" do
      Lain::Epic::STORED_STATUSES.each do |status|
        expect(issue(status:).status).to eq(status)
      end
    end
  end

  # AC: edge order cannot change the digest.
  describe "edge normalization" do
    it "gives two issues differing only in blocks order the same digest" do
      one = issue(blocks: %w[z m a])
      other = issue(blocks: %w[a z m])

      expect(one.digest).to eq(other.digest)
    end

    it "sorts and deduplicates both edge sets" do
      value = issue(blocks: %w[z a z], related: %w[q b q])

      expect(value.blocks).to eq(%w[a z])
      expect(value.related).to eq(%w[b q])
    end

    it "leaves the array the caller passed alone" do
      edges = %w[z a]
      issue(blocks: edges)

      expect(edges).to eq(%w[z a])
      expect(edges).not_to be_frozen
    end
  end

  # AC: the value is deeply frozen.
  describe "immutability" do
    # Every field interpolated, because string interpolation returns a MUTABLE
    # String and that is the documented way this invariant has broken before.
    # The panel's probe covered this; its fixture no longer constructs (its
    # criteria were fence-less), so the coverage lives here instead.
    it "is deeply frozen and Ractor-shareable with every field mutable on the way in" do
      n = 7
      value = described_class.new(id: "a#{n}", title: "t#{n}", description: "d#{n}",
                                  status: +"pending", criteria: +criteria_source,
                                  blocks: ["b#{n}"], related: ["r#{n}"], discovered_from: "x#{n}")

      expect(value).to be_deeply_frozen
      expect(value.to_h.values.compact.flatten).to all(be_frozen)
    end

    it "returns a new value from #with_status rather than mutating" do
      value = issue
      done = value.with_status("done")

      expect(value.status).to eq("pending")
      expect(done.status).to eq("done")
      expect(done.id).to eq(value.id)
    end
  end

  # AC: criteria text is value-bearing and its digest derives.
  describe "gherkin criteria" do
    it "gives two issues differing only in criteria source different digests" do
      one = issue(criteria: criteria_source)
      other = issue(criteria: other_criteria_source)

      expect(one.digest).not_to eq(other.digest)
      expect(one.digest).not_to eq(issue.digest)
    end

    it "derives #criteria_digest from the source text" do
      expect(issue(criteria: criteria_source).criteria_digest)
        .to eq(Lain::Gherkin::Criteria.parse(criteria_source).digest)
      expect(issue(criteria: other_criteria_source).criteria_digest)
        .to eq(Lain::Gherkin::Criteria.parse(other_criteria_source).digest)
    end

    it "carries the source verbatim so a later fence round-trips" do
      expect(issue(criteria: criteria_source).criteria).to eq(criteria_source)
    end

    it "has no criteria digest without criteria" do
      expect(issue.criteria_digest).to be_nil
    end
  end

  # FIX 1 (panel BLOCKER). Gherkin::Parse only sees scenarios inside a
  # ```gherkin fence, so fence-less criteria parse to ZERO scenarios and
  # #criteria_digest returns the digest of an empty scenario list -- a
  # valid-looking content address that every malformed issue shares. The
  # likeliest author mistake is the one that fails silently, so criteria are
  # parsed at construction and both failure modes are MalformedIssue.
  describe "criteria totality -- a fence-less block is not empty criteria, it is a mistake" do
    let(:empty_digest) { Lain::Gherkin::Criteria.new(scenarios: []).digest }

    it "refuses fence-less criteria, naming the fence it needs" do
      expect { issue(criteria: "Scenario: x\n  Given y\n  Then z") }
        .to raise_error(Lain::Epic::MalformedIssue, /```gherkin fence/)
    end

    it "refuses every source that would address as the empty-scenario digest" do
      ["Scenario: x\n  Given y", "", "   ", "no gherkin here at all", "```\nScenario: x\n```"]
        .each do |fenceless|
          expect { issue(criteria: fenceless) }
            .to raise_error(Lain::Epic::MalformedIssue), "expected #{fenceless.inspect} to be refused"
        end
    end

    it "never lets a constructible issue carry the empty-scenario address" do
      expect(issue(criteria: criteria_source).criteria_digest).not_to eq(empty_digest)
    end

    it "surfaces an unparseable fenced block as MalformedIssue, not a Gherkin error" do
      expect { issue(criteria: "```gherkin\nGiven no scenario\n```\n") }
        .to raise_error(Lain::Epic::MalformedIssue, /clause outside any Scenario/)
    end

    # The contract T4 depends on: the delimiters are part of the stored source,
    # so re-emitting `criteria` verbatim re-emits a parseable fence.
    it "keeps the fence delimiters in the stored source" do
      expect(issue(criteria: criteria_source).criteria).to include("```gherkin")
      expect(Lain::Gherkin::Criteria.parse(issue(criteria: criteria_source).criteria).count).to eq(1)
    end
  end

  # FIX 2 (panel). `nil.to_s` is the silent coercion the doctrine forbids: an
  # empty id is a duplicate-"" collision in T2's graph and an unnamed file in
  # T9's home. It also leaves `nil` as the one spelling of an absent
  # discovered_from.
  describe "identifier totality" do
    it "refuses a nil id rather than coercing it to an empty String" do
      expect { issue(id: nil) }.to raise_error(Lain::Epic::MalformedIssue, /issue id.*nil/m)
    end

    it "refuses an empty id" do
      expect { issue(id: "") }.to raise_error(Lain::Epic::MalformedIssue, /issue id.*empty/m)
    end

    it "refuses a whitespace-only id" do
      expect { issue(id: "  ") }.to raise_error(Lain::Epic::MalformedIssue, /issue id.*whitespace/m)
    end

    it "refuses an id with leading or trailing whitespace" do
      expect { issue(id: " a") }.to raise_error(Lain::Epic::MalformedIssue, /whitespace/)
      expect { issue(id: "a ") }.to raise_error(Lain::Epic::MalformedIssue, /whitespace/)
    end

    it "refuses an empty edge id, naming which edge set carried it" do
      expect { issue(blocks: ["", "b"]) }.to raise_error(Lain::Epic::MalformedIssue, /blocks edge.*empty/m)
      expect { issue(related: [nil]) }.to raise_error(Lain::Epic::MalformedIssue, /related edge.*nil/m)
    end

    it "leaves nil as the one spelling of an absent discovered_from" do
      expect { issue(discovered_from: "") }
        .to raise_error(Lain::Epic::MalformedIssue, /discovered_from.*empty/m)
      expect(issue(discovered_from: nil).discovered_from).to be_nil
    end

    it "refuses a nil description rather than coercing it, while still defaulting to empty" do
      expect { issue(description: nil) }.to raise_error(Lain::Epic::MalformedIssue, /description.*nil/m)
      expect(issue.description).to eq("")
    end

    it "refuses a nil status rather than coercing it to an unknown one" do
      expect { issue(status: nil) }.to raise_error(Lain::Epic::MalformedIssue, /status.*nil/m)
    end
  end

  # FIX 3 (panel). A NoMethodError escapes the Lain::Error -> Thor::Error
  # mapping in exe/lain and names neither the field nor the value.
  describe "edge sets are Arrays, loudly" do
    it "is a Lain::Error, so exe/lain renders it instead of crashing" do
      expect(Lain::Epic::MalformedIssue.ancestors).to include(Lain::Error)
    end

    it "refuses nil edges, naming the field and the value" do
      expect { issue(blocks: nil) }
        .to raise_error(Lain::Epic::MalformedIssue, /blocks.*Array.*nil/m)
    end

    it "refuses a bare String for an edge set rather than iterating it" do
      expect { issue(related: "b") }
        .to raise_error(Lain::Epic::MalformedIssue, /related.*Array.*"b"/m)
    end
  end

  # FIX 4 (panel). Same shape as the BLOCKER: passes its own constructor, then
  # fails its own content-addressing. Canonical is what hashes these bytes, so
  # anything Canonical refuses must not be constructible.
  describe "text that cannot be content-addressed" do
    it "refuses invalid-UTF-8 prose at construction rather than at digest time" do
      expect { issue(description: "\xff\xfe".b) }
        .to raise_error(Lain::Epic::MalformedIssue, /UTF-8/)
    end

    it "refuses invalid bytes in every text field" do
      { id: "\xff".b, title: "\xff".b, description: "\xff".b, criteria: "\xff".b,
        blocks: ["\xff".b], related: ["\xff".b], discovered_from: "\xff".b }
        .each do |field, value|
          expect { issue(field => value) }
            .to raise_error(Lain::Epic::MalformedIssue, /UTF-8/), "expected #{field} to be refused"
        end
    end

    it "digests every issue it lets you construct" do
      value = issue(description: "prose", criteria: criteria_source, blocks: %w[b], discovered_from: "d")

      expect { value.digest }.not_to raise_error
      expect { value.criteria_digest }.not_to raise_error
    end

    # Encoding is settled before ids are deduplicated, so one id cannot survive
    # under two spellings and reach T2's graph as two nodes.
    it "settles edge encoding before dedup, so one id is one id" do
      expect(issue(blocks: ["b", "b".b]).blocks).to eq(%w[b])
      expect(issue(blocks: ["b".b]).blocks.map(&:encoding)).to eq([Encoding::UTF_8])
    end
  end

  # FIX 5 (panel). The id grammar is genuinely shared with Plan -- both wrap ids
  # in backticks in markdown -- and the title rules merely coincide today. The
  # extracted collaborator both grammars should depend on is owed (it would
  # touch lib/lain/plan/step.rb, outside this card), so drift is pinned here
  # instead: the constant directly, the titles behaviorally.
  describe "the markdown identifier grammar shared with Plan" do
    def admits?
      yield
      true
    rescue Lain::Error
      false
    end

    it "reserves exactly the characters Plan::Step reserves in an id" do
      expect(Lain::Epic::ID_RESERVED).to eq(Lain::Plan::ID_RESERVED)
    end

    it "agrees with Plan::Step on which titles the markdown grammar admits" do
      titles = ["ok", "", "  lead", "trail ", "a\nb", "a\rb", "ends {in braces}", "{braces} lead",
                "has `backtick`", "a { b } c", "-- dashes --", "  "]

      drifted = titles.reject do |title|
        admits? { Lain::Plan::Step.new(id: "s", title:, size: "S") } ==
          admits? { described_class.new(id: "a", title:) }
      end

      expect(drifted).to be_empty
    end
  end

  describe "#canonical" do
    it "is a String-keyed wire form with a stable shape" do
      expect(issue.canonical.keys)
        .to contain_exactly("id", "title", "description", "status", "criteria", "blocks", "related",
                            "discovered_from")
    end

    it "carries the criteria source itself, not its digest" do
      expect(issue(criteria: criteria_source).canonical["criteria"]).to eq(criteria_source)
    end

    it "makes description value-bearing" do
      expect(issue(description: "one").digest).not_to eq(issue(description: "two").digest)
    end
  end

  # T10: Issue is where BOTH downstream grammars are answered together -- the
  # document grammar Document::Writer refuses, and the filesystem grammar
  # Home::NAME refuses for issues/<id>.md -- so a value can be checked before
  # either one raises at a distance.
  describe "emittability" do
    it "is emittable when both the document and the filesystem grammar accept it" do
      value = issue(description: "fine.", criteria: criteria_source)

      expect(value).to be_emittable
      expect(value.emittable_failures).to be_empty
    end

    # AC: a filesystem-hostile id is named at the issue.
    it "is not emittable when the id is valid for the document grammar but invalid for Home::NAME" do
      value = issue(id: "Upper-Case")

      expect(Lain::Epic::Home::NAME).not_to match(value.id)
      expect(value).not_to be_emittable
      expect(value.emittable_failures.join).to include("filesystem grammar")
    end

    it "names the document grammar when the description would not survive Writer's round trip" do
      value = issue(description: "trailing space.  ")

      expect(value).not_to be_emittable
      expect(value.emittable_failures.join).to include("document grammar")
    end

    it "names the document grammar when the criteria would not survive Writer's round trip" do
      value = issue(criteria: criteria_source.chomp)

      expect(value).not_to be_emittable
      expect(value.emittable_failures.join).to include("document grammar")
    end

    it "reports both grammars at once when both are broken" do
      value = issue(id: "Upper-Case", description: "trailing space.  ")

      expect(value.emittable_failures.size).to eq(2)
    end

    it "keys document_grammar_failures by field, so Writer can ask about one at a time" do
      value = issue(description: "trailing space.  ", criteria: criteria_source.chomp)

      expect(value.document_grammar_failures.keys).to contain_exactly("description", "criteria")
    end
  end

  # Equality is one of the Regular laws; the shared group pins structural
  # equality, the eql?/hash agreement, and Hash-key + Set-dedup behavior
  # together instead of restating them by hand.
  describe "equality (Regular)" do
    include_examples "a Regular value",
                     equal_pair: -> { [issue(blocks: %w[z a]), issue(blocks: %w[a z])] },
                     unequal: -> { issue(id: "b") },
                     non_member: -> { "a" }
  end
end
