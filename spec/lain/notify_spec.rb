# frozen_string_literal: true

require "stringio"

# I5: a desktop-notification surface over dunstify, joining the SAME
# Approval::Queue surface shape Frontend::ApprovalPolicy (I4) does --
# #watch(queue) sweeps the PARKED set (T15: it never consumes the arrival
# queue, which belongs to the human's surface), #decide answers one Pending. dunstify with
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

  # Two gated calls parked on one queue, as a turn making two tier-3 tool calls
  # produces them -- handed back so a caller's ensure can stop both.
  def gated_pair(task, queue)
    Array.new(2) do |n|
      task.async { queue.call(Lain::Effect::ToolCall.new(tool_use_id: "tu_#{n}", name: "bash", input: {}), nil) }
    end
  end

  # dunstify BLOCKS its own process until a human clicks, dismisses, or its own
  # `-t` window expires, so a pending this surface is showing is a pending it
  # HOLDS -- which is what made the stolen one unanswerable for the whole
  # window rather than merely late. The latch reproduces the hold; closing it
  # releases the waiting Thread at once.
  def holding_shell_out_class
    Class.new do
      def initialize(*, latch:, **)
        super()
        @latch = latch
      end

      def run_command = tap { @latch.pop }
      def stdout = ""
    end
  end

  def holding_dunstify(latch)
    klass = holding_shell_out_class
    ->(*, **) { klass.new(latch:) }
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

    it "sweeps the parked set and answers what it finds (the surface loop)" do
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

    # T15 / manual-QA round 4, F18. This surface OBSERVES the parked set; it
    # must never drain {Approval::Queue#dequeue}, which delivers each arrival
    # to exactly one caller and belongs to the human's terminal surface
    # (`queue_surface.rb`'s two-surface discipline). It used to drain it, and
    # from the second gated call of a turn onward it took every one -- the TTY
    # prompt leaves the queue to ask a person while this one re-parks at once,
    # so this one sat ahead in the waiter FIFO forever. The counterfactual is
    # the whole example: a sibling consumer that gets NOTHING is the defect.
    it "leaves every arrival on the queue for the human's surface to consume" do
      held = Thread::Queue.new
      queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: StringIO.new), timeout: 2.0)
      consumed = []

      Sync do |task|
        # First in the waiter FIFO on purpose: the claim is that this surface
        # never takes an arrival, whoever parks first.
        running = [task.async { described_class.new(shell_out_factory: holding_dunstify(held)).watch(queue) },
                   *gated_pair(task, queue)]
        reader = task.async { 2.times { consumed << queue.dequeue.tool_use_id } }
        running << reader
        task.with_timeout(1) { reader.wait }
      rescue Async::TimeoutError
        nil # the assertion below names what was missed; a hang would not
      ensure
        running.each { |fiber| fiber&.stop }
        held.close
      end

      expect(consumed).to contain_exactly("tu_0", "tu_1")
    end

    # T4, from manual-QA round 5 (F24). A pending gets its notification when it
    # PARKS, not when the previous one is answered. `dunstify -A` blocks its own
    # process for the whole of the queue's 300s window, so a surface that waited
    # inline showed the human exactly ONE approval per window however many calls
    # a turn gated -- and the second notification arrived, if it ever did, after
    # the human had already answered somewhere else.
    #
    # Every example here answers its notifications BY HAND, through a
    # rendezvous: `Thread::Queue#pop(timeout:)`, which parks the FIBER under the
    # reactor and blocks plainly without one (measured, both). None of them
    # sleeps for a duration and then asserts. A sleep in a concurrency spec
    # asserts that a race is usually won, which is the one thing these examples
    # exist to refuse.
    describe "several approvals parked at once" do
      def gated_call(command)
        Lain::Effect::ToolCall.new(tool_use_id: command, name: "bash", input: { "command" => command })
      end

      # A pending outside any queue. {Notify#sweep}'s parked set is any
      # Enumerable of them ({Approval::Queue} is one, and the example that has
      # to speak about consumption uses the real thing) -- and an Array is what
      # lets an example drive one deterministic pass.
      def parked(command)
        Lain::Approval::Queue::Pending.new(effect: gated_call(command), requester: "agent", clock: -> { 0.0 })
      end

      # A Pending that records every decision attempted on it: the surface, the
      # verdict, whether that answer WON, and the Thread and Fiber it was
      # answered from. The real class subclassed rather than a double, because
      # what these examples are about is exactly what
      # {Approval::Queue::Pending#decide} does with a second answer.
      def spying_pending(command, attempts)
        Class.new(Lain::Approval::Queue::Pending) do
          define_method(:decide) do |verdict, surface:|
            super(verdict, surface:).tap do |won|
              attempts << { surface:, verdict:, won:, thread: Thread.current, fiber: Fiber.current }
            end
          end
        end.new(effect: gated_call(command), requester: "agent", clock: -> { 0.0 })
      end

      # dunstify, driven by hand. Each invocation announces its own argv on
      # `raised` and then blocks ITS OWN Thread on a reply queue of its own
      # until the example says what that notification reported -- so answering
      # one says nothing whatever about any other, which is the property these
      # examples measure. Keyed by the command the pending would run, because
      # the argv is the only thing that tells two notifications apart.
      def scripted_dunstify(*commands)
        raised = Thread::Queue.new
        replies = commands.to_h { |command| [command, Thread::Queue.new] }
        [scripted_factory(scripted_shell_out_class, raised, replies), raised, replies]
      end

      # The same shape as `holding_shell_out_class` above, except that the queue
      # it blocks on is per-notification and carries the stdout to report.
      def scripted_shell_out_class
        Class.new do
          def initialize(reply:)
            super()
            @reply = reply
          end

          def run_command = tap { @answer = @reply.pop }
          def stdout = @answer.to_s
        end
      end

      def scripted_factory(shell_out, raised, replies)
        lambda do |*args, **|
          argv = args.join(" ")
          raised.push(argv)
          shell_out.new(reply: replies.fetch(replies.keys.find { |command| argv.include?(command) }))
        end
      end

      # The production loop, run for exactly as long as the example needs it:
      # {Notify#watch} sweeps at POLL_INTERVAL and drains whatever came back
      # since. `with_timeout` bounds it, so a surface that never applies a
      # verdict fails the example loudly instead of hanging it.
      def watching(pendings, factory)
        notifier = described_class.new(shell_out_factory: factory)
        Sync do |task|
          watcher = task.async do
            @watching_fiber = Fiber.current
            notifier.watch(pendings)
          end
          task.with_timeout(3) { yield(notifier) }
        ensure
          watcher&.stop
        end
      end

      # Park until the condition holds. The interval is only how often it is
      # re-asked; nothing any example asserts depends on its value, which is
      # what keeps this from being "the race is usually won" spelled as a sleep.
      def until_true(interval: 0.005)
        Async::Task.current.sleep(interval) until yield
      end

      # The first half of what T4 buys, and the half that cannot be seen with
      # one gated call -- which is exactly why a green suite shipped the
      # serialised version. Driven through the REAL queue, because "consumed
      # neither" is a claim about {Approval::Queue#dequeue} and nothing else can
      # make it.
      it "raises the second notification while the first is still unanswered, and consumes neither" do
        factory, raised, replies = scripted_dunstify("one", "two")
        queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: StringIO.new), timeout: 2.0)
        consumed = []
        shown = []

        Sync do |task|
          gated = %w[one two].map { |command| task.async { queue.call(gated_call(command), nil) } }
          reader = task.async { 2.times { consumed << queue.dequeue.input.fetch("command") } }

          described_class.new(shell_out_factory: factory).sweep(queue)
          shown = [raised.pop(timeout: 2), raised.pop(timeout: 2)]
        ensure
          replies.each_value { |reply| reply.push("2") }
          [*gated, reader].each { |fiber| fiber&.stop }
        end

        expect(shown.compact.size).to eq(2)
        expect(shown.join(" ")).to include("one").and include("two")
        expect(consumed).to contain_exactly("one", "two")
      end

      it "applies the answer to the notification that returned, and leaves the other undecided" do
        factory, raised, replies = scripted_dunstify("one", "two")
        first, second = %w[one two].map { |command| parked(command) }
        shown = []

        watching([first, second], factory) do
          shown = Array.new(2) { raised.pop(timeout: 2) }
          replies.fetch("one").push("approve")
          first.await
        end

        expect(shown.compact.size).to eq(2)
        expect(first).to have_attributes(decision: :approve, surface: "dunst")
        expect(second.decided?).to be(false)
      ensure
        # The second notification is deliberately never answered, which is the
        # whole assertion -- so its Thread would otherwise sit on `@reply.pop`
        # for the rest of the worker's life. Every sibling example closes its
        # replies for the same reason.
        replies.each_value { |reply| reply.push("2") }
      end

      # This example REPLACES the single-flight pin that stood here, and the
      # replacement is deliberately weaker in one exact place. The old one
      # worked because its factory settled the sibling's pending WHILE the first
      # notification blocked the sweep; once notifications are concurrent the
      # second popup is already dispatched by then, so "a pending a sibling
      # settled gets no popup" is unattainable in the raise-then-settle window
      # and cannot honestly be asserted. {Notify#notify_about}'s re-check
      # degrades from a narrowing to a guard that only a set settling mid-`select`
      # can even reach, and both are witnessed by the two examples below.
      #
      # What IS still true, and is what a human actually depends on, is the race
      # OUTCOME: the sibling's decision stands, this surface signs nothing over
      # it, and nothing raises. `won:` is the mechanical statement --
      # {Approval::Queue::Pending#decide}'s Boolean is the only honest source
      # for whether an answer landed ({Frontend::Neovim::ApprovalView#decide}
      # argues the same, at more length).
      it "loses cleanly to a sibling that settled a pending while its notification was in flight" do
        attempts = []
        factory, raised, replies = scripted_dunstify("one", "two")
        first = parked("one")
        second = spying_pending("two", attempts)

        watching([first, second], factory) do
          2.times { raised.pop(timeout: 2) }
          second.deny(surface: "tty")
          replies.each_value { |reply| reply.push("approve") }
          until_true { attempts.size == 2 }
        end

        expect(second).to have_attributes(decision: :deny, surface: "tty")
        expect(attempts.map { |attempt| attempt.values_at(:surface, :won) })
          .to eq([%w[tty].push(true), %w[dunst].push(false)])
      end

      # The card's central constraint, witnessed rather than asserted in prose.
      # {Approval::Queue::Pending}'s single-shot resolution is safe without a
      # lock "only because ... two FIBERS cannot both pass the guard" -- a fiber
      # argument, not a thread one -- and `Promise#resolve` reaches an
      # `Async::Condition` that resumes reactor-owned fibers, which is a
      # `FiberError` from a foreign thread. So the Thread runs the shellout and
      # nothing else, and the sweep applies the verdict.
      it "takes every decision on the watching fiber, never on the shellout's own thread" do
        attempts = []
        threads = Thread::Queue.new
        factory, raised, replies = scripted_dunstify("one")
        recording = lambda do |*args, **kwargs|
          threads.push(Thread.current)
          factory.call(*args, **kwargs)
        end
        approval = spying_pending("one", attempts)

        watching([approval], recording) do
          raised.pop(timeout: 2)
          replies.fetch("one").push("approve")
          approval.await
        end

        expect(approval.decision).to eq(:approve)
        expect(attempts.map { |attempt| attempt[:fiber] }).to eq([@watching_fiber])
        expect(attempts.map { |attempt| attempt[:thread] }).to eq([Thread.current])
        expect(threads.pop(timeout: 1)).not_to eq(Thread.current)
      end

      # Fail-closed, asked again of the DRAIN: the verdict now crosses back from
      # a Thread and is applied a sweep later, so none of these restates the
      # inline #decide examples above.
      [["a Deny click", "deny"], ["a dismissal close reason", "2"], ["nothing at all", ""]].each do |name, answer|
        it "denies with surface dunst when the notification reports #{name}" do
          factory, raised, replies = scripted_dunstify("one")
          approval = parked("one")

          watching([approval], factory) do
            raised.pop(timeout: 2)
            replies.fetch("one").push(answer)
            approval.await
          end

          expect(approval).to have_attributes(decision: :deny, surface: "dunst")
        end
      end

      it "denies with surface dunst when the shellout raises on its own thread" do
        approval = parked("one")
        failing = ->(*, **) { raise Errno::ENOENT, "dunstify" }

        watching([approval], failing) { approval.await }

        expect(approval).to have_attributes(decision: :deny, surface: "dunst")
      end

      # `@raised` still does its one job. It matters MORE now, not less: the
      # sweep no longer blocks, so a 50ms poll over a pending whose popup is
      # still up would raise a fresh `-u critical` notification twenty times a
      # second.
      it "asks about a pending once, however many sweeps run over it" do
        factory, raised, replies = scripted_dunstify("one")
        approval = parked("one")
        notifier = described_class.new(shell_out_factory: factory)

        3.times { notifier.sweep([approval]) }
        raised.pop(timeout: 2)

        expect(raised.pop(timeout: 0.2)).to be_nil
      ensure
        replies.fetch("one").push("2")
      end

      # The half of the old single-flight pin that SURVIVES: a pending a sibling
      # settled BEFORE the sweep began gets no popup at all. Named for the line
      # that actually does it -- {Notify#unraised?}, one frame earlier -- because
      # this never reaches {Notify#notify_about}'s own `decided?` guard and a
      # title claiming otherwise would send a reader to the wrong method.
      it "raises nothing for a pending a sibling had already settled before the sweep" do
        factory, raised, = scripted_dunstify("one")
        approval = parked("one")
        approval.deny(surface: "tty")

        described_class.new(shell_out_factory: factory).sweep([approval])

        expect(raised.pop(timeout: 0.2)).to be_nil
        expect(approval).to have_attributes(decision: :deny, surface: "tty")
      end

      # And this is the one that reaches {Notify#notify_about}'s `decided?`
      # guard, which is otherwise UNREACHABLE: nothing between {Notify#sweep}'s
      # `select` and the ask yields, so a set that settles as it is enumerated is
      # the only shape that can flip a pending in between. Contrived on purpose
      # -- the guard is kept for T4b, which puts a real yield point back when it
      # adds the withdrawal, and an untested guard is one that quietly stops
      # working before the card that needs it arrives.
      it "raises nothing for a pending that settles between the snapshot and the ask" do
        factory, raised, = scripted_dunstify("one")
        approval = parked("one")
        settling = Object.new
        settling.define_singleton_method(:select) do |&block|
          [approval].select(&block).tap { approval.deny(surface: "tty") }
        end

        described_class.new(shell_out_factory: factory).sweep(settling)

        expect(raised.pop(timeout: 0.2)).to be_nil
        expect(approval).to have_attributes(decision: :deny, surface: "tty")
      end
    end

    # {QueueSurface#swept}'s guard, and the reason it is not optional here any
    # more: post-T15 this surface raises the notification for EVERY approval, so
    # a sweep that raises and kills the fiber deletes desktop notification for
    # the rest of the session -- silently, with nothing but async's "Task may
    # have ended with unhandled exception" on a stderr nobody is reading. That
    # is the exact failure class this card exists to close.
    # The journal is a REAL Lain::Channel, not an Array standing in for one:
    # `Wiring` hands this surface the run's own channel, and "the record reaches
    # that channel" is the half that makes the guard WITNESSED rather than
    # merely present. A duck that had only ever met an Array would be a guard
    # nobody could prove had fired.
    it "survives a sweep that raises, journals the fault once, and keeps notifying" do
      journal = Lain::Channel.new
      failures = 0
      queue = Lain::Approval::Queue.new(journal: Lain::Journal.new(io: StringIO.new), timeout: 2.0)
      flaky = Object.new
      flaky.define_singleton_method(:each) do |&block|
        failures += 1
        raise "the parked list went away" if failures <= 3

        queue.each(&block)
      end
      flaky.define_singleton_method(:select) { |&block| enum_for(:each).select(&block) }
      factory, invocations = stub_dunstify(answer: "approve")

      Sync do |task|
        running = gated_pair(task, queue)
        watcher = task.async { described_class.new(shell_out_factory: factory, journal:).watch(flaky) }
        task.with_timeout(2) { task.async { Async::Task.current.sleep(0.4) }.wait }
      ensure
        [*running, watcher].each { |fiber| fiber&.stop }
      end

      faults = journal.drain
      expect(failures).to be > 3                                    # the fiber outlived the raise
      expect(invocations).not_to be_empty                           # and went on notifying
      expect(faults.map { |fault| fault["type"] })
        .to eq([Lain::Approval::QueueSurface::FAULT_TYPE]) # once, not once per 50ms poll
      expect(faults.first).to include("surface" => described_class::SURFACE,
                                      "error" => "RuntimeError: the parked list went away")
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
