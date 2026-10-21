# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Confine::Sandbox do
  let(:journal) { RecordingChannel.new }
  let(:fence) { "/srv/lain-fence" }
  let(:runner) { ->(argv) { [argv.include?("--status") ? '{"abi":3}' : "", true] } }
  let(:probe) { Lain::Confine::Probe.new(fence:, journal:, runner:, ptrace_scope: -> { "0" }) }
  let(:masks) { Lain::Confine::MaskList.new(root: "/srv/project", policy: -> { :the_policy }) }
  let(:inner) { Lain::Exec::Local.new }
  let(:sandbox) { described_class.new(root: "/srv/project", home: "/home/h", masks:, probe:, fence:, journal:) }

  def degraded = journal.events.grep(Lain::Telemetry::CapabilityDegraded)

  describe "#wrap" do
    it "wraps the exec in the sandbox when the probe offers every layer" do
      exec = sandbox.wrap(inner, requirer: "Spec")

      expect(exec).to be_a(Lain::Exec::Sandboxed)
      expect(exec.instance_variable_get(:@inner)).to be(inner)
      expect(exec.instance_variable_get(:@launcher)).to be_a(Lain::Confine::Bwrap)
      expect(degraded).to be_empty
    end

    it "hands the profiles the mask list it was given and the home" do
      profiles = sandbox.wrap(inner, requirer: "Spec").instance_variable_get(:@profiles)

      expect(profiles.instance_variable_get(:@masks)).to be(masks)
      expect([profiles.instance_variable_get(:@home), profiles.instance_variable_get(:@root)])
        .to eq(["/home/h", "/srv/project"])
    end

    context "when the box lacks a layer" do
      let(:runner) { ->(_argv) { ["", false] } }

      it "returns the inner exec and journals the sandbox as degraded under the requirer" do
        expect(sandbox.wrap(inner, requirer: "Spec")).to be(inner)
        expect(degraded.find { _1.capability == :sandbox }).to have_attributes(requirer: "Spec")
      end

      it "journals the degraded record to the notes sink when one is given, not the journal" do
        notes = RecordingChannel.new
        noting = described_class.new(root: "/srv/project", home: "/home/h", masks:, probe:, fence:, journal:, notes:)
        noting.wrap(inner, requirer: "Spec")

        expect(notes.events.grep(Lain::Telemetry::CapabilityDegraded).map(&:capability)).to eq([:sandbox])
        expect(journal.events.grep(Lain::Telemetry::CapabilityDegraded).map(&:capability)).not_to include(:sandbox)
      end
    end
  end

  describe ".degraded" do
    it "journals the sandbox as unavailable for the reason given and answers the exec it was handed" do
      exec = described_class.degraded(inner, journal:, requirer: "Spec", because: "no box")

      expect(exec).to be(inner)
      expect(degraded.map(&:to_h)).to contain_exactly(
        a_hash_including(capability: :sandbox, requirer: "Spec", provider: "no box")
      )
    end
  end

  describe "#prime" do
    it "starts the mask classification of a sandbox it built" do
      sandbox.wrap(inner, requirer: "Spec")
      sandbox.prime

      expect(masks.instance_variable_get(:@priming)).to be_a(Thread)
    end

    it "starts nothing when no sandbox was built" do
      sandbox.prime

      expect(masks.instance_variable_get(:@priming)).to be_nil
    end
  end

  describe "a reader call whose listed link lands on what the call runs on", :seam do
    let(:fence) { Lain::Confine::Bwrap.fence_binary }

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
    end

    around do |example|
      Dir.mktmpdir("lain-sandbox-overmask") do |dir|
        @base = File.realpath(dir)
        example.run
      end
    end

    def home = File.join(@base, "home")
    def repo = File.join(@base, "repo")

    def plant(name, target)
      FileUtils.mkdir_p([repo, File.join(home, ".ssh")])
      File.write(File.join(repo, "plain.txt"), "plain words\n")
      File.symlink(target, File.join(repo, name))
      system(SeedRepo::SCRUB, "git", "init", "-q", chdir: repo, exception: true)
    end

    def policy
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: repo, root: repo), home:, root: repo)
    end

    def sandboxed_over(name, target)
      plant(name, target)
      judging = policy
      masks = Lain::Confine::MaskList.new(root: repo, policy: -> { judging })
      described_class.new(root: repo, home:, masks:, probe: Lain::Confine::Probe.new(fence:, journal:), fence:,
                          journal:).wrap(Lain::Exec::Local.new, requirer: "Spec")
    end

    def cat_plain(exec, command: "cat plain.txt", executables: [])
      ruling = Lain::Approval::Escalation::Ruling.allow(rung: "rules", because: "spec", rule: "composed_term")
      request = Lain::Confine::Request.new(ruling:, executables:, cwd: repo, root: repo, tool_use_id: "toolu_1")
      exec.call(command:, cwd: repo, env: {}, timeout: 10, confinement: request)
    end

    def user_program(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#!/bin/sh\necho ran\n")
      File.chmod(0o755, path)
      Lain::Shell::Executable.new(name: File.basename(path), resolved: path, realpath: path, chain: [], shadowed: [],
                                  anomalies: [], klass: :user, fresh: false, run_files: [], wrappers: [])
    end

    {
      "the project root" => ["id_rsa", -> { "." }, -> { repo }],
      "the home directory" => ["secrets.key", -> { home }, -> { home }],
      "/" => ["server.pem", -> { "/" }, -> { "/" }],
      "/usr" => ["credentials", -> { "/usr" }, -> { "/usr" }]
    }.each do |landing, (name, target, landed)|
      it "refuses the call, naming the link, when a listed link lands on #{landing}" do
        capture = cat_plain(sandboxed_over(name, instance_exec(&target)))

        expect(capture).to have_attributes(exit_status: Lain::Shell::Pipeline::NOT_PERMITTED, stdout: "")
        expect(capture.stderr).to include(name, instance_exec(&landed)).and start_with("lain: REFUSED")
      end
    end

    it "refuses the call, naming the link, when a listed link lands on a program the call was granted" do
      program = File.join(home, ".local", "bin", "tool")
      executable = user_program(program)
      capture = cat_plain(sandboxed_over("id_rsa", program), command: program, executables: [executable])

      expect(capture).to have_attributes(exit_status: Lain::Shell::Pipeline::NOT_PERMITTED, stdout: "")
      expect(capture.stderr).to include("id_rsa", program).and start_with("lain: REFUSED")
    end

    it "runs when a masked directory's name only starts like a grant's" do
      FileUtils.mkdir_p(File.join(home, ".rust"))
      capture = cat_plain(sandboxed_over("secrets.key", File.join(home, ".rust")))

      expect(capture).to have_attributes(exit_status: 0, stdout: "plain words\n")
    end
  end
end
