# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# How the chat handoff finds the repository a worker's work merges back into.
# It used to derive that separately from the {Lain::Isolation::Worktree}
# backend that actually cut the worker checkouts -- a second, git-shelled
# `rev-parse --show-toplevel` that can disagree with the backend's own answer
# under GIT_CEILING_DIRECTORIES (see the divergence example below). Reading
# the backend's own #repo_root instead makes the two answers unrepresentable
# as different directories.
RSpec.describe Lain::CLI::Wiring::Handback, :seam do
  around do |example|
    Dir.mktmpdir("lain-handback-repo") do |dir|
      @repo = File.realpath(dir)
      init_repo(@repo)
      @root = File.join(@repo, "sub")
      FileUtils.mkdir_p(@root)
      example.run
    end
  end

  def init_repo(dir) = FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", dir)

  def worktree_backend
    Lain::CLI::IsolationBackend.resolve("worktree", root: @root, paths: Lain::Paths.new)
  end

  def build_handback(isolation)
    described_class.for(isolation:, root: @root, journal: [], role_spawn: -> {})
  end

  it "wires the handoff with the working branch's repository" do
    handback = build_handback(worktree_backend)

    expect(handback.handoff).not_to equal(Lain::Isolation::WorkerHandoff::Null)
  end

  # THE DIVERGENCE. `--isolation worktree` launched from a SUBDIRECTORY of the
  # repository, under GIT_CEILING_DIRECTORIES pointed at the repository root
  # itself: git's own discovery walk stops BEFORE reaching that root when it
  # starts below it (verified against a real `git rev-parse --show-toplevel`),
  # so a handoff that re-derives its root by shelling out raises where the
  # backend -- whose own repository search is a plain directory walk, not a
  # git subprocess -- resolved and cut worktrees just fine.
  it "answers from the backend's own repository rather than raising under GIT_CEILING_DIRECTORIES" do
    with_env("GIT_CEILING_DIRECTORIES" => @repo) do
      isolation = worktree_backend

      handback = nil
      expect { handback = build_handback(isolation) }.not_to raise_error

      expect(handback.handoff.instance_variable_get(:@repo_root)).to eq(@repo)
    end
  end
end
