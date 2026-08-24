# frozen_string_literal: true

require "digest"
require "fileutils"
require "stringio"
require "tmpdir"

# F50, end to end: a lain session must not dirty the repository it is pointed at.
#
# `.lain/state.json` was a project artifact by argument -- "like `.git/`" -- and
# machine state by behaviour: {Lain::StatusFeed} rewrites it on every turn
# (`elapsed`, `idle` and `occupancy` all move), nothing in `lib/` writes a
# `.gitignore`, and lain's OWN repository gitignores it. The people who hit it
# fixed it for themselves and not for the projects lain is pointed at, so a user
# got permanent `git status` noise and a `git add -A` committed the file.
#
# == Why this is a seam and not a unit example
#
# The unit examples in `spec/lain/project_dir_spec.rb` pin the path the locator
# NAMES. They cannot fail if the path is right and something else writes into the
# project anyway, which is the whole finding. So this drives the real fan-out --
# a real {Lain::Agent} over a scripted {Lain::Provider::Mock}, a real
# {Lain::Journal}, a real {Lain::CLI::JournalTee}, a real {Lain::StatusFeed} on
# its own DEFAULT path, a real {Lain::ProjectDir} over a real {Lain::Paths} --
# against a real `git` in a real repository, and asks git.
#
# Nothing here injects a state path. A FIXTURE THAT SUPPLIES BOTH HALVES OF A
# RELATIONSHIP CANNOT TEST THE RELATIONSHIP: `HOME` and `XDG_STATE_HOME` move
# into the fixture -- that is environment, not injection -- and every object is
# built the way `exe/lain` builds it.
RSpec.describe "a session does not dirty the project it runs in", :seam do
  # The subject's own scrub, for the subject's own reason: a suite run from a
  # pre-commit hook inherits GIT_INDEX_FILE and GIT_DIR aimed at lain's own
  # repository, and `-C` does NOT beat those -- an unscrubbed fixture would build
  # its commits against lain's index, pass every normal run, and fail at commit
  # time.
  def git(root, *argv)
    shell = Lain::Shell::Out.new("git", "-C", root, *argv,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command
    raise "git #{argv.join(" ")} failed: #{shell.stderr}" unless shell.exitstatus.zero?

    shell.stdout
  end

  # An identity on the command line rather than in a config: a host with no
  # `user.email` set would otherwise fail the commit, and writing one into the
  # fixture's own config is a spelling of the same thing that survives less.
  def identity = ["-c", "user.email=t@example.invalid", "-c", "user.name=T"]

  def seed_repository(root)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "README.md"), "a project lain is pointed at\n")
    git(root, "init", "--quiet")
    git(root, *identity, "add", "-A")
    git(root, *identity, "commit", "--quiet", "-m", "seed")
  end

  # A committed repository with a clean tree, entered so that every default in
  # the chain reads it: the state feed's path, the project hash, the lot.
  def in_a_clean_repository
    Dir.mktmpdir("lain-hud-state") do |tmp|
      base = File.realpath(tmp)
      root = File.join(base, "project")
      seed_repository(root)
      with_env("HOME" => base, "XDG_STATE_HOME" => File.join(base, "state")) do
        Dir.chdir(root) { yield(root, base) }
      end
    end
  end

  # One real turn, fanned out the way `exe/lain` fans one out: the durable
  # journal leg first, the live-view sink after it.
  def run_a_turn
    feed = Lain::StatusFeed.new
    journal = Lain::CLI::JournalTee.new(Lain::Journal.new(io: StringIO.new), feed)
    record_run([text_response("done", usage: Lain::Usage.new(input_tokens: 12, output_tokens: 3))],
               toolset: Lain::Toolset.new, context: Lain::Context.new(model: "sonnet", max_tokens: 256),
               journal:, prompt: "say done")
    feed
  end

  it "publishes the state feed under XDG state and leaves the repository clean" do
    in_a_clean_repository do |root, base|
      run_a_turn

      # THE FINDING FIRST. These two lines are the whole of F50, and they only
      # get to run if nothing above them raises: the block aggregates failures
      # but an ERROR aborts it, and the `File.read` below is an error the
      # moment the fix is reverted and no file is published at all. Ordered so
      # that a revert reddens with `?? .lain/` rather than with an ENOENT from
      # a line that is not about the finding at all.
      expect(git(root, "status", "--porcelain")).to be_empty
      expect(Dir.exist?(File.join(root, ".lain"))).to be(false)

      # At the recipe's path, not merely SOMEWHERE under XDG state. A `*` for
      # the hash passes for a writer that keyed on the wrong directory
      # entirely -- the shell's rather than the project's -- which is exactly
      # the disagreement that turns a relocated feed into a HUD reading a file
      # nothing writes. Spelled with the real recipe rather than by asking
      # {Lain::ProjectDir}, which would pass against whatever the locator said.
      expected = File.join(base, "state", "lain", "status",
                           Digest::SHA256.hexdigest(root)[0, 12], "state.json")
      expect(Dir.glob(File.join(base, "state", "lain", "status", "*", "state.json"))).to eq([expected])
      expect(JSON.parse(File.read(expected))).to include("elapsed")
    end
  end
end
