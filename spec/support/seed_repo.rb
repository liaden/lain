# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "mixlib/shellout"

# A throwaway git repo to start an example from, built ONCE and copied after
# that.
#
# The specs that drive real git each rebuilt their seed per example: `git init`,
# two `config`s, an `add` and a `commit` -- five subprocesses producing a
# byte-identical directory every time. `worktree_handback_spec` alone paid that
# 72 times, and a git spawn on this machine costs ~5ms whatever it does, so the
# rebuild was pure overhead against work the example had not started yet.
# Measured: **27.1ms to build, 3.5ms to copy**.
#
# Copying is also more faithful than it sounds. A fresh `git init` repo has no
# absolute paths anywhere in `.git` -- config, HEAD and the loose refs are all
# relative -- so a copy IS the repo, not a reconstruction of one. Worktrees
# added during an example DO record absolute paths, which is exactly why the
# template is only ever the seed and never a repo an example has touched.
#
# Keyed by its seed files, because the callers want different ones and a shared
# template that quietly served the wrong contents would be a very confusing
# failure.
module SeedRepo
  # The same scrub the subjects use, so building the template is hermetic under
  # an ambient GIT_*-polluted env (a pre-commit hook) exactly as they are.
  SCRUB = Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB

  # The CONFIG half of that hermeticity, which the scrub cannot reach: these
  # arrive from ~/.gitconfig, not from the environment. A developer with
  # `commit.gpgsign = true` and no secret key gets `error: gpg failed to sign
  # the data` -- exit 128 -- from any spec that commits, on a tree with nothing
  # wrong with it. `core.hooksPath` is the same shape: it would run their hooks
  # inside a fixture.
  #
  # Written into the template's repo-LOCAL config rather than passed as `-c` per
  # invocation, because a copy of the template is a copy of its `.git/config`:
  # one edit here hardens the build AND every example that goes on to commit in
  # a copied repo. Per-invocation pins would protect only the build.
  PINS = { "commit.gpgsign" => "false", "core.hooksPath" => "/dev/null" }.freeze

  class << self
    # @param files [Hash{String=>String}] seed path => contents
    # @return [String] a directory to copy, never to mutate
    def at(files)
      templates[files] ||= build(files)
    end

    private

    # Process-wide by design, and safe without a lock for the reason the whole
    # suite is: `parallel_tests` forks PROCESSES, and one example runs at a
    # time within each, so nothing races this.
    def templates = @templates ||= {} # rubocop:disable ThreadSafety/ClassInstanceVariable

    def build(files)
      dir = Dir.mktmpdir("lain-seed-template")
      at_exit { FileUtils.remove_entry(dir, true) }
      git(dir, "init", "-q")
      git(dir, "config", "user.email", "test@example.com")
      git(dir, "config", "user.name", "Test")
      # Before the first commit, so the build is covered by the same config the
      # copies inherit rather than by a separate mechanism.
      PINS.each { |key, value| git(dir, "config", key, value) }
      files.each { |path, body| File.write(File.join(dir, path), body) }
      git(dir, "add", "-A")
      git(dir, "commit", "-q", "-m", "seed")
      dir
    end

    def git(dir, *)
      Mixlib::ShellOut.new("git", "-C", dir, *, environment: SCRUB).run_command.error!
    end
  end
end
