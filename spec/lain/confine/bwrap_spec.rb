# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe Lain::Confine::Bwrap do
  subject(:launcher) { described_class.new(fence: "/f/lain-fence") }

  let(:term) { Lain::Shell::Term.of(%w[cat README.md]) }
  let(:reader) { Lain::Confine::Profile.reader(root: "/p", home: "/h", masks: ["/p/.env"], exec_files: ["/h/.local/bin/grep"]) }

  def argv_of(wrapped) = wrapped.stages.first.argv

  describe "#wrap" do
    it "puts the reader profile's call inside bwrap, then strace, then the fence" do
      expect(argv_of(launcher.wrap(term, reader, trace_fd: 3))).to eq(
        %W[/usr/bin/bwrap --ro-bind / / --dev /dev --proc /proc
           --size #{Lain::Confine::Profile::TMPFS_BYTES} --tmpfs /tmp --unshare-pid --die-with-parent
           --ro-bind /dev/null /p/.env --
           /usr/bin/strace -f --seccomp-bpf -e trace=execve,execveat -o /dev/fd/3 --
           /f/lain-fence --exec-dir /usr --exec-dir /h/.rustup/toolchains --exec-file /h/.local/bin/grep
           --read-dir /p --read-dir /usr --read-dir /etc --read-dir /proc --read-dir /dev/null
           --read-dir /dev/urandom --read-dir /tmp --read-dir /h/.rustup --read-dir /h/.cargo/bin
           --read-dir /h/.config/git --read-dir /h/.gitconfig --read-dir /h/.local/share/mise/installs
           --write-dir /dev/null --write-dir /tmp --
           cat README.md]
      )
    end

    it "binds back each read dir under /tmp after the private /tmp hides it, then masks" do
      under = Lain::Confine::Profile.reader(root: "/tmp/p", home: "/h", masks: ["/tmp/p/.env"])
      expect(argv_of(launcher.wrap(term, under, trace_fd: 3)).each_cons(3).to_a).to include(
        %w[--tmpfs /tmp --unshare-pid], %w[--ro-bind-try /tmp/p /tmp/p], %w[/tmp/p --ro-bind /dev/null]
      )
    end

    it "binds back a project that is /tmp itself, and a granted program under /tmp" do
      under = Lain::Confine::Profile.reader(root: "/tmp", home: "/h", exec_files: ["/tmp/x/grep"])
      expect(argv_of(launcher.wrap(term, under, trace_fd: 3)).each_cons(3).to_a).to include(
        %w[--ro-bind-try /tmp /tmp], %w[--ro-bind-try /tmp/x/grep /tmp/x/grep]
      )
    end

    it "keeps its private /tmp when the project is elsewhere" do
      expect(argv_of(launcher.wrap(term, reader, trace_fd: 3))).not_to include("--ro-bind-try")
    end

    it "leaves the trace out of a reader profile that has none" do
      untraced = Lain::Confine::Profile.reader(root: "/p", home: "/h", trace: false)
      expect(argv_of(launcher.wrap(term, untraced, trace_fd: 3))).not_to include("/usr/bin/strace")
    end

    it "wraps a traced profile with strace only" do
      expect(argv_of(launcher.wrap(term, Lain::Confine::Profile::TRACED, trace_fd: 5))).to eq(
        %w[/usr/bin/strace -f --seccomp-bpf -e trace=execve,execveat -o /dev/fd/5 -- cat README.md]
      )
    end

    it "returns the term unchanged under :none" do
      expect(launcher.wrap(term, Lain::Confine::Profile::NONE, trace_fd: 3)).to equal(term)
    end

    it "prefixes every stage of every pipeline and keeps what each discards" do
      stage = ->(argv, discards = []) { Lain::Shell::Term::Stage.new(argv:, discards:) }
      piped = Lain::Shell::Term.new(pipelines: [
                                      Lain::Shell::Term::Pipeline.new(stages: [stage.call(%w[ls], [:stderr]),
                                                                               stage.call(%w[wc -l])]),
                                      Lain::Shell::Term::Pipeline.new(stages: [stage.call(%w[pwd])])
                                    ])
      wrapped = launcher.wrap(piped, Lain::Confine::Profile::TRACED, trace_fd: 3)
      expect(wrapped.pipelines.map { |pipeline| pipeline.stages.map { [_1.argv.last(2), _1.discards] } })
        .to eq([[[%w[-- ls], [:stderr]], [%w[wc -l], []]], [[%w[-- pwd], []]]])
    end
  end

  describe ".fence_binary" do
    it "is the release build in the cargo target dir" do
      expect(described_class.fence_binary(env: { "CARGO_TARGET_DIR" => "/t" })).to eq("/t/release/lain-fence")
    end
  end

  describe "a reader call on this box", :seam do
    let(:fence) { described_class.fence_binary }

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
      skip("bwrap cannot make a user namespace on this host") unless
        system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
    end

    around do |example|
      Dir.mktmpdir(nil, example.metadata.fetch(:under, Dir.tmpdir)) do |dir|
        @dir = File.realpath(dir)
        example.run
      end
    end

    def project = File.join(@dir, "proj")
    def home = File.join(@dir, "home")

    def plant
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "README.md"), "the readme\n")
      File.write(File.join(project, ".env"), "SECRET=1\n")
    end

    def confined(*argv)
      plant
      profile = Lain::Confine::Profile.reader(root: project, home:, masks: [File.join(project, ".env")])
      run(argv_of(described_class.new(fence:).wrap(Lain::Shell::Term.of(argv), profile, trace_fd: 3)))
    end

    def run(argv)
      reader, writer = IO.pipe
      out, err, status = Open3.capture3({ "LC_ALL" => "C" }, *argv, chdir: project, 3 => writer)
      [out, err, status.success?]
    ensure
      writer&.close
      reader&.close
    end

    # Under a TMPDIR of /tmp the private /tmp hides the file before the fence can refuse it.
    # This spec file: outside the project, outside every grant, and never under the private /tmp.
    it "refuses a file outside the project" do
      expect(confined("cat", __FILE__)).to match(["", /Permission denied/, false])
    end

    it "refuses a masked file inside the project" do
      expect(confined("cat", File.join(project, ".env"))).to match(["", /Permission denied/, false])
    end

    it "reads the project" do
      expect(confined("cat", File.join(project, "README.md"))).to eq(["the readme\n", "", true])
    end

    it "reads a project under /tmp, which the private /tmp would otherwise hide", under: "/tmp" do
      expect(confined("cat", File.join(project, "README.md"))).to eq(["the readme\n", "", true])
    end

    it "lets a forked child read its own /proc entry" do
      expect(confined("sh", "-c", "cat /proc/self/status; true")).to match([/^Name:\s+cat$/, "", true])
    end

    it "writes its private /tmp" do
      expect(confined("sh", "-c", "echo x > /tmp/scratch && cat /tmp/scratch")).to eq(["x\n", "", true])
    end
  end
end
