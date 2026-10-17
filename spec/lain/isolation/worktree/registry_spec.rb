# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Isolation::Worktree::Registry, :seam do
  subject(:registry) do
    described_class.new(repo_root: @repo, shell_out_factory: Lain::Shell::Out.public_method(:new))
  end

  around do |example|
    Dir.mktmpdir("lain-registry") do |dir|
      @dir = File.realpath(dir)
      @repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(@repo)
      FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", @repo)
      example.run
    end
  end

  def waits_while_repo_is_held
    finished = false
    Lain::Isolation::Worktree::RepoLock.for(@repo).synchronize do
      thread = Thread.new do
        yield
        finished = true
      end
      sleep 0.2
      @finished_while_held = finished
      thread.kill
    end
  end

  it "adds under the repository lock" do
    waits_while_repo_is_held { registry.add(File.join(@dir, "a"), "HEAD", reason: "r") }

    expect(@finished_while_held).to be(false)
  end

  it "removes under the repository lock" do
    waits_while_repo_is_held { registry.remove(File.join(@dir, "a")) }

    expect(@finished_while_held).to be(false)
  end

  it "moves under the repository lock" do
    waits_while_repo_is_held { registry.move(File.join(@dir, "a"), File.join(@dir, "b")) }

    expect(@finished_while_held).to be(false)
  end

  it "prunes under the repository lock" do
    waits_while_repo_is_held { registry.prune }

    expect(@finished_while_held).to be(false)
  end

  it "answers a read without the lock" do
    waits_while_repo_is_held { registry.entries }

    expect(@finished_while_held).to be(true)
  end
end
