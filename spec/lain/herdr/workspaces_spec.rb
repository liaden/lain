# frozen_string_literal: true

RSpec.describe Lain::Herdr::Workspaces do
  let(:listing) { File.read(File.expand_path("../../fixtures/herdr/workspace_list.json", __dir__)) }
  let(:env) { { "HERDR_BIN_PATH" => "/opt/herdr", "HERDR_SOCKET_PATH" => "/run/herdr.sock" } }
  let(:calls) { [] }
  let(:answers) { Hash.new { |_hash, _key| ["{}", 0] } }
  let(:factory) do
    lambda do |*argv, **opts|
      calls << [argv, opts]
      out, status = answers[argv.drop(1).first(2)]
      instance_double(Lain::Shell::Out, run_command: nil, stdout: out, exitstatus: status)
    end
  end
  let(:workspaces) { described_class.new(env:, shell_out_factory: factory) }

  before { answers[%w[workspace list]] = [listing, 0] }

  def argvs = calls.map(&:first)

  describe "#token" do
    it "reports the value to the workspace carrying that label" do
      workspaces.token(label: "reviews", name: "reviews", value: "7 (2 new)")

      expect(argvs.last).to eq(["/opt/herdr", "workspace", "report-metadata", "w4", "--source", "lain-queue",
                                "--token", "reviews=7 (2 new)"])
    end

    it "reaches the herdr server named by the environment" do
      workspaces.token(label: "reviews", name: "reviews", value: "1")

      expect(calls.last.last[:environment]).to eq("HERDR_SOCKET_PATH" => "/run/herdr.sock")
    end

    it "runs nothing after the listing when no workspace has the label" do
      workspaces.token(label: "absent", name: "reviews", value: "1")

      expect(argvs.map { _1[1..2] }).to eq([%w[workspace list]])
    end

    it "does nothing and raises nothing without herdr" do
      bare = described_class.new(env: { "PATH" => "" }, shell_out_factory: factory)

      expect { bare.token(label: "reviews", name: "reviews", value: "1") }.not_to raise_error
      expect(calls).to be_empty
    end

    it "raises nothing when herdr fails or answers garbage" do
      answers[%w[workspace list]] = ["not json", 0]

      expect { workspaces.token(label: "reviews", name: "reviews", value: "1") }.not_to raise_error
      expect(argvs.size).to eq(1)
    end

    it "raises nothing when the spawn fails" do
      failing = ->(*, **) { raise Errno::ENOENT }

      expect { described_class.new(env:, shell_out_factory: failing).token(label: "a", name: "b", value: "c") }
        .not_to raise_error
    end
  end

  describe "#include?" do
    it "says whether a workspace carries the label" do
      expect([workspaces.include?("reviews"), workspaces.include?("absent")]).to eq([true, false])
    end

    it "says no without herdr" do
      expect(described_class.new(env: { "PATH" => "" }, shell_out_factory: factory).include?("reviews")).to be(false)
    end
  end

  describe "#notify" do
    it "shows a notification" do
      workspaces.notify(title: "3 reviews", body: "2 new")

      expect(argvs.last).to eq(["/opt/herdr", "notification", "show", "3 reviews", "--body", "2 new"])
    end

    it "does nothing without herdr" do
      described_class.new(env: { "PATH" => "" }, shell_out_factory: factory).notify(title: "a", body: "b")

      expect(calls).to be_empty
    end
  end

  describe "#create" do
    it "opens a labelled, focused workspace at cwd and runs the command in its root pane" do
      answers[%w[workspace create]] = ['{"result":{"root_pane":{"pane_id":"w9:p1"}}}', 0]

      started = workspaces.create(cwd: "/work/repo", command: "lain up --nvim", label: "review repo")

      created = ["/opt/herdr", "workspace", "create", "--cwd", "/work/repo", "--label", "review repo", "--focus"]

      expect([started, argvs]).to eq(["w9:p1", [created, ["/opt/herdr", "pane", "run", "w9:p1", "lain up --nvim"]]])
    end

    it "runs nothing further, and says so, when the workspace was not created" do
      answers[%w[workspace create]] = ["", 1]

      started = workspaces.create(cwd: "/work/repo", command: "x", label: "y")

      expect([started, argvs.size]).to eq([nil, 1])
    end

    it "says the command did not start when the pane would not run it" do
      answers[%w[workspace create]] = ['{"result":{"root_pane":{"pane_id":"w9:p1"}}}', 0]
      answers[%w[pane run]] = ["", 1]

      expect(workspaces.create(cwd: "/work/repo", command: "x", label: "y")).to be_nil
    end
  end

  describe "an answer that is valid JSON of the wrong shape" do
    ["null", "[]", '"text"', "{}", '{"result":{}}', '{"result":{"workspaces":null}}'].each do |body|
      it "makes #token do nothing for #{body}" do
        answers[%w[workspace list]] = [body, 0]

        expect { workspaces.token(label: "reviews", name: "reviews", value: "1") }.not_to raise_error
        expect(argvs.size).to eq(1)
      end

      it "makes #create run nothing further for #{body}" do
        answers[%w[workspace create]] = [body, 0]

        expect { workspaces.create(cwd: "/work/repo", command: "x", label: "y") }.not_to raise_error
        expect(argvs.size).to eq(1)
      end
    end
  end

  it "finds herdr on PATH when HERDR_BIN_PATH is unset" do
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "herdr")
      File.write(bin, "")
      File.chmod(0o755, bin)

      described_class.new(env: { "PATH" => dir }, shell_out_factory: factory).notify(title: "a", body: "b")

      expect(argvs.last.first).to eq(bin)
    end
  end

  it "runs the real herdr argv through Shell::Out" do
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "herdr")
      File.write(bin, "#!/bin/sh\necho \"$@\" >> #{dir}/log\necho '#{listing.strip}'\n")
      File.chmod(0o755, bin)

      described_class.new(env: { "HERDR_BIN_PATH" => bin }).token(label: "reviews", name: "reviews", value: "4")

      expect(File.read("#{dir}/log")).to include("workspace report-metadata w4 --source lain-queue --token reviews=4")
    end
  end
end
