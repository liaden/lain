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

  def ruling(rung, rule: nil, authority: :automatic, builds: false)
    Lain::Approval::Escalation::Ruling.allow(rung:, because: "approved", rule:, authority:, builds:)
  end

  def request(ruling, executables: [], root: self.root, grants: [])
    Lain::Confine::Request.new(ruling:, executables:, cwd: root, root:, tool_use_id: "toolu_1", grants:)
  end

  def composed(executables: [], builds: false)
    request(ruling("rules", rule: "composed_term", builds:), executables:)
  end

  def executable(name, realpath, klass)
    Lain::Shell::Executable.new(name:, resolved: realpath, realpath:, chain: [], shadowed: [], anomalies: [],
                                klass:, fresh: false, run_files: [], wrappers: [])
  end

  def mask(path) = Lain::Sensitivity::Policy::Mask.new(path:, reason: "secret")

  describe "#for" do
    it "confines a ComposedTerm approval under the reader profile, the project first", :seam do
      profile = profiles.for(composed)

      expect(profile).to have_attributes(name: :reader, trace: true, confined?: true)
      expect(profile.read_dirs.first).to eq(root)
    end

    it "confines a call to the root its request names, as a worktree child's does", :seam do
      child = File.join(@base, "child")
      FileUtils.mkdir_p(child)
      ruled = request(ruling("rules", rule: "composed_term"), root: child)

      expect(profiles.for(ruled).read_dirs.first).to eq(child)
    end

    it "falls back to the session's root when the request names none", :seam do
      expect(profiles.for(request(ruling("rules", rule: "composed_term"), root: nil)).read_dirs.first).to eq(root)
    end

    it "traces an abstention that names the reader rule, since only an allow earns the reader profile" do
      barred = Lain::Approval::Escalation::Ruling.abstain(rung: "rules", because: "barred", rule: "composed_term")
      expect(profiles.for(request(barred))).to eq(Lain::Confine::Profile::TRACED)
    end

    it "masks what the mask list holds when the call is made, not when the profiles were built", :seam do
      profiles
      masked << mask(File.join(root, ".env"))

      expect(profiles.for(composed).masks).to eq([File.join(root, ".env")])
    end

    it "reads each related directory the classifier names, after the project, with the masks named with it", :seam do
      related = File.join(@base, "sibling").tap { FileUtils.mkdir_p(_1) }
      hidden = File.join(related, ".env")
      masked << mask(File.join(root, ".env"))
      answer = Lain::Confine::MaskList::Related.new(roots: [related], masks: [mask(hidden)])
      classifier = Struct.new(:related) { def classify(_) = Lain::Sensitivity::ORDINARY.verdict }.new(answer)

      profile = described_class.new(masks:, probe:, home:, root:, classifier:).for(composed)

      expect(profile.read_dirs.first(2)).to eq([root, related])
      expect(profile.masks).to eq([File.join(root, ".env"), hidden])
    end

    it "names each related directory a listing refused in the line the call's result ends with", :seam do
      refused = File.join(@base, "cache")
      answer = Lain::Confine::MaskList::Related.new(roots: [], masks: [], refused: { refused => "its walk failed" })
      classifier = Struct.new(:related) { def classify(_) = Lain::Sensitivity::ORDINARY.verdict }.new(answer)

      profile = described_class.new(masks:, probe:, home:, root:, classifier:).for(composed)

      expect(profile.tier_line).to end_with("; not read: #{refused} (its walk failed)]")
    end

    it "reads each read root the classifier names, read-only and with no listing behind it", :seam do
      epics = File.join(@base, "state", "epics").tap { FileUtils.mkdir_p(_1) }
      answer = Lain::Confine::MaskList::Related.new(roots: [], masks: [], reads: [epics])
      classifier = Struct.new(:related) { def classify(_) = Lain::Sensitivity::ORDINARY.verdict }.new(answer)

      profile = described_class.new(masks:, probe:, home:, root:, classifier:).for(composed)

      expect(profile.read_dirs.first(2)).to eq([root, epics])
      expect(profile.write_dirs).not_to include(epics)
      expect(Lain::Confine::MaskList::Related::NONE.reads).to eq([])
    end

    it "keeps a ComposedTerm approval of a build in the reader profile while the workspace switch is off", :seam do
      expect(profiles.for(composed(builds: true)).name).to eq(:reader)
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

    it "lets a reader run a program resolved outside /usr that no project could have planted", :seam do
      grep = File.join(home, ".local/bin/grep")
      planted = File.join(root, "bin/cat")
      executables = [executable("grep", grep, :user), executable("cat", planted, :project),
                     executable("head", "/usr/bin/head", :system)]

      expect(profiles.for(composed(executables:)).exec_files).to eq([grep])
    end

    it "lets a reader on the string arm run what the parsed stages name, through the same placement test", :seam do
      cargo = File.join(home, ".cargo/bin/rustup")
      shell = Lain::Shell::Executable.unresolved("cargo --version 2>&1 | head -1")
      fresh = executable("rg", File.join(home, ".local/bin/rg"), :user).with(fresh: true)
      shadowing = executable("cat", File.join(home, "bin/cat"), :user).with(shadowed: ["/usr/bin/cat"])
      grants = [executable("cargo", cargo, :user), executable("head", "/usr/bin/head", :system),
                executable("tool", File.join(root, "bin/tool"), :project), fresh, shadowing]
      ruled = request(ruling("rules", rule: "composed_term"), executables: [shell], grants:)

      expect(profiles.for(ruled).exec_files).to eq([cargo])
    end

    it "drops a string-arm reader grant that lies under a mask, rather than refusing the call", :seam do
      hidden = File.join(home, ".local/bin")
      masked << mask(hidden)
      cargo = File.join(home, ".cargo/bin/rustup")
      shell = Lain::Shell::Executable.unresolved("tool | cargo --version")
      grants = [executable("tool", File.join(hidden, "tool"), :user), executable("cargo", cargo, :user)]

      expect(profiles.for(request(ruling("rules", rule: "composed_term"), executables: [shell], grants:)).exec_files)
        .to eq([cargo])
    end

    it "grants a reader on the string arm nothing when no parsed stage names a program", :seam do
      shell = Lain::Shell::Executable.unresolved("cargo --version 2>&1 | head -1")

      expect(profiles.for(request(ruling("rules", rule: "composed_term"), executables: [shell])).exec_files).to eq([])
    end

    it "lets a reader run the wrappers that run a program", :seam do
      bundle = File.join(home, ".local/share/mise/installs/ruby/bin/bundle")
      wrapped = Lain::Shell::Executable.unresolved("ruby", wrappers: [executable("bundle", bundle, :user)])

      expect(profiles.for(composed(executables: [wrapped])).exec_files).to eq([bundle])
    end

    it "refuses a reader a user program that shadows another of its name on PATH", :seam do
      FileUtils.mkdir_p(File.join(home, "bin"))
      cat = File.join(home, "bin/cat").tap { File.write(_1, "#!/bin/sh\n") }.tap { File.chmod(0o755, _1) }
      resolver = Lain::Shell::Executable::Resolver.new(root:, fresh: Lain::Shell::Executable::Resolver::NeverFresh)
      shadowing = resolver.for(Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "#{File.dirname(cat)}:/usr/bin" }))
                          .call(Lain::Shell::Term.of(%w[cat README.md]))

      expect(shadowing.map { [_1.realpath, _1.shadowed.any?] }).to eq([[cat, true]])
      expect(profiles.for(composed(executables: shadowing)).exec_files).to eq([])
    end

    context "with the workspace switch on" do
      let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }
      let(:profiles) { described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch) }

      def git_init(dir) = system(SeedRepo::SCRUB, "git", "init", "-q", dir, exception: true)

      it "reads no git config in a clone lain cut whose git dir was tampered with, and refuses it", :seam do
        upstream = File.join(@base, "upstream")
        git_init(upstream)
        system(SeedRepo::SCRUB, "git", "-C", upstream, "-c", "user.name=a", "-c", "user.email=a@b", "commit", "-q",
               "--allow-empty", "-m", "i", exception: true)
        leases = File.join(Lain::Paths.new.state_home, "worktrees", Lain::Paths.new.project_hash(upstream))
        FileUtils.mkdir_p(leases)
        clone = File.join(leases, "a")
        Lain::Isolation::Clone::Registry.new(repo_root: upstream, root: leases,
                                             shell_out_factory: Lain::Shell::Out.public_method(:new))
                                        .add(clone, "HEAD", reason: "held")
        File.write(File.join(clone, ".git", "commondir"), "../evil\n")
        allow(Open3).to receive(:capture2).and_call_original
        tampered = described_class.new(masks:, probe:, home:, root: clone, workspace: true, tmpdir: scratch)

        expect { tampered.for(request(ruling("auto"), root: clone)) }.to raise_error(Lain::Confine::Profile::Tampered)
        expect(Open3).not_to have_received(:capture2).with(anything, "git", "-C", clone, "config", any_args)
      ensure
        FileUtils.rm_rf(leases) if leases
      end

      { "the judge" => "auto", "a rule" => "rules", "bypass" => "bypass" }.each do |who, rung|
        it "confines an automatic approval by #{who} under the workspace profile", :seam do
          expect(profiles.for(request(ruling(rung, rule: "project_rules"))))
            .to have_attributes(name: :workspace, confined?: true, trace: true)
        end
      end

      it "writes the project the request names", :seam do
        expect(profiles.for(request(ruling("auto"))).write_dirs).to include(root)
      end

      it "writes a dir made for the call beneath the TMPDIR, never the TMPDIR itself", :seam do
        profile = profiles.for(request(ruling("auto")))

        expect(File.dirname(profile.call_tmpdir)).to eq(scratch)
        expect(File.directory?(profile.call_tmpdir)).to be(true)
        expect(profile.write_dirs).to include(profile.call_tmpdir)
        expect(profile.write_dirs).not_to include(scratch)
      end

      it "makes each call a dir of its own", :seam do
        dirs = Array.new(2) { profiles.for(request(ruling("auto"))).call_tmpdir }
        expect(dirs.uniq.size).to eq(2)
      end

      it "makes no call dir when the TMPDIR is the private /tmp, which is already the call's own", :seam do
        allow(Dir).to receive(:mktmpdir).and_call_original
        on_tmp = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: "/tmp")
        profile = on_tmp.for(request(ruling("auto")))

        expect([profile.call_tmpdir, profile.write_dirs.count("/tmp")]).to eq([nil, 2])
        expect(Dir).not_to have_received(:mktmpdir)
      end

      it "refuses a call whose TMPDIR has gone, naming it", :seam do
        gone = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: File.join(@base, "gone"))

        expect { gone.for(request(ruling("auto"))) }.to raise_error(described_class::NoTmpdir) { |error|
          expect([error.path, error.profile]).to eq([File.join(@base, "gone"), :workspace])
        }
      end

      it "makes no dir for a call that is not a workspace one", :seam do
        profiles.for(composed)
        profiles.for(request(ruling("judge")))

        expect(Dir.children(scratch)).to be_empty
      end

      it "traces a human's approval without confining it, whatever the rung" do
        %w[auto rules surfaces].each do |rung|
          expect(profiles.for(request(ruling(rung, authority: :human)))).to eq(Lain::Confine::Profile::TRACED)
        end
      end

      it "traces the secret oracle's automatic release, which a surface signs and no listed rung" do
        oracle = Lain::Approval::Escalation::Ruling.allow(rung: "surfaces",
                                                          because: "a surface approved this call (secret_oracle)")
        expect(profiles.for(request(oracle))).to eq(Lain::Confine::Profile::TRACED)
      end

      it "traces an approval from a rung the list does not name" do
        expect(profiles.for(request(ruling("approve_all")))).to eq(Lain::Confine::Profile::TRACED)
      end

      it "traces an abstention or a deny from a listed rung" do
        abstained = Lain::Approval::Escalation::Ruling.abstain(rung: "auto", because: "deferred")
        denied = Lain::Approval::Escalation::Ruling.deny(rung: "rules", because: "no")
        expect([abstained, denied].map { profiles.for(request(_1)) }).to all(eq(Lain::Confine::Profile::TRACED))
      end

      it "keeps a ComposedTerm approval in the reader profile", :seam do
        expect(profiles.for(composed).name).to eq(:reader)
      end

      it "runs a ComposedTerm approval of a build under the workspace profile, which writes the project", :seam do
        profile = profiles.for(composed(builds: true))

        expect(profile.name).to eq(:workspace)
        expect(profile.write_dirs).to include(root)
      end

      it "traces a call that carries no ruling" do
        expect(profiles.for(Lain::Confine::Request::NONE)).to eq(Lain::Confine::Profile::TRACED)
      end

      it "masks what the mask list holds when the call is made", :seam do
        profiles.for(request(ruling("auto")))
        masked << mask(File.join(root, ".env"))

        expect(profiles.for(request(ruling("auto"))).masks).to eq([File.join(root, ".env")])
      end

      it "refuses a stage the term resolved to a user program that shadows another of its name, and runs a fresh one",
         :seam do
        FileUtils.mkdir_p(File.join(home, "bin"))
        ls = File.join(home, "bin/ls").tap { File.write(_1, "#!/bin/sh\n") }.tap { File.chmod(0o755, _1) }
        resolver = Lain::Shell::Executable::Resolver.new(root:, fresh: Lain::Shell::Executable::Resolver::NeverFresh)
        shadowing = resolver.for(Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "#{File.dirname(ls)}:/usr/bin" }))
                            .call(Lain::Shell::Term.of(%w[ls]))
        fresh = executable("rg", File.join(home, ".cargo/bin/rg"), :user).with(fresh: true)

        expect(profiles.for(request(ruling("auto"), executables: [*shadowing, fresh])).exec_files)
          .to eq([fresh.realpath])
      end

      describe "a program whose ctime changes during the run", :seam do
        let(:cargo) do
          File.join(home, ".cargo/bin/cargo").tap do |path|
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, "#!/bin/sh\n")
            File.chmod(0o755, path)
          end
        end
        let(:changed) do
          fresh = Lain::Shell::Executable::Fresh.new(start: Time.now - 60, written: [],
                                                     stat: Lain::Shell::Executable::Stat.new)
          Lain::Shell::Executable::Resolver.new(root:, fresh:)
                                           .for(Lain::WorkerEnv.new(cwd: root, env: { "PATH" => File.dirname(cargo) }))
                                           .call(Lain::Shell::Term.of(%w[cargo test]))
        end

        it "still runs in the workspace, while its resolution stays fresh for the tripwire to record" do
          expect(changed.map { [_1.realpath, _1.fresh] }).to eq([[cargo, true]])
          expect(profiles.for(request(ruling("auto"), executables: changed)).exec_files).to eq([cargo])
        end

        it "may not run under the reader" do
          expect(profiles.for(composed(executables: changed)).exec_files).to eq([])
        end
      end

      it "reads each read root and related directory the classifier names, with the related masks, writing neither",
         :seam do
        epics = File.join(@base, "state", "epics").tap { FileUtils.mkdir_p(_1) }
        related = File.join(@base, "sibling").tap { FileUtils.mkdir_p(_1) }
        hidden = File.join(related, ".env")
        answer = Lain::Confine::MaskList::Related.new(roots: [related], masks: [mask(hidden)], reads: [epics])
        classifier = Struct.new(:related) { def classify(_) = Lain::Sensitivity::ORDINARY.verdict }.new(answer)
        bounded = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, classifier:)

        profile = bounded.for(request(ruling("auto")))

        expect([profile.read_dirs, profile.masks]).to match([include(related, epics), include(hidden)])
        expect(profile.write_dirs).not_to include(related, epics)
      end

      # A related listing is refreshed by the call's own ask for masks, so it is read after that ask.
      it "binds the related masks its own call's refresh listed, not the previous call's", :seam do
        listing = Class.new do
          def initialize(base)
            @base = base
            @asks = 0
          end

          def masks = (@asks += 1) && []
          def classify(_) = Lain::Sensitivity::ORDINARY.verdict

          def related
            Lain::Confine::MaskList::Related.new(roots: [], masks: [Lain::Sensitivity::Policy::Mask.new(
              path: File.join(@base, "ask#{@asks}"), reason: "secret"
            )])
          end
        end.new(@base)
        bounded = described_class.new(masks: listing, probe:, home:, root:, workspace: true, tmpdir: scratch,
                                      classifier: listing)

        expect(bounded.for(request(ruling("auto"))).masks).to include(File.join(@base, "ask1"))
      end

      it "names each related directory a listing refused in a workspace call's last line", :seam do
        refused = File.join(@base, "cache")
        answer = Lain::Confine::MaskList::Related.new(roots: [], masks: [], refused: { refused => "its walk failed" })
        classifier = Struct.new(:related) { def classify(_) = Lain::Sensitivity::ORDINARY.verdict }.new(answer)
        bounded = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, classifier:)

        expect(bounded.for(request(ruling("auto"))).tier_line).to end_with("; not read: #{refused} (its walk failed)]")
      end

      it "lists a read root lent to the session, as a judged ls of the epic home does", :seam do
        epics = File.join(@base, "state", "epics", "nyotes").tap { FileUtils.mkdir_p(_1) }
        File.write(File.join(epics, "epic.md"), "# nyotes\n")
        policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root), root:,
                                               read_roots: [File.dirname(epics)])
        system(SeedRepo::SCRUB, "git", "init", "-q", root, exception: true)
        classifier = Lain::Confine::MaskList.new(root:, policy: -> { policy })
        real = Lain::Confine::Probe.new(fence: Lain::Confine::Bwrap.fence_binary, journal:)
        confined = described_class.new(masks: classifier, probe: real, home:, root:, workspace: true,
                                       tmpdir: scratch, classifier:)
        local = Lain::Exec::Local.new(child_env: Lain::Exec::ChildEnv.new(env: ENV.to_h))
        exec = Lain::Exec::Sandboxed.new(inner: local, journal:, profiles: confined,
                                         launcher: Lain::Confine::Bwrap.new(fence: Lain::Confine::Bwrap.fence_binary))

        listed = exec.call(command: "ls #{epics}", cwd: root, env: {}, timeout: 20,
                           confinement: request(ruling("auto")))

        expect(listed).to have_attributes(exit_status: 0, stdout: "epic.md\n")
      end

      it "runs the build output each PROJECT exec rule names in the root the request names, a lease's included",
         :seam do
        lease = File.join(@base, "lease")
        FileUtils.mkdir_p(%w[node_modules .venv/bin target src].map { File.join(lease, _1) })

        profile = profiles.for(request(ruling("auto"), root: lease))

        expect(%w[node_modules/.bin/vitest .venv/bin/pytest target/debug/deps/x-hash src/main.rs]
                 .map { profile.runs?(File.join(lease, _1)) }).to eq([true, true, true, false])
      end

      describe "a cargo checkout with no target/ yet" do
        before { File.write(File.join(root, "Cargo.toml"), "[package]\nname = \"x\"\n") }

        it "makes target/ empty before the call, and runs it", :seam do
          profile = profiles.for(request(ruling("auto")))

          expect([Dir.children(File.join(root, "target")), profile.runs?(File.join(root, "target/debug/x"))])
            .to eq([[], true])
        end

        it "neither makes nor runs a target/ that is a link out of the checkout, nor writes where it points", :seam do
          outside = File.join(@base, "outside").tap { FileUtils.mkdir_p(_1) }
          File.symlink(File.join(outside, "made"), File.join(root, "target"))

          profile = profiles.for(request(ruling("auto")))

          expect([Dir.children(outside), profile.exec_dirs.include?(File.join(root, "target"))]).to eq([[], false])
        end

        it "runs a test binary the same call builds", :seam do
          real = Lain::Confine::Probe.new(fence: Lain::Confine::Bwrap.fence_binary, journal:)
          confined = described_class.new(masks:, probe: real, home:, root:, workspace: true, tmpdir: scratch)
          local = Lain::Exec::Local.new(child_env: Lain::Exec::ChildEnv.new(env: ENV.to_h))
          exec = Lain::Exec::Sandboxed.new(inner: local, journal:, profiles: confined,
                                           launcher: Lain::Confine::Bwrap.new(fence: Lain::Confine::Bwrap.fence_binary))
          bin = "target/debug/deps/x-hash"

          built = exec.call(command: "mkdir -p #{File.dirname(bin)} && cp /usr/bin/true #{bin} && ./#{bin}",
                            cwd: root, env: {}, timeout: 20, confinement: request(ruling("auto")))

          expect(built).to have_attributes(exit_status: 0, stderr: a_string_matching(/\A\[ran: [^\n]+\]\n\z/))
        end

        # The sandbox's own target/ is no change a human must vouch for, so the first build still asks one.
        it "leaves a crate whose lineage ran an unread command barred on its first build", :seam do
          sleep 0.05
          start = Time.now
          sleep 0.05
          lineage = Lain::Shell::Executable::Fresh.new(start:, written: [], stat: Lain::Shell::Executable::Stat.new)
          lineage << Lain::Telemetry::WritesUnread.new(tool_use_id: "tu_0", cwd: root, command: "make")
          described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, fresh: lineage)
                         .for(request(ruling("auto")))
          cargo = executable("cargo", File.join(@base, "bin/cargo"), :user)
          build = Lain::Confine::Request.new(ruling: ruling("auto"), executables: [cargo], argv: [%w[cargo build]],
                                             cwd: root, root:, tool_use_id: "toolu_1")

          expect(File.directory?(File.join(root, "target"))).to be(true)
          expect(described_class::Granting.over(fresh: lineage, home:, root:).build_grant_for(build, vouched: true))
            .to eq("cargo")
        end

        it "makes no target/ for a call it refuses", :seam do
          listed = Struct.new(:masks) { def landed_on(_path) = ["link"] }.new([mask(root)])
          refusing = described_class.new(masks: listed, probe:, home:, root:, workspace: true, tmpdir: scratch)

          expect { refusing.for(request(ruling("auto"))) }.to raise_error(described_class::Overmasked)
          expect(File.exist?(File.join(root, "target"))).to be(false)
        end
      end

      it "stops running a node_modules/ swapped for a link out of the root between 2 calls", :seam do
        FileUtils.mkdir_p(modules = File.join(root, "node_modules"))
        real = profiles.for(request(ruling("auto"))).exec_dirs
        FileUtils.rm_rf(modules)
        File.symlink(FileUtils.mkdir_p(home).first, modules)

        expect([real, profiles.for(request(ruling("auto"))).exec_dirs].map { _1.include?(modules) })
          .to eq([true, false])
      end

      it "never runs the root itself, though a rule lowers to it", :seam do
        answer = Lain::Confine::MaskList::Related.new(roots: [], masks: [],
                                                      execs: Lain::Confine::ExecRules.of(["**", root]))
        classifier = Struct.new(:related) { def classify(_) = Lain::Sensitivity::ORDINARY.verdict }.new(answer)
        wide = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, classifier:)

        expect(wide.for(request(ruling("auto"))).runs?(File.join(root, "planted"))).to be(false)
      end

      it "makes no target/ in a checkout without a Cargo.toml", :seam do
        profiles.for(request(ruling("auto")))

        expect(File.exist?(File.join(root, "target"))).to be(false)
      end

      it "makes no node_modules/ or .venv/bin, which run from the call after the one that made them", :seam do
        absent = profiles.for(request(ruling("auto")))
        made = %w[node_modules .venv/bin].map { File.join(root, _1) }
        expect(made.map { File.exist?(_1) }).to eq([false, false])
        FileUtils.mkdir_p(made)

        expect([absent, profiles.for(request(ruling("auto")))].map { |profile| made.map { profile.runs?("#{_1}/x") } })
          .to eq([[false, false], [true, true]])
      end

      it "runs what the exec rules the classifier carries name in the root", :seam do
        FileUtils.mkdir_p(tools = File.join(root, "tools"))
        answer = Lain::Confine::MaskList::Related.new(roots: [], masks: [],
                                                      execs: Lain::Confine::ExecRules.of(["tools/*", root]))
        classifier = Struct.new(:related) { def classify(_) = Lain::Sensitivity::ORDINARY.verdict }.new(answer)
        bounded = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, classifier:)

        expect(bounded.for(request(ruling("auto"))).runs?(File.join(tools, "gen"))).to be(true)
        expect(profiles.for(request(ruling("auto"))).runs?(File.join(tools, "gen"))).to be(false)
      end

      it "lets a workspace call run a program resolved outside /usr that no project could have planted", :seam do
        grep = File.join(home, ".local/bin/grep")
        executables = [executable("grep", grep, :user), executable("cat", File.join(root, "bin/cat"), :project)]

        expect(profiles.for(request(ruling("auto"), executables:)).exec_files).to eq([grep])
      end

      describe "the programs a parsed command is handed as grants", :seam do
        let(:bin) { File.join(home, ".local/share/mise/installs/ruby/4.0.6/bin") }
        let(:bundle) { executable("bundle", File.join(bin, "bundle"), :user) }
        let(:fresh_paths) { [] }
        let(:fresh) do
          paths = fresh_paths
          Module.new do
            define_singleton_method(:any_under?) { |dir| paths.any? { Lain::Landing.under?(_1, dir) } }
            define_singleton_method(:fresh?) { |_path| true }
          end
        end
        let(:profiles) { described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, fresh:) }

        it "grants an install's bin dir when the lineage was not read, since freshness gates only the reader" do
          unread = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch)

          expect(unread.for(request(ruling("auto"), grants: [bundle])).exec_dirs).to include(bin)
        end

        it "runs a fresh program in an install's bin dir beside a granted one" do
          ruby = script(bin, "ruby")
          rake = script(bin, "rake")
          fresh_paths << rake
          grants = [executable("ruby", ruby, :user), executable("rake", rake, :user).with(fresh: true)]

          profile = profiles.for(request(ruling("auto"), grants:))

          expect([profile.runs?(ruby), profile.runs?(rake)]).to eq([true, true])
        end

        it "grants no install's bin dir that holds a dir, whose programs a dir grant would run too" do
          ruby = script(bin, "ruby")
          git = script(File.join(bin, "sub"), "git")

          profile = profiles.for(request(ruling("auto"), grants: [executable("ruby", ruby, :user)]))

          expect([profile.runs?(ruby), profile.runs?(git)]).to eq([true, false])
        end

        it "grants no install's bin dir it cannot list, since what it holds is unknown" do
          ruby = script(bin, "ruby")
          File.chmod(0o111, bin)

          profile = profiles.for(request(ruling("auto"), grants: [executable("ruby", ruby, :user)]))

          expect([profile.exec_files, profile.exec_dirs.include?(bin)]).to eq([[ruby], false])
        ensure
          File.chmod(0o755, bin)
        end

        it "runs a granted program and the install it sits in, through the filter every program passes" do
          profile = profiles.for(request(ruling("auto"), grants: [bundle]))

          expect([profile.exec_files, profile.exec_dirs]).to match([[bundle.realpath], include(bin)])
        end

        it "refuses a grant the project could have planted or that resolved to nothing, as it refuses a stage" do
          grants = [executable("cat", File.join(root, "bin/cat"), :project), Lain::Shell::Executable.unresolved("x"),
                    executable("tool", File.join(@base, "elsewhere/tool"), :unresolved)]

          expect(profiles.for(request(ruling("auto"), grants:)).exec_files).to eq([])
        end

        it "drops a grant that lies under a mask rather than refusing the call" do
          masked << mask(bin)

          profile = profiles.for(request(ruling("auto"), grants: [bundle]))

          expect(profile.exec_files).to eq([])
          expect(profile.exec_dirs).not_to include(bin)
        end

        def script(dir, name)
          FileUtils.mkdir_p(dir)
          File.join(dir, name).tap do |path|
            File.write(path, "#!/bin/sh\n")
            File.chmod(0o755, path)
          end
        end

        def resolved(argv, path:, fresh: Lain::Shell::Executable::Resolver::NeverFresh)
          resolver = Lain::Shell::Executable::Resolver.new(root:, fresh:)
          resolver.for(Lain::WorkerEnv.new(cwd: root, env: { "PATH" => path })).call(Lain::Shell::Term.of(argv))
        end

        it "refuses a user program first on PATH that shadows another of its name" do
          shadow = script(File.join(@base, "userbin"), "ruby")
          grants = resolved(%w[ruby x.rb], path: "#{File.dirname(shadow)}:#{ENV.fetch("PATH")}")

          expect(grants.map { [_1.realpath, _1.klass, _1.shadowed.any?] }).to eq([[shadow, :user, true]])
          expect(profiles.for(request(ruling("auto"), grants:)).exec_files).to eq([])
        end

        it "grants a mise install's program that shadows only mise's shim of its name" do
          mise = File.join(home, ".local/share/mise")
          ruby = script(File.join(mise, "installs/ruby/4.0.6/bin"), "ruby")
          shims = File.dirname(script(File.join(mise, "shims"), "ruby"))
          grants = resolved(%w[ruby x.rb], path: "#{File.dirname(ruby)}:#{shims}")

          expect(grants.map { [_1.klass, _1.shadowed] }).to eq([[:user, [File.join(shims, "ruby")]]])
          expect(profiles.for(request(ruling("auto"), grants:)).exec_files).to eq([ruby])
        end

        it "refuses a user program that shadows mise's shim, which dispatches to a different program" do
          shims = File.dirname(script(File.join(home, ".local/share/mise/shims"), "ruby"))
          plant = script(File.join(@base, "userbin"), "ruby")
          grants = resolved(%w[ruby x.rb], path: "#{File.dirname(plant)}:#{shims}")

          expect(profiles.for(request(ruling("auto"), grants:)).exec_files).to eq([])
        end

        it "grants a mise install's program ahead of another of its name, as /usr/bin's is, since it is toolchain" do
          ruby = script(File.join(home, ".local/share/mise/installs/ruby/4.0.6/bin"), "ruby")
          later = script(File.join(@base, "sysbin"), "ruby")
          grants = resolved(%w[ruby x.rb], path: "#{File.dirname(ruby)}:#{File.dirname(later)}")

          expect(grants.map(&:shadowed)).to eq([[later]])
          expect(profiles.for(request(ruling("auto"), grants:)).exec_files).to eq([ruby])
        end

        it "refuses a ~/bin program ahead of a mise install's program of its name" do
          plant = script(File.join(home, "bin"), "ruby")
          ruby = script(File.join(home, ".local/share/mise/installs/ruby/4.0.6/bin"), "ruby")
          grants = resolved(%w[ruby x.rb], path: "#{File.dirname(plant)}:#{File.dirname(ruby)}")

          expect(profiles.for(request(ruling("auto"), grants:)).exec_files).to eq([])
        end

        it "grants a user program outside the project that shadows nothing" do
          tool = script(File.join(@base, "outside"), "lain-t5-tool")
          grants = resolved(%w[lain-t5-tool], path: File.dirname(tool))

          expect(profiles.for(request(ruling("auto"), grants:)).exec_files).to eq([tool])
        end

        it "grants a user program written this lineage, which only the reader refuses" do
          tool = script(File.join(@base, "outside"), "lain-t5-tool")
          fresh = Class.new { define_method(:fresh?) { |path| path == tool } }.new
          grants = resolved(%w[lain-t5-tool], path: File.dirname(tool), fresh:)

          expect(profiles.for(request(ruling("auto"), grants:)).exec_files).to eq([tool])
        end

        it "hands a reader call the grants its own placement test keeps, refusing one written this lineage" do
          tool = script(File.join(@base, "outside"), "lain-t5-tool")
          grants = resolved(%w[lain-t5-tool], path: File.dirname(tool))
          fresh = Class.new { define_method(:fresh?) { |path| path == tool } }.new
          written = resolved(%w[lain-t5-tool], path: File.dirname(tool), fresh:)

          expect([grants, written].map { profiles.for(request(ruling("rules", rule: "composed_term"), grants: _1)) }
            .map(&:exec_files)).to eq([[tool], []])
        end
      end

      it "runs the whole bin dir of a mise install a program resolved into, never a sibling version's", :seam do
        bin = File.join(home, ".local/share/mise/installs/ruby/4.0.6/bin")
        planted = File.join(root, "bin/bundle")
        executables = [executable("bundle", File.join(bin, "bundle"), :user), executable("x", planted, :project)]
        quiet = Module.new do
          def self.any_under?(_dir) = false
          def self.fresh?(_path) = true
        end
        read = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, fresh: quiet)
        profile = read.for(request(ruling("auto"), executables:))

        expect(profile.exec_dirs).to include(bin)
        expect([profile.runs?(File.join(bin, "ruby")), profile.runs?("#{bin.sub("4.0.6", "4.0.5")}/ruby"),
                profile.runs?(planted)]).to eq([true, false, false])
        expect(profiles.for(composed(executables:)).exec_dirs).not_to include(bin)
      end

      it "runs no mise install for a program a project could have planted there", :seam do
        bin = File.join(home, ".local/share/mise/installs/ruby/4.0.6/bin")
        executables = [executable("bundle", File.join(bin, "bundle"), :project)]

        expect(profiles.for(request(ruling("auto"), executables:)).exec_dirs).not_to include(bin)
      end

      it "makes the call's private cargo home in its own dir, holding only the config lain writes", :seam do
        FileUtils.mkdir_p(File.join(home, ".cargo/registry"))
        profile = profiles.for(request(ruling("auto")))
        made = profile.homes.sole.source(profile.call_tmpdir)

        expect(Dir.children(made)).to eq(["config.toml"])
        expect(File.read(File.join(made, "config.toml"))).to include(%(auto-clean-frequency = "never"))
      end

      it "stops running target/ from the call after it is replaced by a link out of the root", :seam do
        FileUtils.mkdir_p(target = File.join(root, "target"))
        real = profiles.for(request(ruling("auto"))).exec_dirs
        FileUtils.rm_rf(target)
        File.symlink(FileUtils.mkdir_p(File.join(@base, "outside")).first, target)

        expect([real.include?(target), profiles.for(request(ruling("auto"))).exec_dirs.include?(target)])
          .to eq([true, false])
      end

      it "runs a target/ from the call after the one that made it", :seam do
        before = profiles.for(request(ruling("auto"))).exec_dirs
        FileUtils.mkdir_p(target = File.join(root, "target"))

        expect([before.include?(target), profiles.for(request(ruling("auto"))).exec_dirs.include?(target)])
          .to eq([false, true])
      end

      it "removes the call's dir and refuses the call when its private home cannot be made", :seam do
        FileUtils.mkdir_p(File.join(home, ".cargo/registry"))
        allow(FileUtils).to receive(:mkdir_p).and_call_original
        allow(FileUtils).to receive(:mkdir_p).with(%r{/\.lain-homes/}).and_raise(Errno::ENOSPC)

        expect { profiles.for(request(ruling("auto"))) }.to raise_error(described_class::NoTmpdir)
        expect(Dir.children(scratch)).to be_empty
      end

      describe "a private network", :seam do
        def status(fields) = ["#{JSON.generate({ abi: 6, rights: {}, skipped: [], **fields })}\n", true]

        it "is the call's own where the fence says it can make one" do
          answers["lain-fence"] = status(private_net: false)

          expect(profiles.for(request(ruling("auto"))).private_net).to be(true)
        end

        it "is the host's, so the fence still refuses every bind, where the fence names no private_net" do
          expect(profiles.for(request(ruling("auto"))).private_net).to be(false)
        end
      end

      it "refuses a mask that would empty the project it writes, naming the profile, and makes no dir", :seam do
        listed = Struct.new(:masks) { def landed_on(_path) = ["link"] }.new([mask(root)])
        workspace = described_class.new(masks: listed, probe:, home:, root:, workspace: true, tmpdir: scratch)

        expect { workspace.for(request(ruling("auto"))) }
          .to raise_error(described_class::Overmasked, /link/) { expect(_1.profile).to eq(:workspace) }
        expect(Dir.children(scratch)).to be_empty
      end

      describe "a build tool's ports", :seam do
        let(:fresh_paths) { [] }
        let(:fresh) do
          paths = fresh_paths
          Struct.new(:paths) do
            def any_under?(root) = paths.any? { Lain::Landing.under?(_1, root) }
            def fresh?(_path) = true
          end.new(paths)
        end
        let(:profiles) do
          described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, fresh:,
                              env: { "GEM_HOME" => File.join(@base, "gems") })
        end
        let(:mise) { File.join(home, ".local/share/mise/installs/ruby/4.0.6/bin") }

        before do
          git_init(root)
          FileUtils.mkdir_p([File.join(@base, "gems/bin"), File.join(@base, "gems/specifications"),
                             File.join(root, "target")])
        end

        def run_file(name, fresh: false, klass: :project)
          Lain::Shell::Executable::RunFiles::Entry.new(path: File.join(root, name), klass:, fresh:)
        end

        def tool(name, realpath: File.join(mise, name), klass: :user, run_files: [], **changes)
          executable(name, realpath, klass).with(run_files:, **changes)
        end

        def bundle(**) = tool("bundle", run_files: [run_file("Gemfile"), run_file("Gemfile.lock")], **)

        def cargo(**)
          tool("cargo", realpath: File.join(home, ".cargo/bin/rustup"), run_files: [run_file("Cargo.toml")], **)
        end

        def git(**) = tool("git", realpath: "/usr/bin/git", klass: :system, **)

        def called(argv, executable, rung: "auto", cwd: root)
          Lain::Confine::Request.new(ruling: ruling(rung), executables: [executable], argv: [argv], cwd:, root:,
                                     tool_use_id: "toolu_1")
        end

        def profile_of(...) = profiles.for(called(...))

        it "grants a judge-approved bundle install its ports while nothing in the project is fresh" do
          profile = profile_of(%w[bundle install], bundle)

          expect(profile).to have_attributes(name: :grant, connect_ports: [443, 80],
                                             unix_dirs: ["/run/systemd/resolve"], confined?: true)
          expect(profile.exec_files).to eq([File.join(mise, "bundle")])
          expect(profile.write_dirs).to include(File.join(@base, "gems"), profile.call_tmpdir)
        end

        it "keeps a grant on the host's network, which its fetch needs, though the fence could make a private one" do
          answers["lain-fence"] = ["{\"abi\":6,\"private_net\":false,\"rights\":{},\"skipped\":[]}\n", true]

          expect([profile_of(%w[git fetch origin], git), profile_of(%w[git status], git)].map(&:private_net))
            .to eq([false, true])
        end

        it "keeps a grant's ports for a contained approval of a fetch, off the private network" do
          answers["lain-fence"] = ["{\"abi\":6,\"private_net\":false,\"rights\":{},\"skipped\":[]}\n", true]
          approved = Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "approved",
                                                              authority: :human, contained: true)
          fetch = Lain::Confine::Request.new(ruling: approved, executables: [git], argv: [%w[git fetch origin]],
                                             cwd: root, root:, tool_use_id: "toolu_1")

          expect(profiles.for(fetch)).to have_attributes(name: :grant, connect_ports: [443], private_net: false)
        end

        it "grants a rule's or bypass's approval too, the rungs that earn the workspace profile" do
          expect(%w[rules bypass].map { profile_of(%w[git fetch origin], git, rung: _1).name }).to eq(%i[grant grant])
        end

        it "withdraws the grant once a build input was written this lineage" do
          fresh_paths << File.join(root, "Gemfile")

          expect(profile_of(%w[bundle install], bundle(run_files: [run_file("Gemfile", fresh: true)])))
            .to have_attributes(name: :workspace, connect_ports: [], unix_dirs: [])
        end

        def installed_cargo
          File.join(home, ".cargo/bin/cargo").tap do |path|
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, "#!/bin/sh\n")
            File.chmod(0o755, path)
          end
        end

        def assigned_stage(command)
          resolver = Lain::Shell::Executable::Resolver.new(root:, fresh: Lain::Shell::Executable::Resolver::NeverFresh)
          worker_env = Lain::WorkerEnv.new(cwd: root, env: { "PATH" => "#{File.dirname(installed_cargo)}:/usr/bin" })
          Lain::Shell::Stages.of(command, worker_env:, resolver:).stages.sole
        end

        it "runs the cargo a leading assignment wraps, under the workspace a rule's approval earns" do
          command = "RUST_BACKTRACE=1 cargo build --locked"
          stage = assigned_stage(command)
          string_arm = [Lain::Shell::Executable.unresolved(command)]
          profile = profiles.for(request(ruling("rules"), executables: string_arm, grants: [stage.executable]))

          expect(profile).to have_attributes(name: :workspace, connect_ports: [])
          expect(profile.exec_files).to eq([installed_cargo])
        end

        it "gives a cargo stage a leading assignment wraps no build grant, though its own argv would earn one" do
          wrapped = assigned_stage("RUST_BACKTRACE=1 cargo build --locked").executable

          names = [wrapped, wrapped.with(wrappers: [])].map do |executable|
            profile_of(%w[cargo build --locked], executable, rung: "rules").name
          end

          expect(names).to eq(%i[workspace grant])
        end

        it "withdraws the grant once code the build loads was written, though no run file names it" do
          fresh_paths << File.join(root, "lib/lain/version.rb")

          expect(profile_of(%w[bundle install], bundle)).to have_attributes(name: :workspace, connect_ports: [])
        end

        it "withdraws the grant once any file in a cargo workspace member was written" do
          fresh_paths << File.join(root, "crates/lain-fence/build.rs")

          expect(profile_of(%w[cargo build], cargo)).to have_attributes(name: :workspace, connect_ports: [])
        end

        it "withdraws cargo's grant once the lineage records a write into target/, where the grant may exec" do
          planted = File.join(root, "target/debug/build/x/build-script-build")
          recorded = Lain::Shell::Executable::Fresh.new(start: Time.now + 3600, written: [planted],
                                                        stat: Lain::Shell::Executable::Stat.new)
          quiet = Lain::Shell::Executable::Fresh.new(start: Time.now + 3600, written: [],
                                                     stat: Lain::Shell::Executable::Stat.new)
          names = [recorded, quiet].map do |answer|
            described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, fresh: answer)
                           .for(called(%w[cargo build], cargo)).name
          end

          expect(names).to eq(%i[workspace grant])
        end

        it "grants a first cargo fetch in a fresh checkout its port, with no exec dir" do
          FileUtils.rm_rf(File.join(root, "target"))
          fetch = profile_of(%w[cargo fetch], cargo)

          expect([fetch.name, fetch.connect_ports, fetch.exec_dirs.grep(/target/)]).to eq([:grant, [443], []])
        end

        it "withdraws the grant when a run file outside the root is fresh or did not resolve" do
          outside = Lain::Shell::Executable::RunFiles::Entry.new(path: "/elsewhere/config", klass: :user, fresh: true)
          unresolved = run_file("Gemfile", klass: :unresolved)

          expect([git(run_files: [outside]), bundle(run_files: [unresolved])].zip([%w[git fetch], %w[bundle install]])
            .map { |stage, argv| profile_of(argv, stage).name }).to eq(%i[workspace workspace])
        end

        it "grants git fetch and refuses git push" do
          expect([profile_of(%w[git fetch origin], git).connect_ports, profile_of(%w[git push origin main], git).name])
            .to eq([[443], :workspace])
        end

        it "grants no port to a fetch the human answered secrets, which reads secrets only with no network" do
          answers["lain-fence"] = ["#{JSON.generate({ abi: 6, rights: {}, skipped: [], private_net: false })}\n", true]
          secrets = Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "approved", authority: :human,
                                                             contained: true, unmasked: true)
          asked = Lain::Confine::Request.new(ruling: secrets, executables: [git], argv: [%w[git fetch origin]],
                                             cwd: root, root:, tool_use_id: "toolu_1")

          expect(profiles.for(asked)).to have_attributes(name: :workspace, connect_ports: [], private_net: true)
        end

        it "grants each fetching git subcommand, and cargo fetch" do
          names = [*%w[fetch clone pull ls-remote].map { profile_of(["git", _1, "x"], git).name },
                   profile_of(%w[cargo fetch], cargo).name]
          expect(names).to all(eq(:grant))
        end

        it "refuses a program resolved in the project, a fresh one, or one that did not resolve" do
          planted = tool("bundle", realpath: File.join(root, "bin/bundle"), klass: :project)
          unresolved = Lain::Shell::Executable.unresolved("bundle")

          expect([planted, bundle(fresh: true), unresolved].map { profile_of(%w[bundle install], _1).name })
            .to all(eq(:workspace))
        end

        it "refuses a user program outside a mise install that shadows another of its name, or one with an anomaly" do
          shadowing = bundle(realpath: File.join(home, "bin/bundle"), shadowed: ["/usr/bin/bundle"])
          odd = bundle(anomalies: [:relative_path_entry])

          expect([shadowing, odd].map { profile_of(%w[bundle install], _1).name }).to all(eq(:workspace))
        end

        it "grants a mise install's program its ports though it shadows /usr/bin's, since it is toolchain" do
          expect(profile_of(%w[bundle install], bundle(shadowed: ["/usr/bin/bundle"])).name).to eq(:grant)
        end

        it "refuses a subcommand the card does not name, a leading option, a path word or a wrapper" do
          wrapped = bundle(wrappers: [executable("nice", "/usr/bin/nice", :system)])
          calls = [[%w[bundle exec rake], bundle], [%w[bundle update], bundle], [%w[cargo test], cargo],
                   [%w[cargo run], cargo], [%w[git --no-pager fetch], git], [%w[cargo +nightly build], cargo],
                   [["/usr/bin/git", "fetch"], git], [%w[nice bundle install], wrapped], [%w[git], git]]

          expect(calls.map { |argv, stage| profile_of(argv, stage).name }).to all(eq(:workspace))
        end

        it "grants the options each subcommand lists" do
          calls = [[%w[bundle install --frozen --jobs=4], bundle],
                   [%w[cargo build --locked --offline --release], cargo], [%w[cargo fetch --locked], cargo],
                   [%w[git fetch --prune --quiet origin], git],
                   [%w[git clone --depth=1 url dir], git], [%w[git pull --ff-only], git],
                   [%w[git ls-remote --heads origin], git]]

          expect(calls.map { |argv, stage| profile_of(argv, stage).name }).to all(eq(:grant))
        end

        it "refuses any option no list names: an abbreviation, a bundled short option, a value split off" do
          calls = [[%w[git fetch --upload=x origin], git], [%w[git ls-remote --exec=x origin], git],
                   [%w[git clone --templ=x url], git], [%w[git clone --conf=a=b url], git],
                   [%w[git fetch -qc origin], git], [%w[git clone -qu x url], git], [%w[git fetch -q origin], git],
                   [%w[bundle install --jobs 4], bundle], [%w[bundle install --jobs=x], bundle],
                   [%w[bundle install --jobs=], bundle],
                   [%w[cargo build --locked=x], cargo], [%w[cargo -C sub build], cargo],
                   [%w[cargo build -C sub], cargo]]

          expect(calls.map { |argv, stage| profile_of(argv, stage).name }).to all(eq(:workspace))
        end

        it "refuses a request whose stage is not the program its words name, or carries a wrapper the words do not" do
          wrapped = bundle(wrappers: [executable("nice", "/usr/bin/nice", :system)])
          unplaced = git.with(realpath: nil)

          expect([[%w[git fetch], cargo], [%w[bundle install], wrapped], [%w[git fetch], unplaced]]
            .map { |argv, stage| profile_of(argv, stage).name }).to all(eq(:workspace))
        end

        it "refuses an option that moves the build's inputs or runs a command of the caller's choosing" do
          calls = [[%w[bundle install --gemfile=/x/Gemfile], bundle],
                   [%w[cargo build --manifest-path /x/Cargo.toml], cargo], [%w[cargo build --config x=1], cargo],
                   [%w[cargo build -Zunstable-options], cargo], [%w[git fetch --upload-pack=x origin], git],
                   [%w[git clone -u x url], git], [%w[git clone --template=/x url], git],
                   [%w[git clone -c core.hooksPath=x url], git], [%w[git clone --config a=b url], git]]

          expect(calls.map { |argv, stage| profile_of(argv, stage).name }).to all(eq(:workspace))
        end

        it "refuses more than one stage" do
          request = Lain::Confine::Request.new(ruling: ruling("auto"), executables: [git, git],
                                               argv: [%w[git fetch], %w[git pull]], cwd: root, root:,
                                               tool_use_id: "toolu_1")

          expect(profiles.for(request).name).to eq(:workspace)
        end

        it "refuses a call whose cwd is outside the root, where its inputs are not watched" do
          expect(profile_of(%w[cargo build], cargo, cwd: @base).name).to eq(:workspace)
        end

        it "refuses a call that carries no argv, as one on the string arm does" do
          request = Lain::Confine::Request.new(ruling: ruling("auto"), executables: [git], cwd: root, root:,
                                               tool_use_id: "toolu_1")

          expect(profiles.for(request).name).to eq(:workspace)
        end

        it "grants a ComposedTerm approval of a cargo build the ports a judge's gets" do
          built = Lain::Confine::Request.new(ruling: ruling("rules", rule: "composed_term", builds: true),
                                             executables: [cargo], argv: [%w[cargo build --locked]], cwd: root, root:,
                                             tool_use_id: "toolu_1")
          judged = profile_of(%w[cargo build --locked], cargo, rung: Lain::Approval::Judged::NAME)

          expect([judged, profiles.for(built)].map { [_1.name, _1.connect_ports, _1.unix_dirs] }.uniq)
            .to eq([[:grant, [443], ["/run/systemd/resolve"]]])
        end

        it "never grants a human's approval or a ComposedTerm read" do
          human = Lain::Confine::Request.new(ruling: ruling("auto", authority: :human), executables: [git],
                                             argv: [%w[git fetch]], cwd: root, root:, tool_use_id: "toolu_1")
          composed_call = Lain::Confine::Request.new(ruling: ruling("rules", rule: "composed_term"),
                                                     executables: [git], argv: [%w[git fetch]], cwd: root, root:,
                                                     tool_use_id: "toolu_1")

          expect([profiles.for(human).name, profiles.for(composed_call).name]).to eq(%i[traced reader])
        end

        it "grants nothing when the profiles were given no lineage, which counts every root fresh" do
          unread = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch)

          expect(unread.for(called(%w[git fetch], git)).name).to eq(:workspace)
        end

        it "grants nothing with the workspace switch off" do
          off = described_class.new(masks:, probe:, home:, root:, fresh:)

          expect(off.for(called(%w[git fetch], git))).to eq(Lain::Confine::Profile::TRACED)
        end

        # A lineage that ran a command lain could not read, and nothing else.
        def unread_only
          Module.new do
            def self.any_under?(_root) = true
            def self.changed_under?(_root) = false
            def self.fresh?(_path) = true
          end
        end

        def cargo_build = called(%w[cargo build], cargo)

        def granting(over = fresh) = described_class::Granting.over(fresh: over, home:, root:)

        it "answers ahead of the sandbox as the sandbox grants, over the same lineage" do
          outside = called(%w[cargo build], cargo, cwd: @base)

          expect([granting.build_grant_for(cargo_build), profile_of(%w[cargo build], cargo).name])
            .to eq(["cargo", :grant])
          expect([granting.build_grant_for(outside), profiles.for(outside).name]).to eq([nil, :workspace])
        end

        it "answers none ahead of the sandbox once the project is fresh, or for a call no grant covers" do
          covered = granting.build_grant_for(called(%w[cargo test], cargo))
          fresh_paths << File.join(root, "Cargo.toml")

          expect([covered, granting.build_grant_for(cargo_build)]).to eq([nil, nil])
        end

        it "names the tool a vouch would give back when only the unread mark withholds it" do
          expect([granting(unread_only).build_grant_for(cargo_build),
                  granting(unread_only).build_grant_for(cargo_build, vouched: true)]).to eq([nil, "cargo"])
        end

        it "names nothing from a session whose sandbox grants nothing" do
          expect(described_class::Granting::NONE.build_grant_for(cargo_build, vouched: true)).to be_nil
        end
      end

      describe "a mise install of a version the project pins", :seam do
        let(:fresh_paths) { [] }
        let(:fresh) do
          paths = fresh_paths
          Struct.new(:paths) do
            def any_under?(root) = paths.any? { Lain::Landing.under?(_1, root) }
            def fresh?(_path) = true
          end.new(paths)
        end
        let(:registry) do
          Struct.new(:answer, :asked) { def backend(**words) = (asked << words) && answer }.new("aqua:jqlang/jq", [])
        end
        let(:profiles) { installing({}) }
        let(:data) { File.join(home, ".local/share/mise") }
        let(:binary) do
          File.join(home, ".local/bin/mise").tap do |path|
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, "#!/bin/sh\n")
            File.chmod(0o755, path)
          end
        end

        before do
          git_init(root)
          FileUtils.mkdir_p(data)
          pin("mise.toml", %([tools]\njq = "1.8.1"\n))
        end

        def pin(name, body)
          File.join(root, name).tap { FileUtils.mkdir_p(File.dirname(_1)) }.then { File.write(_1, body) }
        end

        def installing(env)
          described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, fresh:, env:, registry:)
        end

        def mise(realpath = binary) = executable("mise", realpath, :user)

        def install(word, *rest, executable: mise, cwd: root)
          Lain::Confine::Request.new(ruling: ruling("auto"), executables: [executable],
                                     argv: [["mise", "install", word, *rest]], cwd:, root:, tool_use_id: "toolu_1")
        end

        def granted?(request) = profiles.for(request).then { _1.name == :grant && _1.connect_ports == [443] }

        it "grants port 443 and mise's own prefix, runs that mise, and tells it to read no project config" do
          profile = profiles.for(install("jq@1.8.1"))
          own = File.join(profile.call_tmpdir, "mise")

          expect(profile).to have_attributes(name: :grant, connect_ports: [443], private_net: false)
          expect(profile.write_dirs.select { Lain::Landing.under?(_1, home) }).to eq([data])
          expect(profile.runs?(binary)).to be(true)
          expect(profile.env).to include("MISE_IGNORED_CONFIG_PATHS" => root, "MISE_CEILING_PATHS" => root,
                                         "MISE_STATE_DIR" => File.join(own, "state"),
                                         "MISE_CONFIG_DIR" => File.join(own, "config"),
                                         "MISE_CACHE_DIR" => File.join(own, "cache"),
                                         "XDG_CACHE_HOME" => File.join(own, "xdg-cache"), "MISE_DATA_DIR" => data)
          expect(profile.env.fetch("MISE_DISABLE_BACKENDS").split(",")).to include("asdf", "vfox", "cargo", "go", "npm")
        end

        it "drops every other MISE_ name the session would hand the granted mise, such as one trusting a config" do
          session = %w[MISE_TRUSTED_CONFIG_PATHS MISE_ALL_COMPILE MISE_DATA_DIR PATH]

          env = profiles.for(install("jq@1.8.1")).env(session)

          expect(env).to include("MISE_TRUSTED_CONFIG_PATHS" => nil, "MISE_ALL_COMPILE" => nil, "MISE_DATA_DIR" => data)
          expect(env).not_to have_key("PATH")
        end

        it "grants nothing at a root whose path holds a colon, which would split mise's list of ignored roots" do
          colon = File.join(@base, "pro:ject").tap { FileUtils.mkdir_p(_1) }
          File.write(File.join(colon, "mise.toml"), %([tools]\njq = "1.8.1"\n))
          at_colon = described_class.new(masks:, probe:, home:, root: colon, workspace: true, tmpdir: scratch, fresh:,
                                         env: {}, registry:)
          asked = Lain::Confine::Request.new(ruling: ruling("auto"), executables: [mise],
                                             argv: [%w[mise install jq@1.8.1]], cwd: colon, root: colon,
                                             tool_use_id: "toolu_1")

          expect([at_colon.for(asked).name, registry.asked]).to eq([:workspace, []])
        end

        it "asks the backend of the very mise the call runs, under the same ignored-config env" do
          profiles.for(install("jq@1.8.1"))

          expect(registry.asked).to eq([{ mise: binary, name: "jq", root: }])
        end

        it "reads the pins from .tool-versions and from the array and table forms of a config's tools" do
          File.delete(File.join(root, "mise.toml"))
          pin(".tool-versions", "jq 1.7 1.8.1 # two\nnode 22.1.0\n")
          pin(".config/mise/config.toml", %([tools]\ncmake = ["4.5.1", "4.4.0"]\nninja = { version = "1.12.1" }\n))

          words = %w[jq@1.8.1 jq@1.7 node@22.1.0 cmake@4.5.1 cmake@4.4.0 ninja@1.12.1 jq@1.9.0 ninja@1.12.0]
          expect(words.map { granted?(install(_1)) }).to eq(([true] * 6) + ([false] * 2))
        end

        it "grants nothing for a version the project does not pin, and keeps mise hidden there" do
          profile = profiles.for(install("jq@1.7.1"))

          expect(profile).to have_attributes(name: :workspace, connect_ports: [])
          expect(profile.runs?(binary)).to be(false)
          expect(profile.env).to eq({})
        end

        it "reads no pin from a config that does not parse" do
          pin("mise.toml", "[tools\njq = \"1.8.1\"\n")

          expect(granted?(install("jq@1.8.1"))).to be(false)
        end

        it "admits only a short name at an exact version, with no other word, and parks the rest" do
          pin("mise.toml", %([tools]\n"asdf:foo" = "1"\n"ubi:x/y" = "1"\ncmake = "latest"\njq = "1.8.1"\n))
          asks = [["asdf:foo@1"], ["ubi:x/y@1"], ["cmake@latest"], ["jq@1.8.1", "--", "--x"], ["jq@1.8.1", "-v"],
                  ["jq@1.8.1", "jq@1.8.1"], ["jq"]]

          expect(asks.map { granted?(install(*_1)) }).to all(be(false))
          expect(asks.map { described_class.grantable_ports([["mise", "install", *_1]]) }).to all(eq([]))
          expect(described_class.grantable_ports([%w[mise install jq@1.8.1]])).to eq([443])
        end

        {
          "an asdf plugin" => "asdf:mise-plugins/asdf-jq", "a vfox plugin" => "vfox:mise-plugins/vfox-jq",
          "a cargo build" => "cargo:jq", "a go build" => "go:github.com/x/jq", "an npm package" => "npm:jq",
          "ruby, which compiles" => "core:ruby", "python, which may compile" => "core:python",
          "a name mise does not know" => nil
        }.each do |what, answer|
          it "grants nothing when the registry resolves the name to #{what}" do
            registry.answer = answer

            expect(granted?(install("jq@1.8.1"))).to be(false)
          end
        end

        %w[aqua:jqlang/jq ubi:jqlang/jq github:jqlang/jq core:node].each do |answer|
          it "grants the install when the registry resolves the name to #{answer}, which fetches a prebuilt release" do
            registry.answer = answer

            expect(granted?(install("jq@1.8.1"))).to be(true)
          end
        end

        it "grants nothing to a program named mise that is not the box's mise" do
          other = File.join(@base, "elsewhere/mise").tap { FileUtils.mkdir_p(File.dirname(_1)) && File.write(_1, "") }

          expect(granted?(install("jq@1.8.1", executable: mise(other)))).to be(false)
        end

        it "grants nothing from a subdirectory, whose own configs mise would read" do
          sub = File.join(root, "sub").tap { FileUtils.mkdir_p(_1) }

          expect(granted?(install("jq@1.8.1", cwd: sub))).to be(false)
        end

        it "withdraws the grant once anything in the project was written this lineage, before asking mise" do
          fresh_paths << File.join(root, "mise.toml")

          expect([granted?(install("jq@1.8.1")), registry.asked]).to eq([false, []])
        end

        it "reads the backend the box's mise lists first for a short name, and none for a name it does not know" do
          real = "/usr/bin/mise"
          skip "no mise at #{real}" unless File.executable?(real)

          answers = %w[jq no-such-tool-anywhere].map do |name|
            described_class::MiseRegistry.backend(mise: real, name:, root:)
          end

          expect(answers).to match([a_string_starting_with("aqua:"), nil])
        end

        it "asks mise from the root, under the env that ignores its config and drops the session's MISE_ names" do
          seen = File.join(@base, "seen")
          fake = File.join(@base, "bin/mise").tap { FileUtils.mkdir_p(File.dirname(_1)) }
          File.write(fake, "#!/bin/sh\n{ pwd; env; } > #{seen}\necho 'aqua:x/y asdf:x/y'\n")
          File.chmod(0o755, fake)
          ENV["MISE_TRUSTED_CONFIG_PATHS"] = root

          answer = described_class::MiseRegistry.backend(mise: fake, name: "jq", root:)
          lines = File.readlines(seen, chomp: true)

          expect([answer, lines.first]).to eq(["aqua:x/y", root])
          expect(lines).to include("MISE_IGNORED_CONFIG_PATHS=#{root}", "MISE_CEILING_PATHS=#{root}")
          expect(lines.grep(/\AMISE_TRUSTED_CONFIG_PATHS=/)).to eq([])
        ensure
          ENV.delete("MISE_TRUSTED_CONFIG_PATHS")
        end

        it "reads no backend from a mise that does not answer in time" do
          slow = File.join(@base, "bin/mise").tap { FileUtils.mkdir_p(File.dirname(_1)) }
          File.write(slow, "#!/bin/sh\nsleep 5\necho aqua:x/y\n")
          File.chmod(0o755, slow)

          expect(described_class::MiseRegistry.backend(mise: slow, name: "jq", root:, timeout: 0.2)).to be_nil
        end

        it "grants nothing when mise's data dir is home itself, since that write cannot be bounded" do
          expect(installing({ "MISE_DATA_DIR" => home }).for(install("jq@1.8.1")).name).to eq(:workspace)
        end

        it "writes the data dir the env names for mise" do
          named = File.join(@base, "xdg/data/mise").tap { FileUtils.mkdir_p(_1) }

          expect(installing({ "XDG_DATA_HOME" => File.dirname(named) }).for(install("jq@1.8.1")).write_dirs)
            .to include(named)
        end

        it "keeps mise hidden from every other workspace call" do
          plain = profiles.for(request(ruling("auto")))

          expect([plain.runs?(binary), plain.env]).to eq([false, {}])
        end

        it "reads the granted mise as runnable where the planner asks, and the unpinned one as not" do
          expect(profiles.unrunnable(install("jq@1.8.1"))).to eq([])
          expect(profiles.unrunnable(install("jq@1.7.1"))).to eq([binary])
        end

        it "runs none of a trusted project config's hooks under the grant, which run without it" do
          real = "/usr/bin/mise"
          skip "no mise at #{real}" unless File.executable?(real)
          fence = Lain::Confine::Bwrap.fence_binary
          skip "lain-fence is not built at #{fence}" unless File.executable?(fence)

          marks = File.join(root, "marks").tap { FileUtils.mkdir_p(_1) }
          state = File.join(root, ".mise-state")
          # Landlock refuses the proxy's port, so the fetch fails at loopback and no name is resolved.
          call_env = { "MISE_DATA_DIR" => data, "MISE_STATE_DIR" => state, "HTTPS_PROXY" => "http://127.0.0.1:9",
                       "HOME" => home }
          pin("env.sh", "touch #{marks}/env-source\n")
          pin("mise.toml", <<~TOML)
            [hooks]
            preinstall = "touch #{marks}/preinstall"
            postinstall = "touch #{marks}/postinstall"

            [env]
            _.source = "#{root}/env.sh"
            PROBE = "{{ exec(command='touch #{marks}/env-exec') }}"

            [tools]
            jq = "1.8.1"
          TOML
          ran = lambda do
            system(call_env, real, "trust", File.join(root, "mise.toml"), chdir: root, out: File::NULL, err: File::NULL)
            offline = call_env.merge("MISE_OFFLINE" => "1")
            system(offline, real, "install", "jq@1.8.1", chdir: root, out: File::NULL, err: File::NULL)
            Dir.children(marks).sort.tap { FileUtils.rm_f(Dir.glob(File.join(marks, "*"))) }
          end
          real_probe = Lain::Confine::Probe.new(fence:, journal:)
          granting = described_class.new(masks:, probe: real_probe, home:, root:, workspace: true, tmpdir: scratch,
                                         fresh:, env: call_env)
          exec = Lain::Exec::Sandboxed.new(
            inner: Lain::Exec::Local.new(child_env: Lain::Exec::ChildEnv.new(env: ENV.to_h)), journal:,
            profiles: granting, launcher: Lain::Confine::Bwrap.new(fence:)
          )

          expect(ran.call).to eq(%w[env-exec env-source postinstall preinstall])
          result = exec.call(command: "#{real} install jq@1.8.1", cwd: root, env: call_env, timeout: 60,
                             confinement: install("jq@1.8.1", executable: executable("mise", real, :system)))

          expect(result.stderr).to include("Failed to install aqua:jqlang/jq@1.8.1")
            .and(satisfy { !_1.include?("trusted") }), result.stderr

          expect(journal.grep(Lain::Telemetry::Sandbox).map { [_1.profile, _1.network] }).to eq([[:grant, ["443"]]])
          expect(Dir.children(marks)).to eq([])
        end
      end

      describe "the seal set", :seam do
        before { git_init(root) }

        def sealed_paths(ruled_root = root) = profiles.for(request(ruling("auto"), root: ruled_root)).sealed

        it "asks git once for calls in the same root" do
          asks = git_asks
          2.times { sealed_paths }

          expect(asks.count { _1.include?("rev-parse") }).to eq(1)
        end

        it "seals each root's own git dir, never another root's" do
          other = File.join(@base, "other").tap { git_init(_1) }

          expect([sealed_paths, sealed_paths(other)].map { |seals| seals.map(&:path).grep(%r{/\.git/config\z}) })
            .to eq([[File.join(root, ".git/config")], [File.join(other, ".git/config")]])
        end

        it "seals a persistence path that appeared since the last call, rather than listing it absent" do
          envrc = File.join(root, ".envrc")
          before = sealed_paths.find { _1.path == envrc }
          File.write(envrc, "")

          expect([before.absent, sealed_paths.find { _1.path == envrc }.absent]).to eq([true, false])
        end

        def hooks_seals(ruled_root = root) = sealed_paths(ruled_root).map(&:path).grep(/hooks/)

        def git_asks
          asks = []
          allow(Open3).to receive(:capture2).and_wrap_original do |original, *args, **opts|
            asks << args
            original.call(*args, **opts)
          end
          asks
        end

        def config = File.join(root, ".git/config")

        def hooks_path(dir) = "[core]\n\thooksPath = #{dir}\n"

        it "seals the hooks dir an included config file names once the include changes" do
          included = File.join(@base, "inc.cfg").tap { File.write(_1, "") }
          system(SeedRepo::SCRUB, "git", "-C", root, "config", "include.path", included, exception: true)
          sealed_paths
          FileUtils.mkdir_p(hooks = File.join(root, ".githooks"))
          File.write(included, hooks_path(hooks))

          expect(hooks_seals).to include(hooks)
        end

        it "seals the hooks dir an included config file names once the missing include appears" do
          included = File.join(@base, "later.cfg")
          system(SeedRepo::SCRUB, "git", "-C", root, "config", "include.path", included, exception: true)
          sealed_paths
          FileUtils.mkdir_p(hooks = File.join(root, ".githooks"))
          File.write(included, hooks_path(hooks))

          expect(hooks_seals).to include(hooks)
        end

        it "rebuilds after the config is edited in place" do
          sealed_paths
          FileUtils.mkdir_p(hooks = File.join(root, ".githooks"))
          File.open(config, "a") { _1.write(hooks_path(hooks)) }
          File.utime(Time.now + 5, Time.now + 5, config)

          expect(hooks_seals).to include(hooks)
        end

        it "rebuilds after the config is replaced by a rename that keeps its mtime" do
          sealed_paths
          FileUtils.mkdir_p(hooks = File.join(root, ".githooks"))
          replacement = File.join(@base, "config.new")
          File.write(replacement, File.read(config) + hooks_path(hooks))
          File.utime(File.atime(config), File.mtime(config), replacement)
          File.rename(replacement, config)

          expect(hooks_seals).to include(hooks)
        end

        it "rebuilds, and refuses, once a seal is swapped for a link to where it was" do
          envrc = File.join(root, ".envrc").tap { File.write(_1, "") }
          sealed_paths
          File.rename(envrc, moved = File.join(@base, "envrc"))
          File.symlink(moved, envrc)

          expect { sealed_paths }.to raise_error(Lain::Confine::Profile::Unsealable, /\.envrc/)
        end

        it "seals a root by where it lands, so a repointed link never serves the old root's set" do
          other = File.join(@base, "other").tap { git_init(_1) }
          File.symlink(root, link = File.join(@base, "current"))
          sealed_paths(link)
          File.unlink(link)
          File.symlink(other, link)

          expect(sealed_paths(link).map(&:path)).to include(File.join(other, ".git/config"))
            .and(satisfy { |paths| paths.none? { _1.start_with?("#{root}/") } })
        end

        it "seals a root by where it lands outside a git checkout too, where no config file shows the repoint" do
          plain, other = %w[plain other-plain].map { File.join(@base, _1).tap { |dir| FileUtils.mkdir_p(dir) } }
          File.symlink(plain, link = File.join(@base, "current-plain"))
          sealed_paths(link)
          File.unlink(link)
          File.symlink(other, link)

          expect(profiles.for(request(ruling("auto"), root: link)).write_dirs.first).to eq(other)
        end

        it "watches a dangling seal's new landing once the link is repointed" do
          SeedRepo.git(root, "-c", "user.name=a", "-c", "user.email=a@b", "commit", "-q", "--allow-empty", "-m", "i")
          SeedRepo.git(root, "worktree", "add", "-q", worktree = File.join(@base, "wt"))
          hooks = File.join(root, ".git/hooks").tap { FileUtils.rm_rf(_1) }
          File.symlink(File.join(worktree, "landing-a"), hooks)
          sealed_paths(worktree)
          File.unlink(hooks)
          File.symlink(File.join(worktree, "landing-b"), hooks)

          expect(sealed_paths(worktree).find { _1.path == File.join(worktree, "landing-b") }&.absent).to be(true)
        end

        # git's own config files may be absent when the set is built; HOME and XDG point at fixtures.
        def with_fixture_home(global: nil)
          saved = ENV.to_h.slice("HOME", "XDG_CONFIG_HOME", "GIT_CONFIG_GLOBAL")
          ENV["HOME"] = File.join(@base, "fixture-home").tap { FileUtils.mkdir_p(_1) }
          ENV["XDG_CONFIG_HOME"] = File.join(@base, "fixture-xdg")
          ENV["GIT_CONFIG_GLOBAL"] = global
          yield
        ensure
          saved.each_key { ENV[_1] = saved[_1] }
        end

        def appearing(path)
          sealed_paths
          FileUtils.mkdir_p([File.dirname(path), hooks = File.join(root, ".githooks")])
          File.write(path, hooks_path(hooks))
          [hooks_seals, hooks]
        end

        { "~/.gitconfig" => %w[fixture-home .gitconfig], "the XDG config" => %w[fixture-xdg git config],
          "the file GIT_CONFIG_GLOBAL names" => %w[global.cfg] }.each do |name, parts|
          it "rebuilds once #{name} appears naming a hooks dir, though it was absent when the set was built" do
            path = File.join(@base, *parts)
            seals, hooks = with_fixture_home(global: (path if parts == %w[global.cfg])) { appearing(path) }

            expect(seals).to include(hooks)
          end
        end

        it "keeps no set that changed while it was being built" do
          envrc = File.join(root, ".envrc")
          allow(Lain::Confine::Profile).to receive(:workspace).and_wrap_original do |original, **options|
            original.call(**options).tap { File.write(envrc, "") unless File.exist?(envrc) }
          end
          sealed_paths

          expect(sealed_paths.find { _1.path == envrc }.absent).to be(false)
        end

        it "keeps the sets of at most 64 roots, so the first of 65 is built again" do
          roots = Array.new(65) { |index| File.join(@base, "many", index.to_s).tap { git_init(_1) } }
          roots.each { sealed_paths(_1) }
          asks = git_asks
          sealed_paths(roots.first)

          expect(asks.count { _1.include?("rev-parse") }).to eq(1)
        end

        it "lists a sealed path that went away as absent, rather than binding a missing one" do
          hooks = File.join(root, ".git/hooks")
          FileUtils.mkdir_p(hooks)
          sealed_paths
          FileUtils.rm_rf(hooks)

          expect(sealed_paths.find { _1.path == hooks }.absent).to be(true)
        end
      end
    end

    # git exits 128 when it cannot read a config file it was told of, so each file git reads config from is
    # granted to both confined profiles, wherever it lives: the standard globals and every file git reports
    # as an origin. What the session's policy denies is never granted, nor a credential-shaped file an
    # include names; inside the project nothing needs a grant.
    describe "git's config files" do
      let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }
      let(:elsewhere) { File.join(@base, "elsewhere").tap { FileUtils.mkdir_p(_1) } }
      let(:classifier) do
        policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root))
        Lain::Confine::MaskList.new(root:, policy: -> { policy })
      end
      let(:profiles) { described_class.new(masks:, probe:, home:, root:, classifier:) }
      let(:workspace) do
        described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, classifier:)
      end

      around do |example|
        FileUtils.mkdir_p(home)
        system(SeedRepo::SCRUB, "git", "init", "-q", root, exception: true)
        with_env("HOME" => home, "GIT_CONFIG_GLOBAL" => nil, "XDG_CONFIG_HOME" => nil) { example.run }
      end

      def named(user = "P") = "[user]\n\tname = #{user}\n"

      def granted = [profiles.for(composed), workspace.for(request(ruling("auto")))].map(&:read_dirs)

      def write(path, text) = path.tap { FileUtils.mkdir_p(File.dirname(_1)) && File.write(_1, text) }
      public :write, :named

      layouts = {
        "an [include] of ~/.gitconfig.local" => lambda { |spec|
          File.write(File.join(spec.home, ".gitconfig"), "[include]\n\tpath = ~/.gitconfig.local\n")
          File.join(spec.home, ".gitconfig.local").tap { File.write(_1, spec.named) }
        },
        "an includeIf gitdir: naming the project" => lambda { |spec|
          target = File.join(spec.elsewhere, "work.gitconfig").tap { File.write(_1, spec.named) }
          File.write(File.join(spec.home, ".gitconfig"), "[includeIf \"gitdir:#{spec.root}/\"]\n\tpath = #{target}\n")
          target
        },
        "GIT_CONFIG_GLOBAL outside home" => lambda { |spec|
          File.join(spec.elsewhere, "gc").tap { File.write(_1, spec.named) && (ENV["GIT_CONFIG_GLOBAL"] = _1) }
        },
        "XDG_CONFIG_HOME outside home" => lambda { |spec|
          FileUtils.mkdir_p(File.join(spec.elsewhere, "git"))
          ENV["XDG_CONFIG_HOME"] = spec.elsewhere
          File.join(spec.elsewhere, "git", "config").tap { File.write(_1, spec.named) }
        },
        # Gated by its name, and reached only from the user's own config, so it is the user's to read.
        "an [include] of ~/dotfiles/.gitconfig" => lambda { |spec|
          File.write(File.join(spec.home, ".gitconfig"), "[include]\n\tpath = ~/dotfiles/.gitconfig\n")
          spec.write(File.join(spec.home, "dotfiles", ".gitconfig"), spec.named)
        }
      }

      layouts.each do |layout, write|
        it "grants the reader and workspace profiles read on the file #{layout} names", :seam do
          file = write.call(self)

          expect(granted).to all(include(file))
        end
      end

      # The user's ruling: a project config git itself reads is shown to the call, sealed rather than masked,
      # so git works; every other masked file stays masked.
      describe "a tracked project config git includes from .git/config" do
        let(:shared) { File.join(root, ".gitconfig") }
        let(:env_file) { write(File.join(root, ".env"), "TOKEN=x\n") }

        before do
          File.write(File.join(home, ".gitconfig"), named)
          SeedRepo.git(root, "config", "include.path", "../.gitconfig")
          write(shared, "[alias]\n\tst = status\n")
          masked << mask(shared) << mask(env_file)
        end

        def both = [profiles.for(composed), workspace.for(request(ruling("auto")))]

        it "masks it in neither profile, while the other masked file stays masked", :seam do
          expect(both.map(&:masks)).to all(eq([env_file]))
        end

        it "grants it no read of its own, since the project is read whole", :seam do
          expect(both.map(&:read_dirs)).to all(satisfy { !_1.include?(shared) })
        end

        it "seals it in the workspace profile", :seam do
          expect(workspace.for(request(ruling("auto"))).sealed.map(&:path)).to include(shared)
        end

        it "grants no read of its own to an ordinary-named project config either, and does not mask it", :seam do
          plain = write(File.join(root, "tools", "git.inc"), "[alias]\n\tco = checkout\n")
          SeedRepo.git(root, "config", "--add", "include.path", "../tools/git.inc")
          masked << mask(plain)

          expect(both.map { [_1.read_dirs.include?(plain), _1.masks.include?(plain)] }).to all(eq([false, false]))
        end

        it "lets a workspace call on this box read the config with git, and refuses it a write", :seam do
          real = Lain::Confine::Probe.new(fence: Lain::Confine::Bwrap.fence_binary, journal:)
          confined = described_class.new(masks:, probe: real, home:, root:, workspace: true, tmpdir: scratch,
                                         classifier:)
          local = Lain::Exec::Local.new(child_env: Lain::Exec::ChildEnv.new(env: ENV.to_h))
          exec = Lain::Exec::Sandboxed.new(inner: local, journal:, profiles: confined,
                                           launcher: Lain::Confine::Bwrap.new(fence: Lain::Confine::Bwrap.fence_binary))
          run = lambda { |command|
            exec.call(command:, cwd: root, env: {}, timeout: 20, confinement: request(ruling("auto")))
          }

          expect(run.call("git config alias.st")).to have_attributes(exit_status: 0, stdout: "status\n")
          expect(run.call("echo planted >> .gitconfig").exit_status).not_to eq(0)
          expect(File.read(shared)).to eq("[alias]\n\tst = status\n")
        end
      end

      describe "a project config that includes home's secrets", :seam do
        let(:key) { write(File.join(home, ".ssh", "id_ed25519"), "FAKE KEY\n") }
        let(:pypirc) { write(File.join(home, ".pypirc"), "[pypi]\n\tusername = __token__\n\tpassword = pypi-FAKE\n") }
        let(:shared) { File.join(root, ".gitconfig") }

        before do
          File.write(File.join(home, ".gitconfig"), named)
          SeedRepo.git(root, "config", "include.path", "../.gitconfig")
          write(shared, "[includeIf \"gitdir:/nowhere/\"]\n\tpath = #{key}\n[include]\n\tpath = #{pypirc}\n")
        end

        it "grants neither the key an inactive includeIf names nor the credential an active include names" do
          expect(granted.flatten).not_to include(key, pypirc)
        end

        it "seals the included project file, so a call cannot plant an include there" do
          expect(workspace.for(request(ruling("auto"))).sealed.map(&:path)).to include(shared)
        end
      end

      it "grants nothing an inactive includeIf names, though the file is ordinary", :seam do
        target = write(File.join(elsewhere, "other.gitconfig"), named)
        File.write(File.join(home, ".gitconfig"), "[includeIf \"gitdir:/nowhere/\"]\n\tpath = #{target}\n")

        expect(granted.flatten).not_to include(target)
      end

      it "grants no global the policy denies", :seam do
        ENV["GIT_CONFIG_GLOBAL"] = write(File.join(elsewhere, ".netrc"), named)

        expect(granted.flatten).not_to include(ENV.fetch("GIT_CONFIG_GLOBAL"))
      end

      it "grants nothing for a config file that is not there, nor for a directory", :seam do
        ENV["GIT_CONFIG_GLOBAL"] = File.join(elsewhere, "absent")
        absent = granted.flatten
        ENV["GIT_CONFIG_GLOBAL"] = elsewhere

        expect(absent).not_to include(File.join(elsewhere, "absent"))
        expect(granted.flatten).not_to include(elsewhere)
      end

      it "grants a file an include gains between calls", :seam do
        File.write(File.join(home, ".gitconfig"), named)
        granted
        added = write(File.join(elsewhere, "late.gitconfig"), named("Q"))
        File.write(File.join(home, ".gitconfig"), "#{named}[include]\n\tpath = #{added}\n")

        expect(granted).to all(include(added))
      end

      it "follows GIT_CONFIG_GLOBAL when it changes between calls in one root", :seam do
        ENV["GIT_CONFIG_GLOBAL"] = first = write(File.join(elsewhere, "first"), named)
        granted
        ENV["GIT_CONFIG_GLOBAL"] = second = write(File.join(elsewhere, "second"), named)

        expect(granted).to all(include(second).and(satisfy { !_1.include?(first) }))
      end

      context "when git runs under each profile on this box", :seam do
        let(:probe) { Lain::Confine::Probe.new(fence: Lain::Confine::Bwrap.fence_binary, journal:) }

        let(:launcher) { Lain::Confine::Bwrap.new(fence: Lain::Confine::Bwrap.fence_binary) }

        def user_name(arm)
          local = Lain::Exec::Local.new(child_env: Lain::Exec::ChildEnv.new(env: ENV.to_h))
          chosen, approval = arm == :reader ? [profiles, composed] : [workspace, request(ruling("auto"))]
          Lain::Exec::Sandboxed.new(inner: local, journal:, profiles: chosen, launcher:)
                               .call(command: "git config user.name", cwd: root, env: {}, timeout: 20,
                                     confinement: approval)
        end

        layouts.each do |layout, write|
          it "reads the user name from #{layout}" do
            write.call(self)

            expect([user_name(:reader), user_name(:workspace)])
              .to all(have_attributes(exit_status: 0, stdout: "P\n",
                                      stderr: a_string_matching(/\A\[ran: [^\n]+\]\n\z/)))
          end
        end
      end
    end

    context "when this kernel cannot trace" do
      before { answers["strace"] = ["", false] }

      it "still confines a reader call, with no trace", :seam do
        expect(profiles.for(composed)).to have_attributes(name: :reader, trace: false, confined?: true)
      end

      it "neither traces nor confines any other call" do
        expect(profiles.for(request(ruling("judge")))).to eq(Lain::Confine::Profile::NONE)
      end

      it "still confines a workspace call, with no trace", :seam do
        workspace = described_class.new(masks:, probe:, home:, root:, workspace: true,
                                        tmpdir: File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) })
        expect(workspace.for(request(ruling("auto")))).to have_attributes(name: :workspace, trace: false)
      end
    end

    describe "a human's approval of a secret-bearing call without network", :seam do
      let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }
      let(:netted) { ["#{JSON.generate({ abi: 6, rights: {}, skipped: [], private_net: false })}\n", true] }

      def human(contained: false, network: false)
        Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "approved", authority: :human,
                                                 contained:, network:)
      end

      it "runs under the reader profile with a private network when the workspace switch is off" do
        answers["lain-fence"] = netted

        expect(profiles.for(request(human(contained: true))))
          .to have_attributes(name: :reader, private_net: true, connect_ports: [], confined?: true)
      end

      it "runs under the workspace profile with a private network when the workspace switch is on" do
        answers["lain-fence"] = netted
        workspace = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch)

        expect(workspace.for(request(human(contained: true)))).to have_attributes(name: :workspace, private_net: true)
      end

      it "is refused where the box cannot give the call a private network" do
        expect { profiles.for(request(human(contained: true))) }
          .to raise_error(described_class::Uncontainable) { expect(_1.profile).to eq(:reader) }
      end

      it "contains an automatic allow the same way, under either switch" do
        answers["lain-fence"] = netted
        judged = Lain::Approval::Escalation::Ruling.allow(rung: Lain::Approval::Judged::NAME, because: "judged",
                                                          contained: true)
        workspace = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch)

        expect([profiles.for(request(judged)), workspace.for(request(judged))].map { [_1.name, _1.private_net] })
          .to eq([[:reader, true], [:workspace, true]])
      end

      it "refuses an automatic contained allow where the box cannot give a private network, under either switch" do
        judged = Lain::Approval::Escalation::Ruling.allow(rung: Lain::Approval::Judged::NAME, because: "judged",
                                                          contained: true)
        workspace = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch)

        expect { profiles.for(request(judged)) }.to raise_error(described_class::Uncontainable)
        expect { workspace.for(request(judged)) }.to raise_error(described_class::Uncontainable)
      end

      it "stays traced and unconfined when the human chose network" do
        answers["lain-fence"] = netted

        expect(profiles.for(request(human(network: true)))).to eq(Lain::Confine::Profile::TRACED)
      end

      describe "the call's own project scripts" do
        let(:workspace) { described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch) }
        let(:key) { File.join(root, "config/master.key") }
        let(:masked) { [mask(key)] }

        def script(relative)
          File.join(root, relative).tap do |path|
            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, "#!/bin/sh\n")
          end
        end

        before do
          answers["lain-fence"] = netted
          script("config/master.key")
        end

        it "exec-grants bin/rails under the workspace profile, with no network and the key still masked" do
          rails = script("bin/rails")

          profile = workspace.for(request(human(contained: true), grants: [executable("bin/rails", rails, :project)]))

          expect(profile).to have_attributes(name: :workspace, private_net: true, connect_ports: [])
          expect(profile.exec_files).to include(rails)
          expect(profile.masks).to include(key)
        end

        it "exec-grants a script this lineage wrote, since the call has no network" do
          rails = script("bin/rails")
          written = executable("bin/rails", rails, :project).with(fresh: true)

          profile = workspace.for(request(human(contained: true), grants: [written]))

          expect(profile).to have_attributes(name: :workspace, private_net: true)
          expect(profile.exec_files).to include(rails)
        end

        it "grants no project script on an automatic contained allow" do
          rails = script("bin/rails")
          judged = Lain::Approval::Escalation::Ruling.allow(rung: Lain::Approval::Judged::NAME, because: "judged",
                                                            contained: true)

          profile = workspace.for(request(judged, grants: [executable("bin/rails", rails, :project)]))

          expect(profile.exec_files).not_to include(rails)
        end

        it "grants the call's own programs for that call only, and nothing else under the project" do
          rails, other, bystander = %w[bin/rails bin/other bin/bystander].map { script(_1) }
          own = [executable("bin/rails", rails, :project), executable("bin/other", other, :project)]

          granted = workspace.for(request(human(contained: true), executables: own))
          later = workspace.for(request(human(contained: true)))

          expect(granted.exec_files).to include(rails, other)
          expect(granted.exec_files).not_to include(bystander)
          expect(later.exec_files).not_to include(rails, other)
        end

        it "grants no project script a mask lands on" do
          profile = workspace.for(request(human(contained: true), grants: [executable("key", key, :project)]))

          expect(profile.exec_files).not_to include(key)
        end

        it "grants no program of another class that the reader's own test refuses" do
          rg = File.join(home, ".local/bin/rg")
          shadowing = executable("rg", rg, :user).with(shadowed: ["/usr/bin/rg"])

          profile = workspace.for(request(human(contained: true), grants: [shadowing]))

          expect(profile.exec_files).not_to include(rg)
        end

        it "exec-grants the script, fresh or not, under the reader profile with no network when the switch is off" do
          rails, other = %w[bin/rails bin/other].map { script(_1) }
          own = [executable("bin/rails", rails, :project), executable("bin/other", other, :project).with(fresh: true)]

          profile = profiles.for(request(human(contained: true), grants: own))

          expect(profile).to have_attributes(name: :reader, private_net: true, connect_ports: [])
          expect(profile.exec_files).to include(rails, other)
        end
      end

      describe "a human's secrets answer" do
        let(:workspace) { described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch) }
        let(:key) { File.join(root, "config/master.key") }
        let(:outside) { File.join(@base, "elsewhere/id_ed25519") }
        let(:held) { Lain::Sensitivity::Policy::Mask.new(path: File.join(root, "leaked.txt"), reason: :tainted) }
        let(:masked) { [mask(key), mask(File.join(root, ".env")), mask(outside), held] }

        def secrets(contained: true)
          Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "approved", authority: :human,
                                                   contained:, unmasked: true)
        end

        before do
          answers["lain-fence"] = netted
          FileUtils.mkdir_p(File.join(@base, "home/.bundle"))
          File.write(File.join(@base, "home/.bundle/config"), "BUNDLE_X: y\n")
        end

        it "runs under the workspace profile with a private network and none of the project's masks" do
          profile = workspace.for(request(secrets))

          expect(profile).to have_attributes(name: :workspace, private_net: true, unmasked?: true, connect_ports: [])
          expect(profile.masks).not_to include(key, File.join(root, ".env"))
        end

        it "lifts them under the reader profile too, when the workspace switch is off" do
          expect(profiles.for(request(secrets))).to have_attributes(name: :reader, private_net: true, unmasked?: true)
          expect(profiles.for(request(secrets)).masks).not_to include(key)
        end

        it "keeps a mask that lands outside the project, a file a scan held, and the hidden toolchain files" do
          profile = workspace.for(request(secrets))

          expect(profile.masks).to include(outside, held.path)
          expect(profile.hidden).to include(File.join(@base, "home/.bundle/config"))
        end

        it "keeps a related directory's masks" do
          related_env = File.join(@base, "related/.env")
          classifier = Struct.new(:related) { def classify(_path) = Lain::Sensitivity::ORDINARY.verdict }
                             .new(Lain::Confine::MaskList::Related.new(roots: [File.dirname(related_env)],
                                                                       masks: [mask(related_env)]))
          related = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch, classifier:)

          expect(related.for(request(secrets)).masks).to include(related_env)
        end

        it "masks the project again on the next plain approval" do
          workspace.for(request(secrets))

          expect(workspace.for(request(human(contained: true)))).to have_attributes(unmasked?: false)
          expect(workspace.for(request(human(contained: true))).masks).to include(key, File.join(root, ".env"))
        end

        it "lifts only the masks under the call's own root when it has one" do
          child = File.join(root, "child").tap { FileUtils.mkdir_p(_1) }
          child_key = File.join(child, ".env")
          masked << mask(child_key)

          profile = workspace.for(request(secrets, root: child))

          expect(profile.masks).not_to include(child_key)
          expect(profile.masks).to include(key)
        end

        it "keeps a listed link's mask on the project itself, which still refuses the call as any overmask does" do
          linked = Struct.new(:masks) { def landed_on(_path) = ["here"] }.new([*masked, mask(root)])
          listing = described_class.new(masks: linked, probe:, home:, root:, workspace: true, tmpdir: scratch)

          expect { listing.for(request(secrets)) }.to raise_error(described_class::Overmasked, /here/)
        end

        it "names the masks it would lift, the project's own and no other" do
          expect(described_class.lifted(masked, root)).to eq([key, File.join(root, ".env")])
        end
      end
    end
  end

  describe "a linter, granted by its file rather than by a stage the call names", :seam do
    let(:bin) { File.join(home, ".local/bin").tap { FileUtils.mkdir_p(_1) } }
    let(:shellcheck) { File.join(bin, "shellcheck") }
    let(:fresh_paths) { [] }
    let(:fresh) do
      Struct.new(:paths) do
        def any_under?(_root) = false
        def fresh?(path) = paths.include?(path)
      end.new(fresh_paths)
    end
    let(:path) { bin }
    let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }
    let(:linting) { described_class.new(masks:, probe:, home:, root:, fresh:, env: { "PATH" => path }) }
    let(:workspace) do
      described_class.new(masks:, probe:, home:, root:, fresh:, env: { "PATH" => path }, workspace: true,
                          tmpdir: scratch)
    end

    def contained
      Lain::Approval::Escalation::Ruling.allow(rung: Lain::Approval::Judged::NAME, because: "judged", contained: true)
    end

    def elf(file, segment: 1)
      FileUtils.mkdir_p(File.dirname(file))
      fields = [2, 62, 1, 0, 64, 0, 0, 64, 56, 1, 0, 0, 0].pack("S<S<L<Q<Q<Q<L<S<S<S<S<S<S<")
      header = ["\x7FELF".b, [2, 1, 1].pack("C3"), "\0" * 9, fields, [segment].pack("L<"), "\0" * 52].join
      File.binwrite(file, header)
      File.chmod(0o755, file)
      file
    end

    before do
      answers["lain-fence"] = ["#{JSON.generate({ abi: 6, rights: {}, skipped: [], private_net: false })}\n", true]
    end

    it "runs a static user binary that shadows nothing, under the contained reader and workspace profiles alike" do
      elf(shellcheck)

      expect([linting, workspace].map { _1.for(request(contained)).runs?(shellcheck) }).to eq([true, true])
      expect(linting.for(composed).runs?(shellcheck)).to be(true)
    end

    it "reads it as runnable where the planner asks, so a call naming it parks for nothing" do
      elf(shellcheck)
      named = executable("shellcheck", shellcheck, :user)

      expect(linting.unrunnable(request(contained), [named])).to eq([])
    end

    it "grants nothing, and still builds the profile, for a linter whose headers claim an unreachable offset" do
      elf(shellcheck)
      File.binwrite(shellcheck, [2**63].pack("Q<"), 32)

      expect(linting.for(request(contained)).runs?(shellcheck)).to be(false)
    end

    it "grants no binary that names a loader, whose libraries the sandbox would not show" do
      elf(shellcheck, segment: 3)

      expect(linting.for(request(contained)).runs?(shellcheck)).to be(false)
    end

    it "grants no linter the project holds, on PATH ahead of the user's through direnv" do
      planted = elf(File.join(root, "bin/shellcheck"))
      elf(shellcheck)
      direnv = described_class.new(masks:, probe:, home:, root:, fresh:,
                                   env: { "PATH" => "#{File.dirname(planted)}:#{path}" })

      profile = direnv.for(request(contained))

      expect([profile.runs?(planted), profile.exec_files]).to eq([false, []])
    end

    it "grants no link whose target was written this session" do
      target = elf(File.join(@base, "downloads/shellcheck"))
      File.symlink(target, shellcheck)
      fresh_paths << target

      expect(linting.for(request(contained)).runs?(target)).to be(false)
    end

    it "grants no user binary that shadows another of its name on PATH" do
      elf(shellcheck)
      other = elf(File.join(@base, "elsewhere/shellcheck"))
      shadowing = described_class.new(masks:, probe:, home:, root:, fresh:,
                                      env: { "PATH" => "#{path}:#{File.dirname(other)}" })

      expect(shadowing.for(request(contained)).exec_files).to eq([])
    end

    it "grants no other program that rides in under a linter's name, as a link to it does" do
      mise = elf(File.join(@base, "elsewhere/mise"))
      File.symlink(mise, shellcheck)

      expect(linting.for(request(contained)).exec_files).to eq([])
    end

    it "drops a linter a mask lands on, rather than refusing the call" do
      elf(shellcheck)
      masked << mask(bin)

      expect(linting.for(request(contained)).exec_files).to eq([])
    end

    it "drops a linter a related directory's mask lands on, under either profile, rather than refusing the call" do
      elf(shellcheck)
      related = Lain::Confine::MaskList::Related.new(roots: [], masks: [mask(bin)])
      classifier = Struct.new(:related) { def classify(_) = Lain::Sensitivity::ORDINARY.verdict }.new(related)
      both = [false, true].map do |switch|
        described_class.new(masks:, probe:, home:, root:, fresh:, env: { "PATH" => path }, classifier:,
                            workspace: switch, tmpdir: scratch)
      end

      expect(both.map { _1.for(request(contained)).exec_files }).to eq([[], []])
    end

    it "runs a linter in a mise install's bin dir without granting the dir, so no neighbour there runs" do
      install = File.join(home, ".local/share/mise/installs/shellcheck/0.10.0/bin")
      linter = elf(File.join(install, "shellcheck"))
      neighbour = elf(File.join(install, "neighbour"))
      installed = described_class.new(masks:, probe:, home:, root:, fresh:, env: { "PATH" => install },
                                      workspace: true, tmpdir: scratch)

      profile = installed.for(request(contained))

      expect([profile.runs?(linter), profile.runs?(neighbour), profile.exec_dirs.include?(install)])
        .to eq([true, false, false])
    end

    it "grants nothing by name to a session that read no lineage, which counts every file as fresh" do
      elf(shellcheck)
      unread = described_class.new(masks:, probe:, home:, root:, env: { "PATH" => path })

      expect(unread.for(request(contained)).runs?(shellcheck)).to be(false)
    end

    it "runs the box's own static shellcheck inside a compound command, offline and refusing no exec" do
      host = ENV.fetch("PATH", "").split(":").map { File.join(_1, "shellcheck") }.find { File.executable?(_1) }
      static = host && !host.start_with?("/usr/") && Lain::Confine::Elf.static?(host)
      skip "no static shellcheck outside /usr on this box's PATH" unless static

      FileUtils.cp(host, shellcheck)
      File.write(File.join(root, "s.sh"), "#!/bin/sh\necho $1\n")
      real = Lain::Confine::Probe.new(fence: Lain::Confine::Bwrap.fence_binary, journal:)
      confined = described_class.new(masks:, probe: real, home:, root:, fresh:, env: { "PATH" => path })
      exec = Lain::Exec::Sandboxed.new(inner: Lain::Exec::Local.new(child_env: Lain::Exec::ChildEnv.new(env: ENV.to_h)),
                                       journal:, profiles: confined,
                                       launcher: Lain::Confine::Bwrap.new(fence: Lain::Confine::Bwrap.fence_binary))

      linted = exec.call(command: "bash -n s.sh && shellcheck s.sh", cwd: root, env: { "PATH" => "#{bin}:/usr/bin" },
                         timeout: 30, confinement: request(contained))
      record = journal.find { _1.is_a?(Lain::Telemetry::Sandbox) }

      expect(linted).to have_attributes(exit_status: 1, stdout: a_string_including("SC2086"))
      expect(record).to have_attributes(network: false)
    end
  end

  describe "a directory the request's bounds lend", :seam do
    let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }
    let(:refs) { File.join(@base, "data", "refs").tap { FileUtils.mkdir_p(_1) } }
    let(:listing) do
      Class.new do
        attr_reader :asked

        def initialize = @asked = []

        def related = Lain::Confine::MaskList::Related::NONE

        def lending = @lending ||= Lain::Sensitivity::Bounds::Lending.new

        def classify(path)
          Data.define(:level) { def ordinary? = level == :ordinary }
              .new(File.basename(path) == "secrets" ? :gated : :ordinary)
        end

        def lent(dirs)
          @asked << dirs
          masks = dirs.map { Lain::Sensitivity::Policy::Mask.new(path: File.join(_1, ".env"), reason: "secret") }
          Lain::Confine::MaskList::Related.new(roots: dirs, masks:)
        end
      end.new
    end
    let(:lending) { described_class.new(masks:, probe:, home:, root:, classifier: listing) }

    def lent(dir) = Lain::Sensitivity::Bounds.of(reads: [root, dir])

    def bounded(bounds, ruling: ruling("rules", rule: "composed_term"))
      Lain::Confine::Request.new(ruling:, executables: [], cwd: root, root:, tool_use_id: "toolu_1", bounds:)
    end

    it "reads it with the masks its own listing names, writing nothing there" do
      profile = lending.for(bounded(lent(refs)))

      expect([profile.read_dirs, profile.masks]).to match([include(refs), include(File.join(refs, ".env"))])
      expect(profile.write_dirs).not_to include(refs)
      expect(listing.asked).to eq([[refs]])
    end

    it "reads nothing beyond the project for a request whose bounds lend nothing, and lists nothing" do
      profile = lending.for(bounded(Lain::Sensitivity::Bounds.of(reads: [root])))

      expect([profile.read_dirs, listing.asked]).to match([not_include(refs), []])
    end

    it "lists nothing for a read inside the project, which is read already" do
      lending.for(bounded(lent(File.join(root, "docs").tap { FileUtils.mkdir_p(_1) })))

      expect(listing.asked).to eq([])
    end

    it "names nothing for a lent directory that does not exist, which holds nothing to bind" do
      profile = lending.for(bounded(lent(File.join(@base, "gone"))))

      expect([profile.unread, listing.asked]).to eq([{}, []])
    end

    it "carries the lend to a workspace call too" do
      workspace = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch,
                                      classifier: listing)

      profile = workspace.for(bounded(lent(refs), ruling: ruling("auto")))

      expect([profile.read_dirs, profile.masks]).to match([include(refs), include(File.join(refs, ".env"))])
      expect(profile.write_dirs).not_to include(refs)
    end

    it "refuses home, an ancestor of the project and a gated directory, naming why, and lists none of them" do
      FileUtils.mkdir_p(home)
      gated = File.join(@base, "secrets").tap { FileUtils.mkdir_p(_1) }

      unread = ["/", home, @base, gated].map { lending.for(bounded(lent(_1))) }.map { [_1.unread, _1.read_dirs] }

      expect(unread).to match([[{ "/" => "it is the filesystem root" }, not_include("/")],
                               [{ home => "it is the home directory or holds it" }, not_include(home)],
                               [{ @base => "it holds the project root" }, not_include(@base)],
                               [{ gated => "its path is classified gated" }, not_include(gated)]])
      expect(listing.asked).to eq([])
    end
  end

  describe "#unrunnable" do
    let(:uv) { executable("uv", File.join(home, ".local/bin/uv"), :user) }
    let(:judge) { Lain::Approval::Judged::NAME }

    before do
      answers["lain-fence"] = ["#{JSON.generate({ abi: 6, rights: {}, skipped: [], private_net: false })}\n", true]
    end

    def contained = Lain::Approval::Escalation::Ruling.allow(rung: judge, because: "approved", contained: true)

    it "names a program the call runs that its request earns no grant for", :seam do
      expect(profiles.unrunnable(request(contained), [uv])).to eq([uv.realpath])
    end

    it "names nothing when the request grants every program the call runs", :seam do
      expect(profiles.unrunnable(request(contained, executables: [uv]))).to eq([])
      expect(profiles.unrunnable(request(contained, grants: [uv]), [uv])).to eq([])
    end

    it "names a program the contained profile refuses whatever the request carries, such as a fresh one", :seam do
      written = uv.with(fresh: true)

      expect(profiles.unrunnable(request(contained, executables: [written]))).to eq([written.realpath])
    end

    it "says whether a ruling earns a confined profile at all, which only then is worth a request" do
      expect([profiles.confines?(contained), profiles.confines?(ruling(judge))]).to eq([true, false])
    end

    it "makes no call dir for a workspace call, since it builds no sandbox", :seam do
      scratch = File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) }
      workspace = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch)

      expect(workspace.unrunnable(request(ruling(judge)), [uv])).to eq([uv.realpath])
      expect(Dir.children(scratch)).to eq([])
    end
  end
end
