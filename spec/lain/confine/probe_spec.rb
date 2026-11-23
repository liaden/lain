# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Confine::Probe do
  let(:journal) { [] }
  let(:answers) do
    { "bwrap" => ["", true], "lain-fence" => ["{\"abi\":9,\"reap\":true,\"rights\":{},\"skipped\":[]}\n", true],
      "strace" => ["strace 6.1", true] }
  end
  let(:runner) { ->(argv) { answers.fetch(File.basename(argv.first)) } }
  let(:scope) { -> { "1\n" } }
  let(:bwrap) { Lain::Confine::Bwrap.new(fence: "/x/lain-fence", bwrap: "/x/bwrap") }

  def probe
    described_class.new(fence: "/x/lain-fence", bwrap:, runner:, ptrace_scope: scope, journal:)
  end

  describe "#supports?" do
    it "offers every layer on a full box" do
      expect(%i[bwrap landlock trace].map { |layer| probe.supports?(layer) }).to eq([true] * 3)
      expect(journal).to be_empty
    end

    it "journals a missing strace once and narrows only the trace" do
      answers["strace"] = ["", false]
      subject = probe

      expect([subject.supports?(:trace), subject.supports?(:trace), subject.supports?(:bwrap)])
        .to eq([false, false, true])
      expect(journal.map(&:capability)).to eq([:trace])
      expect(journal.first).to be_a(Lain::Telemetry::CapabilityDegraded)
    end

    it "refuses the trace when ptrace_scope forbids tracing a child" do
      %W[2\n 3\n].each do |value|
        j = []
        refused = described_class.new(fence: "/x/lain-fence", bwrap:, runner:, ptrace_scope: -> { value }, journal: j)
        expect([refused.supports?(:trace), j.map(&:capability)]).to eq([false, [:trace]])
      end
    end

    it "allows the trace when the yama file is absent" do
      absent = described_class.new(fence: "/x/lain-fence", bwrap:, runner:, ptrace_scope: -> {}, journal:)
      expect(absent.supports?(:trace)).to be(true)
    end

    it "never reads a missing sandbox as granted" do
      answers["bwrap"] = ["bwrap: No permissions to create new namespace", false]
      answers["lain-fence"] = ['{"abi":0,"rights":{},"skipped":[]}', true]
      subject = probe

      expect([subject.supports?(:bwrap), subject.supports?(:landlock)]).to eq([false, false])
      expect(journal.map(&:capability)).to eq(%i[bwrap landlock])
    end

    it "treats a binary that cannot start, or a fence that prints nothing, as absent" do
      broken = described_class.new(fence: "/x/lain-fence", bwrap:, runner: lambda { |argv|
        raise Errno::ENOENT, argv.first if File.basename(argv.first) == "bwrap"

        File.basename(argv.first) == "lain-fence" ? ["", true] : ["ok", true]
      }, ptrace_scope: scope, journal:)

      expect([broken.supports?(:bwrap), broken.supports?(:landlock)]).to eq([false, false])
      expect(journal.find { _1.capability == :bwrap }.provider)
        .to eq("bwrap cannot build the reader namespace: No such file or directory - /x/bwrap")
    end

    it "raises on a layer it does not know" do
      expect { probe.supports?(:gvisor) }.to raise_error(KeyError)
    end
  end

  describe "the bwrap it probes" do
    let(:seen) { [] }
    let(:true_on_path) { Lain::Shell::Path.find("true", path: ENV.fetch("PATH", "")) }
    let(:recording) do
      lambda do |argv|
        seen << argv
        runner.call(argv)
      end
    end

    def recorded(layer)
      described_class.new(fence: "/x/lain-fence", bwrap:, runner: recording, ptrace_scope: scope, journal:)
                     .supports?(layer)
      seen.select { _1.first == "/x/bwrap" }
    end

    it "tries the namespace a confined call runs under" do
      expect(recorded(:bwrap)).to eq([[*bwrap.namespace_argv(private_net: false), true_on_path]])
      expect(seen.first.each_cons(2).to_a).to include(%w[--proc /proc], %w[--unshare-pid --die-with-parent])
    end

    it "tries a private network with --unshare-net in the namespace a confined call runs under" do
      answers["lain-fence"] = ['{"abi":9,"private_net":true,"reap":true,"rights":{},"skipped":[]}', true]

      expect(recorded(:private_net)).to eq([[*bwrap.namespace_argv(private_net: true), true_on_path]])
    end

    it "reports a bwrap missing from PATH without running anything for it" do
      Dir.mktmpdir("lain-probe-empty") do |dir|
        absent = Lain::Confine::Bwrap.on_path(fence: "/x/lain-fence", env: { "PATH" => dir })
        subject = described_class.new(fence: "/x/lain-fence", bwrap: absent, runner: recording, ptrace_scope: scope,
                                      journal:)

        expect([subject.supports?(:bwrap), seen.map { File.basename(_1.first) }]).to eq([false, %w[lain-fence]])
        expect(journal.first.provider).to include("bwrap is not on PATH")
      end
    end

    it "journals bwrap's own refusal" do
      refusal = "bwrap: Creating new namespace failed: Operation not permitted\nmore\n"
      refusing = ->(argv) { argv.include?("--proc") ? [refusal, false] : runner.call(argv) }
      subject = described_class.new(fence: "/x/lain-fence", bwrap:, runner: refusing, ptrace_scope: scope, journal:)

      expect(subject.supports?(:bwrap)).to be(false)
      expect(journal.map { [_1.capability, _1.provider] }).to eq(
        [[:bwrap, "bwrap cannot build the reader namespace: Creating new namespace failed: Operation not permitted"]]
      )
    end
  end

  describe "#fence_gap" do
    it "is nil when the fence reports an ABI" do
      expect(probe.fence_gap).to be_nil
    end

    it "says why the fence cannot be used" do
      answers["lain-fence"] = ["", false]

      expect(probe.fence_gap).to eq("/x/lain-fence exited with failure")
    end

    it "tells a fence that cannot start from one that runs and offers nothing" do
      answers["lain-fence"] = ["", false]
      refused = described_class.new(fence: "/x/lain-fence", bwrap:, ptrace_scope: scope, journal:,
                                    runner: lambda { |argv|
                                      argv.first == "/x/lain-fence" ? raise(Errno::ENOENT) : ["", true]
                                    })

      expect([refused.fence_unstartable?, probe.fence_unstartable?]).to eq([true, false])
    end
  end

  describe "the three layer checks" do
    it "run at once, so a box pays the slowest check rather than the sum" do
      lock = Mutex.new
      all_in = ConditionVariable.new
      arrived = 0
      met = []
      rendezvous = lambda do
        lock.synchronize do
          arrived += 1
          all_in.broadcast
          deadline = Time.now + 2
          all_in.wait(lock, 0.1) while arrived < 3 && Time.now < deadline
          met << arrived
        end
      end
      meeting = lambda do |argv|
        rendezvous.call
        runner.call(argv)
      end
      subject = described_class.new(fence: "/x/lain-fence", bwrap:, runner: meeting, ptrace_scope: scope, journal:)

      subject.supports?(:bwrap)

      expect(met).to eq([3, 3, 3])
    end

    it "journal in bwrap, landlock, trace order on every run of a box missing all three" do
      answers.replace("bwrap" => ["", false], "lain-fence" => ['{"abi":0}', true], "strace" => ["", false])

      orders = Array.new(20) do
        j = []
        described_class.new(fence: "/x/lain-fence", bwrap:, runner:, ptrace_scope: scope, journal: j).supports?(:bwrap)
        j.map(&:capability)
      end

      expect(orders.uniq).to eq([%i[bwrap landlock trace]])
    end

    it "hand a check's unexpected error to the caller of supports?" do
      exploding = ->(argv) { File.basename(argv.first) == "strace" ? raise("strace blew up") : runner.call(argv) }
      subject = described_class.new(fence: "/x/lain-fence", bwrap:, runner: exploding, ptrace_scope: scope, journal:)

      expect { subject.supports?(:bwrap) }.to raise_error(RuntimeError, "strace blew up")
    end

    it "write nothing to stderr when a check raises" do
      exploding = ->(argv) { File.basename(argv.first) == "strace" ? raise("strace blew up") : runner.call(argv) }
      subject = described_class.new(fence: "/x/lain-fence", bwrap:, runner: exploding, ptrace_scope: scope, journal:)

      expect { expect { subject.supports?(:bwrap) }.to raise_error(RuntimeError) }.not_to output.to_stderr
    end

    it "ask the fence for its report once, though two readers want it at the same moment" do
      calls = Queue.new
      slow = lambda do |argv|
        calls << argv if argv.last == "--status"
        sleep 0.05 if argv.last == "--status"
        runner.call(argv)
      end
      answers["lain-fence"] = ['{"abi":9,"private_net":false,"reap":true,"rights":{},"skipped":[]}', true]
      subject = described_class.new(fence: "/x/lain-fence", bwrap:, runner: slow, ptrace_scope: scope, journal:)

      [Thread.new { subject.supports?(:landlock) }, Thread.new { subject.supports?(:private_net) }].each(&:join)

      expect(calls.size).to eq(1)
    end
  end

  describe "production construction" do
    it "probes the real box without a double" do
      real = described_class.new(fence: "/nonexistent/lain-fence", journal:)

      expect(real.supports?(:landlock)).to be(false)
      expect(journal.map(&:capability)).to include(:landlock)
    end

    it "runs the true on PATH, never a failing one in the cwd through an empty PATH entry", :seam do
      skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
      skip("bwrap cannot build a pid namespace with its own /proc on this host") unless
        system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--proc", "/proc", "--unshare-pid", "--", "/usr/bin/true",
               %i[out err] => File::NULL)
      Dir.mktmpdir("lain-probe-cwd-true") do |dir|
        FileUtils.mkdir_p(File.join(dir, "empty"))
        File.write(File.join(dir, "true"), "#!/bin/sh\nexit 1\n")
        File.chmod(0o755, File.join(dir, "true"))

        answers = with_env("PATH" => "#{dir}/empty::/usr/bin:/bin") do
          Dir.chdir(dir) do
            real = described_class.new(fence: "/nonexistent/lain-fence", journal:, ptrace_scope: scope)
            [real.supports?(:bwrap), real.supports?(:trace)]
          end
        end

        expect(answers).to eq([true, true])
      end
    end

    it "answers that strace is not on PATH, never running one in the cwd through an empty PATH entry", :seam do
      Dir.mktmpdir("lain-probe-cwd-strace") do |dir|
        %w[empty bin].each { FileUtils.mkdir_p(File.join(dir, _1)) }
        File.symlink(Lain::Shell::Path.find("true", path: ENV.fetch("PATH", "")), File.join(dir, "bin", "true"))
        File.write(File.join(dir, "strace"), "#!/bin/sh\nexit 0\n")
        File.chmod(0o755, File.join(dir, "strace"))

        traced = with_env("PATH" => "#{dir}/empty::#{dir}/bin") do
          Dir.chdir(dir) do
            described_class.new(fence: "/nonexistent/lain-fence", journal:, ptrace_scope: scope).supports?(:trace)
          end
        end

        expect([traced, journal.find { _1.capability == :trace }&.provider]).to eq([false, "strace is not on PATH"])
      end
    end

    it "finds bwrap working on a box where the namespace can be built", :seam do
      skip("/usr/bin/bwrap is not installed") unless File.executable?("/usr/bin/bwrap")
      skip("bwrap cannot build a pid namespace with its own /proc on this host") unless
        system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--proc", "/proc", "--unshare-pid", "--", "true",
               %i[out err] => File::NULL)

      expect(described_class.new(fence: Lain::Confine::Bwrap.fence_binary, journal:).supports?(:bwrap)).to be(true)
    end
  end

  describe "edge cases" do
    ["[]", "null", '{"abi":null}', '{"abi":"9"}', "not json"].each do |text|
      it "reads fence output #{text.inspect} as no Landlock, journalled once" do
        answers["lain-fence"] = [text, true]
        subject = probe

        expect([subject.supports?(:landlock), subject.supports?(:landlock), subject.abi]).to eq([false, false, 0])
        expect(journal.map(&:capability)).to eq([:landlock])
      end
    end

    ["", "garbage", "1.5"].each do |text|
      it "treats ptrace_scope #{text.inspect} as a gap" do
        unreadable = described_class.new(fence: "/x/lain-fence", bwrap:, runner:, ptrace_scope: -> { text }, journal:)
        expect(unreadable.supports?(:trace)).to be(false)
      end
    end

    it "treats an unreadable ptrace_scope file as a gap and a missing one as allowed" do
      allow(File).to receive(:read).with(described_class::PTRACE_SCOPE).and_raise(Errno::EACCES)
      expect(described_class.new(fence: "/x/lain-fence", bwrap:, runner:, journal:).supports?(:trace)).to be(false)

      allow(File).to receive(:read).with(described_class::PTRACE_SCOPE).and_raise(Errno::ENOENT)
      expect(described_class.new(fence: "/x/lain-fence", bwrap:, runner:, journal: []).supports?(:trace)).to be(true)
    end

    it "judges the trace by an actual traced run of the true on PATH" do
      Dir.mktmpdir("lain-probe-true") do |dir|
        File.write(File.join(dir, "true"), "#!/bin/sh\n")
        File.chmod(0o755, File.join(dir, "true"))
        seen = []
        spy = lambda { |argv|
          seen << argv
          answers.fetch(File.basename(argv.first))
        }
        described_class.new(fence: "/x/lain-fence", bwrap:, env: { "PATH" => ":#{dir}" }, runner: spy,
                            ptrace_scope: scope, journal:).supports?(:trace)

        expect(seen).to include([bwrap.strace, "-f", "-o", "/dev/null", File.join(dir, "true")])
      end
    end

    it "names the fence path in the reason when the fence cannot start" do
      starter = lambda { |argv|
        raise Errno::ENOENT, argv.first if argv.first == "/x/lain-fence"

        ["", true]
      }
      described_class.new(fence: "/x/lain-fence", bwrap:, runner: starter, ptrace_scope: scope, journal:)
                     .supports?(:landlock)

      expect(journal.first.provider).to include("cannot start /x/lain-fence")
    end

    it "names the fence path and ABI 0 in the reason when Landlock is off" do
      answers["lain-fence"] = ['{"abi":0}', true]
      probe.supports?(:landlock)

      expect(journal.first.provider).to include("/x/lain-fence reports ABI 0")
    end

    it "ignores an ABI printed by a fence that exited non-zero" do
      answers["lain-fence"] = ['{"abi":9}', false]
      subject = probe

      expect([subject.supports?(:landlock), subject.abi]).to eq([false, 0])
      expect(journal.first.provider).to include("exited with failure")
    end

    it "offers the reaper when the fence's status says it reaps" do
      expect(probe.supports?(:reap)).to be(true)
      expect(journal).to be_empty
    end

    # An older fence rejects --reap-only and exits 125, which would fail every unconfined call.
    it "journals a fence whose status says nothing of reaping as unable to reap, once" do
      answers["lain-fence"] = ['{"abi":9,"rights":{},"skipped":[]}', true]
      subject = probe

      expect([subject.supports?(:reap), subject.supports?(:reap), subject.supports?(:landlock)])
        .to eq([false, false, true])
      expect(journal.map(&:capability)).to eq([:reap])
      expect(journal.first.provider).to include("/x/lain-fence cannot reap")
    end

    it "offers a private network when the fence's status names private_net, whatever its value outside one" do
      answers["lain-fence"] = ['{"abi":9,"private_net":false,"reap":true,"rights":{},"skipped":[]}', true]

      expect(probe.supports?(:private_net)).to be(true)
      expect(journal).to be_empty
    end

    # A box whose bwrap makes a user namespace but not a network one would abort every workspace call.
    it "journals a bwrap that cannot unshare a network as giving no private network, naming bwrap" do
      answers["lain-fence"] = ['{"abi":9,"private_net":false,"reap":true,"rights":{},"skipped":[]}', true]
      netless = lambda do |argv|
        argv.include?("--unshare-net") ? ["bwrap: No permissions to create new namespace", false] : runner.call(argv)
      end
      subject = described_class.new(fence: "/x/lain-fence", bwrap:, runner: netless, ptrace_scope: scope, journal:)

      expect([subject.supports?(:private_net), subject.supports?(:bwrap)]).to eq([false, true])
      expect(journal.map(&:capability)).to eq([:private_net])
      expect(journal.first.provider).to include("bwrap cannot build a private-network namespace")
    end

    # A fence built before the flag rejects it and exits 125, which would fail every workspace call.
    it "journals a fence whose status says nothing of a private network as unable to give one, once" do
      subject = probe

      expect([subject.supports?(:private_net), subject.supports?(:private_net), subject.supports?(:landlock)])
        .to eq([false, false, true])
      expect(journal.map(&:capability)).to eq([:private_net])
      expect(journal.first.provider).to include("/x/lain-fence cannot give a call a private network")
    end

    it "asks bwrap for a network namespace once, and journals once, when two readers ask at the same moment" do
      answers["lain-fence"] = ['{"abi":9,"private_net":false,"reap":true,"rights":{},"skipped":[]}', true]
      spawned = Queue.new
      slow = lambda do |argv|
        return runner.call(argv) unless argv.include?("--unshare-net")

        spawned << argv
        sleep 0.05
        ["bwrap: No permissions to create new namespace", false]
      end
      subject = described_class.new(fence: "/x/lain-fence", bwrap:, runner: slow, ptrace_scope: scope, journal:)
      subject.fence_gap

      answers = Array.new(8) { Thread.new { subject.supports?(:private_net) } }.map(&:value)

      expect([answers.uniq, spawned.size, journal.map(&:capability)]).to eq([[false], 1, [:private_net]])
    end

    it "exposes the ABI the fence reported" do
      expect(probe.abi).to eq(9)
    end
  end
end
