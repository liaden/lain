# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tmpdir"

RSpec.describe Lain::CLI::WindowSurface do
  let(:root) { @root ||= File.realpath(Dir.mktmpdir("window-surface")) }
  let(:calls_path) { File.join(root, "calls") }
  let(:notes) { [] }
  let(:sink) do
    told = notes
    Object.new.tap { |sink| sink.define_singleton_method(:puts) { |line| told << line } }
  end
  # `plugin list --json` as herdr 0.9.5 prints it, recorded from a real one.
  let(:linked) do
    '{"id":"cli:plugin","result":{"plugins":[{"name":"lain","plugin_id":"lain","enabled":true,' \
      '"panes":[{"id":"run"}]}]}}'
  end
  let(:unlinked) { '{"id":"cli:plugin","result":{"plugins":[]}}' }

  after { FileUtils.remove_entry(@root) if @root }

  def stub_herdr(listing)
    File.join(root, "herdr").tap do |path|
      File.write(path, "#!/bin/sh\necho \"$*\" >> #{calls_path.shellescape}\necho '#{listing}'\n", perm: 0o755)
    end
  end

  def calls = File.exist?(calls_path) ? File.readlines(calls_path, chomp: true) : []

  def resolver_at(via, bin: stub_herdr(linked))
    target = Lain::Herdr::Target.new(bin:, pane: "w1:p7", socket: File.join(root, "s.sock"), via:)
    Struct.new(:current).new(target)
  end

  def choose(resolver) = described_class.for(resolver:, notes: sink)

  it "is a HerdrSurface for a plain herdr pane with lain linked" do
    expect(choose(resolver_at(:env))).to be_a(Lain::CLI::HerdrSurface)
    expect(calls).to eq(["plugin list --json"])
  end

  it "is a TmuxSurface for a cockpit target, without asking herdr" do
    expect(choose(resolver_at(:cockpit))).to be_a(Lain::CLI::TmuxSurface)
    expect(calls).to be_empty
  end

  it "is a TmuxSurface with 1 note naming lain herdr link when lain is not linked" do
    expect(choose(resolver_at(:env, bin: stub_herdr(unlinked)))).to be_a(Lain::CLI::TmuxSurface)
    expect(notes).to eq([described_class::NOT_LINKED])
    expect(notes.first).to include("lain herdr link")
  end

  it "does not take another plugin whose path merely contains lain" do
    other = '{"result":{"plugins":[{"name":"x","plugin_id":"other","path":"/dev/lain/plugin"}]}}'

    expect(choose(resolver_at(:env, bin: stub_herdr(other)))).to be_a(Lain::CLI::TmuxSurface)
  end

  it "does not take lain's plugin when herdr lists it disabled" do
    disabled = linked.sub('"enabled":true', '"enabled":false')

    expect(choose(resolver_at(:env, bin: stub_herdr(disabled)))).to be_a(Lain::CLI::TmuxSurface)
  end

  it "reads herdr's plain 'No plugins installed.' as not linked" do
    expect(choose(resolver_at(:env, bin: stub_herdr("No plugins installed.")))).to be_a(Lain::CLI::TmuxSurface)
    expect(notes.size).to eq(1)
  end

  it "is a TmuxSurface when herdr cannot be run, and says why once" do
    expect(choose(resolver_at(:env, bin: File.join(root, "missing")))).to be_a(Lain::CLI::TmuxSurface)
    expect(notes.size).to eq(1)
  end

  it "is a TmuxSurface and never calls herdr outside herdr" do
    expect(choose(Struct.new(:current).new(nil))).to be_a(Lain::CLI::TmuxSurface)
    expect(calls).to be_empty
    expect(notes).to be_empty
  end

  describe "::Lazy" do
    it "asks nothing of herdr until a window is wanted, and chooses once" do
      resolver = Struct.new(:current).new(resolver_at(:env).current)
      lazy = described_class::Lazy.new(resolver:, notes: sink)

      expect(calls).to be_empty
      2.times { lazy.missing_from_global_environment([]) }
      expect(calls).to eq(["plugin list --json"])
    end

    it "chooses once when 2 threads want a window together" do
      slow = Object.new
      current = resolver_at(:env).current
      slow.define_singleton_method(:current) { sleep(0.1).then { current } }
      lazy = described_class::Lazy.new(resolver: slow, notes: sink)

      Array.new(2) { Thread.new { lazy.windows_from_here?({}) } }.each(&:join)

      expect(calls).to eq(["plugin list --json"])
    end

    it "tells its note with the choice settled, so a sink that asks the surface again does not deadlock" do
      lazy = nil
      asking = Object.new
      told = notes
      asking.define_singleton_method(:puts) do |line|
        told << line
        lazy.windows_from_here?({})
      end
      lazy = described_class::Lazy.new(resolver: resolver_at(:env, bin: stub_herdr(unlinked)), notes: asking)

      expect(lazy.windows_from_here?({})).to be(false)
      expect(notes).to eq([described_class::NOT_LINKED])
    end

    it "answers whether windows can open from tmux without asking herdr" do
      lazy = described_class::Lazy.new(resolver: resolver_at(:env), notes: sink)

      expect(lazy.windows_from_here?({ "TMUX" => "/tmp/tmux-1000/default,1,0" })).to be(true)
      expect(calls).to be_empty
    end

    it "asks herdr when there is no tmux, and answers true for a linked herdr pane" do
      lazy = described_class::Lazy.new(resolver: resolver_at(:env), notes: sink)

      expect(lazy.windows_from_here?({})).to be(true)
      expect(calls).to eq(["plugin list --json"])
    end

    it "answers false when there is neither tmux nor a linked herdr pane" do
      lazy = described_class::Lazy.new(resolver: Struct.new(:current).new(nil), notes: sink)

      expect(lazy.windows_from_here?({})).to be(false)
    end
  end
end
