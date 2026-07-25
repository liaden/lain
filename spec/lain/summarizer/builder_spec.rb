# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# The `.lain/summarizers.rb` DSL: a project declares the pure, synchronous
# summarizers that compact a tool result without spending a token. Rails-like --
# the file is the user's own Ruby, evaluated with no sandbox -- and each
# `summarizer "<name>" do ... end` block becomes a fresh anonymous subclass of
# {Lain::Summarizer::Base}, so a second load never reopens the first's class.
RSpec.describe Lain::Summarizer::Builder do
  # Writes a `.lain/summarizers.rb` under a throwaway root and loads it. The
  # repo's own `/.lain/` is gitignored, so specs never touch it.
  def load_catalog(source)
    Dir.mktmpdir("lain-summarizers") do |root|
      FileUtils.mkdir_p(File.join(root, ".lain"))
      File.write(File.join(root, ".lain", "summarizers.rb"), source)
      return Lain::Summarizer::Catalog.load(root:)
    end
  end

  def result(text, tool_name: "bash")
    Lain::Summarizer::Result.new(tool_name:, text:)
  end

  let(:coverage_dsl) do
    <<~RUBY
      summarizer "coverage" do
        def suitable?(result) = result.text.include?("Coverage report")

        def compact(result) = "coverage: green"
      end
    RUBY
  end

  let(:rspec_dsl) do
    <<~RUBY
      summarizer "rspec" do
        def suitable?(result) = result.text.include?("examples,")

        def compact(result) = "rspec: green"
      end
    RUBY
  end

  let(:coverage_result) { result("Coverage report generated") }
  let(:rspec_result) { result("4 examples, 0 failures") }
  let(:unrelated_result) { result("total 0", tool_name: "list_files") }

  it "is an empty catalog when the project has no .lain/summarizers.rb, never an error" do
    Dir.mktmpdir("lain-no-summarizers") do |root|
      catalog = Lain::Summarizer::Catalog.load(root:)

      expect(catalog).to be_empty
      expect(catalog.to_a).to eq([])
    end
  end

  it "holds one summarizer that answers for what it was declared suitable for" do
    catalog = load_catalog(coverage_dsl)

    expect(catalog.count).to eq(1)
    expect(catalog.first).to be_suitable(coverage_result)
    expect(catalog.first).not_to be_suitable(unrelated_result)
  end

  it "returns the summarizer suitable for the given result" do
    catalog = load_catalog(coverage_dsl + rspec_dsl)

    expect(catalog.for(rspec_result).name).to eq("rspec")
    expect(catalog.for(rspec_result).compact(rspec_result)).to eq("rspec: green")
  end

  it "returns the FIRST declared of two suitable summarizers -- declaration order is the user's lever" do
    catalog = load_catalog(<<~RUBY)
      summarizer "first" do
        def suitable?(result) = true
      end

      summarizer "second" do
        def suitable?(result) = true
      end
    RUBY

    expect(catalog.for(coverage_result).name).to eq("first")
  end

  it "returns nothing for a result no summarizer is suitable for" do
    catalog = load_catalog(coverage_dsl + rspec_dsl)

    expect(catalog.for(unrelated_result)).to be_nil
  end

  it "yields equivalent but independent summarizers when the same catalog is loaded twice" do
    first = load_catalog(coverage_dsl)
    second = load_catalog(coverage_dsl)

    expect(first.for(coverage_result)).not_to be_nil
    expect(second.for(coverage_result)).not_to be_nil
    expect(second.first.class).not_to be(first.first.class)
  end

  # A user's own `def initialize` lands AHEAD of `Base`'s Freezable in the MRO,
  # so purity cannot be left to the base class alone: without `super` the
  # instance would never freeze and would accumulate state across calls, which
  # on a bench makes an arm non-reproducible.
  it "freezes a declared summarizer even when the user's own initialize never calls super" do
    catalog = load_catalog(<<~RUBY)
      summarizer "stateful" do
        def initialize(name)
          @name = "hijacked"
        end

        def suitable?(result) = true

        def compact(result) = "c"
      end
    RUBY

    expect(catalog.first).to be_frozen
  end

  it "keeps the DECLARED name whatever the user's block does to it" do
    catalog = load_catalog(<<~RUBY)
      summarizer "declared" do
        def name = "hijacked"

        def suitable?(result) = true
      end
    RUBY

    expect(catalog.first.name).to eq("declared")
  end

  it "still refuses a duplicate when a user's own #name would have hidden the collision" do
    expect { load_catalog(<<~RUBY) }
      summarizer "coverage" do
        def name = "zzz"

        def suitable?(result) = true
      end

      summarizer "coverage" do
        def suitable?(result) = true
      end
    RUBY
      .to raise_error(described_class::Duplicate, /coverage/)
  end

  # A declared class is anonymous, so anything Ruby prints about it -- an
  # `inspect`, a FrozenError from a user's `@memo ||=` -- would otherwise be an
  # object address, exactly the failure {Base} avoids for NotImplementedError.
  it "prints a declared class as `summarizer \"<name>\"`, not as an object address" do
    catalog = load_catalog(coverage_dsl)

    expect(catalog.first.class.to_s).to eq(%(summarizer "coverage"))
    expect(catalog.first.class.inspect).to eq(%(summarizer "coverage"))
  end

  it "prints a declared summarizer itself by name too" do
    catalog = load_catalog(coverage_dsl)

    expect(catalog.first.inspect).to eq(%(#<summarizer "coverage">))
  end

  it "names the summarizer when a memoizing compact hits the frozen instance" do
    catalog = load_catalog(<<~RUBY)
      summarizer "memoizing" do
        def suitable?(result) = true

        def compact(result) = @memo ||= "cached"
      end
    RUBY

    expect { catalog.for(coverage_result).compact(coverage_result) }
      .to raise_error(FrozenError, /summarizer "memoizing"/)
  end

  # The builder's ivars share a namespace with the user's own code, and
  # `@summarizers` is a name a file ABOUT summarizers is likely to reach for.
  it "keeps its declarations out of reach of a user's own @summarizers ivar" do
    catalog = load_catalog("@summarizers = []\n#{coverage_dsl}@summarizers.clear\n")

    expect(catalog.count).to eq(1)
  end

  it "refuses an unknown DSL verb loudly, naming the known verbs" do
    expect { load_catalog(%(summariser "typo" do\nend\n)) }
      .to raise_error(described_class::Unknown, /summariser.*summarizer/m)
  end

  it "refuses a duplicate summarizer name loudly, naming the collision" do
    expect { load_catalog(coverage_dsl + coverage_dsl) }
      .to raise_error(described_class::Duplicate, /coverage/)
  end

  # `return if ENV["CI"]` is idiomatic in a config file, and this DSL is the
  # user's own Ruby. A top-level `return` unwinds the evaluation itself, so
  # every declaration above it is discarded -- silently, and surfacing much
  # later as a NoMethodError naming lain's internals. It fails at LOAD instead.
  it "refuses a file that returns before its end, naming the path" do
    expect { load_catalog(%(#{coverage_dsl}return if ENV["NOPE"].nil?\n#{rspec_dsl})) }
      .to raise_error(described_class::Unwound, /summarizers\.rb.*`return`/m)
  end

  # The sentinel that detects the unwind must not be a value the user's own
  # `return` can carry, or the bug this refusal exists to kill is reachable
  # through the refusal itself.
  it "refuses a return that carries the completion sentinel's own value" do
    expect { load_catalog("#{coverage_dsl}return :completed\n") }
      .to raise_error(described_class::Unwound)
  end

  it "refuses a return whose value merely CLAIMS to equal the sentinel" do
    expect { load_catalog(<<~RUBY) }
      #{coverage_dsl}
      liar = Object.new
      def liar.==(other) = true
      return liar
    RUBY
      .to raise_error(described_class::Unwound)
  end

  it "refuses a bare top-level return rather than handing back an unusable catalog" do
    expect { load_catalog("#{coverage_dsl}return\n") }
      .to raise_error(described_class::Unwound)
  end

  it "refuses a summarizer declared without a block, naming what a block must define" do
    expect { load_catalog(%(summarizer "bodyless"\n)) }
      .to raise_error(ArgumentError, /bodyless.*suitable\?.*compact/m)
  end

  # Pins the contract A3 has to build against: #for CALLS user predicates, so it
  # is as brittle as the file it loaded. It stays loud on purpose -- rescuing
  # inside the catalog would hide a broken summarizer forever -- which means a
  # caller's fallthrough to the model tier must wrap #for as well as #compact.
  it "lets a raising suitable? propagate out of #for, consulting no later summarizer" do
    catalog = load_catalog(<<~RUBY)
      summarizer "brittle" do
        def suitable?(result) = raise("bad regex")
      end

      summarizer "good" do
        def suitable?(result) = true

        def compact(result) = "GOOD"
      end
    RUBY

    expect { catalog.for(coverage_result) }.to raise_error(RuntimeError, "bad regex")
  end

  it "names the user's file in the backtrace when a user summarizer raises" do
    catalog = load_catalog(<<~RUBY)
      summarizer "explodes" do
        def suitable?(result) = true

        def compact(result) = raise("boom")
      end
    RUBY

    expect { catalog.for(coverage_result).compact(coverage_result) }
      .to raise_error(RuntimeError, "boom") { |error|
        expect(error.backtrace.first).to include(File.join(".lain", "summarizers.rb"))
      }
  end
end
