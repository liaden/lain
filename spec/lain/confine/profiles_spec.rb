# frozen_string_literal: true

require "tmpdir"

RSpec.describe Lain::Confine::Profiles do
  around do |example|
    Dir.mktmpdir("lain-profiles") do |dir|
      @base = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@base, "project"))
      example.run
    end
  end

  let(:root) { File.join(@base, "project") }
  let(:home) { File.join(@base, "home") }
  let(:journal) { [] }
  let(:answers) do
    { "bwrap" => ["", true], "lain-fence" => ["{\"abi\":6,\"rights\":{},\"skipped\":[]}\n", true],
      "strace" => ["strace 6.1", true] }
  end
  let(:probe) do
    Lain::Confine::Probe.new(fence: "/x/lain-fence", journal:, ptrace_scope: -> { "1\n" },
                             runner: ->(argv) { answers.fetch(File.basename(argv.first)) })
  end
  let(:masked) { [] }
  let(:masks) { Struct.new(:masks).new(masked) }
  let(:profiles) { described_class.new(masks:, probe:, home:, root:) }

  def ruling(rung, rule: nil, authority: :automatic)
    Lain::Approval::Escalation::Ruling.allow(rung:, because: "approved", rule:, authority:)
  end

  def request(ruling, executables: [], root: self.root)
    Lain::Confine::Request.new(ruling:, executables:, cwd: root, root:, tool_use_id: "toolu_1")
  end

  def composed(executables: []) = request(ruling("rules", rule: "composed_term"), executables:)

  def executable(name, realpath, klass)
    Lain::Shell::Executable.new(name:, resolved: realpath, realpath:, chain: [], shadowed: [], anomalies: [],
                                klass:, fresh: false, run_files: [], wrappers: [])
  end

  def mask(path) = Lain::Sensitivity::Policy::Mask.new(path:, reason: "secret")

  describe "#for" do
    it "confines a ComposedTerm approval under the reader profile, the project first" do
      profile = profiles.for(composed)

      expect(profile).to have_attributes(name: :reader, trace: true, confined?: true)
      expect(profile.read_dirs.first).to eq(root)
    end

    it "confines a call to the root its request names, as a worktree child's does" do
      child = File.join(@base, "child")
      FileUtils.mkdir_p(child)
      ruled = request(ruling("rules", rule: "composed_term"), root: child)

      expect(profiles.for(ruled).read_dirs.first).to eq(child)
    end

    it "falls back to the session's root when the request names none" do
      expect(profiles.for(request(ruling("rules", rule: "composed_term"), root: nil)).read_dirs.first).to eq(root)
    end

    it "traces an abstention that names the reader rule, since only an allow earns the reader profile" do
      barred = Lain::Approval::Escalation::Ruling.abstain(rung: "rules", because: "barred", rule: "composed_term")
      expect(profiles.for(request(barred))).to eq(Lain::Confine::Profile::TRACED)
    end

    it "masks what the mask list holds when the call is made, not when the profiles were built" do
      profiles
      masked << mask(File.join(root, ".env"))

      expect(profiles.for(composed).masks).to eq([File.join(root, ".env")])
    end

    it "traces a judge's approval without confining it" do
      expect(profiles.for(request(ruling("judge")))).to eq(Lain::Confine::Profile::TRACED)
    end

    it "traces a human's approval without confining it" do
      expect(profiles.for(request(ruling("asking", authority: :human)))).to eq(Lain::Confine::Profile::TRACED)
    end

    it "traces an allow by any other rule without confining it" do
      expect(profiles.for(request(ruling("rules", rule: "project_rules")))).to eq(Lain::Confine::Profile::TRACED)
    end

    it "traces a call that carries no ruling" do
      expect(profiles.for(Lain::Confine::Request::NONE)).to eq(Lain::Confine::Profile::TRACED)
    end

    it "lets a reader run a program resolved outside /usr that no project could have planted" do
      grep = File.join(home, ".local/bin/grep")
      planted = File.join(root, "bin/cat")
      executables = [executable("grep", grep, :user), executable("cat", planted, :project),
                     executable("head", "/usr/bin/head", :system)]

      expect(profiles.for(composed(executables:)).exec_files).to eq([grep])
    end

    it "lets a reader run the wrappers that run a program" do
      bundle = File.join(home, ".local/share/mise/installs/ruby/bin/bundle")
      wrapped = Lain::Shell::Executable.unresolved("ruby", wrappers: [executable("bundle", bundle, :user)])

      expect(profiles.for(composed(executables: [wrapped])).exec_files).to eq([bundle])
    end

    context "when this kernel cannot trace" do
      before { answers["strace"] = ["", false] }

      it "still confines a reader call, with no trace" do
        expect(profiles.for(composed)).to have_attributes(name: :reader, trace: false, confined?: true)
      end

      it "neither traces nor confines any other call" do
        expect(profiles.for(request(ruling("judge")))).to eq(Lain::Confine::Profile::NONE)
      end
    end
  end
end
