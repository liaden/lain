# frozen_string_literal: true

RSpec.describe Lain::Confine::Probe do
  let(:journal) { [] }
  let(:answers) do
    { "bwrap" => ["", true], "lain-fence" => ["{\"abi\":9,\"rights\":{},\"skipped\":[]}\n", true],
      "strace" => ["strace 6.1", true] }
  end
  let(:runner) { ->(argv) { answers.fetch(File.basename(argv.first)) } }
  let(:scope) { -> { "1\n" } }

  def probe
    described_class.new(fence: "/x/lain-fence", runner:, ptrace_scope: scope, journal:)
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
        refused = described_class.new(fence: "/x/lain-fence", runner:, ptrace_scope: -> { value }, journal: j)
        expect([refused.supports?(:trace), j.map(&:capability)]).to eq([false, [:trace]])
      end
    end

    it "allows the trace when the yama file is absent" do
      absent = described_class.new(fence: "/x/lain-fence", runner:, ptrace_scope: -> {}, journal:)
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
      broken = described_class.new(fence: "/x/lain-fence", runner: lambda { |argv|
        raise Errno::ENOENT, argv.first if File.basename(argv.first) == "bwrap"

        File.basename(argv.first) == "lain-fence" ? ["", true] : ["ok", true]
      }, ptrace_scope: scope, journal:)

      expect([broken.supports?(:bwrap), broken.supports?(:landlock)]).to eq([false, false])
    end

    it "raises on a layer it does not know" do
      expect { probe.supports?(:gvisor) }.to raise_error(KeyError)
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
      refused = described_class.new(fence: "/x/lain-fence", ptrace_scope: scope, journal:,
                                    runner: lambda { |argv|
                                      argv.first == "/x/lain-fence" ? raise(Errno::ENOENT) : ["", true]
                                    })

      expect([refused.fence_unstartable?, probe.fence_unstartable?]).to eq([true, false])
    end
  end

  describe "production construction" do
    it "probes the real box without a double" do
      real = described_class.new(fence: "/nonexistent/lain-fence", journal:)

      expect(real.supports?(:landlock)).to be(false)
      expect(journal.map(&:capability)).to include(:landlock)
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
        unreadable = described_class.new(fence: "/x/lain-fence", runner:, ptrace_scope: -> { text }, journal:)
        expect(unreadable.supports?(:trace)).to be(false)
      end
    end

    it "treats an unreadable ptrace_scope file as a gap and a missing one as allowed" do
      allow(File).to receive(:read).with(described_class::PTRACE_SCOPE).and_raise(Errno::EACCES)
      expect(described_class.new(fence: "/x/lain-fence", runner:, journal:).supports?(:trace)).to be(false)

      allow(File).to receive(:read).with(described_class::PTRACE_SCOPE).and_raise(Errno::ENOENT)
      expect(described_class.new(fence: "/x/lain-fence", runner:, journal: []).supports?(:trace)).to be(true)
    end

    it "judges the trace by an actual traced run" do
      seen = []
      spy = lambda { |argv|
        seen << argv
        answers.fetch(File.basename(argv.first))
      }
      described_class.new(fence: "/x/lain-fence", runner: spy, ptrace_scope: scope, journal:).supports?(:trace)

      expect(seen).to include(%w[strace -f -o /dev/null true])
    end

    it "names the fence path in the reason when the fence cannot start" do
      starter = lambda { |argv|
        raise Errno::ENOENT, argv.first if argv.first == "/x/lain-fence"

        ["", true]
      }
      described_class.new(fence: "/x/lain-fence", runner: starter, ptrace_scope: scope, journal:).supports?(:landlock)

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

    it "exposes the ABI the fence reported" do
      expect(probe.abi).to eq(9)
    end
  end
end
