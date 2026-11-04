# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A git read the judge approves under the workspace profile is not walked, so what keeps a secret
# from history out of the model's copy is the output mask: the history the board reads off the
# repository, applied to the result of a real `git log -p` on the way out of the tool phase.
RSpec.describe "A judge-approved git log over a secret in history", :seam do
  # No credential shape, so it is the history the board read that masks it, not the shape detector.
  let(:secret) { "quietly-kept-history-value" }
  let(:journal) { RecordingChannel.new }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal:, journal_path: "judged-git-history.ndjson") }
  let(:toolset) { Lain::Toolset.new([Lain::Tools::Bash.new]) }
  let(:session) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: @root, env: {})) }
  let(:asked) { [] }

  around do |example|
    Dir.mktmpdir("judged-git-history") do |dir|
      base = File.realpath(dir)
      @home = File.join(base, "home")
      @root = File.join(base, "repo")
      FileUtils.mkdir_p(@home)
      FileUtils.cp_r("#{SeedRepo.at({ ".env" => "APP_COLOUR=#{secret}\n", "README" => "seed\n" })}/.", @root)
      SeedRepo.git(@root, "rm", "-q", ".env")
      SeedRepo.git(@root, "commit", "-q", "-m", "drop the env file")
      example.run
    end
  end

  def policy
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: @home, cwd: @root, root: @root),
                                  home: @home, root: @root)
  end

  def board
    @board ||= begin
      sensitivity = policy
      history = Lain::Sensitivity::HistoryLiterals.new(root: @root, policy: sensitivity).prime
      secrets = Lain::Sensitivity::Secrets::Source.new(child_env: Lain::Exec::ChildEnv.new(env: {}), history:)
      Lain::CLI::Switchboard.new(journal: chronicle.record_journal, model: "m", toolset:, sensitivity:, secrets:,
                                 attended: false, approval: :auto,
                                 judge: ->(tool:, **) { asked.push(tool).then { :approve } },
                                 masks: Lain::Approval::Judgement::Masking.new(
                                   Lain::Confine::MaskList.new(root: @root, policy: -> { sensitivity })
                                 ))
    end
  end

  def run(command)
    dispatch_call("bash", { "command" => command }, toolset: board.toolset,
                                                    layers: Lain::CLI::ToolGuard.stack(chronicle, board).to_a,
                                                    context: session)
  end

  it "runs the log the judge approved, with the value .env once held masked" do
    content = run("git log -p").content

    expect(asked).to eq(["bash"])
    expect(content).to include("drop the env file", "APP_COLOUR=<redacted:")
    expect(content).not_to include(secret)
  end
end
