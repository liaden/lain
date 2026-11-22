# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe Lain::Exec::Sandboxed do
  around do |example|
    Dir.mktmpdir("lain-sandboxed", example.metadata.fetch(:under, Dir.tmpdir)) do |dir|
      @base = File.realpath(dir)
      FileUtils.mkdir_p([File.join(@base, "project"), File.join(@base, "home")])
      example.run
    end
  end

  let(:root) { File.join(@base, "project") }
  let(:home) { File.join(@base, "home") }
  let(:journal) { [] }

  let(:reader_tier) { "[ran: reader; no network; no /dev/dri; home masked]\n" }

  def ruling(rung, rule: nil) = Lain::Approval::Escalation::Ruling.allow(rung:, because: "approved", rule:)

  def executable(name, realpath, klass)
    Lain::Shell::Executable.new(name:, resolved: realpath, realpath:, chain: [], shadowed: [], anomalies: [],
                                klass:, fresh: false, run_files: [], wrappers: [])
  end

  # A spec's paths sit under its TMPDIR, which can read as a token; the refusal then names no path.
  def as_shown(path)
    line = format(described_class::REFUSED, path:)
    Lain::Sensitivity::Regions.detect(line).empty? ? path : described_class::PATH_WITHHELD
  end

  def composed(executables: [executable("cat", "/usr/bin/cat", :system)])
    Lain::Confine::Request.new(ruling: ruling("rules", rule: "composed_term"), executables:, cwd: root, root:,
                               tool_use_id: "toolu_1")
  end

  def judged
    Lain::Confine::Request.new(ruling: ruling("judge"), executables: [], cwd: root, root:, tool_use_id: "toolu_1")
  end

  def recorded(type) = journal.select { _1.journal_type == type }

  describe "with its collaborators doubled" do
    let(:profile) { Lain::Confine::Profile.reader(root:, home:) }
    let(:profiles) { Struct.new(:profile) { def for(_request) = profile }.new(profile) }
    let(:launcher) { Lain::Confine::Bwrap.new(fence: "/x/lain-fence") }
    let(:inner) { inner_class.new }
    let(:sandboxed) { described_class.new(inner:, launcher:, profiles:, journal:, ceiling: 4096) }
    let(:inner_class) do
      Class.new do
        attr_reader :calls
        attr_accessor :behaviour

        def initialize
          @calls = []
          @behaviour = ->(**) { Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "") }
        end

        def takes_term?(term) = term.stages.size == 1

        def call(**kwargs)
          @calls << kwargs
          behaviour.call(**kwargs)
        end
      end
    end

    def tier = "#{profile.tier_line}\n"

    def run(command: Lain::Shell::Term.of(%w[cat README.md]), timeout: 5, confinement: composed)
      sandboxed.call(command:, cwd: root, env: {}, timeout:, confinement:)
    end

    it "answers for a term as its inner exec does" do
      piped = Lain::Shell::Term.of(%w[cat a], %w[head -1])
      expect([sandboxed.takes_term?(Lain::Shell::Term.of(%w[cat a])), sandboxed.takes_term?(piped)])
        .to eq([true, false])
    end

    it "runs nothing when a program the call resolved to lies outside what the profile may run" do
      planted = File.join(root, "bin/cat")
      capture = run(confinement: composed(executables: [executable("cat", planted, :project)]))

      expect(inner.calls).to be_empty
      expect(capture).to have_attributes(exit_status: 126, stdout: "")
      expect(capture.stderr).to include(format(described_class::REFUSED, path: as_shown(planted)))
      expect(recorded("exec_record").sole).to have_attributes(execs: [], refusals: [], fd_execs: [])
      expect(recorded("sandbox").sole).to have_attributes(profile: :reader, refused: [planted])
    end

    it "runs nothing when a wrapper the call resolved to lies outside what the profile may run" do
      planted = File.join(root, "bin/nice")
      wrapped = Lain::Shell::Executable.unresolved("cat", wrappers: [executable("nice", planted, :project)])

      capture = run(confinement: composed(executables: [wrapped]))

      expect([inner.calls, capture.exit_status, recorded("sandbox").sole.refused]).to eq([[], 126, [planted]])
    end

    describe "the tier line" do
      def tail(capture) = capture.stderr.lines.last.chomp

      it "ends a reader run with what it lacked" do
        expect(tail(run)).to eq("[ran: reader; no network; no /dev/dri; home masked]")
      end

      it "starts the line on its own when stderr did not end in a newline, so the line can be found" do
        inner.behaviour = ->(**) { Lain::Exec::Capture.new(exit_status: 1, stdout: "", stderr: "bad") }

        expect(run.stderr).to eq("bad\n#{profile.tier_line}\n")
      end

      it "finds the line at the end of an over-ceiling capture whose stderr had no newline" do
        inner.behaviour = lambda do |**|
          Lain::Exec::Capture.new(exit_status: 1, stdout: "a" * 4000, stderr: "bad", size: 9000, ceiling: 4096)
        end

        expect(described_class::Tier.last_line(run.stderr)).to eq("#{profile.tier_line}\n")
      end

      it "ends a call that timed out with the line, since it ran" do
        inner.behaviour = ->(**) { raise Lain::Exec::Timeout, "partial output" }

        expect { run }.to raise_error(Lain::Exec::Timeout, "partial output\n#{profile.tier_line}\n")
      end

      it "carries no line when the call was refused before it ran, since nothing ran" do
        planted = File.join(root, "bin/cat")
        capture = run(confinement: composed(executables: [executable("cat", planted, :project)]))

        expect(capture.exit_status).to eq(126)
        expect(described_class::Tier.last_line(capture.stderr)).to be_nil
      end

      it "carries no line when the profile could not be chosen, since nothing ran" do
        error = Lain::Confine::Profiles::Overmasked.new(path: root, names: ["link"], profile: :workspace)
        raising = Struct.new(:error) { def for(_request) = raise(error) }.new(error)
        capture = described_class.new(inner:, launcher:, profiles: raising, journal:)
                                 .call(command: Lain::Shell::Term.of(%w[cat README.md]), cwd: root, env: {},
                                       timeout: 5, confinement: composed)

        expect(described_class::Tier.last_line(capture.stderr)).to be_nil
      end

      describe "against the output ceiling" do
        def producing(bytes)
          inner.behaviour = ->(**) { Lain::Exec::Capture.new(exit_status: 0, stdout: "a" * bytes, stderr: "", ceiling: 4096) }
        end

        it "does not count the line, so a result exactly at the ceiling still renders" do
          producing(4096)
          capture = run

          expect(capture.size).to eq(4096)
          rendered = Lain::Tools::Bash.render_output(capture)

          expect(rendered).to be_ok
          expect(rendered.content).to end_with("#{tail(capture)}\n")
        end

        it "ends a capture over the ceiling with the line too" do
          inner.behaviour = lambda do |**|
            Lain::Exec::Capture.new(exit_status: 0, stdout: "a" * 4097, stderr: "", size: 9000, ceiling: 4096)
          end
          capture = run

          expect([capture.size, tail(capture)]).to eq([9000, "[ran: reader; no network; no /dev/dri; home masked]"])
        end
      end

      context "with the traced profile" do
        let(:profile) { Lain::Confine::Profile::TRACED }

        it "says the run was unconfined" do
          expect(tail(run(confinement: judged))).to eq("[ran: unconfined, with network]")
        end
      end

      context "with a build granted ports" do
        let(:profile) { Lain::Confine::Profile.reader(root:, home:).with(connect_ports: [443, 80]) }

        it "names the ports rather than claiming no network" do
          expect(tail(run)).to eq("[ran: reader; network only on ports 443, 80; no /dev/dri; home masked]")
        end
      end

      context "when the kernel does not enforce the network rule" do
        let(:sandboxed) do
          described_class.new(inner:, launcher:, profiles:, journal:, ceiling: 4096, net_enforced: false)
        end

        it "says with network for a confined profile with no private network" do
          expect(tail(run)).to eq("[ran: reader; with network; no /dev/dri; home masked]")
        end

        it "records network true" do
          run

          expect(recorded("sandbox").sole).to have_attributes(network: true)
        end
      end

      context "when the kernel does not enforce the network rule but the call has a private network" do
        let(:profile) { Lain::Confine::Profile.reader(root:, home:).with(private_net: true) }
        let(:sandboxed) do
          described_class.new(inner:, launcher:, profiles:, journal:, ceiling: 4096, net_enforced: false)
        end

        it "still says no network, since the namespace holds it" do
          expect(tail(run)).to include("no network")
        end
      end
    end

    describe "a human's approval of a call that reads secrets" do
      def human(contained: false, network: false)
        ruled = Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "approved", authority: :human,
                                                         contained:, network:)
        Lain::Confine::Request.new(ruling: ruled, executables: [], cwd: root, root:, tool_use_id: "toolu_1")
      end

      context "with a plain allow under the traced profile" do
        let(:profile) { Lain::Confine::Profile::TRACED }

        it "records network true and the traced profile" do
          run(confinement: judged)

          expect(recorded("sandbox").sole).to have_attributes(network: true, profile: :traced)
        end
      end

      context "with a contained run under a private-net profile" do
        let(:profile) { Lain::Confine::Profile.reader(root:, home:).with(private_net: true) }

        it "records no network even when the ruling named it" do
          run(confinement: human(network: true))

          expect(recorded("sandbox").sole).to have_attributes(network: false)
        end
      end

      context "with a build granted port 443" do
        let(:profile) { Lain::Confine::Profile.reader(root:, home:).with(connect_ports: [443]) }

        it "records the granted ports" do
          run(confinement: human(contained: true))

          expect(recorded("sandbox").sole).to have_attributes(network: ["443"])
        end
      end

      it "records no choice of network on a contained call" do
        run(confinement: human(contained: true))

        expect(recorded("sandbox").sole).to have_attributes(network: false)
      end

      it "tells the model a contained call ran with masked files hidden and no network" do
        capture = run(confinement: human(contained: true))

        expect(capture.stderr).to include("files lain masks read as empty or as a decoy in the sandbox",
                                          "it had no network", "read_file", "git status may list each tracked one as M")
        expect(capture.stderr).not_to include("cannot be read")
      end

      it "adds nothing to an ordinary call" do
        expect(run.stderr).not_to include(described_class::CONTAINED)
      end

      context "when the command names a masked file" do
        let(:profile) do
          Lain::Confine::Profile.reader(root:, home:,
                                        masks: [File.join(root, ".env"), File.join(root, "config/master.key")])
        end

        it "says the file is masked and reads as empty" do
          capture = run(command: Lain::Shell::Term.of(%w[cat .env]), confinement: human(contained: true))

          expect(capture.stderr).to include(".env is masked in the sandbox and reads as empty")
          expect(capture.stderr).not_to include("master.key")
        end

        it "says a decoy key is a decoy, not the project's key" do
          capture = run(command: Lain::Shell::Term.of(%w[cat config/master.key]), confinement: human(contained: true))

          expect(capture.stderr).to include("config/master.key is a decoy in the sandbox, not the project's key")
        end

        it "names the file a command string wrote" do
          capture = run(command: "cat .env", confinement: human(contained: true))

          expect(capture.stderr).to include(".env is masked in the sandbox and reads as empty")
        end

        it "names a file typed under the home, in a term and in a string alike" do
          profile = Lain::Confine::Profile.reader(root: home, home:, masks: [File.join(home, ".env")])
          tilde = Struct.new(:profile) { def for(_request) = profile }.new(profile)
          [Lain::Shell::Term.of(%w[cat ~/.env]), "cat ~/.env"].each do |command|
            capture = described_class.new(inner:, launcher:, profiles: tilde, journal:, ceiling: 4096)
                                     .call(command:, cwd: home, env: { "HOME" => home }, timeout: 5,
                                           confinement: human(contained: true))

            expect(capture.stderr).to include(".env is masked in the sandbox and reads as empty")
          end
        end

        it "keeps the note printable when a masked name holds a newline or an escape" do
          odd = File.join(root, "a\nb\e[31m")
          profile = Lain::Confine::Profile.reader(root:, home:, masks: [odd])
          odd_profiles = Struct.new(:profile) { def for(_request) = profile }.new(profile)
          capture = described_class.new(inner:, launcher:, profiles: odd_profiles, journal:, ceiling: 4096)
                                   .call(command: Lain::Shell::Term.of(["cat", "a\nb\e[31m"]), cwd: root, env: {},
                                         timeout: 5, confinement: human(contained: true))

          expect(capture.stderr).to include("is masked in the sandbox").and(satisfy { !_1.include?("\e") })
          expect(capture.stderr.lines.size).to eq(3)
          expect(capture.stderr).to end_with("#{profile.tier_line}\n")
        end

        it "adds only today's line to a command that names no masked file" do
          capture = run(command: Lain::Shell::Term.of(%w[ls]), confinement: human(contained: true))

          expect(capture.stderr).to eq("#{described_class::CONTAINED}\n#{tier}")
        end
      end

      context "when the human answered secrets" do
        let(:profile) { Lain::Confine::Profile.reader(root:, home:).with(private_net: true, unmasked: true) }
        let(:listed) do
          names = %w[g.key .env config/master.key b.pem a.env d/.env f.key]
          [*names.map { Lain::Sensitivity::Policy::Mask.new(path: File.join(root, _1), reason: :credential) },
           Lain::Sensitivity::Policy::Mask.new(path: File.join(root, "child/d/.env"), reason: :credential),
           Lain::Sensitivity::Policy::Mask.new(path: File.join(home, ".ssh/id_ed25519"), reason: :credential)]
        end
        let(:sandboxed) do
          described_class.new(inner:, launcher:, profiles:, journal:, ceiling: 4096,
                              masks: Struct.new(:masks).new(listed))
        end

        def secrets
          ruled = Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "approved", authority: :human,
                                                           contained: true, unmasked: true)
          Lain::Confine::Request.new(ruling: ruled, executables: [], cwd: root, root:, tool_use_id: "toolu_1")
        end

        it "names the first 5 files it could read, and says it had no network" do
          stderr = run(command: Lain::Shell::Term.of(%w[ls]), confinement: secrets).stderr

          expect(stderr).to include(format(described_class::Lifting::CONTAINED_SECRETS,
                                           files: ".env, a.env, b.pem, child/d/.env, config/master.key and 3 more"))
          expect(stderr).not_to include(described_class::CONTAINED, "id_ed25519")
        end

        it "names the files under the call's own root, not the session's" do
          child = File.join(root, "child")
          own = Lain::Confine::Request.new(ruling: secrets.ruling, executables: [], cwd: child, root: child,
                                           tool_use_id: "toolu_1")

          stderr = run(command: Lain::Shell::Term.of(%w[ls]), confinement: own).stderr

          expect(stderr).to include(format(described_class::Lifting::CONTAINED_SECRETS, files: "d/.env"))
        end

        it "records that the run had the project's secrets" do
          run(confinement: secrets)

          expect(recorded("sandbox").sole).to have_attributes(secrets: true, network: false)
        end
      end

      it "records no secrets on a plain contained call" do
        run(confinement: human(contained: true))

        expect(recorded("sandbox").sole).to have_attributes(secrets: false)
      end

      context "when the contained call earned a build tool's ports" do
        let(:profile) { Lain::Confine::Profile.reader(root:, home:).with(connect_ports: [443, 80]) }

        it "names the ports it could reach rather than saying it had no network" do
          capture = run(confinement: human(contained: true))

          expect(capture.stderr).to include("files lain masks read as empty or as a decoy in the sandbox", "443, 80",
                                            "read_file")
          expect(capture.stderr).not_to include("no network", "without network")
        end
      end

      context "when the profiles cannot contain the call" do
        let(:profiles) do
          Class.new do
            def for(_request) = raise(Lain::Confine::Profiles::Uncontainable.new(profile: :reader))
          end.new
        end

        it "runs nothing, and the refusal names the network answer" do
          capture = run(confinement: human(contained: true))

          expect(inner.calls).to be_empty
          expect(capture.stderr).to include(described_class::UNCONTAINABLE)
          expect(described_class::UNCONTAINABLE).to include("network")
          expect(recorded("sandbox").sole).to have_attributes(profile: :reader, refused: [])
        end
      end

      context "when the sandbox refuses every unconfined call" do
        let(:profiles) do
          Class.new do
            def for(_request) = raise(Lain::Confine::Sandbox::Unconfined.new(profile: :traced))
          end.new
        end

        it "runs nothing, and the refusal names --human remote" do
          capture = run(confinement: human)

          expect(inner.calls).to be_empty
          expect(capture.exit_status).to eq(Lain::Shell::Pipeline::NOT_PERMITTED)
          expect(capture.stderr).to include(described_class::UNCONFINED).and include("--human remote")
          expect(recorded("sandbox").sole).to have_attributes(profile: :traced, refused: [])
        end
      end
    end

    describe "the grants its record names" do
      let(:tool) { File.join(home, ".cargo/bin/rg") }
      let(:profile) { Lain::Confine::Profile.reader(root:, home:, exec_files: [tool]) }
      let(:grants) do
        [executable("rg", tool, :user), executable("x", File.join(@base, "elsewhere/x"), :user),
         executable("env", "/usr/bin/env", :system)]
      end

      def granting(grants)
        Lain::Confine::Request.new(ruling: ruling("rules", rule: "composed_term"), cwd: root, root:,
                                   tool_use_id: "toolu_1", executables: [executable("cat", "/usr/bin/cat", :system)],
                                   grants:)
      end

      it "names only the grants the profile runs because they were granted, not what /usr runs anyway" do
        run(confinement: granting(grants))

        expect(recorded("sandbox").sole.granted).to eq([tool])
      end

      it "names no grant for a call it does not confine" do
        unconfined = Lain::Confine::Profile::TRACED.with(exec_files: [tool])
        traced = Struct.new(:profile) { def for(_request) = profile }.new(unconfined)
        described_class.new(inner:, launcher:, profiles: traced, journal:)
                       .call(command: Lain::Shell::Term.of(%w[cat README.md]), cwd: root, env: {}, timeout: 5,
                             confinement: granting(grants))

        expect(recorded("sandbox").sole.granted).to eq([])
      end
    end

    it "bounds its refusal by the ceiling it was given" do
      capture = run(confinement: composed(executables: [executable("cat", File.join(root, "bin/cat"), :project)]))
      expect(capture.ceiling).to eq(4096)
    end

    it "hands the trace to descriptor 3 and wraps the term the preflight has already read" do
      run

      handed = inner.calls.sole
      expect(handed[:fds].keys).to eq([3])
      expect(handed[:launch].call(Lain::Shell::Term.of(%w[cat README.md])).stages.sole.argv.first)
        .to eq("/usr/bin/bwrap")
    end

    describe "a run that could read the project's secrets" do
      let(:key) { "4f9a2c7d1e8b3a6f0c5d2e9b7a4f1c3e" }
      let(:taint) { Lain::Sensitivity::Taint.new }
      let(:secrets) { Struct.new(:known) { def for_reads(_context) = known }.new([key]) }
      let(:profile) { Lain::Confine::Profile.reader(root:, home:).with(unmasked: true) }
      let(:sandboxed) do
        described_class.new(inner:, launcher:, profiles:, journal:, ceiling: 4096, taint: -> { taint },
                            secrets: -> { secrets })
      end

      def writing(name, body)
        inner.behaviour = lambda do |**|
          File.write(File.join(root, name), body)
          Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
        end
      end

      it "gates a file it wrote that holds a known value, and names it in the note" do
        writing("leaked.txt", "#{key}\n")

        capture = run

        expect(taint.paths).to eq([File.join(root, "leaked.txt")])
        expect(capture.stderr).to include(format(described_class::TAINTED, path: "leaked.txt"))
      end

      it "gates a file too large to scan and says it was not scanned" do
        writing("big.bin", "a" * (9 * 1024 * 1024))

        expect(run.stderr).to include(format(described_class::UNSCANNED, path: "big.bin"))
        expect(taint.paths).to eq([File.join(root, "big.bin")])
      end

      it "names a commit it made that holds a known value" do
        git = ->(*args) { SeedRepo.git(root, "-c", "user.name=s", "-c", "user.email=s@x", *args).stdout }
        git.call("init", "-q")
        File.write(File.join(root, "key"), key)
        inner.behaviour = lambda do |**|
          git.call("add", "key")
          git.call("commit", "-qm", "x")
          Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
        end

        stderr = run.stderr

        expect(stderr).to include(format(described_class::TAINTED_COMMIT, commit: git.call("rev-parse", "HEAD").strip,
                                                                          path: "key"))
      end

      it "still gates what a call wrote before it raised, and lets the error through" do
        inner.behaviour = lambda do |**|
          File.write(File.join(root, "leaked.txt"), key)
          raise Lain::Exec::Timeout, "deadline"
        end

        expect { run }.to raise_error(Lain::Exec::Timeout)
        expect(taint.paths).to eq([File.join(root, "leaked.txt")])
      end

      it "returns the call's own result when the call removed the project it ran in" do
        inner.behaviour = lambda do |**|
          FileUtils.rm_rf(root)
          Lain::Exec::Capture.new(exit_status: 0, stdout: "done", stderr: "")
        end

        expect(run).to have_attributes(exit_status: 0, stdout: "done")
      end

      it "lets any other error from the scan through" do
        allow(taint).to receive(:scan).and_raise(Errno::EIO)

        expect { run }.to raise_error(Errno::EIO)
      end

      it "holds the whole project when the scan itself fails, and lets the failure through naming the hold" do
        allow(taint).to receive(:scan).and_raise(ArgumentError, "a bug in the scan")

        expect { run }.to raise_error(ArgumentError, /\Aa bug in the scan\n.*could not finish scanning/m)
        expect(taint.paths).to eq([root])
      end

      it "journals the hold it took, naming the held path, for a human reading the session" do
        allow(taint).to receive(:scan).and_raise(ArgumentError, "a bug in the scan")

        expect { run }.to raise_error(ArgumentError)
        expect(recorded("sandbox")).to include(have_attributes(tool_use_id: "toolu_1", profile: :reader,
                                                               held: [root], secrets: true))
      end

      def refused_over_hold(path, names: [])
        taint.hold_whole(path)
        held = Struct.new(:error) { def for(_request) = raise(error) }
                     .new(Lain::Confine::Profiles::Overmasked.new(path:, names:, profile: :workspace))
        refusing = described_class.new(inner:, launcher:, profiles: held, journal:, taint: -> { taint })
        refusing.call(command: Lain::Shell::Term.of(%w[cat README.md]), cwd: root, env: {}, timeout: 5,
                      confinement: composed).stderr
      end

      it "refuses a later contained call in a held project with its own sentence, not a listed link's" do
        stderr = refused_over_hold(root)

        expect(stderr).to include("so until lain exits the project is held")
        expect(stderr).not_to include("listed link")
        expect(recorded("sandbox").sole).to have_attributes(refused: [root])
      end

      it "names a listed link that lands on a held path, as any overmask, since a link made that mask" do
        expect(refused_over_hold(File.join(root, "target"), names: ["link"])).to include("the listed link link")
      end

      it "names a held directory below the project as what is held, not the project" do
        stderr = refused_over_hold(File.join(root, "target"))

        expect(stderr).to include("so until lain exits target is held")
      end

      it "holds the whole project when the scan fails after the call raised, and keeps the call's error" do
        allow(taint).to receive(:scan).and_raise(ArgumentError, "a bug in the scan")
        inner.behaviour = ->(**) { raise Lain::Exec::Timeout, "deadline" }

        expect { run }.to raise_error(Lain::Exec::Timeout)
        expect(taint.paths).to eq([root])
      end

      it "names a directory it could not open, apart from a file too large to scan" do
        inner.behaviour = lambda do |**|
          FileUtils.mkdir_p(File.join(root, "hid"))
          File.write(File.join(root, "hid/leak"), key)
          File.chmod(0o000, File.join(root, "hid"))
          Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
        end

        expect(run.stderr).to eq("#{format(described_class::UNOPENED, path: "hid")}\n#{tier}")
      ensure
        File.chmod(0o755, File.join(root, "hid")) if File.directory?(File.join(root, "hid"))
      end

      context "when the policy already gates a written file by its name" do
        let(:policy) do
          Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:), home:, root:)
        end
        let(:sandboxed) do
          described_class.new(inner:, launcher:, profiles:, journal:, ceiling: 4096, taint: -> { taint },
                              secrets: -> { secrets },
                              classifier: policy)
        end

        it "leaves it out of the note, which names only what the gate did not already hold" do
          inner.behaviour = lambda do |**|
            [".env", "leaked.txt"].each { File.write(File.join(root, _1), key) }
            Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
          end

          expect(run.stderr).to eq("#{format(described_class::TAINTED, path: "leaked.txt")}\n#{tier}")
        end
      end

      it "adds nothing to the output when it wrote no known value" do
        writing("app.rb", "class App; end\n")

        expect([run.stderr, taint.paths]).to eq([tier, []])
      end

      context "when the profile keeps the masks" do
        let(:profile) { Lain::Confine::Profile.reader(root:, home:) }

        it "scans nothing" do
          writing("leaked.txt", key)

          expect([run.stderr, taint.paths]).to eq([tier, []])
        end
      end
    end

    describe "a profile with masks" do
      let(:env_file) { File.join(root, ".env") }
      let(:profile) { Lain::Confine::Profile.reader(root:, home:, masks: [env_file]) }

      def git(*args) = SeedRepo.git(root, "-c", "user.name=s", "-c", "user.email=s@x", *args).stdout

      def tracked_env
        File.write(env_file, "SECRET=1\n")
        git("init", "-q")
        git("add", ".env")
        git("commit", "-qm", "seed")
      end

      it "hands each stage a descriptor per mask after the trace's, binds it from there, and closes it after" do
        run(command: Lain::Shell::Term.of(%w[cat a], %w[head -1]))

        handed = inner.calls.sole
        wrapped = handed[:launch].call(Lain::Shell::Term.of(%w[cat a], %w[head -1]))
        expect(handed[:fds].keys).to eq([3, 4, 5, 6])
        expect(wrapped.stages.map { _1.argv.each_cons(3).find { |flags| flags.first == "--ro-bind-data" } })
          .to eq([["--ro-bind-data", "5", env_file], ["--ro-bind-data", "6", env_file]])
        expect(handed[:fds].values_at(5, 6)).to all(be_closed)
      end

      it "points git in the call at the filter for a tracked mask, and at nothing for an untracked one" do
        run
        File.write(env_file, "SECRET=1\n")
        run
        tracked_env
        run

        expect(inner.calls.map { _1[:pinned_env].key?("GIT_CONFIG_COUNT") }).to eq([false, false, true])
        expect(inner.calls.last[:pinned_env]).to include("GIT_CONFIG_KEY_1" => "filter.laindecoy0.clean")
      end

      it "puts back an index entry the call staged an empty mask into, and names a commit that holds one" do
        tracked_env
        before = git("rev-parse", ":.env")
        inner.behaviour = lambda do |**|
          File.write(env_file, "")
          git("commit", "-qam", "emptied")
          File.write(env_file, "SECRET=1\n")
          Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
        end

        capture = run

        expect(git("rev-parse", ":.env")).to eq(before)
        expect(capture.stderr).to include(git("rev-parse", "HEAD").chomp, ".env", "git commit --amend")
      end

      def staging_empty_env(*flags)
        lambda do |**|
          File.write(env_file, "")
          git("add", *flags, ".env")
          File.write(env_file, "SECRET=1\n")
          yield if block_given?
          Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")
        end
      end

      it "says a stand-in it could not take back out of the index is still there, and how to undo it" do
        tracked_env
        lock = File.join(root, ".git", "index.lock")
        inner.behaviour = staging_empty_env { FileUtils.touch(lock) }

        capture = run

        expect(capture.stderr).to include("could not", "update-index --cacheinfo 100644,")
        expect(capture.stderr).not_to include("put git's index entry")
      ensure
        FileUtils.rm_f(lock)
      end

      it "takes a stand-in staged for a mask git did not track back out of the index, and says so" do
        File.write(env_file, "SECRET=1\n")
        git("init", "-q")
        git("commit", "-q", "--allow-empty", "-m", "seed")
        inner.behaviour = staging_empty_env("-f")

        capture = run

        expect(git("ls-files", "--", ".env")).to eq("")
        expect(capture.stderr).to include(".env", "back out of git's index", "an empty file or a decoy was staged")
      end
    end

    context "when the fence cannot reap" do
      let(:profile) { Lain::Confine::Profile::TRACED }
      let(:sandboxed) { described_class.new(inner:, launcher:, profiles:, journal:, ceiling: 4096, reaps: false) }

      it "runs an unconfined call as written and untraced, rather than under a fence that would refuse it" do
        run(confinement: judged)

        expect(inner.calls.sole).not_to include(:fds)
        expect(inner.calls.sole[:launch]).to be(Lain::Shell::Pipeline::AS_WRITTEN)
        expect(recorded("sandbox").sole).to have_attributes(profile: :none, trace: false)
        expect(recorded("exec_record")).to be_empty
      end

      it "still confines a reader call" do
        readers = Struct.new(:profile) { def for(_request) = profile }.new(Lain::Confine::Profile.reader(root:, home:))
        described_class.new(inner:, launcher:, profiles: readers, journal:, reaps: false)
                       .call(command: Lain::Shell::Term.of(%w[cat README.md]), cwd: root, env: {}, timeout: 5,
                             confinement: composed)

        expect(recorded("sandbox").sole).to have_attributes(profile: :reader)
      end
    end

    it "closes its trace writers and journals the trace when the call times out" do
      inner.behaviour = ->(**) { raise Lain::Exec::Timeout, "too slow" }

      expect { run }.to raise_error(Lain::Exec::Timeout, /\Atoo slow\n\[ran: [^\n]+\]\n\z/)
      expect(inner.calls.sole[:fds].fetch(3)).to be_closed
      expect(recorded("exec_record").sole).to have_attributes(truncated: false, incomplete: false)
    end

    def capture = Lain::Exec::Capture.new(exit_status: 0, stdout: "", stderr: "")

    def writing(*lines)
      inner.behaviour = lambda do |fds:, **|
        fds.fetch(3).write(lines.map { "#{_1}\n" }.join)
        capture
      end
    end

    describe "a refusal after a human approved the call contained" do
      let(:planted) { "/srv/project/bin/x" }

      def approved(authority, executables: [])
        ruled = Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "approved", authority:,
                                                         contained: true)
        Lain::Confine::Request.new(ruling: ruled, executables:, cwd: root, root:, tool_use_id: "toolu_1")
      end

      def refused_exec = %(10 execve("#{planted}", ["x"], 0x0 /* 0 vars */) = -1 EACCES (Permission denied))

      it "says the human approved it contained, names what cannot run, and offers network" do
        stderr = run(confinement: approved(:human, executables: [executable("x", planted, :project)])).stderr

        expect(stderr).to include("approved it contained", as_shown(planted), "answer network")
        expect(stderr).not_to include("ask the human to approve it")
      end

      it "says the same of a program the trace saw refused" do
        writing(refused_exec)
        stderr = run(confinement: approved(:human)).stderr

        expect(stderr).to include("approved it contained", "answer network")
        expect(stderr).not_to include("ask the human to approve it")
      end

      it "keeps the plain refusal for a contained ruling from the judge" do
        writing(refused_exec)

        expect(run(confinement: approved(:automatic)).stderr)
          .to include(format(described_class::REFUSED, path: planted))
      end
    end

    it "reads what the trace holds once the call is over" do
      writing('10 execve("/usr/bin/cat", ["cat"], 0x0 /* 0 vars */) = 0')
      run

      expect(recorded("exec_record").sole)
        .to have_attributes(execs: [{ path: "/usr/bin/cat", argv0: "cat", rc: 0 }], incomplete: false)
    end

    describe "wording a refusal the trace recorded" do
      let(:planted) { "/srv/project/bin/x" }
      let(:wording) { format(described_class::REFUSED, path: planted) }

      def refused_exec(path) = %(10 execve("#{path}", ["x"], 0x0 /* 0 vars */) = -1 EACCES (Permission denied))
      def ran_exec(path) = %(11 execve("#{path}", ["x"], 0x0 /* 0 vars */) = 0)

      it "ends the output with the refusal for an exec the sandbox refused" do
        writing(refused_exec(planted))

        expect(run.stderr).to end_with("#{wording}\n#{tier}")
      end

      it "adds nothing to a call with no refusal" do
        writing(ran_exec("/usr/bin/cat"))

        expect(run.stderr).not_to include("REFUSED")
      end

      it "treats a refusal followed by a successful exec of the same program as search noise" do
        writing(refused_exec(planted), ran_exec("/usr/bin/x"))

        expect(run.stderr).not_to include("REFUSED")
      end

      it "words a refusal that no later exec of the program answered, beside one that did" do
        writing(refused_exec(planted), refused_exec("/other/y"), ran_exec("/usr/bin/y"))

        expect(run.stderr).to end_with("#{wording}\n#{tier}").and(satisfy { !_1.include?("/other/y") })
      end

      it "words a refusal that an unrelated successful exec of the same program came before" do
        inner.behaviour = lambda do |fds:, **|
          fds.fetch(3).write("#{ran_exec("/usr/bin/x")}\n")
          fds.fetch(4).write("#{refused_exec(planted)}\n")
          capture
        end

        expect(run(command: Lain::Shell::Term.of(%w[x a], %w[x b])).stderr).to end_with("#{wording}\n#{tier}")
      end

      # The output detector scans the whole result, so a path that reads as a token would withhold the
      # sentence that says why the call failed. The sentence stays; only the path goes.
      {
        "a mktemp-style dir" => "/home/alice/tmp/lain/wt-T41/t41-unseal20261026-3334363-2ovwkj/bin/tool",
        "the Nix store" => "/nix/store/9w2l1vc5kq8x3m4p0z7r6y5t4s3a2b1c-git-2.44.0/bin/git"
      }.each do |where, path|
        it "words a refused exec in #{where} with the path withheld, keeping the sentence" do
          writing(refused_exec(path))

          stderr = run.stderr
          expect(stderr).to end_with("#{format(described_class::REFUSED, path: "[path withheld]")}\n#{tier}")
          expect(stderr).not_to include(path)
          expect(Lain::Sensitivity::Regions.detect(stderr)).to be_empty
        end
      end

      it "shows a path holding a newline on one line, so it cannot forge another" do
        forged = "#{planted}\nforged"
        writing(refused_exec(forged.gsub("\n", "\\n")))

        stderr = run.stderr
        expect(stderr).to include(format(described_class::REFUSED, path: "#{planted}\\nforged"))
        expect(stderr.lines.size).to eq(2)
        expect(stderr).to end_with(tier)
      end

      def loud(stdout, exit_status: 3, size: stdout.bytesize)
        inner.behaviour = lambda do |fds:, **|
          fds.fetch(3).write("#{refused_exec(planted)}\n")
          Lain::Exec::Capture.new(exit_status:, stdout:, stderr: "", size:, ceiling: 4096)
        end
      end

      it "keeps the line visible when it would push an output just under the ceiling over it" do
        loud("a" * 4000)
        capture = run

        expect(capture).to have_attributes(exit_status: 3, stdout: "",
                                           stderr: a_string_ending_with("#{wording}\n#{tier}"))
        expect(Lain::Tools::Bash.render_output(capture)).to be_ok
      end

      it "keeps the line visible when the output is already over the ceiling" do
        loud("a" * 4097, size: 9000)
        capture = run

        expect(capture).to have_attributes(exit_status: 3, stdout: "",
                                           stderr: a_string_ending_with("#{wording}\n#{tier}"))
        expect(Lain::Tools::Bash.render_output(capture)).to be_ok
      end

      it "counts the added line in the capture's size, and the tier line after it not at all" do
        writing(refused_exec(planted))
        capture = run
        tier = described_class::Tier.last_line(capture.stderr)

        expect(capture.size).to eq(capture.stdout.bytesize + capture.stderr.bytesize - tier.bytesize)
      end

      it "words nothing under a trace that confines nothing" do
        traced = Struct.new(:profile) { def for(_request) = profile }.new(Lain::Confine::Profile::TRACED)
        writing(refused_exec(planted))

        auditing = described_class.new(inner:, launcher:, profiles: traced, journal:)
        capture = auditing.call(command: Lain::Shell::Term.of(%w[cat a]), cwd: root, env: {}, timeout: 5,
                                confinement: judged)

        expect(capture.stderr).not_to include("REFUSED")
      end
    end

    describe "naming the sandbox when a read is denied" do
      def failing(stderr, exit_status: 1)
        inner.behaviour = lambda do |fds:, **|
          fds.fetch(3).write("")
          Lain::Exec::Capture.new(exit_status:, stdout: "", stderr:)
        end
      end

      it "ends the output with a line naming the profile and read_file for a Permission denied outside the read list" do
        failing("cat: /srv/elsewhere/notes.txt: Permission denied\n")

        expect(run.stderr).to end_with(
          "The reader sandbox limits reads to the project and its related directories. " \
          "To see a masked file, use read_file.\n#{tier}"
        )
      end

      it "leaves a Permission denied for a path inside the read list alone" do
        failing("cat: #{root}/secret: Permission denied\n")

        expect(run.stderr).not_to include("read_file")
      end

      it "names the sandbox for a relative Permission denied path that resolves outside the read list" do
        FileUtils.mkdir_p(root)
        failing("cat: ../other/secret: Permission denied\n")

        expect(run.stderr).to include("read_file")
      end

      it "leaves a relative Permission denied path that resolves inside the read list alone" do
        failing("cat: docs/secret: Permission denied\n")

        expect(run.stderr).not_to include("read_file")
      end

      {
        "a single-quoted absolute path" => "cat: '/srv/elsewhere/x': Permission denied\n",
        "a double-quoted absolute path" => "cat: \"/srv/elsewhere/x\": Permission denied\n",
        "an absolute path with spaces" => "cat: /srv/my dir/x: Permission denied\n",
        "a quoted relative path" => "cat: '../other/my x': Permission denied\n",
        "one denial among several" => "cat: ROOT/a: Permission denied\ncat: /srv/elsewhere/x: Permission denied\n"
      }.each do |what, stderr|
        it "names the sandbox for #{what} outside the read list" do
          failing(stderr.gsub("ROOT", root))

          expect(run.stderr).to end_with("use read_file.\n#{tier}")
        end
      end

      it "leaves several denials all inside the read list alone" do
        failing("cat: '#{root}/my dir/a': Permission denied\ncat: docs/b: Permission denied\n")

        expect(run.stderr).not_to include("read_file")
      end

      it "leaves an ordinary failure alone" do
        failing("1 example, 1 failure\n")

        expect(run.stderr).to eq("1 example, 1 failure\n#{tier}")
      end

      it "leaves a successful call alone" do
        failing("cat: /srv/elsewhere/notes.txt: Permission denied\n", exit_status: 0)

        expect(run.stderr).not_to include("read_file")
      end
    end

    it "folds the same connect from 2 stages into one entry and sums the dropped" do
      line = %(5 connect(3, {sa_family=AF_UNIX, sun_path="/x"}, 110) = 0\n)
      inner.behaviour = lambda do |fds:, **|
        fds.fetch(3).write(line)
        fds.fetch(4).write(line)
        capture
      end
      run(command: Lain::Shell::Term.of(%w[cat a], %w[head -1]))

      expect(recorded("exec_record").sole).to have_attributes(connects: [a_hash_including(count: 2)],
                                                              connects_dropped: 0)
    end

    it "hands each stage its own descriptor and merges their records in stage order" do
      inner.behaviour = lambda do |fds:, **|
        fds.fetch(4).write(%(20 execve("/usr/bin/head", ["head"], 0x0 /* 0 vars */) = 0\n))
        fds.fetch(3).write(%(10 execve("/usr/bin/cat", ["cat"], 0x0 /* 0 vars */) = 0\n))
        capture
      end
      run(command: Lain::Shell::Term.of(%w[cat README.md], %w[head -1]))

      expect(inner.calls.sole[:fds].keys).to eq([3, 4])
      expect(recorded("exec_record").sole.execs.map { _1[:path] }).to eq(%w[/usr/bin/cat /usr/bin/head])
    end

    # Truncated keeps meaning the cap; an exec whose line never closed is a different fact.
    it "journals the trace as incomplete when an exec never closes" do
      writing('10 execve("/usr/bin/cat", ["cat"], 0x0 /* 0 vars */ <unfinished ...>')
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      run(timeout: 30)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect(recorded("exec_record").sole).to have_attributes(truncated: false, incomplete: true)
    end

    it "waits a bounded time for an exec to close after the call, and journals it complete when it does" do
      late = []
      inner.behaviour = lambda do |fds:, **|
        writer = fds.fetch(3).dup
        writer.write("10 execve(\"/usr/bin/cat\", [\"cat\"], 0x0 /* 0 vars */ <unfinished ...>\n")
        late << Thread.new do
          sleep 0.2
          writer.write("10 <... execve resumed>) = 0\n10 +++ exited with 0 +++\n")
        ensure
          writer.close
        end
        capture
      end

      run
      late.each(&:join)

      expect(recorded("exec_record").sole).to have_attributes(incomplete: false, execs: [a_hash_including(rc: 0)])
    end

    describe "a workspace call that creates a sealed path it found absent", :seam do
      let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }
      let(:profile) { Lain::Confine::Profile.workspace(root:, home:, tmpdir: scratch) }
      let(:envrc) { File.join(root, ".envrc") }

      def creating(path)
        inner.behaviour = lambda do |**|
          File.write(path, "")
          capture
        end
      end

      it "journals the created path on a sandbox record after the call, and leaves the path where it is" do
        creating(envrc)
        run

        expect(recorded("sandbox").map(&:created_sealed)).to eq([[], [envrc]])
        expect(recorded("sandbox").last).to have_attributes(tool_use_id: "toolu_1", profile: :workspace)
        expect(File.exist?(envrc)).to be(true)
      end

      it "journals one sandbox record when the call created no sealed path" do
        run

        expect(recorded("sandbox").sole.created_sealed).to eq([])
      end

      it "checks after a call that timed out, and leaves the timeout to reach the caller" do
        inner.behaviour = lambda do |**|
          File.write(envrc, "")
          raise Lain::Exec::Timeout, "too slow"
        end

        expect { run }.to raise_error(Lain::Exec::Timeout, /\Atoo slow\n\[ran: [^\n]+\]\n\z/)
        expect(recorded("sandbox").last.created_sealed).to eq([envrc])
      end

      it "names a sealed path created as a dangling link" do
        inner.behaviour = lambda do |**|
          File.symlink(File.join(@base, "nowhere"), envrc)
          capture
        end
        run

        expect(recorded("sandbox").last.created_sealed).to eq([envrc])
      end

      it "never flags a sealed path that was already there as a dangling link before the call" do
        expect(profile.sealed.find { _1.path == envrc }.absent).to be(true)
        File.symlink(File.join(@base, "nowhere"), envrc)
        run

        expect(recorded("sandbox").map(&:created_sealed)).to eq([[]])
      end

      describe "when journalling what the call created fails" do
        let(:journal) do
          Class.new(Array) do
            def <<(record)
              raise IOError, "journal is gone" if record.journal_type == "sandbox" && record.created_sealed.any?

              super
            end
          end.new
        end

        it "raises that failure from a call that otherwise ran clean" do
          creating(envrc)
          expect { run }.to raise_error(IOError, "journal is gone")
        end

        it "leaves the call's own timeout to reach the caller" do
          inner.behaviour = lambda do |**|
            File.write(envrc, "")
            raise Lain::Exec::Timeout, "too slow"
          end
          expect { run }.to raise_error(Lain::Exec::Timeout, /\Atoo slow\n\[ran: [^\n]+\]\n\z/)
        end
      end
    end

    describe "a workspace call's own TMPDIR" do
      let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }
      let(:call_dir) { Dir.mktmpdir("lain-call-", scratch) }
      let(:profile) { Lain::Confine::Profile.workspace(root:, home:, tmpdir: scratch).for_call(call_dir, granted: scratch) }

      it "pins the call's TMPDIR to its own dir, and removes the dir once the call is over", :seam do
        run

        expect(inner.calls.sole[:pinned_env]).to include("TMPDIR" => call_dir)
        expect([File.exist?(call_dir), File.directory?(scratch)]).to eq([false, true])
      end

      it "removes the dir after a call that timed out", :seam do
        inner.behaviour = ->(**) { raise Lain::Exec::Timeout, "too slow" }

        expect { run }.to raise_error(Lain::Exec::Timeout)
        expect(File.exist?(call_dir)).to be(false)
      end

      it "removes the dir after a call it refused to start", :seam do
        run(confinement: composed(executables: [executable("cat", File.join(root, "bin/cat"), :project)]))

        expect([inner.calls, File.exist?(call_dir)]).to eq([[], false])
      end

      it "removes a dir the call left unreadable, without following a link out of it", :seam do
        outside = File.join(@base, "outside").tap { FileUtils.mkdir_p(_1) }
        File.chmod(0o500, outside)
        inner.behaviour = lambda do |**|
          FileUtils.mkdir_p(locked = File.join(call_dir, "d"))
          File.write(File.join(locked, "f"), "")
          File.symlink(outside, File.join(locked, "link"))
          File.chmod(0o000, locked)
          capture
        end
        run

        expect([File.exist?(call_dir), File.stat(outside).mode & 0o777]).to eq([false, 0o500])
        expect(recorded("sandbox").map(&:kept_tmpdir)).to eq([nil])
      ensure
        File.chmod(0o700, outside)
      end

      it "journals a dir it could not remove", :seam do
        allow(FileUtils).to receive(:rm_rf)
        run

        expect(recorded("sandbox").last).to have_attributes(kept_tmpdir: call_dir, created_sealed: [])
      ensure
        FileUtils.remove_entry(call_dir)
      end

      it "leaves TMPDIR to the child's env for a profile with no dir of its own" do
        readers = Struct.new(:profile) { def for(_request) = profile }.new(Lain::Confine::Profile.reader(root:, home:))
        described_class.new(inner:, launcher:, profiles: readers, journal:)
                       .call(command: Lain::Shell::Term.of(%w[cat README.md]), cwd: root, env: {}, timeout: 5,
                             confinement: composed)

        expect(inner.calls.sole[:pinned_env]).not_to include("TMPDIR")
      end
    end

    describe "calls through real profiles that a wrapper changes, as the egress seam's does", :seam do
      let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }
      let(:probe) { Struct.new(:nothing) { def supports?(_layer) = true }.new }
      let(:masks) { Struct.new(:masks) { def landed_on(_path) = [] }.new([]) }
      let(:profiles) do
        real = Lain::Confine::Profiles.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch)
        # A port is the host's, so the wrapper takes the call back onto the host's network.
        Struct.new(:profiles) do
          def for(request) = profiles.for(request).with(connect_ports: [8080], private_net: false)
        end.new(real)
      end

      it "gives each call a dir of its own and removes each once" do
        judged_call = Lain::Confine::Request.new(ruling: ruling("auto"), executables: [], cwd: root, root:,
                                                 tool_use_id: "toolu_1")
        2.times { run(confinement: judged_call) }
        dirs = inner.calls.map { _1[:pinned_env].fetch("TMPDIR") }

        expect(dirs.uniq.size).to eq(2)
        expect(dirs.map { File.dirname(_1) }.uniq).to eq([scratch])
        expect(Dir.children(scratch)).to be_empty
      end
    end

    describe "a profile that refuses the call" do
      let(:raising) { Struct.new(:error) { def for(_request) = raise(error) } }

      def refused_by(error)
        described_class.new(inner:, launcher:, profiles: raising.new(error), journal:).call(
          command: Lain::Shell::Term.of(%w[cat README.md]), cwd: root, env: {}, timeout: 5, confinement: composed
        )
      end

      it "journals an overmask under the profile that was refused" do
        refused_by(Lain::Confine::Profiles::Overmasked.new(path: root, names: ["link"], profile: :workspace))

        expect(recorded("sandbox").sole).to have_attributes(profile: :workspace, refused: [root])
      end

      it "withholds an overmasked path that reads as a token, keeping the sentence and the record" do
        store = "/nix/store/9w2l1vc5kq8x3m4p0z7r6y5t4s3a2b1c-app-1.0/config"
        capture = refused_by(Lain::Confine::Profiles::Overmasked.new(path: store, names: ["link"], profile: :workspace))

        expect(capture.stderr).to include("lands on [path withheld]", "Stop and tell the human")
        expect(capture.stderr).not_to include(store)
        expect(recorded("sandbox").sole).to have_attributes(refused: [store])
      end

      it "withholds a listed link's name that reads as a token, keeping the sentence" do
        name = "keys/ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
        capture = refused_by(Lain::Confine::Profiles::Overmasked.new(path: "/srv/app/config", names: [name],
                                                                     profile: :workspace))

        expect(capture.stderr).to include("the listed link [name withheld] lands on /srv/app/config",
                                          "Stop and tell the human")
        expect(capture.stderr).not_to include(name)
      end

      {
        "has gone" => ->(path) { Lain::Confine::Profiles::NoTmpdir.new(path:, profile: :workspace) },
        "is home or holds it" => ->(path) { Lain::Confine::Profile::HomeTmpdir.new(path:) }
      }.each do |why, error|
        it "withholds a mktemp-shaped TMPDIR that #{why}, keeping the sentence and the record" do
          tmp = "/home/tara/tmp/lain/wt-T41/t41-unseal20261026-3334363-2ovwkj/t"
          capture = refused_by(error.call(tmp))

          expect(capture.stderr).to include("the TMPDIR [path withheld]", "Retrying will be refused again")
          expect(capture.stderr).not_to include(tmp)
          expect(Lain::Sensitivity::Regions.detect(capture.stderr)).to be_empty
          expect(recorded("sandbox").sole).to have_attributes(refused: [tmp])
        end
      end

      it "refuses a subclass of a refusal it knows with that refusal's sentence" do
        later = Class.new(Lain::Confine::Profile::Tampered)
        capture = refused_by(later.new(path: "/srv/lease", why: "commondir", profile: :workspace))

        expect([capture.exit_status, capture.stderr]).to match([Lain::Shell::Pipeline::NOT_PERMITTED, /redirects git/])
      end

      it "refuses a call whose TMPDIR has gone, in words, and journals it" do
        gone = "/srv/scratch/gone"
        capture = refused_by(Lain::Confine::Profiles::NoTmpdir.new(path: gone, profile: :workspace))

        expect(inner.calls).to be_empty
        expect(capture.exit_status).to eq(Lain::Shell::Pipeline::NOT_PERMITTED)
        expect(capture.stderr).to start_with("lain: REFUSED").and include(gone)
        expect(recorded("sandbox").sole).to have_attributes(profile: :workspace, refused: [gone])
      end

      it "refuses a call whose seal is reached through a link, naming the link and the reader arm" do
        link = File.join(root, ".envrc")
        capture = refused_by(Lain::Confine::Profile::Unsealable.new(path: link, link:))

        expect(inner.calls).to be_empty
        expect(capture.exit_status).to eq(Lain::Shell::Pipeline::NOT_PERMITTED)
        expect(capture.stderr).to start_with("lain: REFUSED")
          .and include(" .envrc is a link", "Stop and tell the human", "--confine reader")
        expect(capture.stderr).not_to include(root)
        expect(recorded("sandbox").sole).to have_attributes(profile: :workspace, refused: [link])
      end

      it "refuses a call whose TMPDIR is home or holds it, naming it" do
        capture = refused_by(Lain::Confine::Profile::HomeTmpdir.new(path: "/home/alice"))

        expect(inner.calls).to be_empty
        expect(capture.stderr).to start_with("lain: REFUSED").and include("/home/alice", "Stop and tell the human")
        expect(recorded("sandbox").sole).to have_attributes(profile: :workspace, refused: ["/home/alice"])
      end
    end

    context "when journalling the trace fails" do
      let(:journal) do
        Class.new(Array) do
          def <<(record)
            raise IOError, "journal is gone" if record.journal_type == "exec_record"

            super
          end
        end.new
      end

      it "raises that failure from a call that otherwise ran clean" do
        expect { run }.to raise_error(IOError, "journal is gone")
      end

      it "leaves the call's own timeout to reach the caller" do
        inner.behaviour = ->(**) { raise Lain::Exec::Timeout, "too slow" }
        expect { run }.to raise_error(Lain::Exec::Timeout, /\Atoo slow\n\[ran: [^\n]+\]\n\z/)
      end
    end
  end

  describe "as an exec backend over a real Local" do
    let(:fence) { Lain::Confine::Bwrap.fence_binary }
    let(:backend) do
      described_class.new(inner: Lain::Exec::Local.new, launcher: Lain::Confine::Bwrap.new(fence:),
                          profiles: Struct.new(:none) { def for(_request) = none }.new(Lain::Confine::Profile::NONE),
                          journal:)
    end

    before do
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
    end

    # The contract ignores what a call returns, so this host checks each one really ran.
    def run_term(term)
      capture = backend.call(command: term, cwd: Dir.pwd, env: {}, timeout: 10)
      expect(capture.exit_status).to eq(0), capture.stderr
    end

    def terms_taken = [Lain::Shell::Term.of(%w[printf hi]), Lain::Shell::Term.of(%w[printf hi], %w[cat])]
    def terms_refused = []

    it_behaves_like "an exec backend answering for a term"
  end

  describe "on this box", :seam do
    let(:fence) { Lain::Confine::Bwrap.fence_binary }
    let(:policy) do
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root))
    end
    let(:runner) do
      lambda do |argv|
        out, status = Open3.capture2e(*argv)
        [out, status.success?]
      end
    end
    let(:probe) { Lain::Confine::Probe.new(fence:, journal:, runner:) }
    let(:launcher) { Lain::Confine::Bwrap.new(fence:) }
    let(:sandboxed) do
      described_class.new(
        inner: Lain::Exec::Local.new, launcher:, journal:,
        profiles: Lain::Confine::Profiles.new(
          masks: Lain::Confine::MaskList.new(root:, policy: -> { policy }), probe:, home: Dir.home, root:
        )
      )
    end

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
      skip("bwrap cannot make a user namespace on this host") unless
        system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)

      SeedRepo.git(root, "init", "-q")
      File.write(File.join(root, "README.md"), "the readme\n")
    end

    def run(command, confinement: composed, env: {}, timeout: 10)
      sandboxed.call(command:, cwd: root, env: { "LC_ALL" => "C", **env }, timeout:, confinement:)
    end

    def term(*argvs) = Lain::Shell::Term.of(*argvs)

    it "runs a ComposedTerm approval under the reader profile, and journals what it ran" do
      expect(run(term(%w[cat README.md]))).to have_attributes(exit_status: 0, stdout: "the readme\n")
      expect(recorded("sandbox").sole).to have_attributes(tool_use_id: "toolu_1", profile: :reader, trace: true)
      expect(recorded("exec_record").sole.execs).to include(a_hash_including(path: "/usr/bin/cat", rc: 0))
    end

    it "hides a secret that appeared after the sandbox was built" do
      sandboxed
      File.write(File.join(root, ".env"), "SECRET=1\n")

      expect(run(term(%w[cat .env])).stdout).not_to include("SECRET")
    end

    context "when a program is planted on PATH after the call was resolved" do
      let(:planted) { File.join(root, "bin", "cat") }
      let(:path) { { "PATH" => "#{File.dirname(planted)}:/usr/bin:/bin" } }

      before do
        FileUtils.mkdir_p(File.dirname(planted))
        File.write(planted, "#!/bin/sh\necho planted\n")
        File.chmod(0o755, planted)
      end

      it "is refused by the kernel when the shell execs it" do
        capture = run("cat README.md", env: path)

        expect(capture.stdout).not_to include("planted")
        expect(recorded("exec_record").sole.refusals).to include({ path: planted, errno: "EACCES" })
      end

      it "tells the model the refusal is final when the program had no other copy to fall through to" do
        expect(run("cat README.md", env: { "PATH" => File.dirname(planted) }).stderr)
          .to end_with("#{format(described_class::REFUSED, path: as_shown(planted))}\n#{reader_tier}")
      end

      it "is refused when a term's stage execs it, which then falls through to the next PATH entry" do
        expect(run(term(%w[cat README.md]), env: path).stdout).to eq("the readme\n")
        expect(recorded("exec_record").sole.refusals).to include({ path: planted, errno: "EACCES" })
      end
    end

    it "traces a judge's approval without confining it" do
      expect(run(term(["cat", __FILE__]), confinement: judged).exit_status).to eq(0)
      expect(recorded("sandbox").sole).to have_attributes(profile: :traced, trace: true)
      expect(recorded("exec_record").sole.execs).to include(a_hash_including(path: "/usr/bin/cat"))
    end

    describe "a call that reaches the network" do
      let(:server) { TCPServer.new("127.0.0.1", 0) }
      let(:port) { server.addr[1] }
      let(:datagrams) { UDPSocket.new.tap { _1.bind("127.0.0.1", 0) } }
      let(:udp_port) { datagrams.addr[1] }

      after { [server, datagrams].each(&:close) }

      def ruby_run(code) = "#{RbConfig.ruby} -rsocket -e '#{code}'"

      it "records a connect with its address, port and rc" do
        run("exec 3<>/dev/tcp/127.0.0.1/#{port}", confinement: judged)

        expect(recorded("exec_record").sole.connects)
          .to include({ call: "connect", family: "AF_INET", address: "127.0.0.1", port:, rc: 0, errno: nil, count: 1 })
      end

      it "records a refused connect under the reader profile with its errno" do
        run("exec 3<>/dev/tcp/127.0.0.1/#{port}", confinement: composed)

        expect(recorded("exec_record").sole.connects)
          .to include(a_hash_including(call: "connect", port:, rc: -1, errno: "EACCES"))
      end

      it "folds a burst of datagrams to one address into one counted entry" do
        run(ruby_run("s = UDPSocket.new; 2000.times { s.send(%q(x), 0, %q(127.0.0.1), #{udp_port}) }"),
            confinement: judged)

        expect(recorded("exec_record").sole.connects.sole).to include(call: "sendto", port: udp_port, count: 2000)
      end

      it "records a sendto that names an address and nothing for a send on a connected socket" do
        code = "UDPSocket.new.send(%q(x), 0, %q(127.0.0.1), #{udp_port}); " \
               "TCPSocket.new(%q(127.0.0.1), #{port}).send(%q(y), 0)"
        run(ruby_run(code), confinement: judged)

        expect(recorded("exec_record").sole.connects.select { _1[:call] == "sendto" })
          .to eq([{ call: "sendto", family: "AF_INET", address: "127.0.0.1", port: udp_port, rc: 1, errno: nil,
                    count: 1 }])
      end
    end

    describe "a call granted its build tool's ports" do
      let(:server) { TCPServer.new("127.0.0.1", 0) }
      let(:port) { server.addr[1] }
      let(:other) { TCPServer.new("127.0.0.1", 0) }
      let(:datagrams) { UDPSocket.new.tap { _1.bind("127.0.0.1", 0) } }
      let(:fixture_home) { File.join(@base, "fixture-home").tap { FileUtils.mkdir_p(File.join(_1, ".cargo/bin")) } }
      let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }
      # Nothing in this lineage was written, and its start is after every file the spec made.
      let(:fresh) { Lain::Shell::Executable::Fresh.new(start: Time.now + 3600, written: [], stat: Lain::Shell::Executable::Stat.new) }
      let(:sandboxed) do
        described_class.new(
          inner: Lain::Exec::Local.new, launcher:, journal:,
          profiles: Lain::Confine::Profiles.new(
            masks: Lain::Confine::MaskList.new(root:, policy: -> { policy }), probe:, home: fixture_home, root:,
            workspace: true, tmpdir: scratch, fresh:, env: { "GEM_HOME" => File.join(@base, "gems") }
          )
        )
      end

      # The test grants the listener's port in place of 443, so nothing leaves loopback.
      before { stub_const("Lain::Confine::Profile::GRANTS", { "git" => [port], "cargo" => [port] }) }

      after { [server, other, datagrams].each(&:close) }

      def granted(argv, realpath)
        stage = Lain::Shell::Executable.new(name: argv.first, resolved: realpath, realpath:, chain: [], shadowed: [],
                                            anomalies: [], klass: :system, fresh: false, run_files: [], wrappers: [])
        Lain::Confine::Request.new(ruling: ruling("auto"), executables: [stage], argv: [argv], cwd: root, root:,
                                   tool_use_id: "toolu_1")
      end

      def connects = recorded("exec_record").sole.connects.select { _1[:call] == "connect" && _1[:family] == "AF_INET" }

      it "connects on the granted port, and is refused and recorded on another" do
        run("exec 3<>/dev/tcp/127.0.0.1/#{port}; exec 4<>/dev/tcp/127.0.0.1/#{other.addr[1]}",
            confinement: granted(%w[git fetch origin], "/usr/bin/git"))

        expect(recorded("sandbox").map(&:profile)).to include(:grant)
        expect(connects).to contain_exactly(a_hash_including(port:, rc: 0),
                                            a_hash_including(port: other.addr[1], rc: -1, errno: "EACCES"))
      end

      it "opens no datagram socket" do
        capture = run("echo x > /dev/udp/127.0.0.1/#{datagrams.addr[1]}",
                      confinement: granted(%w[git fetch origin], "/usr/bin/git"))

        expect(capture.exit_status).not_to eq(0)
        expect(datagrams.recv_nonblock(1, exception: false)).to eq(:wait_readable)
      end

      it "writes cargo's registry and is refused a write to ~/.cargo/bin" do
        registry = File.join(fixture_home, ".cargo/registry").tap { FileUtils.mkdir_p(_1) }
        FileUtils.mkdir_p(File.join(root, "target"))
        capture = run("echo x > #{registry}/ok && echo x > #{fixture_home}/.cargo/bin/cargo",
                      confinement: granted(%w[cargo build], "/usr/bin/true"))

        expect(File.exist?(File.join(registry, "ok"))).to be(true)
        expect(capture.stderr).to match(/cargo: (Permission denied|Read-only file system)/)
        expect(File.exist?(File.join(fixture_home, ".cargo/bin/cargo"))).to be(false)
      end

      it "runs under the workspace profile, with no ports, once a file in the project was written" do
        fresh << Lain::Telemetry::FileWritten.from_stat(File.stat(File.join(root, "README.md")),
                                                        path: File.join(root, "README.md"), tool_use_id: "tu_0")
        run("exec 3<>/dev/tcp/127.0.0.1/#{port}", confinement: granted(%w[git fetch origin], "/usr/bin/git"))

        # The plain workspace call has a loopback of its own, where nothing listens on the host's port.
        expect(recorded("sandbox").map(&:profile)).to include(:workspace)
        expect(connects).to contain_exactly(a_hash_including(port:, rc: -1,
                                                             errno: a_string_matching(/EACCES|ECONNREFUSED/)))
      end
    end

    it "runs a piped term under the reader profile and under the trace alone" do
      [composed, judged].each do |confinement|
        expect(run(term(%w[cat README.md], %w[head -1]), confinement:))
          .to have_attributes(exit_status: 0, stdout: "the readme\n")
      end
    end

    it "still names a missing program as not found" do
      expect(run(term(%w[no-such-program-anywhere])))
        .to have_attributes(exit_status: 127,
                            stderr: "lain: no-such-program-anywhere: command not found\n#{reader_tier}")
    end

    it "keeps bundler from reading the user's own config, which may hold gem credentials" do
      expect(run(term(%w[printenv BUNDLE_USER_CONFIG])).stdout).to eq("/dev/null\n")
    end

    it "leaves nothing alive in the sandbox once a timeout has killed the call" do
      marker = "30.#{Process.pid}#{rand(1000)}"

      expect { run("sleep #{marker}", timeout: 1) }.to raise_error(Lain::Exec::Timeout)
      expect(system("pgrep", "-f", "sleep #{marker}", out: File::NULL)).to be(false)
    end

    # The traced command inherits none of the trace descriptors, so it cannot write lines of its own into them.
    it "keeps a traced command from adding an exec to its record, or hiding one" do
      forged = %(printf 'execve("/usr/lib/forged", ["forged"], 0x0 /* 0 vars */) = 0\\n' >&3)
      run("#{forged}; printf x >&3; /usr/bin/id -u", confinement: judged)

      paths = recorded("exec_record").sole.execs.map { _1[:path] }
      expect(paths).to include("/usr/bin/id")
      expect(paths).not_to include("/usr/lib/forged")
    end

    # The reaper spawns the command where a shell's exec "$@" used to, so it must fall back to sh as execvp does.
    it "runs an executable with no shebang under the reaper, as a shell would" do
      script = File.join(root, "plain")
      File.write(script, "echo noshebang ran\n")
      File.chmod(0o755, script)

      expect(run(term([script]), confinement: judged))
        .to have_attributes(exit_status: 0, stdout: "noshebang ran\n")
    end

    it "closes a traced command's trace descriptor through the reaper, with no shell shim in front of it" do
      launched = []
      allow(launcher).to receive(:wrap).and_wrap_original do |wrap, *args, **kwargs|
        wrap.call(*args, **kwargs).tap { launched << _1 }
      end

      expect(run("printf x >&3 || echo refused", confinement: judged).stdout).to eq("refused\n")
      expect(launched.sole.stages.sole.argv.drop_while { _1 != "--" }.take(4))
        .to eq(["--", fence, "--reap-only", "--"])
    end

    describe "a command that leaves a background process behind" do
      let(:marker) { "30#{rand(1000)}.#{Process.pid}" }

      def alive?(pattern) = system("pgrep", "-f", pattern, out: File::NULL)

      def took
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      after { system("pkill", "-f", "sleep #{marker}") }

      # No nohup: the reaper sends nothing to a background child when the command exits on its own.
      it "returns once the traced command exits, keeps its background child running, and lists its execs" do
        seconds = took do
          expect(run("sleep #{marker} & /usr/bin/true; echo hi", confinement: judged).stdout).to eq("hi\n")
        end
        sleep 0.2

        expect(seconds).to be < 2
        expect(alive?("^sleep #{marker}$")).to be(true)
        expect(recorded("exec_record").sole.execs).to include(a_hash_including(path: "/usr/bin/true", rc: 0))
      end

      it "returns once the traced command exits, even while its child holds the output open" do
        expect(took { run("sleep 3 & echo hi", confinement: judged) }).to be < 2
      end

      # bwrap's pid namespace ends with the call, so the reader's children end with it.
      it "returns once a reader command exits, and its child ends with it" do
        expect(took { run("sleep #{marker} & echo hi") }).to be < 2
        sleep 0.2
        expect(alive?("sleep #{marker}")).to be(false)
      end

      it "times a traced call out within its deadline and the pipeline's grace, and reaps its setsid grandchild" do
        seconds = took do
          expect { run("setsid sleep #{marker} & sleep #{marker}1", confinement: judged, timeout: 1) }
            .to raise_error(Lain::Exec::Timeout)
        end
        sleep 0.5

        expect(seconds).to be < 1 + Lain::Shell::Pipeline::DEFAULT_GRACE
        expect(alive?("^sleep #{marker}$")).to be(false)
      end

      context "when this kernel cannot trace" do
        let(:runner) do
          real = super()
          ->(argv) { File.basename(argv.first) == "strace" ? ["", false] : real.call(argv) }
        end

        it "reaps an untraced unconfined call's setsid grandchild on a timeout" do
          expect { run("setsid sleep #{marker} & sleep #{marker}1", confinement: judged, timeout: 1) }
            .to raise_error(Lain::Exec::Timeout)
          sleep 0.5

          expect(recorded("sandbox").sole).to have_attributes(profile: :none, trace: false)
          expect(alive?("^sleep #{marker}$")).to be(false)
        end
      end
    end

    it "records the exec of every stage of a three-stage term, run after run" do
      File.write(File.join(root, "f"), "a\nb\n")
      programs = %w[/usr/bin/cat /usr/bin/head /usr/bin/wc]
      [composed(executables: []), judged].each do |confinement|
        lost = Array.new(20) do
          journal.clear
          run(term(%w[cat f], %w[head -1], %w[wc -l]), confinement:)
          paths = recorded("exec_record").sole.execs.select { _1[:rc].zero? }.map { _1[:path] }
          programs - paths
        end
        expect(lost.flatten).to be_empty
      end
    end

    it "records a path longer than strace's default string limit whole" do
      long = File.join(root, "a-program-name-well-past-thirty-two-bytes")
      File.symlink("/usr/bin/true", long)

      run(term([long]), confinement: judged)

      expect(recorded("exec_record").sole.execs).to include(a_hash_including(path: long, rc: 0))
    end

    # An unlinked file is invisible to a listing, so ask which process still holds one.
    def held_under(dir) = Dir.glob("/proc/[0-9]*/fd/*").filter_map { link(_1) }.select { _1.start_with?("#{dir}/") }

    def link(path)
      File.readlink(path)
    rescue SystemCallError
      nil
    end

    # The loop truncates the file before it writes, so a read can land on an empty one.
    def loop_count(path)
      Timeout.timeout(5) do
        loop do
          text = File.read(path)
          return text.to_i unless text.empty?

          sleep 0.01
        end
      end
    end

    # The call closes its end of the trace pipe when it ends; the tracer must outlive that.
    # An undrained pipe would stall the tracer, and so the loop, after about 270 iterations.
    it "keeps a background process the traced call left running at full speed, and holds no file in TMPDIR" do
      calltmp = File.join(@base, "calltmp")
      count = File.join(@base, "count")
      FileUtils.mkdir_p(calltmp)
      loop_body = "n=0; while :; do /usr/bin/true; n=$((n+1)); echo $n > #{count}; done"
      run("nohup sh -c '#{loop_body}' >/dev/null 2>&1 & echo started",
          confinement: judged, env: { "TMPDIR" => calltmp })
      # Under load the traced loop can take longer than a fixed second to write its first line.
      Timeout.timeout(15) { sleep 0.05 until File.exist?(count) }
      reached = 0
      begin
        wait_until(timeout: 10, reason: "the loop count passing 1000") { (reached = loop_count(count)) >= 1000 }
      rescue RuntimeError => e
        raise "#{e.message}; it reached #{reached}"
      end

      expect(held_under(calltmp)).to be_empty
    ensure
      system("pkill", "-f", count)
    end

    context "when this kernel cannot trace" do
      let(:runner) do
        real = super()
        ->(argv) { File.basename(argv.first) == "strace" ? ["", false] : real.call(argv) }
      end

      it "still confines a reader call, and records that it ran untraced" do
        expect(run(term(%w[cat README.md])).stdout).to eq("the readme\n")
        expect(run(term(["cat", __FILE__])).exit_status).not_to eq(0)
        expect(recorded("sandbox").map(&:trace)).to eq([false, false])
        expect(recorded("exec_record")).to be_empty
      end
    end
  end
end
