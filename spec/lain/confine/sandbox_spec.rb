# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Confine::Sandbox do
  let(:journal) { RecordingChannel.new }
  let(:fence) { "/srv/lain-fence" }
  let(:runner) { ->(argv) { [argv.include?("--status") ? '{"abi":3,"reap":true}' : "", true] } }
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

    it "does not launch a bwrap found in the cwd through an empty PATH entry" do
      Dir.mktmpdir("lain-sandbox-cwd") do |dir|
        File.write(File.join(dir, "bwrap"), "#!/bin/sh\n")
        File.chmod(0o755, File.join(dir, "bwrap"))
        stub_const("ENV", ENV.to_h.merge("PATH" => "::"))

        launcher = Dir.chdir(dir) { sandbox.wrap(inner, requirer: "Spec").instance_variable_get(:@launcher) }

        expect(launcher.instance_variable_get(:@bwrap)).to be_nil
      end
    end

    it "hands the profiles the mask list it was given and the home" do
      profiles = sandbox.wrap(inner, requirer: "Spec").instance_variable_get(:@profiles)

      expect(profiles.instance_variable_get(:@masks)).to be(masks)
      expect([profiles.instance_variable_get(:@home), profiles.instance_variable_get(:@root)])
        .to eq(["/home/h", "/srv/project"])
    end

    it "leaves the workspace profile off unless it is asked for" do
      ruling = Lain::Approval::Escalation::Ruling.allow(rung: "auto", because: "judged")
      request = Lain::Confine::Request.new(ruling:, executables: [], cwd: nil, root: nil, tool_use_id: "toolu_1")
      profiles = sandbox.wrap(inner, requirer: "Spec").instance_variable_get(:@profiles)

      expect(profiles.for(request)).to eq(Lain::Confine::Profile::TRACED)
    end

    describe "the lineage's freshness" do
      let(:ruling) { Lain::Approval::Escalation::Ruling.allow(rung: "auto", because: "judged") }
      let(:git) do
        Lain::Shell::Executable.new(name: "git", resolved: "/usr/bin/git", realpath: "/usr/bin/git", chain: [],
                                    shadowed: [], anomalies: [], klass: :system, fresh: false, run_files: [],
                                    wrappers: [])
      end

      let(:masks) do
        policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: "/home/h", cwd: @repo))
        Lain::Confine::MaskList.new(root: @repo, policy: -> { policy })
      end

      around do |example|
        Dir.mktmpdir("lain-sandbox-fresh") do |dir|
          @repo, @scratch = %w[repo scratch].map { File.join(File.realpath(dir), _1).tap { |d| FileUtils.mkdir_p(d) } }
          system(SeedRepo::SCRUB, "git", "init", "-q", chdir: @repo, exception: true)
          example.run
        end
      end

      def fetch_profile(**)
        request = Lain::Confine::Request.new(ruling:, executables: [git], argv: [%w[git fetch]], cwd: @repo,
                                             root: @repo, tool_use_id: "toolu_1")
        described_class.new(root: @repo, home: "/home/h", masks:, probe:, fence:, journal:, workspace: true,
                            tmpdir: @scratch, **).wrap(inner, requirer: "Spec")
                       .instance_variable_get(:@profiles).for(request)
      end

      it "hands the profiles the freshness it was given, which a grant reads" do
        quiet = Lain::Shell::Executable::Fresh.new(start: Time.now + 3600, written: [],
                                                   stat: Lain::Shell::Executable::Stat.new)

        expect(fetch_profile(fresh: quiet).name).to eq(:grant)
      end

      it "grants nothing when it was given no freshness" do
        expect(fetch_profile.name).to eq(:workspace)
      end
    end

    # The read grant on git's config files asks the session's own policy, through the mask list built over it.
    it "grants no git config file the session's policy denies" do
      Dir.mktmpdir("lain-sandbox-policy") do |dir|
        base = File.realpath(dir)
        repo, home = %w[repo h].map { File.join(base, _1).tap { |d| FileUtils.mkdir_p(d) } }
        system(SeedRepo::SCRUB, "git", "init", "-q", repo, exception: true)
        netrc = File.join(base, ".netrc").tap { File.write(_1, "[user]\n\tname = P\n") }
        policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: repo))
        listed = Lain::Confine::MaskList.new(root: repo, policy: -> { policy })
        ruling = Lain::Approval::Escalation::Ruling.allow(rung: "rules", because: "read", rule: "composed_term")
        request = Lain::Confine::Request.new(ruling:, executables: [], cwd: repo, root: repo, tool_use_id: "toolu_1")

        read = with_env("GIT_CONFIG_GLOBAL" => netrc) do
          described_class.new(root: repo, home:, masks: listed, probe:, fence:, journal:).wrap(inner, requirer: "Spec")
                         .instance_variable_get(:@profiles).for(request).read_dirs
        end

        expect(read).not_to include(netrc)
      end
    end

    context "when the fence cannot reap" do
      let(:runner) { ->(argv) { [argv.include?("--status") ? '{"abi":3}' : "", true] } }

      it "runs an unconfined call as written, untraced, and journals the reaper as degraded" do
        capture = sandbox.wrap(inner, requirer: "Spec")
                         .call(command: "echo hi", cwd: Dir.pwd, env: {}, timeout: 5)

        expect(capture).to have_attributes(exit_status: 0, stdout: "hi\n")
        expect(degraded.map(&:capability)).to eq([:reap])
        expect(journal.events.grep(Lain::Telemetry::Sandbox).sole).to have_attributes(profile: :none, trace: false)
      end
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

      it "names the missing lain-fence when the binary cannot be started" do
        missing = ->(_argv) { raise Errno::ENOENT, "/srv/lain-fence" }
        probe = Lain::Confine::Probe.new(fence:, journal:, runner: missing, ptrace_scope: -> { "0" })
        described_class.new(root: "/srv/project", home: "/home/h", masks:, probe:, fence:, journal:)
                       .wrap(inner, requirer: "Spec")

        notice = degraded.find { _1.capability == :sandbox }.provider
        expect(notice).to include("lain-fence cannot start #{fence}")
        expect(notice).not_to include("landlock")
      end

      it "names the probe's reason when an executable fence reports ABI 0" do
        zero = ->(argv) { [argv.include?("--status") ? '{"abi":0}' : "", true] }
        probe = Lain::Confine::Probe.new(fence:, journal:, runner: zero, ptrace_scope: -> { "0" })
        described_class.new(root: "/srv/project", home: "/home/h", masks:, probe:, fence:, journal:)
                       .wrap(inner, requirer: "Spec")

        expect(degraded.find { _1.capability == :sandbox }.provider).to include("#{fence} reports ABI 0")
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

  describe "with the workspace switch on, on this box", :seam do
    let(:fence) { Lain::Confine::Bwrap.fence_binary }

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
    end

    around do |example|
      Dir.mktmpdir("lain-sandbox-workspace") do |dir|
        @base = File.realpath(dir)
        FileUtils.mkdir_p([repo, home, scratch])
        system(SeedRepo::SCRUB, "git", "init", "-q", chdir: repo, exception: true)
        example.run
      end
    end

    def home = File.join(@base, "home")
    def repo = File.join(@base, "repo")
    def scratch = File.join(@base, "scratch")

    def policy
      Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: repo, root: repo), home:, root: repo)
    end

    def workspace(tmpdir)
      judging = policy
      masks = Lain::Confine::MaskList.new(root: repo, policy: -> { judging })
      described_class.new(root: repo, home:, masks:, probe: Lain::Confine::Probe.new(fence:, journal:), fence:,
                          journal:, workspace: true, tmpdir:).wrap(Lain::Exec::Local.new, requirer: "Spec")
    end

    def judged(command, tmpdir: scratch)
      ruling = Lain::Approval::Escalation::Ruling.allow(rung: Lain::Approval::Judged::NAME, because: "judged")
      request = Lain::Confine::Request.new(ruling:, executables: [], cwd: repo, root: repo, tool_use_id: "toolu_1")
      workspace(tmpdir).call(command:, cwd: repo, env: {}, timeout: 10, confinement: request)
    end

    def sandbox_records = journal.events.grep(Lain::Telemetry::Sandbox)

    def exec_in(root)
      judging = policy
      masks = Lain::Confine::MaskList.new(root:, policy: -> { judging })
      described_class.new(root:, home:, masks:, probe: Lain::Confine::Probe.new(fence:, journal:), fence:,
                          journal:, workspace: true, tmpdir: scratch).wrap(Lain::Exec::Local.new, requirer: "Spec")
    end

    def judged_in(exec, root, command)
      ruling = Lain::Approval::Escalation::Ruling.allow(rung: Lain::Approval::Judged::NAME, because: "judged")
      request = Lain::Confine::Request.new(ruling:, executables: [], cwd: root, root:, tool_use_id: "toolu_1")
      exec.call(command:, cwd: root, env: {}, timeout: 10, confinement: request)
    end

    it "flags the new landing of a dangling hooks link the human repointed between calls" do
      system(SeedRepo::SCRUB, "git", "-C", repo, "-c", "user.name=a", "-c", "user.email=a@b", "commit", "-q",
             "--allow-empty", "-m", "i", exception: true)
      system(SeedRepo::SCRUB, "git", "-C", repo, "worktree", "add", "-q", worktree = File.join(@base, "wt"),
             exception: true)
      hooks = File.join(repo, ".git/hooks").tap { FileUtils.rm_rf(_1) }
      File.symlink(File.join(worktree, "landing-a"), hooks)
      exec = exec_in(worktree)
      judged_in(exec, worktree, "true")
      File.unlink(hooks)
      File.symlink(File.join(worktree, "landing-b"), hooks)
      judged_in(exec, worktree, "mkdir landing-b")

      expect(sandbox_records.map(&:created_sealed)).to eq([[], [], [File.join(worktree, "landing-b")]])
    end

    it "runs a judge's approval under the workspace profile, which writes the project" do
      capture = judged("echo hi > out.txt")

      expect(capture.exit_status).to eq(0)
      expect(File.read(File.join(repo, "out.txt"))).to eq("hi\n")
      expect(sandbox_records.sole).to have_attributes(profile: :workspace, created_sealed: [])
    end

    it "flags the new landing of a hooks link to /dev/null the human repointed between calls" do
      File.symlink(File::NULL, link = File.join(@base, "hooks-link"))
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", link, exception: true)
      exec = exec_in(repo)
      judged_in(exec, repo, "true")
      File.unlink(link)
      File.symlink(File.join(repo, "landing-b"), link)
      judged_in(exec, repo, "mkdir landing-b")

      expect(sandbox_records.map(&:created_sealed).last).to eq([File.join(repo, "landing-b")])
    end

    it "refuses a call whose hooks link outside the writes leads to a link inside them, so no hook is planted" do
      FileUtils.mkdir_p(real = File.join(@base, "real-hooks"))
      File.symlink(real, inside = File.join(repo, "x"))
      File.symlink(inside, outside = File.join(@base, "hooks-link"))
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", outside, exception: true)
      capture = judged("rm x && mkdir x && echo planted > x/pre-commit")

      expect([capture.exit_status, capture.stderr]).to match([Lain::Shell::Pipeline::NOT_PERMITTED, /REFUSED/])
      expect([File.symlink?(inside), File.exist?(File.join(real, "pre-commit"))]).to eq([true, false])
    end

    it "refuses a call whose hooks hop is spelled outside the writes but really lands on a link inside them" do
      FileUtils.mkdir_p([real = File.join(@base, "real-hooks"), File.join(repo, "d")])
      File.symlink(real, inside = File.join(repo, "d", "b"))
      File.symlink(File.join(repo, "d"), File.join(@base, "out-a"))
      File.symlink(File.join(@base, "out-a", "b"), outside = File.join(@base, "hooks-link"))
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", outside, exception: true)
      capture = judged("rm d/b && mkdir d/b && echo planted > d/b/pre-commit")

      expect([capture.exit_status, capture.stderr]).to match([Lain::Shell::Pipeline::NOT_PERMITTED, /REFUSED/])
      expect([File.symlink?(inside), File.exist?(File.join(real, "pre-commit"))]).to eq([true, false])
    end

    it "flags the new landing of a hooks chain whose second link the human repointed between calls" do
      FileUtils.mkdir_p(real = File.join(@base, "real-hooks"))
      File.symlink(real, second = File.join(@base, "second"))
      File.symlink(second, first = File.join(@base, "hooks-link"))
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", first, exception: true)
      exec = exec_in(repo)
      judged_in(exec, repo, "true")
      File.unlink(second)
      File.symlink(File.join(repo, "landing-b"), second)
      judged_in(exec, repo, "mkdir landing-b")

      expect(sandbox_records.map(&:created_sealed).last).to eq([File.join(repo, "landing-b")])
    end

    it "refuses a call whose hooks path meets a link inside the writes through a parent folder linked outside" do
      FileUtils.mkdir_p(File.join(real = File.join(@base, "real"), "hooks"))
      File.symlink(real, inside = File.join(repo, "c"))
      File.symlink(inside, File.join(@base, "a"))
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", File.join(@base, "a", "hooks"),
             exception: true)
      capture = judged("rm c && mkdir -p c/hooks && echo planted > c/hooks/pre-commit")

      expect([capture.exit_status, capture.stderr]).to match([Lain::Shell::Pipeline::NOT_PERMITTED, /REFUSED/])
      expect([File.symlink?(inside), File.exist?(File.join(real, "hooks", "pre-commit"))]).to eq([true, false])
    end

    it "flags the new landing of a hooks path whose parent folder's second link the human repointed between calls" do
      FileUtils.mkdir_p(File.join(real = File.join(@base, "real"), "hooks"))
      File.symlink(real, second = File.join(@base, "q"))
      File.symlink(second, first = File.join(@base, "p"))
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", File.join(first, "hooks"),
             exception: true)
      exec = exec_in(repo)
      judged_in(exec, repo, "true")
      File.unlink(second)
      File.symlink(File.join(repo, "landing"), second)
      judged_in(exec, repo, "mkdir -p landing/hooks")

      expect(sandbox_records.map(&:created_sealed).last).to eq([File.join(repo, "landing", "hooks")])
    end

    it "seals the hooks dir git really runs when core.hooksPath climbs a .. after a link" do
      FileUtils.mkdir_p([File.join(repo, "deep"), hooks = File.join(repo, "hooks")])
      File.symlink(File.join(repo, "deep"), File.join(@base, "l"))
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", "#{@base}/l/../hooks", exception: true)
      capture = judged("echo planted > hooks/pre-commit")

      expect(capture.stderr).to match(/Read-only file system|Permission denied/)
      expect(File.exist?(File.join(hooks, "pre-commit"))).to be(false)
    end

    it "flags an absent hooks dir the call made, reached by a link target that climbs a .. after a link" do
      FileUtils.mkdir_p(File.join(repo, "deep"))
      File.symlink(File.join(repo, "deep"), File.join(@base, "l"))
      File.symlink("l/../hooks", File.join(@base, "h"))
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", File.join(@base, "h"), exception: true)
      judged("mkdir hooks && echo planted > hooks/pre-commit")

      expect(sandbox_records.map(&:created_sealed).last).to eq([File.join(repo, "hooks")])
    end

    it "flags the missing component the call made, when core.hooksPath climbs a .. after it" do
      FileUtils.mkdir_p(File.join(repo, "hooks"))
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", "missing/../hooks", exception: true)
      judged("mkdir missing && echo planted > hooks/pre-commit")

      expect(sandbox_records.map(&:created_sealed).last).to eq([File.join(repo, "missing")])
    end

    it "refuses a hook planted where a .. after a missing component spells, even with the missing name removed" do
      FileUtils.mkdir_p(hooks = File.join(repo, "hooks"))
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", "missing/../hooks", exception: true)
      capture = judged("mkdir missing && echo planted > hooks/pre-commit; rmdir missing")

      expect(capture.stderr).to match(/Read-only file system|Permission denied/)
      expect(File.exist?(File.join(hooks, "pre-commit"))).to be(false)
    end

    it "flags the missing component the call made a link, when core.hooksPath climbs a .. after it" do
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", "missing/../hooks", exception: true)
      judged("mkdir -p a/b a/hooks && ln -s a/b missing && echo planted > a/hooks/pre-commit")

      expect(sandbox_records.map(&:created_sealed).last).to eq([File.join(repo, "missing")])
    end

    it "runs git in a repository whose core.hooksPath is /dev/null" do
      system(SeedRepo::SCRUB, "git", "-C", repo, "config", "core.hooksPath", File::NULL, exception: true)
      capture = judged("git status --short")

      expect([capture.exit_status, capture.stderr]).to eq([0, ""])
    end

    it "refuses a write to the repository's config, and leaves the config as it was" do
      config = File.join(repo, ".git/config")
      before = File.read(config)
      capture = judged("echo x >> .git/config")

      expect(capture.exit_status).not_to eq(0)
      expect(capture.stderr).to match(/Read-only file system|Permission denied/)
      expect(File.read(config)).to eq(before)
    end

    it "writes a TMPDIR of the call's own, removed after it, and refuses the TMPDIR it sits in" do
      capture = judged('echo x > "$TMPDIR/own" && echo "$TMPDIR"; echo y > "$(dirname "$TMPDIR")/beside"')
      own = capture.stdout.lines.first.chomp

      expect(File.dirname(own)).to eq(scratch)
      expect(capture.stderr).to match(/beside: (Read-only file system|Permission denied)/)
      expect([File.exist?(own), Dir.children(scratch)]).to eq([false, []])
    end

    it "writes the private /tmp when TMPDIR is /tmp, and makes no call dir there" do
      name = "lain-t38-#{Process.pid}-#{rand(1 << 32)}"
      capture = judged(%(echo x > /tmp/#{name} && cat /tmp/#{name}), tmpdir: "/tmp")

      expect(capture).to have_attributes(exit_status: 0, stdout: "x\n")
      expect(File.exist?("/tmp/#{name}")).to be(false)
    end

    it "removes a call's TMPDIR that the call left unreadable" do
      judged('mkdir "$TMPDIR/d" && touch "$TMPDIR/d/f" && chmod 000 "$TMPDIR/d"')

      expect(Dir.children(scratch)).to be_empty
      expect(sandbox_records.map(&:kept_tmpdir)).to eq([nil])
    end

    it "flags a sealed path the call created where it was absent, and leaves it in place" do
      commondir = File.join(repo, ".git/commondir")
      judged(": > .git/commondir")

      expect(sandbox_records.map(&:created_sealed)).to eq([[], [commondir]])
      expect(File.exist?(commondir)).to be(true)
    end
  end

  describe "a workspace call in a shared clone lease, on this box", :seam do
    let(:fence) { Lain::Confine::Bwrap.fence_binary }

    before do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
    end

    around do |example|
      Dir.mktmpdir("lain-sandbox-clone") do |dir|
        @base = File.realpath(dir)
        FileUtils.mkdir_p([upstream, home, scratch])
        FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", upstream)
        SeedRepo.git(upstream, "config", "--unset", "core.hooksPath")
        FileUtils.mkdir_p(File.join(upstream, ".git", "hooks"))
        File.write(hook = File.join(upstream, ".git", "hooks", "pre-commit"), "#!/bin/sh\necho upstream-hook-ran >&2\n")
        File.chmod(0o755, hook)
        @backend = Lain::Isolation::Clone.new(repo_root: upstream, root: leases,
                                              base: Lain::Isolation::WorkingBranch.checked_out(repo_root: upstream))
        @lease = @backend.acquire("worker-1")
        example.run
      ensure
        @lease&.release(discard: true)
        FileUtils.rm_rf(leases)
      end
    end

    def upstream = File.join(@base, "upstream")
    def home = File.join(@base, "home")
    def scratch = File.join(@base, "scratch")
    def clone = @lease.worker_env.cwd
    # Under lain's lease container, the one tree whose records lain trusts.
    def leases = File.join(Lain::Paths.new.state_home, "worktrees", Lain::Paths.new.project_hash(upstream))
    def git_in_clone(*) = SeedRepo.git(clone, *).stdout.strip
    def upstream_refs = SeedRepo.git(upstream, "for-each-ref", "--format=%(refname) %(objectname)").stdout

    def masks
      policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: clone, root: clone),
                                             home:, root: clone)
      Lain::Confine::MaskList.new(root: clone, policy: -> { policy })
    end

    def call(command)
      exec = described_class.new(root: clone, home:, masks:, probe: Lain::Confine::Probe.new(fence:, journal:), fence:,
                                 journal:, workspace: true, tmpdir: scratch)
                            .wrap(Lain::Exec::Local.new, requirer: "Spec")
      ruling = Lain::Approval::Escalation::Ruling.allow(rung: Lain::Approval::Judged::NAME, because: "judged")
      request = Lain::Confine::Request.new(ruling:, executables: [], cwd: clone, root: clone, tool_use_id: "toolu_1")
      exec.call(command:, cwd: clone, env: {}, timeout: 20, confinement: request)
    end

    def as_worker = "git -c user.name=w -c user.email=w@e"

    it "commits under upstream's pre-commit, deletes a packed branch and finishes a conflicted merge cleanly" do
      git_in_clone("branch", "doomed")
      git_in_clone("pack-refs", "--all")
      capture = call(<<~SH)
        set -e
        echo one > README && #{as_worker} commit -qam one
        #{as_worker} branch -d doomed
        #{as_worker} switch -qc side HEAD~1 && echo side > README && #{as_worker} commit -qam side
        #{as_worker} switch -q --detach @{-1}
        #{as_worker} merge -q side || true
        echo resolved > README && git add README && #{as_worker} commit -q --no-edit
        test ! -e .git/AUTO_MERGE && echo clean
      SH

      expect([capture.exit_status, capture.stdout.lines.last]).to eq([0, "clean\n"])
      expect(capture.stderr).to include("upstream-hook-ran")
      expect(capture.stderr).not_to match(/Read-only|Permission denied|unable to/)
      expect(git_in_clone("branch", "--list", "doomed")).to eq("")
    end

    it "refuses or flags every write to the clone's config, hooks and alternates, and to upstream's refs and objects" do
      before = upstream_refs
      tip = git_in_clone("rev-parse", "HEAD")
      config = File.read(File.join(clone, ".git", "config"))
      capture = call(<<~SH)
        echo x >> .git/config
        git config core.hooksPath /tmp
        echo x > .git/hooks/pre-commit
        echo /tmp > .git/objects/info/alternates
        echo #{tip} > #{upstream}/.git/refs/heads/planted
        touch #{upstream}/.git/objects/planted
        echo #{tip} > .git/objects/info/http-alternates
        true
      SH

      expect(capture.stderr.scan(/Read-only file system|Permission denied|Device or resource busy/).size).to be >= 6
      expect(File.read(File.join(clone, ".git", "config"))).to eq(config)
      expect(File.exist?(File.join(clone, ".git", "hooks", "pre-commit"))).to be(false)
      expect(File.read(File.join(clone, ".git", "objects", "info", "alternates")).strip)
        .to eq(File.join(upstream, ".git", "objects"))
      expect([upstream_refs, File.exist?(File.join(upstream, ".git", "objects", "planted"))]).to eq([before, false])
      expect(journal.events.grep(Lain::Telemetry::Sandbox).last.created_sealed)
        .to eq([File.join(clone, ".git", "objects", "info", "http-alternates")])
    end

    it "refuses a workspace call rooted at the lease root, which holds the records lain trusts" do
      exec = described_class.new(root: leases, home:, masks:, probe: Lain::Confine::Probe.new(fence:, journal:), fence:,
                                 journal:, workspace: true, tmpdir: scratch)
                            .wrap(Lain::Exec::Local.new, requirer: "Spec")
      ruling = Lain::Approval::Escalation::Ruling.allow(rung: Lain::Approval::Judged::NAME, because: "judged")
      request = Lain::Confine::Request.new(ruling:, executables: [], cwd: leases, root: leases, tool_use_id: "toolu_1")
      capture = exec.call(command: "true", cwd: leases, env: {}, timeout: 20, confinement: request)

      expect([capture.exit_status, capture.stderr])
        .to match([Lain::Shell::Pipeline::NOT_PERMITTED, /REFUSED.*holds lain's own state/])
    end

    it "never runs a commondir plant from release or gc, and keeps the clone for a human" do
      marker = File.join(@base, "pwned")
      call(<<~SH)
        mkdir -p evil && cp -r .git/objects .git/refs evil/
        printf '[core]\\n\\trepositoryformatversion = 0\\n\\tfsmonitor = "touch #{marker}; false"\\n' > evil/config
        echo ../evil > .git/commondir
      SH
      lain_reads_the_lease
      @lease.release
      record = Lain::Isolation::Gc.new(repo_root: upstream, root: leases, retain_days: 0,
                                       clock: -> { Time.now + 86_400 }).call.find { _1.name == clone }

      expect(File.exist?(File.join(clone, ".git", "commondir"))).to be(true)
      expect([File.exist?(marker), File.directory?(clone)]).to eq([false, true])
      expect([record.action, record.reason]).to match([:kept, /commondir/])
      expect(@outcomes).to eq(%i[failed failed failed])
      expect([@refused.exit_status,
              @refused.stderr]).to match([Lain::Shell::Pipeline::NOT_PERMITTED, /REFUSED.*redirects git/])
    end

    # Every site where lain runs its own git in a lease, outside the sandbox.
    def lain_reads_the_lease
      @refused = call("true")
      [clone, File.join(clone, "evil")].each { Lain::FileWalk.new(root: _1).first(3) }
      expect { checked_tree.dirty? }.to raise_error(Lain::Error, /commondir/)
      @outcomes = [Lain::Isolation::SelfSync.new(base: @backend.base).unasked(@lease, worker_id: "worker-1").outcome,
                   handed_back.kind, retired.kind]
    end

    def checked_tree
      Lain::Isolation::WorkerChecks::Tree.new(clone, base: @backend.base,
                                                     shell_out_factory: Lain::Shell::Out.public_method(:new))
    end

    def handed_back
      Lain::Isolation::Worktree::Handback.new(repo_root: upstream, base: Lain::Isolation::WorkingBranch::NONE)
                                         .anchor(@lease, worker_id: "worker-1")
    end

    def retired
      Lain::Isolation::Worktree::Handback::Retirement.over(isolation: @backend).surrender(@lease, worker_id: "worker-1")
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

    # This spec's paths sit under its TMPDIR, which can read as a token; the refusal then names no path.
    def shown(name, path)
      line = format(Lain::Exec::Sandboxed::OVERMASKED, names: name, path:)
      Lain::Sensitivity::Regions.detect(line).empty? ? path : Lain::Exec::Sandboxed::PATH_WITHHELD
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
        expect(capture.stderr).to include(name, shown(name, instance_exec(&landed))).and start_with("lain: REFUSED")
      end
    end

    it "refuses the call, naming the link, when a listed link lands on a program the call was granted" do
      program = File.join(home, ".local", "bin", "tool")
      executable = user_program(program)
      capture = cat_plain(sandboxed_over("id_rsa", program), command: program, executables: [executable])

      expect(capture).to have_attributes(exit_status: Lain::Shell::Pipeline::NOT_PERMITTED, stdout: "")
      expect(capture.stderr).to include("id_rsa", shown("id_rsa", program)).and start_with("lain: REFUSED")
    end

    it "runs when a masked directory's name only starts like a grant's" do
      FileUtils.mkdir_p(File.join(home, ".rust"))
      capture = cat_plain(sandboxed_over("secrets.key", File.join(home, ".rust")))

      expect(capture).to have_attributes(exit_status: 0, stdout: "plain words\n")
    end
  end
end
