# frozen_string_literal: true

RSpec.describe Lain do
  it "has a version number" do
    expect(Lain::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  # The ceiling on `lib/lain.rb` itself, and the reason it needs one: until
  # `SILENT` and `.live` moved here they were entries in the loader's ignore
  # list, where an exemption was a line somebody had to look at and argue for.
  # That list reached zero and was deleted, so nothing else applies that
  # pressure to this file and this example is what replaced it. zeitwerk_spec's orphan sweep takes
  # any `Lain::X` defined here as findable -- which it is -- and a singleton
  # method is invisible to every constant walk there is, so a sixth member
  # would arrive unremarked in a file that is already the longest thing a
  # reader of this gem meets first.
  #
  # Asked by SOURCE LOCATION rather than by name: `VERSION` and the extension's
  # twenty-six constants are `Lain`'s too, and the question is not what the
  # module holds but what this one file puts there.
  describe "what lib/lain.rb puts on Lain itself" do
    def sourced_here(names)
      manifest = File.expand_path("../lib/lain.rb", __dir__)
      names.select { yield(_1)&.first == manifest }
    end

    it "adds only the members named here, so a new one is a deliberate edit" do
      constants = sourced_here(described_class.constants(false)) do |name|
        described_class.const_source_location(name, false)
      end

      expect(constants.sort).to eq(%i[Ext LOADER LOADER_INFLECTIONS SILENT])
    end

    # `.live` is the whole of it, and the half no constant sweep can see: a
    # method has no cpath, so the loader cannot be asked about one and
    # zeitwerk_spec cannot either.
    it "defines only .live on the module itself" do
      methods = sourced_here(described_class.methods(false)) { described_class.method(_1).source_location }

      expect(methods).to eq(%i[live])
    end
  end

  describe ".live" do
    it "calls a callable and returns what it returns" do
      expect(described_class.live(-> { 42 })).to eq(42)
    end

    it "returns a plain value as-is" do
      expect(described_class.live(42)).to eq(42)
    end

    # Every hand-written thunk site this replaces let the thunk's own raise
    # propagate rather than rescuing it -- `.live` is resolution, not policy,
    # so it stays that way.
    it "propagates a raise from the callable rather than swallowing it" do
      boom = -> { raise "boom" }

      expect { described_class.live(boom) }.to raise_error("boom")
    end

    it "passes a callable's nil through rather than defaulting it" do
      expect(described_class.live(-> {})).to be_nil
    end

    # None of the four sites this generalizes memoized their thunk -- each
    # read calls again, because the live value may differ between calls (a
    # Timeline's head moves). `.live` keeps that: it is a pure resolution, not
    # a cache.
    it "calls the callable again on a second resolution rather than memoizing" do
      calls = 0
      counting = lambda do
        calls += 1
        calls
      end

      expect(described_class.live(counting)).to eq(1)
      expect(described_class.live(counting)).to eq(2)
    end

    # Single-level: a caller who wants two layers unwrapped has to say so
    # twice, rather than `.live` deciding for them by resolving until the
    # result stops answering `#call`.
    it "resolves only one level, leaving a callable-returning-callable uncalled" do
      inner = -> { 7 }
      outer = -> { inner }

      expect(described_class.live(outer)).to equal(inner)
    end

    # The four sites this generalizes each handed a zero-arg thunk; a
    # callable requiring one is not a shape any of them produced, and `.live`
    # does not accommodate it either -- it is a public method now, so this is
    # worth a named example rather than an inherited, unstated assumption.
    it "raises ArgumentError for a callable that requires an argument" do
      needs_one = ->(x) { x }

      expect { described_class.live(needs_one) }.to raise_error(ArgumentError)
    end
  end

  # The gemspec's prose is the first thing a reader of this repo meets, and
  # nothing compiles it -- a class renamed or deleted leaves a description
  # naming a class that never existed here, which is how `Provider::BedrockRaw`
  # and `Provider::AnthropicRaw` survived in it. A name is judged Lain's own by
  # its head segment resolving under {Lain}, so third-party names in the same
  # prose (Gem::Specification, Reline::LineEditor) are left alone.
  describe "the gemspec's prose" do
    def named_constants
      File.read(File.expand_path("../lain.gemspec", __dir__))
          .scan(/\b(?:Lain::)?([A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)+)/).flatten.uniq
          .select { |name| described_class.const_defined?(name.split("::").first, false) }
    end

    it "names only classes that exist" do
      undefined = named_constants.reject { |name| described_class.const_defined?(name) }

      expect(undefined).to be_empty, "lain.gemspec names #{undefined.join(", ")}, defined nowhere under Lain"
    end

    it "names some, so the walk above is not vacuous" do
      expect(named_constants).not_to be_empty
    end
  end

  # Proves the magnus FFI boundary is wired and `rake compile` produced a loadable
  # extension. Until the Timeline lands in Rust, this is the only thing crossing it.
  describe ".hello" do
    it "round-trips a string through the Rust extension" do
      expect(described_class.hello("lain")).to eq("Hello from Rust, lain!")
    end
  end
end

# The first-run failure, and the only way to see it: `lain` is already loaded in
# THIS process, so nothing in-process can exercise the rescue. A subprocess with
# a load path holding lain's Ruby but NOT its compiled artifact reproduces a
# fresh clone exactly -- which is where it was reported from, on macOS,
# 2026-08-05, against `./exe/lain` and `bundle exec exe/lain --help` alike.
#
# The artifact is gitignored (`*.so`, 47MB), so this is the state every clone,
# every `git worktree` and every new machine starts in. Ruby's own message for
# it is `cannot load such file -- lain/lain`, which names an internal path and
# suggests nothing.
RSpec.describe "lain.rb without the compiled extension", :seam do
  # A load path that is lain's `lib/` minus the artifact. Symlinked per entry
  # rather than copied: the real `lib/` holds a 47MB `.so` and copying it for
  # each run is the whole cost of this example.
  def lib_without_extension
    real = File.expand_path("../lib", __dir__)
    Dir.mktmpdir("lain-no-ext") { |dir| yield mirrored(real, dir) }
  end

  # `lain/` is rebuilt entry by entry so the artifact can be left out; every
  # other child of `lib/` is one symlink, since only that directory holds one.
  def mirrored(real, dir)
    link_children(real, dir) { |entry| entry != "lain" }
    FileUtils.mkdir_p(File.join(dir, "lain"))
    link_children(File.join(real, "lain"), File.join(dir, "lain")) { |entry| !entry.match?(/\.(so|bundle|dll)\z/) }
    dir
  end

  def link_children(from, to, &keep)
    Dir.children(from).select(&keep).each { |entry| FileUtils.ln_s(File.join(from, entry), File.join(to, entry)) }
  end

  def require_lain_from(dir)
    IO.popen({ "RUBYOPT" => nil, "BUNDLER_SETUP" => nil },
             [RbConfig.ruby, "-I#{dir}", "-e", 'require "lain"'],
             err: %i[child out], &:read)
  end

  it "says the extension is unbuilt and how to build it, not `cannot load such file`" do
    output = lib_without_extension { |dir| require_lain_from(dir) }

    expect(output).to include("compiled Rust extension is not built")
      .and include("rake compile")
    expect($CHILD_STATUS).not_to be_success
  end

  # The counter-example that keeps the rescue honest: swallowing Ruby's own
  # message would lose the path that says WHICH require failed, and a second
  # unbuilt extension later would then be indistinguishable from this one.
  it "keeps Ruby's own LoadError message rather than replacing it" do
    output = lib_without_extension { |dir| require_lain_from(dir) }

    expect(output).to include("cannot load such file -- lain/lain")
  end
end
