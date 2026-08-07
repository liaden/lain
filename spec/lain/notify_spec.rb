# frozen_string_literal: true

require "stringio"

# I5: a desktop-notification surface over dunstify, joining the SAME
# Approval::Queue surface shape Frontend::ApprovalPolicy (I4) does --
# #watch(queue) parks on arrivals, #decide answers one Pending. dunstify with
# -A actions BLOCKS its own process until the human picks a button, dismisses,
# or its own -t window expires, so every real invocation runs on a dedicated
# Thread (see the class comment); the bridge back to the calling fiber is a
# Thread::Queue#pop, which Fiber::SchedulerInterface's block/unblock hooks
# park as a FIBER wait under `async`, never an OS-thread-wide block.
RSpec.describe Lain::Notify do
  let(:effect) { Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { command: "rm -rf /tmp/x" }) }

  def pending
    Lain::Approval::Queue::Pending.new(effect:, requester: "agent", clock: -> { 0.0 })
  end

  # The queue's window must govern, never a surface's -- a surface backstop
  # shorter than the queue's own timeout would deny the shared Pending on the
  # surface's clock and journal that denial as surface: "dunst" with a
  # latency that measures nothing real (a panel-ruled defect, fixed by
  # deriving DEFAULT_TIMEOUT_MS from Approval::Queue::DEFAULT_TIMEOUT rather
  # than copying its value). This pins the inequality so the two constants
  # can never drift apart silently again.
  it "never lets its own default expiry precede the queue's own timeout window" do
    expect(described_class::DEFAULT_TIMEOUT_MS).to be >= Lain::Approval::Queue::DEFAULT_TIMEOUT * 1000
  end

  # Stands in for Mixlib::ShellOut the same way Tools::Bash's own specs
  # double it (an anonymous Class.new, not a named constant -- Bash's own
  # bash_spec.rb avoids Lint/ConstantDefinitionInBlock the same way): records
  # the argv it was built with, answers a canned stdout for #run_command to
  # have "produced". No real process ever runs.
  def fake_shell_out_class
    Class.new do
      attr_reader :argv

      def initialize(*argv, answer:, **)
        @argv = argv
        @answer = answer
      end

      def run_command = self
      def stdout = @answer
    end
  end

  def stub_dunstify(answer:)
    invocations = []
    fake_shell_out = fake_shell_out_class
    factory = lambda do |*args, **_kwargs|
      invocations << args
      fake_shell_out.new(*args, answer:)
    end
    [factory, invocations]
  end

  describe "an approval notifies with buttons" do
    it "fires a notification carrying approve/deny actions" do
      factory, invocations = stub_dunstify(answer: "approve")

      described_class.new(shell_out_factory: factory).decide(pending)

      args = invocations.first
      expect(args).to include("-A", "approve,Approve").and include("-A", "deny,Deny")
    end

    it "names the tool and its input in the notification body" do
      factory, invocations = stub_dunstify(answer: "approve")

      described_class.new(shell_out_factory: factory).decide(pending)

      expect(invocations.first.join(" ")).to include("bash").and include("rm -rf /tmp/x")
    end

    # T16, and the review round's own correction: this surface DECIDES. A click
    # on Approve signs a full approval as surface "dunst", racing the TTY prompt
    # and the editor's list -- so it is the third deciding surface and it says
    # the same sentence they do.
    describe "a pending whose approval would release sensitive regions" do
      let(:secret) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }
      let(:regions) { Lain::Sensitivity::Regions.detect("API_KEY=#{secret}\n") }

      def notified(path: "/repo/.env", regions: self.regions)
        factory, invocations = stub_dunstify(answer: "deny")
        outstanding = Lain::Approval::Queue::Outstanding.new(path:, regions:)
        described_class.new(shell_out_factory: factory)
                       .decide(Lain::Approval::Queue::Pending.new(effect:, requester: "agent",
                                                                  clock: -> { 0.0 }, outstanding:))
        invocations.first
      end

      it "warns on the notification, in the terminal prompt's own words" do
        expect(notified.join(" ")).to include("1 sensitive region outstanding")
      end

      it "names the file, so a click is not blind" do
        expect(notified.join(" ")).to include("/repo/.env")
      end

      it "puts none of the regions' bytes on the desktop" do
        expect(notified.join(" ")).not_to include(secret)
      end

      it "leaves an ordinary approval's notification unwarned" do
        factory, invocations = stub_dunstify(answer: "deny")

        described_class.new(shell_out_factory: factory).decide(pending)

        expect(invocations.first.join(" ")).not_to include("outstanding")
      end

      # dunst renders Pango markup, so `<` and `&` are markup on this surface
      # and nowhere else -- and `inspect`, which the body has always used,
      # escapes neither. A path is model-influenced, so a crafted one could
      # otherwise re-word the question a click answers.
      it "escapes markup a crafted path would otherwise inject" do
        summary = notified(path: "/repo/<b>SAFE</b>&.env").find { |arg| arg.include?("outstanding") }

        expect(summary).to include("&lt;b&gt;SAFE&lt;/b&gt;&amp;")
        expect(summary).not_to include("<b>")
      end

      # The pre-existing half of the same hole, closed in the same commit: the
      # body has carried unescaped `input.inspect` since I5.
      it "escapes markup in the input body too" do
        crafted = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { command: "<i>ls</i> & go" })
        factory, invocations = stub_dunstify(answer: "deny")

        described_class.new(shell_out_factory: factory)
                       .decide(Lain::Approval::Queue::Pending.new(effect: crafted, requester: "agent",
                                                                  clock: -> { 0.0 }))

        expect(invocations.first.join(" ")).to include("&lt;i&gt;ls&lt;/i&gt; &amp; go")
        expect(invocations.first.join(" ")).not_to include("<i>")
      end
    end

    it "approves when the human clicks Approve" do
      factory, = stub_dunstify(answer: "approve")
      approval = pending

      described_class.new(shell_out_factory: factory).decide(approval)

      expect(approval).to have_attributes(decision: :approve, surface: "dunst")
    end

    it "denies when the human clicks Deny" do
      factory, = stub_dunstify(answer: "deny")
      approval = pending

      described_class.new(shell_out_factory: factory).decide(approval)

      expect(approval).to have_attributes(decision: :deny, surface: "dunst")
    end

    # dunstify prints a numeric close-reason code (1=expired, 2=dismissed by
    # the user, 3=closed via the API, 4=undefined) when no action was chosen --
    # never one of our own action identifiers, since neither is numeric.
    %w[1 2 3 4].each do |close_reason|
      it "fails closed (denies) on the real dismissal/timeout close reason #{close_reason.inspect}" do
        factory, = stub_dunstify(answer: close_reason)
        approval = pending

        described_class.new(shell_out_factory: factory).decide(approval)

        expect(approval.decision).to eq(:deny)
      end
    end

    it "fails closed on empty or garbage stdout, never raising" do
      factory, = stub_dunstify(answer: "")
      approval = pending

      described_class.new(shell_out_factory: factory).decide(approval)

      expect(approval.decision).to eq(:deny)
    end

    it "fails closed when the shellout itself raises" do
      failing_factory = ->(*, **) { raise Errno::ENOENT, "dunstify" }
      approval = pending

      described_class.new(shell_out_factory: failing_factory).decide(approval)

      expect(approval.decision).to eq(:deny)
    end

    it "is a no-op on a pending another surface already decided" do
      factory, = stub_dunstify(answer: "approve")
      approval = pending
      approval.deny(surface: "tty")

      expect(described_class.new(shell_out_factory: factory).decide(approval)).to be(false)
      expect(approval).to have_attributes(decision: :deny, surface: "tty")
    end

    it "parks on the queue and answers arrivals (the surface loop)" do
      factory, = stub_dunstify(answer: "approve")
      queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: StringIO.new))
      notifier = described_class.new(shell_out_factory: factory)

      Sync do |task|
        run = task.async { queue.call(effect, nil) }
        watcher = task.async { notifier.watch(queue) }

        expect(run.wait).to be(true)
      ensure
        watcher&.stop
      end
    end

    it "runs the blocking dunstify wait off the reactor fiber, not on it" do
      slow_shell_out = Class.new do
        def initialize(*) = nil
        def run_command = sleep(0.2) && self
        def stdout = "approve"
      end
      factory = ->(*, **) { slow_shell_out.new }
      approval = pending
      notifier = described_class.new(shell_out_factory: factory)
      ticks = 0

      Sync do |task|
        ticker = task.async do
          loop do
            sleep(0.02)
            ticks += 1
          end
        end
        notifier.decide(approval)
      ensure
        ticker&.stop
      end

      expect(ticks).to be >= 3
      expect(approval.decision).to eq(:approve)
    end
  end

  describe "a question notifies" do
    it "names the asking agent, with no action buttons -- answering happens at a real surface" do
      factory, invocations = stub_dunstify(answer: "")

      described_class.new(shell_out_factory: factory).question(agent: "lain", text: "which port?")

      args = invocations.first
      expect(args.join(" ")).to include("lain").and include("which port?")
      expect(args).not_to include("-A")
    end

    it "returns nil (fire-and-forget, nothing to decide)" do
      factory, = stub_dunstify(answer: "")

      result = described_class.new(shell_out_factory: factory).question(agent: "lain", text: "which port?")

      expect(result).to be_nil
    end
  end

  # CONSENT, then capability -- in that order, and the order is the whole
  # point. `dunstify` on PATH says the desktop CAN be reached; it never says
  # this process MAY reach it, and every spec, probe and subagent in this
  # repository runs on the SAME machine, with the same PATH, as the human whose
  # screen it would interrupt. On 2026-08-05 nine real notifications reached a
  # working human that way, fired by agents through
  # `CLI::Wiring#wire_agent`'s then-unconditional `.for`. So the real adapter is
  # opt-in: a caller that owns the human's attention says so in as many words,
  # and PATH is only the second question.
  describe ".for" do
    # LAIN_DESKTOP is deleted around the caller-decides examples so they read
    # the SUBJECT's default rather than whatever the human running the suite
    # happens to export -- these are exactly the examples that env var overrides.
    def unconsented(**) = with_env("LAIN_DESKTOP" => nil) { described_class.for(**) }

    it "answers Null when nobody consented, even with the command right there on PATH" do
      expect(unconsented(command: "ls")).to be_a(described_class::Null)
    end

    it "builds the real adapter for a caller that consents, when the command resolves on PATH" do
      expect(unconsented(command: "ls", desktop: true)).to be_a(described_class)
    end

    it "answers Null when a consenting caller's command is absent from PATH" do
      expect(unconsented(command: "no-such-binary-xyz", desktop: true)).to be_a(described_class::Null)
    end

    # The env var is the machine's last word in BOTH directions, and one
    # spelling for both: `LAIN_DESKTOP=1` is what the `:desktop` seam at the
    # foot of this file already uses to mean "this shell may reach the real
    # desktop", and `LAIN_DESKTOP=0` is how an agent driving the real `lain
    # chat` silences a CLI whose flag defaults to on.
    it "lets LAIN_DESKTOP=1 turn a non-consenting caller's notifier real" do
      with_env("LAIN_DESKTOP" => "1") do
        expect(described_class.for(command: "ls")).to be_a(described_class)
      end
    end

    it "lets LAIN_DESKTOP=0 silence a consenting caller" do
      with_env("LAIN_DESKTOP" => "0") do
        expect(described_class.for(command: "ls", desktop: true)).to be_a(described_class::Null)
      end
    end

    it "leaves the caller's own answer standing for any other LAIN_DESKTOP value" do
      with_env("LAIN_DESKTOP" => "true") do
        expect(described_class.for(command: "ls")).to be_a(described_class::Null)
        expect(described_class.for(command: "ls", desktop: true)).to be_a(described_class)
      end
    end
  end

  describe Lain::Notify::Null do
    it "swallows an approval decision, denying it fail-closed (nobody is watching)" do
      approval = pending

      described_class.new.decide(approval)

      expect(approval.decision).to eq(:deny)
    end

    it "never touches the queue when watching, so another surface still decides it" do
      queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: StringIO.new))

      Sync do |task|
        watcher = task.async { described_class.new.watch(queue) }
        run = task.async { queue.call(effect, nil) }
        tty = task.async { Lain::Frontend::ApprovalPolicy.new(reader: ->(_prompt) { "y\n" }).watch(queue) }

        expect(run.wait).to be(true)
      ensure
        watcher&.stop
        tty&.stop
      end
    end

    it "swallows a question notification" do
      expect(described_class.new.question(agent: "lain", text: "which port?")).to be_nil
    end
  end

  # LAIN_DESKTOP=1 bundle exec rspec spec/lain/notify_spec.rb -- drives a real
  # dunstify process against this machine's real dunst (verified present:
  # `dunstify -c` advertises the `actions` capability). Skipped, not run, by
  # default: this is a spec-suite property test against the local desktop
  # environment, not against lain, the same posture :nvim/:ollama take for
  # their own real binaries/servers.
  describe "against a real dunstify", :desktop do
    it "fires a real notification and fails closed when nobody answers before it expires" do
      skip("Set LAIN_DESKTOP=1 to run against a real dunstify") unless ENV["LAIN_DESKTOP"] == "1"

      notifier = described_class.for(timeout_ms: 1_200)
      skip("dunstify not found on PATH") unless notifier.is_a?(described_class)

      approval = pending
      notifier.decide(approval)

      expect(approval.decision).to eq(:deny)
    end
  end
end
