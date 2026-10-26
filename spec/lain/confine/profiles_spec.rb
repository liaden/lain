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

    context "with the workspace switch on" do
      let(:scratch) { File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) } }
      let(:profiles) { described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: scratch) }

      def git_init(dir) = system(SeedRepo::SCRUB, "git", "init", "-q", dir, exception: true)

      { "the judge" => "auto", "a rule" => "rules", "bypass" => "bypass" }.each do |who, rung|
        it "confines an automatic approval by #{who} under the workspace profile" do
          expect(profiles.for(request(ruling(rung, rule: "project_rules"))))
            .to have_attributes(name: :workspace, confined?: true, trace: true)
        end
      end

      it "writes the project the request names" do
        expect(profiles.for(request(ruling("auto"))).write_dirs).to include(root)
      end

      it "writes a dir made for the call beneath the TMPDIR, never the TMPDIR itself" do
        profile = profiles.for(request(ruling("auto")))

        expect(File.dirname(profile.call_tmpdir)).to eq(scratch)
        expect(File.directory?(profile.call_tmpdir)).to be(true)
        expect(profile.write_dirs).to include(profile.call_tmpdir)
        expect(profile.write_dirs).not_to include(scratch)
      end

      it "makes each call a dir of its own" do
        dirs = Array.new(2) { profiles.for(request(ruling("auto"))).call_tmpdir }
        expect(dirs.uniq.size).to eq(2)
      end

      it "makes no call dir when the TMPDIR is the private /tmp, which is already the call's own" do
        allow(Dir).to receive(:mktmpdir).and_call_original
        on_tmp = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: "/tmp")
        profile = on_tmp.for(request(ruling("auto")))

        expect([profile.call_tmpdir, profile.write_dirs.count("/tmp")]).to eq([nil, 2])
        expect(Dir).not_to have_received(:mktmpdir)
      end

      it "refuses a call whose TMPDIR has gone, naming it" do
        gone = described_class.new(masks:, probe:, home:, root:, workspace: true, tmpdir: File.join(@base, "gone"))

        expect { gone.for(request(ruling("auto"))) }.to raise_error(described_class::NoTmpdir) { |error|
          expect([error.path, error.profile]).to eq([File.join(@base, "gone"), :workspace])
        }
      end

      it "makes no dir for a call that is not a workspace one" do
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

      it "keeps a ComposedTerm approval in the reader profile" do
        expect(profiles.for(composed).name).to eq(:reader)
      end

      it "traces a call that carries no ruling" do
        expect(profiles.for(Lain::Confine::Request::NONE)).to eq(Lain::Confine::Profile::TRACED)
      end

      it "masks what the mask list holds when the call is made" do
        profiles.for(request(ruling("auto")))
        masked << mask(File.join(root, ".env"))

        expect(profiles.for(request(ruling("auto"))).masks).to eq([File.join(root, ".env")])
      end

      it "lets a workspace call run a program resolved outside /usr that no project could have planted" do
        grep = File.join(home, ".local/bin/grep")
        executables = [executable("grep", grep, :user), executable("cat", File.join(root, "bin/cat"), :project)]

        expect(profiles.for(request(ruling("auto"), executables:)).exec_files).to eq([grep])
      end

      it "runs the whole bin dir of a mise install a program resolved into, never a sibling version's" do
        bin = File.join(home, ".local/share/mise/installs/ruby/4.0.6/bin")
        planted = File.join(root, "bin/bundle")
        executables = [executable("bundle", File.join(bin, "bundle"), :user), executable("x", planted, :project)]
        profile = profiles.for(request(ruling("auto"), executables:))

        expect(profile.exec_dirs).to include(bin)
        expect([profile.runs?(File.join(bin, "ruby")), profile.runs?("#{bin.sub("4.0.6", "4.0.5")}/ruby"),
                profile.runs?(planted)]).to eq([true, false, false])
        expect(profiles.for(composed(executables:)).exec_dirs).not_to include(bin)
      end

      it "runs no mise install for a program a project could have planted there" do
        bin = File.join(home, ".local/share/mise/installs/ruby/4.0.6/bin")
        executables = [executable("bundle", File.join(bin, "bundle"), :project)]

        expect(profiles.for(request(ruling("auto"), executables:)).exec_dirs).not_to include(bin)
      end

      it "makes the call's private cargo home in its own dir, holding only the config lain writes" do
        FileUtils.mkdir_p(File.join(home, ".cargo/registry"))
        profile = profiles.for(request(ruling("auto")))
        made = profile.homes.sole.source(profile.call_tmpdir)

        expect(Dir.children(made)).to eq(["config.toml"])
        expect(File.read(File.join(made, "config.toml"))).to include(%(auto-clean-frequency = "never"))
      end

      it "stops running target/ from the call after it is replaced by a link out of the root" do
        FileUtils.mkdir_p(target = File.join(root, "target"))
        real = profiles.for(request(ruling("auto"))).exec_dirs
        FileUtils.rm_rf(target)
        File.symlink(FileUtils.mkdir_p(File.join(@base, "outside")).first, target)

        expect([real.include?(target), profiles.for(request(ruling("auto"))).exec_dirs.include?(target)])
          .to eq([true, false])
      end

      it "runs a target/ from the call after the one that made it" do
        before = profiles.for(request(ruling("auto"))).exec_dirs
        FileUtils.mkdir_p(target = File.join(root, "target"))

        expect([before.include?(target), profiles.for(request(ruling("auto"))).exec_dirs.include?(target)])
          .to eq([false, true])
      end

      it "removes the call's dir and refuses the call when its private home cannot be made" do
        FileUtils.mkdir_p(File.join(home, ".cargo/registry"))
        allow(FileUtils).to receive(:mkdir_p).and_call_original
        allow(FileUtils).to receive(:mkdir_p).with(%r{/\.lain-homes/}).and_raise(Errno::ENOSPC)

        expect { profiles.for(request(ruling("auto"))) }.to raise_error(described_class::NoTmpdir)
        expect(Dir.children(scratch)).to be_empty
      end

      describe "a private network" do
        def status(fields) = ["#{JSON.generate({ abi: 6, rights: {}, skipped: [], **fields })}\n", true]

        it "is the call's own where the fence says it can make one" do
          answers["lain-fence"] = status(private_net: false)

          expect(profiles.for(request(ruling("auto"))).private_net).to be(true)
        end

        it "is the host's, so the fence still refuses every bind, where the fence names no private_net" do
          expect(profiles.for(request(ruling("auto"))).private_net).to be(false)
        end
      end

      it "refuses a mask that would empty the project it writes, naming the profile, and makes no dir" do
        listed = Struct.new(:masks) { def landed_on(_path) = ["link"] }.new([mask(root)])
        workspace = described_class.new(masks: listed, probe:, home:, root:, workspace: true, tmpdir: scratch)

        expect { workspace.for(request(ruling("auto"))) }
          .to raise_error(described_class::Overmasked, /link/) { expect(_1.profile).to eq(:workspace) }
        expect(Dir.children(scratch)).to be_empty
      end

      describe "a build tool's ports" do
        let(:fresh_paths) { [] }
        let(:fresh) do
          paths = fresh_paths
          Struct.new(:paths) do
            def any_under?(root) = paths.any? { Lain::Landing.under?(_1, root) }
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

        it "grants a rule's or bypass's approval too, the rungs that earn the workspace profile" do
          expect(%w[rules bypass].map { profile_of(%w[git fetch origin], git, rung: _1).name }).to eq(%i[grant grant])
        end

        it "withdraws the grant once a build input was written this lineage" do
          fresh_paths << File.join(root, "Gemfile")

          expect(profile_of(%w[bundle install], bundle(run_files: [run_file("Gemfile", fresh: true)])))
            .to have_attributes(name: :workspace, connect_ports: [], unix_dirs: [])
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

        it "refuses a user program that shadows another of its name, or one resolved with an anomaly" do
          shadowing = bundle(shadowed: ["/usr/bin/bundle"])
          odd = bundle(anomalies: [:relative_path_entry])

          expect([shadowing, odd].map { profile_of(%w[bundle install], _1).name }).to all(eq(:workspace))
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

        it "never grants a human's approval or a ComposedTerm one" do
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
      end

      describe "the seal set" do
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

    context "when this kernel cannot trace" do
      before { answers["strace"] = ["", false] }

      it "still confines a reader call, with no trace" do
        expect(profiles.for(composed)).to have_attributes(name: :reader, trace: false, confined?: true)
      end

      it "neither traces nor confines any other call" do
        expect(profiles.for(request(ruling("judge")))).to eq(Lain::Confine::Profile::NONE)
      end

      it "still confines a workspace call, with no trace" do
        workspace = described_class.new(masks:, probe:, home:, root:, workspace: true,
                                        tmpdir: File.join(@base, "scratch").tap { FileUtils.mkdir_p(_1) })
        expect(workspace.for(request(ruling("auto")))).to have_attributes(name: :workspace, trace: false)
      end
    end
  end
end
