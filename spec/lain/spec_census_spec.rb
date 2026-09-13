# frozen_string_literal: true

require "open3"

# `load`, not `require_relative`: the subject lives at `bin/spec-census` with no
# `.rb` extension (matching `bin/comment-census`), and Ruby's `require` family
# resolves a feature by trying known suffixes -- it does not fall back to the
# literal path, so `require_relative` raises LoadError on an extensionless
# script. `load` takes the path as-is; the file only defines a module and a CLI
# block guarded by `$PROGRAM_NAME == __FILE__`, which is false under rspec.
load File.expand_path("../../bin/spec-census", __dir__)

# Both censuses are worklists a human acts on, so what is asserted here is the
# SCANNERS' behaviour and the REPORT's completeness -- never a count against
# the real tree. That was the shape this file replaces: two examples that
# walked `spec/` and `lib/` on every suite run, cost 99.7% of a 5.9s file, and
# could not go red whatever they found. The whole-tree walk is `bin/spec-census`
# now, and the one thing a whole-tree walk can legitimately fail on -- a count
# that grew -- is its `--check` ratchet.
#
# Every fixture below is a String. Nothing here reads this repository's own
# tree, which is what keeps the file fast and what `spec/repo_as_fixture_spec.rb`
# asks of a spec besides.
RSpec.describe SpecCensus do
  describe SpecCensus::Assertions::Scanner do
    def scan(source) = described_class.new("fixture_spec.rb").scan(source)

    it "flags an example whose sole assertion is expect { }.not_to raise_error" do
      source = <<~RUBY
        it "does not raise" do
          expect { subject.call }.not_to raise_error
        end
      RUBY

      found = scan(source)

      expect(found.size).to eq(1)
      expect(found.first.shape).to eq(:sole_raise_error)
      expect(found.first.line).to eq(1)
    end

    it "flags the same shape spelled with .to_not" do
      found = scan(<<~RUBY)
        it "does not raise, spelled the other way" do
          expect { subject.call }.to_not raise_error
        end
      RUBY

      expect(found.map(&:shape)).to eq([:sole_raise_error])
    end

    it "flags a nested expect inside an expect block" do
      source = <<~RUBY
        it "answers an Integer without raising" do
          expect { expect(subject.call).to be_a(Integer) }.not_to raise_error
        end
      RUBY

      found = scan(source)

      expect(found.map(&:shape)).to eq([:nested_expect])
    end

    it "does not ALSO flag the nested-expect example as a sole raise_error assertion" do
      # The nested inner matcher counts toward this example's assertion total,
      # so it is not "sole" by count -- shape 2 is what catches it, not shape 1.
      found = scan(<<~RUBY)
        it "answers an Integer without raising" do
          expect { expect(subject.call).to be_a(Integer) }.not_to raise_error
        end
      RUBY

      expect(found.map(&:shape)).not_to include(:sole_raise_error)
    end

    it "does not flag expect { }.not_to raise_error beside a real assertion" do
      source = <<~RUBY
        it "computes the value and does not raise" do
          expect { subject.call }.not_to raise_error
          expect(subject.result).to eq(42)
        end
      RUBY

      expect(scan(source)).to be_empty
    end

    it "does not flag a healthy example asserting an observable outcome" do
      source = <<~RUBY
        it "returns the computed total" do
          expect(subject.total).to eq(7)
        end
      RUBY

      expect(scan(source)).to be_empty
    end

    it "does not flag expect { }.to raise_error (asserting that it DOES raise)" do
      source = <<~RUBY
        it "raises for an invalid argument" do
          expect { subject.call(nil) }.to raise_error(ArgumentError)
        end
      RUBY

      expect(scan(source)).to be_empty
    end

    it "does not flag a pending example with no block" do
      expect(scan(%(it "is not written yet"\n))).to be_empty
    end

    it "reports the example's own line, not a nested one" do
      source = <<~RUBY
        describe "wrapper" do
          it "does not raise" do
            expect { subject.call }.not_to raise_error
          end
        end
      RUBY

      expect(scan(source).first.line).to eq(2)
    end

    it "carries the example's description for a readable report" do
      found = scan(<<~RUBY)
        it "is the Null channel, so a caller never has to guard `if journal`" do
          expect { subject.call }.not_to raise_error
        end
      RUBY

      expect(found.first.description).to eq("is the Null channel, so a caller never has to guard `if journal`")
    end

    it "flags an example whose only assertions are two vacuous not_to raise_error calls" do
      source = <<~RUBY
        it "never raises either way" do
          expect { subject.a }.not_to raise_error
          expect { subject.b }.not_to raise_error
        end
      RUBY

      found = scan(source)

      expect(found.map(&:shape)).to eq([:sole_raise_error])
    end

    it "recognises is_expected.to as a real assertion beside a raise_error smoke check" do
      source = <<~RUBY
        it "computes the value and does not raise" do
          expect { subject.call }.not_to raise_error
          is_expected.to eq(42)
        end
      RUBY

      expect(scan(source)).to be_empty
    end

    it "recognises expect_any_instance_of(...).to as a real assertion beside a raise_error smoke check" do
      source = <<~RUBY
        it "delegates without raising" do
          expect { subject.call }.not_to raise_error
          expect_any_instance_of(Logger).to receive(:info)
        end
      RUBY

      expect(scan(source)).to be_empty
    end

    it "flags a bang-suffixed check inside the block as a likely-meaningful sole assertion" do
      source = <<~RUBY
        it "refuses when the budget is exceeded" do
          expect { budget.check_tokens!(200) }.not_to raise_error
        end
      RUBY

      expect(scan(source).first.bang_call).to be(true)
    end

    it "does not flag bang_call when the wrapped call has no bang" do
      source = <<~RUBY
        it "is idempotent on close" do
          expect { journal.close }.not_to raise_error
        end
      RUBY

      expect(scan(source).first.bang_call).to be(false)
    end

    it "flags raise_sibling when a sibling example in the same describe asserts raise_error" do
      source = <<~RUBY
        describe "#check!" do
          it "accepts a valid value" do
            expect { subject.check!(1) }.not_to raise_error
          end

          it "refuses an invalid value" do
            expect { subject.check!(-1) }.to raise_error(ArgumentError)
          end
        end
      RUBY

      accepts = scan(source).find { |v| v.shape == :sole_raise_error }

      expect(accepts.raise_sibling).to be(true)
    end

    it "does not flag raise_sibling when no sibling in the same describe raises" do
      source = <<~RUBY
        describe "#close" do
          it "is idempotent on close" do
            expect { journal.close }.not_to raise_error
          end
        end
      RUBY

      expect(scan(source).first.raise_sibling).to be(false)
    end

    it "does not credit a raising example in a DIFFERENT nested context as a sibling" do
      source = <<~RUBY
        describe "Foo" do
          context "accepts" do
            it "accepts nothing new" do
              expect { subject.check!(1) }.not_to raise_error
            end
          end

          context "refuses" do
            it "refuses bad input" do
              expect { subject.check!(-1) }.to raise_error(ArgumentError)
            end
          end
        end
      RUBY

      accepts = scan(source).find { |v| v.shape == :sole_raise_error }

      expect(accepts.raise_sibling).to be(false)
    end
  end

  # The whole-tree examples this file replaces each carried ONE real assertion
  # beside their report: that the rendered report listed every violation it was
  # handed, which fails if a `partition` into buckets ever drops one. That
  # assertion is kept -- against fixtures that exercise all four buckets, which
  # is strictly more of the renderer than a real-tree list happened to reach.
  describe SpecCensus::AssertionReport do
    def violation(path, shape, bang_call: nil, raise_sibling: nil)
      SpecCensus::Assertions::Violation.new(path, 42, shape, "does a thing", bang_call, raise_sibling)
    end

    let(:every_bucket) do
      [violation("spec/a_spec.rb", :sole_raise_error, bang_call: true, raise_sibling: false),
       violation("spec/b_spec.rb", :sole_raise_error, bang_call: false, raise_sibling: false),
       violation("spec/support_matchers_spec.rb", :nested_expect),
       violation("spec/c_spec.rb", :nested_expect)]
    end

    it "renders every violation it was handed, whichever bucket it lands in" do
      listed = described_class.text(every_bucket).lines.grep(/\[(sole_raise_error|nested_expect)\]/)

      expect(listed.size).to eq(every_bucket.size)
    end

    it "counts the read-first split the reading order is built on" do
      expect(described_class.text(every_bucket))
        .to include("bang_call or raise_sibling detected (read first): 1")
        .and include("neither signal detected:                          1")
    end
  end

  describe SpecCensus::LibReach::Scanner do
    def scan(lib, spec = {}) = described_class.new(lib, spec).violations

    let(:consumer) { { "lib/consumer.rb" => "class Consumer\n  def run = Widget.new.total\nend\n" } }

    it "flags a public lib method that only spec names" do
      found = scan({ "lib/widget.rb" => "class Widget\n  def total = 1\nend\n" },
                   { "spec/widget_spec.rb" => "it('x') { expect(Widget.new.total).to eq(1) }\n" })

      expect(found.map { |v| v.definition.to_s }).to eq(["Widget#total"])
      expect(found.first.line).to eq(2)
    end

    it "does not flag a method another lib file calls" do
      lib = { "lib/widget.rb" => "class Widget\n  def total = 1\nend\n" }.merge(consumer)

      expect(scan(lib, { "spec/widget_spec.rb" => "expect(Widget.new.total).to eq(1)\n" })).to be_empty
    end

    it "does not flag a method nothing names at all -- unreached is a different finding" do
      expect(scan({ "lib/widget.rb" => "class Widget\n  def total = 1\nend\n" })).to be_empty
    end

    it "counts a Symbol in lib as a reference, so send/delegation does not read as spec-only" do
      lib = { "lib/widget.rb" => "class Widget\n  def total = 1\nend\n",
              "lib/proxy.rb" => "class Proxy\n  def call(w) = w.public_send(:total)\nend\n" }

      expect(scan(lib, { "spec/widget_spec.rb" => "expect(Widget.new.total).to eq(1)\n" })).to be_empty
    end

    it "does not flag a method the file already made private" do
      source = "class Widget\n  private\n\n  def total = 1\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "subject.send(:total)\n" })).to be_empty
    end

    it "does not flag `private def`" do
      source = "class Widget\n  private def total = 1\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "subject.send(:total)\n" })).to be_empty
    end

    it "does not flag a name listed by private_class_method" do
      source = "class Widget\n  def self.total = 1\n  private_class_method :total\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "described_class.total\n" })).to be_empty
    end

    it "reads `public` as reopening the default after a `private` section" do
      source = "class Widget\n  private\n\n  def hidden = 1\n\n  public\n\n  def total = 2\nend\n"
      found = scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "subject.total\nsubject.hidden\n" })

      expect(found.map { |v| v.definition.name }).to eq([:total])
    end

    it "reads a Data.define block as a class body, so its `private` section is honoured" do
      source = "Widget = Data.define(:n) do\n  def total = 1\n\n  private\n\n  def hidden = 2\nend\n"
      found = scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "subject.total\nsubject.hidden\n" })

      expect(found.map { |v| v.definition.name }).to eq([:total])
    end

    it "does not flag a name Ruby invokes without spelling it" do
      source = "class Widget\n  def to_s = 'w'\n  def each = nil\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "expect(subject.to_s).to eq('w')\n" }))
        .to be_empty
    end

    it "shares references between two methods of the same name, so either reference clears both" do
      lib = { "lib/widget.rb" => "class Widget\n  def total = 1\nend\n",
              "lib/gadget.rb" => "class Gadget\n  def total = 2\nend\n",
              "lib/consumer.rb" => "class Consumer\n  def run = Gadget.new.total\nend\n" }

      expect(scan(lib, { "spec/widget_spec.rb" => "expect(Widget.new.total).to eq(1)\n" })).to be_empty
    end

    it "renders a `class << self` def as a singleton, the way a caller spells it" do
      source = "class Widget\n  class << self\n    def total = 1\n  end\nend\n"
      found = scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "described_class.total\n" })

      expect(found.map { |v| v.definition.to_s }).to eq(["Widget.total"])
    end

    it "honours a `private` section inside `class << self`" do
      source = "class Widget\n  class << self\n    private\n\n    def total = 1\n  end\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "described_class.send(:total)\n" }))
        .to be_empty
    end

    it "renders a def after a bare `module_function` as a singleton" do
      source = "module Widget\n  module_function\n\n  def total = 1\nend\n"
      found = scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "Widget.total\n" })

      expect(found.map { |v| v.definition.to_s }).to eq(["Widget.total"])
    end

    it "does not flag a protected method -- it is not part of the public interface either" do
      source = "class Widget\n  protected\n\n  def total = 1\nend\n"

      expect(scan({ "lib/widget.rb" => source }, { "spec/widget_spec.rb" => "subject.send(:total)\n" })).to be_empty
    end

    it "does not flag an inspection method on a test double, which the specs are why it exists" do
      source = "module Provider\n  class Mock\n    def call_count = 1\n  end\nend\n"

      expect(scan({ "lib/mock.rb" => source }, { "spec/mock_spec.rb" => "expect(subject.call_count).to eq(1)\n" }))
        .to be_empty
    end

    it "tags unwired_owner when the owning constant has no lib consumer either" do
      found = scan({ "lib/widget.rb" => "class Widget\n  def total = 1\nend\n" },
                   { "spec/widget_spec.rb" => "expect(Widget.new.total).to eq(1)\n" })

      expect(found.first.unwired_owner).to be(true)
    end

    it "does not tag unwired_owner when lib names the class somewhere else" do
      lib = { "lib/widget.rb" => "class Widget\n  def total = 1\nend\n",
              "lib/consumer.rb" => "class Consumer\n  def run = Widget.new\nend\n" }
      found = scan(lib, { "spec/widget_spec.rb" => "expect(Widget.new.total).to eq(1)\n" })

      expect(found.first.unwired_owner).to be(false)
    end

    it "names the spec sites that reach it, so the reading list needs no second search" do
      found = scan({ "lib/widget.rb" => "class Widget\n  def total = 1\nend\n" },
                   { "spec/widget_spec.rb" => "\n\nexpect(Widget.new.total).to eq(1)\n" })

      expect(found.first.spec_sites).to include("spec/widget_spec.rb:3")
    end
  end

  describe SpecCensus::LibReachReport do
    def violation(name, unwired_owner:)
      definition = SpecCensus::LibReach::Definition.new("lib/widget.rb", 2, name, "Widget", false)
      SpecCensus::LibReach::Violation.new(definition, ["spec/widget_spec.rb:3"], unwired_owner)
    end

    let(:both_sections) { [violation(:total, unwired_owner: true), violation(:sum, unwired_owner: false)] }

    it "renders every violation it was handed, in whichever section it lands" do
      listed = described_class.text(both_sections).lines.grep(%r{^  lib/.*:\d+ })

      expect(listed.size).to eq(both_sections.size)
    end
  end

  # The ratchet is the one thing in this script that can FAIL, so it is the one
  # thing here asserted against exit status rather than against text. Nothing
  # gates on `--check` yet; that is precisely why it needs a spec, because a
  # gate nobody runs is a gate nobody notices has rotted.
  # The ratchet is the one thing in this script that can FAIL, so it gets two
  # kinds of coverage and neither one stubs its own subject. `check` takes its
  # censuses as an argument precisely so a spec can hand it real ones; what is
  # left -- the argv dispatch and the exit STATUS a caller reads -- is asserted
  # against the real binary through a real process, the way
  # `spec/lain/comment_census_spec.rb` asserts `bin/comment-census`. Catching a
  # `SystemExit` in-process is the shape CLAUDE.md warns truncates a run while
  # still reporting "0 failures"; only one example here does it, deliberately,
  # and it is the one that has nothing else to assert.
  describe SpecCensus::CLI do
    def census(name, size, ceiling)
      described_class::Census.new(name, Array.new(size) { |i| "spec/a_spec.rb:#{i} [sole_raise_error]" }, ceiling)
    end

    describe "the verdict on one census" do
      it "reads a count at its ceiling as a pass" do
        expect(described_class.verdict(census(:assertions, 184, 184)))
          .to eq("ok   assertions: 184 (at the ceiling)")
      end

      it "tells a reader to lower a ceiling the count has fallen below" do
        expect(described_class.verdict(census(:assertions, 100, 184))).to include("lower it")
      end

      # The finding this replaces: a bare "FAIL assertions: 185 > 184" gives a
      # developer no baseline to diff and no statement of what they may do
      # about it, and the instruction lived only in a comment they never see.
      it "prints the offending entries, so the reader can see WHICH one is new" do
        failed = described_class.verdict(census(:assertions, 3, 2))

        expect(failed.lines.grep(/\[sole_raise_error\]/).size).to eq(3)
      end

      it "names both legal answers where the person who tripped the gate reads them" do
        failed = described_class.verdict(census(:assertions, 3, 2))

        expect(failed).to include("document-with-a-reason").and include("in its own commit, saying why")
      end
    end

    describe "the gate over every census" do
      it "reports every census over its ceiling, not just the first" do
        report = described_class.report([census(:assertions, 2, 1), census(:lib_reach, 2, 1)])

        expect(report).to match(/FAIL assertions.*FAIL lib_reach/m)
      end

      it "passes a tree whose every census sits at its ceiling" do
        expect { described_class.check([census(:assertions, 1, 1)]) }
          .to output(/ok   assertions/).to_stdout
      end

      it "exits non-zero when a census has grown past its ceiling" do
        expect { described_class.check([census(:assertions, 2, 1)]) }
          .to raise_error(SystemExit) { |exit| expect(exit.status).to eq(1) }
      end
    end

    # Through the real binary: these assert the STATUS a shell reads, which is
    # the half `raise_error(SystemExit)` cannot see, and they exercise the
    # `$PROGRAM_NAME == __FILE__` guard that makes the script a script. Both
    # refuse before either census runs, so neither pays for a tree walk.
    describe "the command line, run as a command" do
      def run_cli(*args)
        Open3.capture3(RbConfig.ruby, File.expand_path("../../bin/spec-census", __dir__), *args)
      end

      it "refuses an unknown flag with a usage message and a distinct status" do
        _stdout, stderr, status = run_cli("--nonsense")

        expect(status.exitstatus).to eq(2)
        expect(stderr).to include("usage: bin/spec-census")
      end

      # It takes no file arguments, and the failure this prevents is silent:
      # a path argument would otherwise be ignored while the whole tree was
      # scanned and reported.
      it "refuses a file argument rather than ignoring it" do
        _stdout, stderr, status = run_cli("spec/lain/spec_census_spec.rb")

        expect(status.exitstatus).to eq(2)
        expect(stderr).to include("Takes no file arguments")
      end
    end
  end
end
