# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# `lain epic finish SLUG`: once every issue of an epic is done, its working
# branch goes to the remote as one branch, one pull request to main is opened
# and merged, and the remote branch is deleted. The local branch is left for
# worktree gc.
#
# Real git against a local BARE remote; GitHub is a double. Never the network.
# `exe/lain` is a script that guards its own `LainCLI.start`, so loading it only defines the Thor classes.
load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI::Epic)

RSpec.describe Lain::CLI::EpicFinish, :seam do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = File.realpath(tmp)
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", root)
      git(root, "branch", "-M", "main")
      git(root, "switch", "-q", "-c", "epic/demo")
      commit("README" => "the epic's work\n")
      git(root, "switch", "-q", "main")
      git(@tmp, "init", "--bare", "-q", remote)
      git(root, "remote", "add", "origin", remote)
      FileUtils.mkdir_p(paths.sessions_dir)
      write_epic("demo", "a" => "done", "b" => "done")
      write_epic("other", "a" => "done", "b" => "in_flight")
      example.run
    end
  end

  def root = File.join(@tmp, "project")
  def remote = File.join(@tmp, "remote.git")
  def state_home = File.join(@tmp, "state")
  def paths = @paths ||= Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home, "HOME" => state_home })
  def config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg, gates: {}))

  def write_epic(slug, statuses)
    issues = statuses.map { |id, status| Lain::Epic::Issue.new(id:, title: "the #{id} issue", status:) }
    Lain::Epic::Home.resolve(config:, paths:, root:, slug:).write_epic(Lain::Epic::Graph.new(issues:))
  end

  def shell(dir, *args)
    Lain::Shell::Out.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
                    .run_command
  end

  def git(dir, *) = SeedRepo.git(dir, *).stdout.strip

  def commit(files)
    files.each { |path, body| File.write(File.join(root, path), body) }
    git(root, "add", *files.keys)
    git(root, "commit", "-q", "-m", "work")
  end

  def tip = git(root, "rev-parse", "refs/heads/epic/demo")

  def remote_ref(ref) = shell(remote, "rev-parse", "--verify", "--quiet", ref).stdout.strip

  def answer(value) = Lain::Forge::Gh::Answer.new(ok: true, detail: { "value" => value })

  let(:github) do
    instance_double(Lain::Forge::Gh, pr_create: answer(7), pr_merge: answer(7), merge_state: answer("CLEAN"),
                                     pr_list: answer([]), pr_view: answer({ "state" => "OPEN" }))
  end
  let(:calls) { [] }
  let(:recording) do
    lambda do |*argv, **options|
      calls << argv
      Lain::Shell::Out.new(*argv, **options)
    end
  end

  def command = described_class.new(root:, paths:, config:, github:, shell_out_factory: recording)

  def forge_actions
    Dir.children(paths.sessions_dir).sort
       .flat_map { |name| Lain::Journal.records(File.foreach(File.join(paths.sessions_dir, name))).to_a }
       .select { |record| record["type"] == Lain::Forge::Intent::JOURNAL_TYPE }.map { |record| record["action"] }
  end

  describe "a finished epic becomes one PR" do
    it "promotes epic/demo, merges one pull request to main, deletes the remote branch, keeps the local one" do
      landed = tip

      output = command.finish("demo").text

      expect(github).to have_received(:pr_create).once.with(hash_including(base: "main", head: "epic/demo"))
      expect(github).to have_received(:pr_merge).once
      expect(remote_ref("refs/heads/epic/demo")).to be_empty
      expect(tip).to eq(landed)
      expect(forge_actions).to eq(%w[promote pr_create pr_merge branch_delete])
      expect(output).to include("finished demo at #{landed}", "pull request #7 -- merged", "epic/demo")
    end

    it "counts a remote branch GitHub deleted on merge as done, and deletes nothing itself" do
      allow(github).to receive(:pr_merge) do
        git(remote, "update-ref", "-d", "refs/heads/epic/demo")
        answer(7)
      end

      output = command.finish("demo").text

      expect(output).to include("finished demo")
      expect(calls.flatten).not_to include("--delete")
    end

    it "finishes when somebody else merged the pull request, deleting the remote branch" do
      allow(github).to receive_messages(pr_view: answer({ "state" => "MERGED" }), merge_state: answer("UNKNOWN"))

      output = command.finish("demo").text

      expect(output).to include("finished demo")
      expect(github).not_to have_received(:pr_merge)
      expect(remote_ref("refs/heads/epic/demo")).to be_empty
    end

    # Adding an issue after a finish is work that must reach main too.
    it "opens a second pull request for the tip, once the epic branch moved after a finish" do
      command.finish("demo")
      git(root, "switch", "-q", "epic/demo")
      commit("LATER" => "c's work\n")
      git(root, "switch", "-q", "main")
      write_epic("demo", "a" => "done", "b" => "done", "c" => "done")
      moved = tip

      output = command.finish("demo").text

      expect(output).to include("finished demo at #{moved}")
      expect(github).to have_received(:pr_create).twice
      expect(forge_actions).to eq(%w[promote pr_create pr_merge branch_delete] * 2)
    end

    it "changes nothing when run again" do
      command.finish("demo")
      first = forge_actions

      command.finish("demo")

      expect(forge_actions).to eq(first)
      expect(github).to have_received(:pr_create).once
    end
  end

  # Scenario: landing and finishing refuse over a torn sign-off too. Finishing
  # folds forge records, not sign-offs, but it reads the same directory -- and
  # a torn sign-off there is exactly as undecided.
  describe "a torn implementation sign-off in the session journals" do
    it "refuses, naming the file and the line, before anything reaches the remote" do
      decision = Lain::Approval::GateDecision.new(artifact_digest: "blake3:#{"a" * 64}", epic_slug: "demo",
                                                  stage: "implementation", approved: true, answered_by: "human",
                                                  policy: "hands_off", latency: 0.0, issue_id: "a")
      line = JSON.generate({ "ts" => "2026-01-01T00:00:00.000000Z" }.merge(decision.to_journal))
      File.write(File.join(paths.sessions_dir, "fixture.ndjson"), line[0, line.size / 2])

      expect { command.finish("demo") }
        .to raise_error(Lain::CLI::SessionJournals::Unreadable, /fixture\.ndjson.*line 1/)
      expect(github).not_to have_received(:pr_create)
      expect(remote_ref("refs/heads/epic/demo")).to be_empty
    end
  end

  describe "an unfinished one is refused" do
    it "names the issue that is not done, before anything reaches the remote" do
      expect { command.finish("other") }.to raise_error(described_class::Unfinished) { |error|
        expect(error.message).to include("b", "in_flight")
      }
      expect(forge_actions).to be_empty
      expect(calls.flatten).not_to include("push")
    end

    it "names the remedy for an abandoned issue, which cannot be landed" do
      write_epic("shelved", "a" => "done", "b" => "abandoned")

      expect { command.finish("shelved") }.to raise_error(described_class::Unfinished) { |error|
        expect(error.message).to include("b is abandoned", "mark it done or remove it from epic.md")
        expect(error.message).not_to include("epic land")
      }
    end
  end

  # The removed promotion pushed one remote branch per issue beneath the
  # epic's name, and git cannot hold a branch and branches nested under it.
  describe "per-issue branches the old promotion left on the remote" do
    it "refuses, naming them, and deletes none of them" do
      %w[a b].each { |issue| git(root, "push", "-q", "origin", "#{tip}:refs/heads/epic/demo/#{issue}") }
      finish = command

      output = finish.finish("demo")

      expect(output.text).to include("stopped demo", "refs/heads/epic/demo/a", "refs/heads/epic/demo/b",
                                     "`lain epic finish demo` again")
      expect(output.status).to eq(1)
      expect(%w[a b].map { |issue| remote_ref("refs/heads/epic/demo/#{issue}") }).to all(eq(tip))
      expect(remote_ref("refs/heads/epic/demo")).to be_empty
      expect(github).not_to have_received(:pr_create)
    end
  end

  describe "a repository with no remote" do
    before { git(root, "remote", "remove", "origin") }

    it "refuses in words naming --local, touching nothing and never saying inconsistent_journal" do
      expect { command.finish("demo") }.to raise_error(described_class::NoRemote) { |error|
        expect(error.message).to eq("this repository has no remote; finish it with lain epic finish demo --local")
      }
      expect(forge_actions).to be_empty
      expect(github).not_to have_received(:pr_create)
    end
  end

  describe "one command object asked to finish twice" do
    it "gives each answer its own status, so a refused finish is not inherited by the next" do
      %w[a b].each { |issue| git(root, "push", "-q", "origin", "#{tip}:refs/heads/epic/demo/#{issue}") }
      finish = command
      refused = finish.finish("demo")
      %w[a b].each { |issue| git(root, "push", "-q", "origin", ":refs/heads/epic/demo/#{issue}") }

      accepted = finish.finish("demo")

      expect([refused.status, accepted.status]).to eq([1, 0])
    end
  end

  describe "finishing locally" do
    before { git(root, "remote", "remove", "origin") }

    def local
      described_class.new(root:, paths:, config:, github:, shell_out_factory: recording,
                          finisher: described_class::Local.new(root:, shell_out_factory: recording))
    end

    def forge_records
      Dir.children(paths.sessions_dir).sort
         .flat_map { |name| Lain::Journal.records(File.foreach(File.join(paths.sessions_dir, name))).to_a }
         .select { |record| record["type"].start_with?("forge_") }
    end

    it "merges epic/demo into main, pushes nothing, and journals the finish with remote false" do
      before = git(root, "rev-parse", "main")
      landed = tip

      output = local.finish("demo").text

      expect(git(root, "rev-list", "--parents", "-n", "1", "main").split.drop(1)).to eq([before, landed])
      expect(output).to include("finished demo at #{landed}", "merged into main", "nothing was pushed")
      expect(calls.flatten).not_to include("push")
      expect(github).not_to have_received(:pr_create)
      intent, outcome = forge_records
      expect(intent).to include("action" => "local_merge", "epic_slug" => "demo")
      expect(outcome).to include("intent_id" => intent["intent_id"], "ok" => true)
      expect(outcome["detail"]).to include("remote" => false)
      expect([intent["params"]["sha"], outcome["detail"]["sha"]]).to eq([landed, landed])
    end

    it "refuses an epic with no branch, naming it, and journals nothing" do
      git(root, "branch", "-q", "-D", "epic/demo")

      expect { local.finish("demo") }.to raise_error(described_class::NoBranch) { |error|
        expect(error.message).to eq("there is no epic/demo branch in #{root} -- nothing merged into main")
      }
      expect(forge_records).to be_empty
    end

    it "refuses an unfinished epic, naming the issue, and journals nothing" do
      expect { local.finish("other") }.to raise_error(described_class::Unfinished) { |error|
        expect(error.message).to include("b is in_flight", "nothing merged into main")
        expect(error.message).not_to include("remote")
      }
      expect(forge_records).to be_empty
    end

    it "stops on a conflict, naming the path, with main where it was" do
      commit("README" => "main moved\n")
      before = git(root, "rev-parse", "main")

      output = local.finish("demo").text

      expect(output).to include("stopped demo", "README", "`lain epic finish demo --local` again")
      expect(git(root, "rev-parse", "main")).to eq(before)
    end

    it "is what `lain epic finish SLUG --local` runs" do
      env = { "XDG_STATE_HOME" => state_home, "XDG_CONFIG_HOME" => File.join(@tmp, "config"), "HOME" => state_home }
      before = git(root, "rev-parse", "main")

      with_env(env) do
        home = Lain::Epic::Home.resolve(config: Lain::Config.load(root:), paths: Lain::Paths.new, root:, slug: "demo")
        home.write_epic(Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "a", status: "done")]))
        expect { Dir.chdir(root) { LainCLI::Epic.start(%w[finish demo --local], debug: true) } }
          .to output(/finished demo.*nothing was pushed/m).to_stdout
      end

      expect(git(root, "rev-list", "--parents", "-n", "1", "main").split.drop(1)).to eq([before, tip])
    end

    it "is never read by a later remote finish as that finish's own merge" do
      local.finish("demo")
      git(root, "remote", "add", "origin", remote)

      command.finish("demo")

      expect(github).to have_received(:pr_merge).once
      expect(forge_actions).to eq(%w[local_merge promote pr_create pr_merge branch_delete])
    end

    # A crash between the intent and its outcome: the remote fold reads every
    # forge record of the epic, and an unanswerable one would stop it for good.
    it "does not stop a later remote finish when a local merge crashed before its outcome" do
      crashed = Lain::Forge::Intent.new(action: "local_merge", epic_slug: "demo",
                                        issue_id: Lain::Forge::Landing::WHOLE_EPIC,
                                        params: { "head" => "epic/demo", "base" => "main", "sha" => tip })
      line = JSON.generate({ "ts" => "2026-01-01T00:00:00.000000Z" }.merge(crashed.to_journal))
      File.write(File.join(paths.sessions_dir, "crashed.ndjson"), "#{line}\n")
      git(root, "remote", "add", "origin", remote)

      output = command.finish("demo").text

      expect(output).to include("finished demo", "pull request #7 -- merged")
      expect(github).to have_received(:pr_merge).once
    end
  end

  it "runs its git through Shell::Out, as lain epic land does" do
    allow(Lain::Shell::Out).to receive(:new).and_call_original

    described_class.new(root:, paths:, config:, github:).finish("demo")

    expect(Lain::Shell::Out).to have_received(:new).with("git", "-C", any_args).at_least(:once)
  end

  it "refuses an unnamed choice between epics, advising the finish spelling" do
    expect { command.finish }.to raise_error(Lain::CLI::Epic::Ambiguous, /name one: lain epic finish SLUG/)
  end
end
