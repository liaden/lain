# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Landing::Walk do
  around do |example|
    Dir.mktmpdir("landing-walk") do |dir|
      @root = File.realpath(dir)
      example.run
    end
  end

  def at(*names) = File.join(@root, *names)

  def walk(path, **) = Lain::Landing.walk(path, **)

  it "lands a path with no links on itself, with nothing left over and no hops" do
    FileUtils.mkdir_p(at("real", "dir"))
    expect(walk(at("real", "dir"))).to eq(described_class.new(path: at("real", "dir"), tail: [], hops: []))
  end

  it "follows each link from its own directory and climbs a .. from where the link lands" do
    FileUtils.mkdir_p([at("real", "a"), at("real", "c")])
    File.symlink(at("real", "a"), at("a"))
    File.symlink("../c", at("real", "a", "b"))

    expect(walk(at("a", "b", "x")))
      .to have_attributes(path: at("real", "c"), tail: ["x"], hops: [at("a"), at("real", "a", "b")], absent?: true)
  end

  it "hands back the tail after the first missing component uncleaned, .. kept" do
    FileUtils.mkdir_p(at("real"))
    expect(walk(at("real", "missing", "..", "x")))
      .to have_attributes(path: at("real"), tail: ["missing", "..", "x"], hops: [])
  end

  it "follows a dangling link to where its target would be, absent there" do
    File.symlink(at("gone", "target"), at("dangling"))
    expect(walk(at("dangling"))).to have_attributes(path: @root, tail: %w[gone target], hops: [at("dangling")])
  end

  it "follows the kernel's 40 links and stops at the 41st, which it names last and marks looped" do
    FileUtils.mkdir_p(real = at("real"))
    links = (0..40).inject([real]) { |made, i| [*made, at("l#{i}").tap { File.symlink(made.last, _1) }] }

    expect(walk(links[40])).to have_attributes(path: real, tail: [], looped?: false)
    expect(walk(links[41])).to have_attributes(absent?: true, looped?: true, hops: links[1..].reverse)
  end

  it "asks the disk only through the facts it is handed" do
    facts = Class.new do
      def symlink?(path) = path == "/l"
      def exist?(path) = %w[/t /t/x].include?(path)
      def readlink(_path) = "/t"
    end.new

    expect(walk("/l/x/y", facts:)).to eq(described_class.new(path: "/t/x", tail: ["y"], hops: ["/l"]))
  end

  it "is a deeply frozen value" do
    expect(Ractor.shareable?(walk(@root))).to be(true)
  end

  describe "walking a landing again", aggregate_failures: false do
    before do
      FileUtils.mkdir_p(at("real", "dir"))
      File.write(at("real", "dir", "file"), "")
      File.symlink("real/dir", at("link_dir"))
      File.symlink("..", at("real", "up"))
      File.symlink(at("gone", "target"), at("dangling"))
      File.symlink(at("real"), at("abs"))
      File.symlink(at("loop"), at("loop"))
    end

    let(:names) { %w[real dir file link_dir up dangling abs loop .. . missing gone] }

    it "lands where it is, on every draw" do
      component = PropCheck::Generators.one_of(*names.map { PropCheck::Generators.constant(_1) })
      forall(names: PropCheck::Generators.array(component, max: 6)) do |names:|
        landed = walk(at(*names))
        expect(walk(landed.path)).to eq(described_class.new(path: landed.path, tail: [], hops: []))
      end
    end
  end

  describe "the symlink limit" do
    let(:lib) { Pathname.new(File.expand_path("../../../lib/lain", __dir__)) }
    let(:sites) do
      %w[landing.rb landing/walk.rb confine/profile.rb shell/executable/resolver.rb shell/executable/realpath_walk.rb]
    end

    it "is spelled once, as Landing::HOPS" do
      forties = sites.to_h { [_1, lib.join(_1).read.scan(/\b40\b/).size] }
      expect(forties).to eq(sites.to_h { [_1, _1 == "landing.rb" ? 1 : 0] })
      expect(Lain::Landing::HOPS).to eq(40)
    end
  end
end
