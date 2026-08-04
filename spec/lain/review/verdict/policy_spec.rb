# frozen_string_literal: true

RSpec.describe Lain::Review::Verdict::Policy do
  # The narrowest duck a policy asks of a changeset, and it is deliberately the
  # SAME one `Marks#states` asks (`#base_ref`, `#hunks`) -- a policy reads the
  # tri-state through Marks and never derives it itself, so it cannot grow a
  # second, disagreeing derivation.
  def changeset(hunks:, base_ref: "base1") = Data.define(:base_ref, :hunks).new(base_ref:, hunks:)

  def hunk(path:, lines:)
    Lain::Review::Hunk.new(path:, old_start: 1, old_count: 1, new_start: 1, new_count: 1, lines:)
  end

  def marked(pairs, base_ref: "base1")
    pairs.reduce(Lain::Review::Marks.new(base_ref:)) { |marks, (key, state)| marks.mark(key, state) }
  end

  # a.rb has two hunks, b.rb one -- so "partially reviewed" is expressible for a
  # single file, which is what the card's own scenario asks for.
  let(:hunks) do
    [hunk(path: "a.rb", lines: ["+a"]), hunk(path: "a.rb", lines: ["+b"]), hunk(path: "b.rb", lines: ["+c"])]
  end
  let(:a_keys) { Lain::Review::Hunk.keys(hunks.select { |one| one.path == "a.rb" }) }
  let(:b_keys) { Lain::Review::Hunk.keys(hunks.select { |one| one.path == "b.rb" }) }
  let(:subject_changeset) { changeset(hunks:) }

  describe "the port itself" do
    it "refuses to judge on its own, because admissibility is what a subclass IS" do
      expect { described_class.new.admit!("approve", changeset: subject_changeset, marks: marked([])) }
        .to raise_error(NotImplementedError, /admit!/)
    end

    it "names EveryHunk as the policy a session takes when nobody says otherwise" do
      expect(described_class.default).to be_a(described_class::EveryHunk)
    end

    it "raises a Lain::Error subclass, so a CLI boundary renders it rather than crashing" do
      expect(described_class::Incomplete.ancestors).to include(Lain::Error)
    end
  end

  describe described_class::EveryHunk do
    subject(:policy) { described_class.new }

    it "refuses an approve over a partially reviewed file, naming that file" do
      marks = marked([[a_keys.first, "reviewed"], [b_keys.first, "reviewed"]])

      expect { policy.admit!("approve", changeset: subject_changeset, marks:) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete, /a\.rb/)
    end

    it "does not name a file that IS fully reviewed" do
      marks = marked([[a_keys.first, "reviewed"], [b_keys.first, "reviewed"]])

      expect { policy.admit!("approve", changeset: subject_changeset, marks:) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete) do |error|
          expect(error.message).not_to include("b.rb")
        end
    end

    it "names every unreviewed file when nothing has been marked at all" do
      expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([])) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete) do |error|
          expect(error.message).to include("a.rb").and include("b.rb")
        end
    end

    it "reports WHICH way each named file falls short, since partial and unreviewed call for different work" do
      marks = marked([[a_keys.first, "reviewed"]])

      expect { policy.admit!("approve", changeset: subject_changeset, marks:) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete) do |error|
          expect(error.message).to include("a.rb is partial").and include("b.rb is unreviewed")
        end
    end

    it "admits an approve once every hunk of every file is marked" do
      marks = marked((a_keys + b_keys).map { |key| [key, "reviewed"] })

      expect { policy.admit!("approve", changeset: subject_changeset, marks:) }.not_to raise_error
    end

    it "admits over a changeset with no hunks at all, because there is nothing left unreviewed" do
      expect { policy.admit!("approve", changeset: changeset(hunks: []), marks: marked([])) }.not_to raise_error
    end

    # The escape the `deferred` gate needs has to be REACHABLE from the refusal
    # itself: an unattended run that hits this wall gets one sentence, and the
    # sentence has to say what to swap.
    it "points at the swap rather than only at the wall" do
      expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([])) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete, /Permissive/)
    end

    # A work-scale changeset is thousands of files (research 3.7). Naming every
    # one of them turns a refusal into an unreadable wall, and the count is the
    # part a human acts on.
    it "caps how many files it names and says how many it did not" do
      many = (1..20).map { |number| hunk(path: format("f%02d.rb", number), lines: ["+#{number}"]) }

      expect { policy.admit!("approve", changeset: changeset(hunks: many), marks: marked([])) }
        .to raise_error(Lain::Review::Verdict::Policy::Incomplete) do |error|
          expect(error.message).to match(/\b#{20 - described_class::NAMED_LIMIT} more\b/)
        end
    end

    it "derives its 'reviewed' comparison from Marks::REVIEWED rather than restating the spelling" do
      expect(described_class::REVIEWED).to eq(Lain::Review::Marks::REVIEWED.to_sym)
    end

    it "refuses a base it was not recorded against, rather than judging across a base change" do
      marks = marked((a_keys + b_keys).map { |key| [key, "reviewed"] }, base_ref: "other")

      expect { policy.admit!("approve", changeset: subject_changeset, marks:) }
        .to raise_error(Lain::Review::Marks::BaseMismatch)
    end
  end

  describe described_class::Permissive do
    subject(:policy) { described_class.new }

    it "admits a verdict over a changeset nobody has reviewed at all" do
      expect { policy.admit!("approve", changeset: subject_changeset, marks: marked([])) }.not_to raise_error
    end

    it "is a Policy, so a session wired with one is wired with the same duck" do
      expect(policy).to be_a(Lain::Review::Verdict::Policy)
    end
  end

  describe Lain::Review::Verdict::None do
    it "is not nil, so no caller has to nil-check a verdict that has not been submitted" do
      expect(described_class).not_to be_nil
    end

    it "answers #empty? -- the ONE predicate a recorded verdict String answers too" do
      expect(described_class).to be_empty
      expect(Lain::Review::VERDICTS.first).not_to be_empty
    end

    it "renders as nothing at all, so an interpolating surface prints no placeholder" do
      expect("verdict: #{described_class}").to eq("verdict: ")
    end

    it "is not a member of the verdict vocabulary" do
      expect(Lain::Review::VERDICTS).not_to include(described_class)
    end
  end
end
