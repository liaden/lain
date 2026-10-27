# frozen_string_literal: true

# A Grader::Fixture is a deterministic task: a named bundle of HARD assertions
# over some subject, scored pass/fail with no model in the loop. Its verdict is
# a pure function of the subject, so scoring the same subject twice is the same
# Grade -- which is what lets Compare treat a fixture score as a real metric and
# speculative branching argmax over it.
RSpec.describe Lain::Grader::Fixture do
  # A tiny subject so the fixture's own behavior is visible without dragging a
  # whole run in.
  subject_struct = Struct.new(:steps, :identical)

  def fixture
    described_class.new("byte-stable replay") do |f|
      f.check("reconstructs two model calls") { |s| s.steps == 2 }
      f.check("replays byte-identically", &:identical)
    end
  end

  it "scores 1.0 and passes when every criterion holds" do
    grade = fixture.grade(subject_struct.new(2, true))

    expect(grade.score).to eq(1.0)
    expect(grade).to be_pass
  end

  it "scores the fraction met and fails when any criterion misses" do
    grade = fixture.grade(subject_struct.new(2, false))

    expect(grade.score).to eq(0.5)
    expect(grade).not_to be_pass
  end

  it "explains itself: #why names each failing criterion" do
    grade = fixture.grade(subject_struct.new(3, false))

    expect(grade.why).to include("replays byte-identically")
    expect(grade.why).to include("reconstructs two model calls")
  end

  it "is deterministic: the same subject scores the same Grade twice" do
    subject = subject_struct.new(2, true)
    expect(fixture.grade(subject)).to eq(fixture.grade(subject))
  end

  it "counts a criterion that raises as a failure rather than crashing" do
    exploding = described_class.new("boom") do |f|
      f.check("touches a missing method", &:no_such_method)
    end

    grade = exploding.grade(subject_struct.new(1, true))
    expect(grade).not_to be_pass
    expect(grade.why).to match(/NoMethodError|boom|touches a missing method/)
  end

  describe "over a real DryReplay output" do
    let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
    let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

    let(:dry_replay) do
      agent, provider = record_run([tool_response(["t1", "echo", { "text" => "hi" }]), text_response("ok")],
                                   toolset:, context:, prompt: "echo hi")
      Lain::Bench::DryReplay.new(timeline: agent.timeline, baseline: provider.requests, toolset:)
    end

    it "asserts byte-identity under the recording's own Context" do
      grade = described_class.new("identity holds") do |f|
        f.check("byte-identical under identity") { |dr| dr.diff(context).identical? }
      end.grade(dry_replay)

      expect(grade).to be_pass
    end
  end

  describe "#identity" do
    def fixture
      described_class.new("byte-stable replay") do |f|
        f.check("reconstructs two model calls") { |s| s.steps == 2 }
        f.check("replays byte-identically") { |s| s.identical == true }
      end
    end

    it "names the fixture and each criterion description" do
      expect(fixture.identity).to include("class" => "Lain::Grader::Fixture", "name" => "byte-stable replay",
                                          "descriptions" => ["reconstructs two model calls",
                                                             "replays byte-identically"])
    end

    it "holds a digest of each predicate's source, not an absolute path" do
      predicates = fixture.identity.fetch("predicates")

      expect(predicates.size).to eq(2)
      expect(predicates).to all(start_with("blake3:"))
    end

    # A proc whose file cannot be read: it has a location but no source to digest.
    def unreadable(path, line)
      predicate = proc { true }
      predicate.define_singleton_method(:source_location) { [path, line] }
      described_class.new("u") { |f| f.check("c", &predicate) }
    end

    it "falls back to the location relative to the repo root when the source cannot be read" do
      root = Lain::Paths::Shipped::GEM_ROOT

      expect(unreadable(File.join(root, "lib/nowhere.rb"), 7).identity.fetch("predicates")).to eq(["lib/nowhere.rb:7"])
    end

    it "falls back to the basename outside the repo root" do
      expect(unreadable("/elsewhere/deep/nowhere.rb", 3).identity.fetch("predicates")).to eq(["nowhere.rb:3"])
    end

    def built_from(dir, name, source)
      path = File.join(dir, name)
      File.write(path, source)
      eval(File.read(path), TOPLEVEL_BINDING, path, 1) # rubocop:disable Security/Eval
    end

    def one_check(body) = %(Lain::Grader::Fixture.new("f") { |f| f.check("c") { |s| #{body} } }\n)

    it "digests predicates with different bodies differently" do
      Dir.mktmpdir do |dir|
        one = built_from(dir, "a.rb", one_check("s > 1"))
        two = built_from(dir, "b.rb", one_check("s > 100"))

        expect(one.identity.fetch("predicates")).not_to eq(two.identity.fetch("predicates"))
      end
    end

    it "keeps a predicate's digest when only code above it moves it" do
      Dir.mktmpdir do |dir|
        before = built_from(dir, "a.rb", one_check("s > 1"))
        after = built_from(dir, "b.rb", "# a new header\n\n#{one_check("s > 1")}")

        expect(after.identity.fetch("predicates")).to eq(before.identity.fetch("predicates"))
      end
    end

    it "cannot see a value a predicate closed over" do
      make = ->(limit) { described_class.new("f") { |f| f.check("c") { |s| s > limit } } }

      expect(make.call(1).identity).to eq(make.call(100).identity)
    end

    it "changes when a description changes" do
      other = described_class.new("byte-stable replay") { |f| f.check("something else") { true } }

      expect(other.identity).not_to eq(fixture.identity)
    end

    it "marks a predicate with no source location rather than failing" do
      symbol = described_class.new("sym") { |f| f.check("symbol proc", &:itself) }

      expect(symbol.identity.fetch("predicates")).to eq(["unlocated"])
    end

    it "is deeply frozen" do
      expect(fixture.identity).to be_deeply_frozen
    end
  end
end
