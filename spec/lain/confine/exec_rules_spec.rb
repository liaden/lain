# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

RSpec.describe Lain::Confine::ExecRules do
  def rules(*pairs) = described_class.of(*pairs)

  def pool = [["target/**", "/p"], ["bin/*", "/p"], [".venv/bin/*", "/q"], ["exe/lain", "/c"], ["*", "/r"]]
  def drawn = rules(*pool.select { rand < 0.4 })

  def paths
    %w[/p/target/debug/deps/x /p/bin/tool /p/src/main.rs /q/.venv/bin/pytest /c/exe/lain /c/exe/other /r/x /s/x]
  end

  describe "the join" do
    include_examples "a monoid", operation: ->(a, b) { a | b }, identity: described_class::NONE,
                                 generator: -> { drawn }
    include_examples "a commutative monoid", operation: ->(a, b) { a | b }, generator: -> { drawn }

    it "runs what either side runs", aggregate_failures: false do
      draws = PropCheck::Generator.new { PropCheck::LazyTree.wrap([drawn, drawn, paths.sample]) }

      forall(draw: draws) do |draw:|
        a, b, path = draw
        expect((a | b).exec?(path)).to eq(a.exec?(path) || b.exec?(path))
      end
    end
  end

  it "runs a path under a rule's root that its glob matches, dotted segments included" do
    set = rules(["target/**", "/p"], [".venv/bin/*", "/p"])

    verdicts = %w[/p/target/debug/deps/store-1a2b /p/.venv/bin/pytest /p/src/main.rs /elsewhere/target/x]

    expect(verdicts.map { set.exec?(_1) }).to eq([true, true, false, false])
  end

  it "runs nothing beside its root that only shares the root's spelling as a prefix" do
    expect(rules(["target/**", "/p"]).exec?("/ptarget/x")).to be(false)
  end

  it "runs a dotted path a leading wildcard matches" do
    expect(rules(["*", "/p"]).exec?("/p/.venv/bin/pytest")).to be(true)
  end

  it "runs nothing a parent segment climbs out to" do
    expect(rules(["target/**", "/p"]).exec?("/p/target/../../etc/x")).to be(false)
  end

  it "refuses a glob that climbs out of its root or is absolute" do
    expect([["../**", "/p"], ["target/../../x", "/p"], ["/usr/bin/*", "/p"]].map do |pair|
      rules(pair)
    rescue ArgumentError
      :refused
    end).to eq(%i[refused refused refused])
  end

  it "refuses a glob that is empty or holds an empty or `.` segment" do
    expect([["", "/p"], ["a/./b", "/p"], ["a//b", "/p"], ["a/", "/p"]].map do |pair|
      rules(pair)
    rescue ArgumentError
      :refused
    end).to eq(%i[refused refused refused refused])
  end

  it "refuses a rule whose root is not absolute" do
    expect { described_class::Rule.new(glob: "x", root: "p") }.to raise_error(ArgumentError, /"p"/)
  end

  it "expands a relative root against the process directory" do
    expect(rules(%w[x p]).exec?(File.join(Dir.pwd, "p", "x"))).to be(true)
  end

  it "builds a rule that is shareable from strings nobody froze" do
    expect(Ractor.shareable?(described_class::Rule.new(glob: +"x", root: +"/p"))).to be(true)
  end

  it "runs nothing when it is none" do
    expect(paths.map { described_class::NONE.exec?(_1) }).to all(be(false))
  end

  it "is equal however its rules were ordered or repeated" do
    a = rules(["bin/*", "/p"], ["target/**", "/p"])
    b = rules(["target/**", "/p"], ["bin/*", "/p"], ["bin/*", "/p"])

    expect([a == b, a.hash == b.hash]).to eq([true, true])
  end

  it "tells apart sets that hold different rules" do
    expect(rules(["bin/*", "/p"]) == rules(["target/**", "/p"])).to be(false)
  end

  it "lowers a wild rule to the directory above its first wild segment, and a literal one to itself" do
    set = rules(["target/**", "/p"], ["node_modules/.bin/*", "/p"], ["exe/lain", "/c"], ["*", "/r"], ["*/bin/x", "/s"])

    expect(set.dirs).to contain_exactly("/p/target", "/p/node_modules/.bin", "/c/exe/lain", "/r", "/s")
  end

  it "orders a set below one holding every rule it holds" do
    small = rules(["bin/*", "/p"])
    large = small | rules(["target/**", "/p"])

    expect([small <= large, large <= small]).to eq([true, false])
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(rules(*pool) | described_class::NONE)).to be(true)
  end

  it "runs what is under a root's real landing when the root is spelled through a link" do
    Dir.mktmpdir("exec-link") do |dir|
      real = File.join(File.realpath(dir), "real").tap { FileUtils.mkdir_p(_1) }
      File.symlink(real, File.join(dir, "link"))

      expect(rules(["target/**", File.join(dir, "link")]).exec?(File.join(real, "target/debug/x"))).to be(true)
    end
  end

  describe ".project" do
    subject(:project) { described_class.project("/p") }

    it "runs a fresh build's test binaries and package runners, and not the source beside them" do
      verdicts = %w[/p/target/debug/deps/store-1a2b /p/node_modules/.bin/vitest /p/.venv/bin/pytest /p/src/main.rs]

      expect(verdicts.map { project.exec?(_1) }).to eq([true, true, true, false])
    end

    # npm links each `.bin` entry into its package, and the kernel grants the link's target, not the link.
    it "runs the package file a `.bin` link lands on" do
      expect(project.exec?("/p/node_modules/vitest/vitest.mjs")).to be(true)
    end

    it "lowers every rule to a directory the fence can grant" do
      expect(project.dirs).to contain_exactly("/p/target", "/p/node_modules", "/p/.venv/bin")
    end
  end

  describe ".lain" do
    let(:checkout) { Lain::Paths::Shipped::GEM_ROOT }

    around do |example|
      Dir.mktmpdir("exec-lain") do |dir|
        @base = File.realpath(dir)
        example.run
      end
    end

    def bin(name) = File.join(@base, name).tap { FileUtils.mkdir_p(_1) }

    def shim(into)
      _, err, status = Open3.capture3("bash", File.join(checkout, "bin/install-shim"), into)
      raise "install-shim failed: #{err}" unless status.success?

      File.join(into, "lain")
    end

    def binstub(into)
      File.join(into, "lain").tap do |path|
        File.write(path, <<~RUBY)
          #!/usr/bin/env ruby
          # This file was generated by RubyGems.
          load Gem.bin_path("lain", "lain")
        RUBY
        File.chmod(0o755, path)
      end
    end

    it "runs this checkout's exe/lain and the shim that runs it, and not a binstub named lain" do
      installed = shim(bin("local"))
      gem = binstub(bin("gems"))
      set = described_class.lain(path: [bin("gems"), bin("local")].join(File::PATH_SEPARATOR))

      expect([File.join(checkout, "exe/lain"), installed, gem].map { set.exec?(_1) }).to eq([true, true, false])
    end

    it "does not run a script that execs this checkout's lain but was not written by bin/install-shim" do
      script = File.join(bin("local"), "lain")
      File.write(script, "#!/usr/bin/env bash\nexec ruby #{File.join(checkout, "exe/lain")} \"$@\"\n")

      expect(described_class.lain(path: File.dirname(script)).exec?(script)).to be(false)
    end

    it "runs a shim holding a line the shell's word rules cannot split" do
      installed = shim(bin("local"))
      File.write(installed, File.read(installed).sub("\n", "\n# it's unbalanced\n"))

      expect(described_class.lain(path: File.dirname(installed)).exec?(installed)).to be(true)
    end

    it "does not run a shim written for another checkout" do
      other = shim(bin("local"))
      set = described_class.lain(checkout: bin("elsewhere"), path: File.dirname(other))

      expect(set.exec?(other)).to be(false)
    end

    it "lowers to the entry point and each shim, no wider" do
      installed = shim(bin("local"))

      expect(described_class.lain(path: File.dirname(installed)).dirs)
        .to contain_exactly(File.join(checkout, "exe/lain"), installed)
    end
  end
end
