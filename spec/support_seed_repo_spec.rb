# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "mixlib/shellout"

# worktree_handback_spec was flaky for weeks because `git commit` and `git merge`
# end by spawning a DETACHED `git maintenance run --auto`, which outlives the
# example and writes under .git/objects while Dir.mktmpdir tears the repo down.
# The failure names whichever example the `around` hook was closing, never the
# cause, so the only durable guard is one that asks git directly whether a
# process was spawned.
RSpec.describe SeedRepo, :seam do
  def commit_trace(repo, *config)
    args = config.flat_map { |pair| ["-c", pair] }
    shell = Mixlib::ShellOut.new("git", "-C", repo, *args, "commit", "--allow-empty", "-q", "-m", "probe",
                                 environment: SeedRepo::SCRUB.merge("GIT_TRACE" => "2"))
    shell.run_command.error!
    shell.stderr
  end

  around do |example|
    Dir.mktmpdir("lain-seed-guard") do |dir|
      @repo = File.join(dir, "repo")
      FileUtils.mkdir_p(@repo)
      FileUtils.cp_r("#{described_class.at({ "README" => "seed\n" })}/.", @repo)
      example.run
    end
  end

  it "commits without spawning a detached maintenance process for teardown to race" do
    expect(commit_trace(@repo)).not_to include("maintenance")
  end

  # Without this the example above could pass because the trace stopped showing
  # maintenance at all, rather than because the pins hold it off.
  it "would spawn one if the pins were lifted, so the trace above can see the difference" do
    trace = commit_trace(@repo, "maintenance.auto=true", "gc.auto=6700")

    expect(trace).to include("maintenance")
  end
end
