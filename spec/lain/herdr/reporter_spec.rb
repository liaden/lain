# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "shellwords"
require "stringio"
require "timeout"
require "tmpdir"

RSpec.describe Lain::Herdr::Reporter do
  telemetry = Lain::Telemetry
  child = "blake3:#{"c" * 64}"
  other = "blake3:#{"d" * 64}"
  digest = ->(letter) { "blake3:#{letter * 64}" }

  request = telemetry::RequestSent.new(digest: digest.call("e"), payload: {}, stream: true, extra: {},
                                       prefix_digests: nil, prefix_chain_version: nil, requester: nil)
  settled = telemetry::AskSettled.new(head: digest.call("f"), stop_reason: "end_turn", turns: 1, seconds: 1.0)
  spawn_of = lambda do |id|
    telemetry::Message.new(digest: id, kind: :spawn, from: "main", to: "reviewer",
                           payload: { "role" => "reviewer", "lifecycle" => "launched" },
                           causal_parents: [], correlation: nil)
  end
  completion = lambda do |id|
    telemetry::Message.new(digest: digest.call("9"), kind: :message, from: "reviewer", to: "main",
                           payload: { "lifecycle" => "stopped" }, causal_parents: [id], correlation: nil)
  end
  wait_of = lambda do |id, spawn, summary|
    telemetry::AwaitingHuman.new(kind: "approval", ref: id, summary:, requester: "reviewer", tool: "bash",
                                 tool_use_id: id, spawn:)
  end
  decided = ->(id) { { "type" => "approval_decision", "tool_use_id" => id } }

  # main works, a child blocks on approval of bash, and the approval is the last thing to close.
  let(:blocks_then_done) do
    [request, spawn_of.call(child), wait_of.call("call_1", child, "bash: curl -H 'x: #{token}'"),
     completion.call(child), settled, decided.call("call_1")]
  end
  let(:token) { "ghp_#{"a1B2" * 9}" }

  let(:dir) { @dir ||= File.realpath(Dir.mktmpdir("herdr-reporter")) }
  let(:calls_path) { File.join(dir, "calls") }
  let(:socket) { File.join(dir, "herdr.sock") }
  let(:notes) { StringIO.new }
  let(:clock) { instance_double(Lain::RunClock, elapsed: 0.0) }

  after { FileUtils.remove_entry(@dir) if @dir }

  # Each call is 1 line of unit-separated words, so a word with a space survives. `agent get`
  # answers agent_not_found as herdr 0.9.5 does; a report fails on each count listed in `failing`.
  def stub_herdr(holder: nil, failing: [], delay: 0)
    path = File.join(dir, "herdr")
    reply = holder ? JSON.generate("result" => { "type" => "agent_info", "agent" => { "agent" => holder } }) : nil
    File.write(path, <<~SH, perm: 0o755)
      #!/bin/sh
      { printf '%s\\037' "$@"; printf 'socket=%s\\n' "$HERDR_SOCKET_PATH"; } >> #{calls_path.shellescape}
      if [ "$1" = agent ]; then
        #{reply ? "printf '%s\\n' #{reply.shellescape}; exit 0" : "echo '{\"error\":{\"code\":\"agent_not_found\"}}' >&2; exit 1"}
      fi
      count=$(( $(cat #{File.join(dir, "count").shellescape} 2>/dev/null || echo 0) + 1 ))
      echo "$count" > #{File.join(dir, "count").shellescape}
      sleep #{delay}
      case " #{failing.join(" ")} " in *" $count "*) exit 1 ;; esac
      exit 0
    SH
    path
  end

  def calls
    return [] unless File.exist?(calls_path)

    File.readlines(calls_path, chomp: true).map { |line| line.split("\x1f")[0..-2] }
  end

  def reports = calls.select { _1.first(2) == %w[pane report-agent] }

  def flag(call, name) = call.index(name)&.then { call[_1 + 1] }

  def resume_of(call) = call.include?("--") ? call[(call.index("--") + 1)..] : nil

  def target(pane: "w1:p7", via: :env, bin: stub_herdr)
    Lain::Herdr::Target.new(bin:, pane:, socket:, via:)
  end

  def fixed(*targets)
    answers = targets.dup
    Object.new.tap do |resolver|
      resolver.define_singleton_method(:current) do
        answers.size > 1 ? answers.shift : answers.first
      end
    end
  end

  def journal(path) = instance_double(Lain::CLI::Chronicle, journal_path: path)

  def reporter(resolver:, session: journal(File.join(dir, "s.ndjson")), root: dir, **)
    described_class.new(resolver:, session:, root:, notes:, **)
  end

  def run(subject, records)
    tracker = Lain::AgentStates::Tracker.new(clock:)
    tracker.on_change(&subject)
    records.each { tracker << _1 }
    subject.release
  end

  def messages = reports.map { [flag(_1, "--state"), flag(_1, "--message")] }

  describe "state changes" do
    it "reach herdr in order as working, blocked and idle, with rising seq, for lain's pane" do
      run(reporter(resolver: fixed(target)), blocks_then_done)

      expect(reports.map { flag(_1, "--state") }).to eq(%w[working blocked idle])
      expect(reports.map { _1[2] }.uniq).to eq(["w1:p7"])
      expect(reports.map { [flag(_1, "--source"), flag(_1, "--agent")] }.uniq).to eq([%w[lain lain]])
      seqs = reports.map { Integer(flag(_1, "--seq")) }
      expect(seqs.each_cons(2).all? { |before, after| after > before }).to be(true)
    end

    it "carries the wait's summary, masked, as the blocked call's message" do
      run(reporter(resolver: fixed(target)), blocks_then_done)

      message = flag(reports.find { flag(_1, "--state") == "blocked" }, "--message")
      expect(message).to start_with("bash: curl -H")
      expect(message).not_to include(token)
    end

    it "masks a secret-named environment value the wait's summary carries" do
      value = "opensesame-plain-words-42"
      with_env("LAIN_SPEC_REPORTER_TOKEN" => value) do
        run(reporter(resolver: fixed(target)), [wait_of.call("call_1", nil, "bash: echo #{value}")])
      end

      message = flag(reports.find { flag(_1, "--state") == "blocked" }, "--message")
      expect(message).to start_with("bash: echo")
      expect(message).not_to include(value)
    end

    it "sends the summary on 1 line, cut to the tmux message limit" do
      run(reporter(resolver: fixed(target)), [wait_of.call("call_1", nil, "bash: \e[31mred\nnext #{"x" * 300}")])

      message = flag(reports.last, "--message")
      expect([message.match?(/[[:cntrl:]]/), message.size]).to eq([false, 200])
    end

    it "drops the message once nothing is blocked" do
      run(reporter(resolver: fixed(target)), [request, wait_of.call("call_1", nil, "bash"), decided.call("call_1")])

      expect(messages).to eq([["working", nil], %w[blocked bash], ["working", nil]])
    end

    it "keeps seq rising across a restart of lain on the same pane" do
      run(reporter(resolver: fixed(target)), [request])
      run(reporter(resolver: fixed(target)), [request])

      seqs = calls.map { Integer(flag(_1, "--seq")) }
      expect(seqs.size).to eq(4)
      expect(seqs.each_cons(2).all? { |before, after| after > before }).to be(true)
    end

    it "sends nothing for a change that arrives after it released" do
      subject = reporter(resolver: fixed(target))
      run(subject, [request])
      blocked = Lain::Journal::Projection::AgentStates::Agent.new(id: "main", state: :blocked, what: "late")

      expect { subject.call(Lain::AgentStates::Tracker::Change.new(rollup: :blocked, agent: blocked, since: 0.0)) }
        .not_to raise_error
      expect(messages).to eq([["working", nil]])
    end

    it "notes a fault of its own rather than swallowing it" do
      broken = Object.new.tap { |resolver| resolver.define_singleton_method(:current) { raise "resolver broke" } }
      run(reporter(resolver: broken), [request])

      expect(notes.string).to match(/herdr: reporting failed.*resolver broke/)
    end

    it "masks a secret its own fault's message carries" do
      value = "opensesame-plain-words-42"
      broken = Object.new.tap { |resolver| resolver.define_singleton_method(:current) { raise "bad #{value}" } }
      with_env("LAIN_SPEC_REPORTER_TOKEN" => value) { run(reporter(resolver: broken), [request]) }

      expect(notes.string).to include("herdr: reporting failed")
      expect(notes.string).not_to include(value)
    end

    it "reaches herdr over the target's socket" do
      run(reporter(resolver: fixed(target)), blocks_then_done)

      expect(File.readlines(calls_path, chomp: true).map { _1.split("\x1f").last }.uniq).to eq(["socket=#{socket}"])
    end
  end

  describe "the resume command" do
    it "restarts a cockpit chat through lain up on its tmux session" do
      run(reporter(resolver: fixed(target(via: :cockpit)), session: journal("rel/s.ndjson"),
                   up_session: "S"), [request])

      expect(resume_of(reports.first))
        .to eq(["lain", "up", dir, "--session", "S", "--", "--resume", File.expand_path("rel/s.ndjson")])
    end

    it "restarts a chat in a plain herdr pane through lain chat" do
      run(reporter(resolver: fixed(target)), [request])

      expect(resume_of(reports.first)).to eq(["lain", "chat", "--resume", File.join(dir, "s.ndjson")])
    end

    it "is left out when the chat asks for none" do
      run(reporter(resolver: fixed(target), resume: false), [request])

      expect(reports.map { [flag(_1, "--state"), resume_of(_1)] }).to eq([["working", nil]])
    end

    it "is left out past the 8 KiB herdr accepts" do
      run(reporter(resolver: fixed(target(via: :cockpit)), root: "/#{"a" * 9000}", up_session: "S"), [request])

      expect(reports.map { [flag(_1, "--state"), resume_of(_1)] }).to eq([["working", nil]])
    end

    it "names the session file as it is at each report, since a promoted aside moves it" do
      moving = instance_double(Lain::CLI::Chronicle)
      allow(moving).to receive(:journal_path).and_return(File.join(dir, "aside.ndjson"), File.join(dir, "kept.ndjson"))
      run(reporter(resolver: fixed(target), session: moving), [request, wait_of.call("call_1", nil, "bash")])

      expect(reports.map { resume_of(_1).last }).to eq([File.join(dir, "aside.ndjson"), File.join(dir, "kept.ndjson")])
    end

    it "is left out for a root herdr would refuse, and the state still goes" do
      run(reporter(resolver: fixed(target(via: :cockpit)), root: File.join(dir, "it's"), up_session: "S"), [request])

      expect(reports.map { [flag(_1, "--state"), resume_of(_1)] }).to eq([["working", nil]])
    end
  end

  it "releases the old pane and resends the state when the resolver answers a new one" do
    old = target(pane: "w1:p3")
    run(reporter(resolver: fixed(old, old, target(pane: "w2:p1"))),
        [spawn_of.call(child), wait_of.call("call_1", child, "bash"), spawn_of.call(other)])

    pane_calls = calls.map { [*_1.first(3), flag(_1, "--state")] }
    expect(pane_calls).to eq([%w[pane report-agent w1:p3 working], %w[pane report-agent w1:p3 blocked],
                              ["pane", "release-agent", "w1:p3", nil], %w[pane report-agent w2:p1 blocked],
                              ["pane", "release-agent", "w2:p1", nil]])
    expect(calls.select { _1[1] == "release-agent" }.map { [flag(_1, "--source"), flag(_1, "--agent")] }.uniq)
      .to eq([%w[lain lain]])
  end

  it "releases its pane once when the session closes" do
    subject = reporter(resolver: fixed(target))
    run(subject, [request])
    subject.release

    expect(calls.count { _1.first(3) == %w[pane release-agent w1:p7] }).to eq(1)
  end

  it "sends nothing to a pane another agent holds" do
    bin = stub_herdr(holder: "claude")
    env = { "HERDR_ENV" => "1", "HERDR_PANE_ID" => "w1:p7", "HERDR_BIN_PATH" => bin, "HERDR_SOCKET_PATH" => socket }
    run(reporter(resolver: Lain::Herdr::Target::Resolver.new(env:, interactive: true)), blocks_then_done)

    expect(calls.map { _1.first(2) }).to eq([%w[agent get]])
  end

  it "reports display metadata to its pane" do
    subject = reporter(resolver: fixed(target))
    subject.metadata("lain_parked", "fix the flake")
    subject.release

    call = calls.find { _1.first(2) == %w[pane report-metadata] }
    expect([call[2], flag(call, "--source"),
            flag(call, "--token")]).to eq(["w1:p7", "lain", "lain_parked=fix the flake"])
  end

  it "masks a secret-named environment value in a metadata token's value" do
    value = "opensesame-plain-words-42"
    with_env("LAIN_SPEC_REPORTER_TOKEN" => value) do
      subject = reporter(resolver: fixed(target))
      subject.metadata("lain_parked", "echo #{value}")
      subject.release
    end

    sent = flag(calls.find { _1[1] == "report-metadata" }, "--token")
    expect(sent).to start_with("lain_parked=echo").and(satisfy { !_1.include?(value) })
  end

  it "answers the mask it reports through" do
    expect(reporter(resolver: fixed(target)).mask).to be(described_class::MASK)
    expect(reporter(resolver: fixed(target)).mask_with(:chat).mask).to eq(:chat)
  end

  it "clears a metadata token when the value is nil, and sends nothing else new" do
    subject = reporter(resolver: fixed(target))
    tracker = Lain::AgentStates::Tracker.new(clock:)
    tracker.on_change(&subject)
    tracker << request
    subject.metadata("lain_parked", "waiting on CI")
    subject.metadata("lain_parked", nil)
    subject.release

    expect(calls.map { _1.first(2) }.uniq).to eq([%w[pane report-agent], %w[pane report-metadata],
                                                  %w[pane release-agent]])
    set, cleared = calls.select { _1[1] == "report-metadata" }
    expect([flag(set, "--token"), flag(set, "--clear-token"), flag(cleared, "--clear-token"),
            flag(cleared, "--token")]).to eq(["lain_parked=waiting on CI", nil, "lain_parked", nil])
  end

  describe Lain::Herdr::Reporter::Null do
    it "answers the reporter's messages and does nothing" do
      expect(described_class.new.mask).to be(Lain::Herdr::Reporter::MASK)
      expect([described_class.new.metadata("t", "v"), described_class.new.release,
              described_class.new.call(nil), described_class.new.mask_with(:m).class]).to eq([nil, nil, nil,
                                                                                              described_class])
    end
  end

  describe Lain::Herdr::Reporter::CockpitSession do
    def answering(stdout, status: 0, asked: [])
      lambda do |*argv, **options|
        asked << [argv, options[:environment]]
        instance_double(Lain::Shell::Out, run_command: nil, stdout:, exitstatus: status)
      end
    end

    it "names the tmux session of the chat's pane" do
      asked = []
      env = { "TMUX" => "/tmp/tmux-1/default,1,0", "TMUX_PANE" => "%3" }

      expect(described_class.new(env:, shell_out: answering("S\n", asked:)).to_s).to eq("S")
      expect(asked).to eq([[%w[tmux display-message -p -t %3] + ["\#{session_name}"],
                            { "TMUX" => "/tmp/tmux-1/default,1,0" }]])
    end

    it "is empty outside tmux or when tmux fails" do
      failing = answering("", status: 1)

      expect([described_class.new(env: {}, shell_out: failing).to_s,
              described_class.new(env: { "TMUX_PANE" => "%3" }, shell_out: failing).to_s]).to eq(["", ""])
    end
  end

  describe "a herdr that is missing or failing" do
    it "notes once that reporting failed when the binary is missing, and the chat goes on" do
      run(reporter(resolver: fixed(target(bin: File.join(dir, "absent")))), blocks_then_done)

      expect(notes.string.lines.size).to eq(1)
      expect(notes.string).to match(/report.*failed/)
    end

    it "notes again only after a success has cleared the failure" do
      run(reporter(resolver: fixed(target(bin: stub_herdr(failing: [1, 2, 4])))), [request, spawn_of.call(child),
                                                                                   wait_of.call("c", child, "x"),
                                                                                   decided.call("c"), settled])

      expect(notes.string.lines.size).to eq(2)
    end

    it "gives up on a herdr that hangs, past its timeout" do
      stub_const("#{described_class}::TIMEOUT", 0.2)
      run(reporter(resolver: fixed(target(bin: stub_herdr(delay: 5)))), [request])

      expect(notes.string.lines.size).to eq(1)
    end
  end

  # ChatLaunch's own wiring of the resolver, with the chat behind it replaced by records.
  describe "a chat launch" do
    def journaling_wiring(records)
      lambda do |chronicle:, **|
        Object.new.tap do |wiring|
          wiring.define_singleton_method(:conductor) { nil }
          wiring.define_singleton_method(:run) do |**|
            chronicle.start(context: Lain::Context.new(model: "claude-opus-4-8", max_tokens: 16),
                            toolset: Lain::Toolset.new, sections: SessionSections.complete)
            records.each { _1.is_a?(Proc) ? _1.call(chronicle) : chronicle.instrumentation.journal << _1 }
          end
        end
      end
    end

    def launch_in_herdr(options, records)
      env = { "HERDR_ENV" => "1", "HERDR_PANE_ID" => "w1:p7", "HERDR_BIN_PATH" => stub_herdr,
              "HERDR_SOCKET_PATH" => socket }
      project = Lain::Project.new(root: dir, cwd: dir, kind: :project, detected_by: :flag)
      factories = { env:, wiring_factory: journaling_wiring(records), project_factory: -> { project },
                    gc_schedule_factory: ->(root:) { -> { root } } }
      launch = ChatLaunchProbe::Launch.new(ChatLaunchProbe::LAUNCH_DEFAULTS.merge(options), **factories)
      with_env("XDG_STATE_HOME" => File.join(dir, "state")) { launch.call { |_notice| nil } }
      launch
    end

    # Kept only once the first report is out, since the worker reads the path when it reports.
    def promote_after_a_report
      lambda do |chronicle|
        Timeout.timeout(10) { sleep 0.01 while reports.empty? }
        chronicle.promote!
      end
    end

    it "follows an aside's record to where keeping it moved the file" do
      launch = launch_in_herdr({ journal: true, btw: true },
                               [request, promote_after_a_report, wait_of.call("call_1", nil, "bash")])
      kept = File.expand_path(launch.chronicle.journal_path)

      paths = reports.map { resume_of(_1).last }
      expect(paths.size).to eq(2)
      expect(paths.first).not_to eq(kept)
      expect(paths.last).to eq(kept)
    end

    it "reports nothing for a non-interactive chat, whatever HERDR_* says" do
      launch_in_herdr({ journal: true, non_interactive: true, prompt: "go" }, [request, settled])

      expect(calls).to be_empty
    end
  end

  # A real `lain chat` in a child process: ChatLaunch, Wiring, the TTY and the approval queue, with only
  # the model replaced and herdr a stub on a temp path. stdin is the human: 2 prompts and the `y` for bash.
  describe "a chat in a herdr pane", :seam do
    child = <<~'RUBY'
      require "lain"

      dir = ARGV.fetch(0)
      text = ->(words) { Lain::Response.new(content: [{ "type" => "text", "text" => words }], stop_reason: :end_turn) }
      bash = { "type" => "tool_use", "id" => "tu_bash", "name" => "bash",
               "input" => { "command" => "touch #{File.join(dir, "made")}" } }
      provider = Lain::Provider::Mock.new(responses: [text.call("one"),
                                                      Lain::Response.new(content: [bash], stop_reason: :tool_use),
                                                      text.call("ran it"), text.call("unexpected")])
      backend = Class.new(Lain::CLI::Backend) { define_method(:provider) { |**| provider } }
      launch = Class.new(Lain::CLI::ChatLaunch) do
        define_method(:backend) { @backend ||= backend.new(@options, root: project.root) }
      end
      project = Lain::Project.new(root: dir, cwd: dir, kind: :project, detected_by: :flag)
      chat = launch.new({ journal: true, provider: "ollama", model: nil, max_tokens: 64, grace: 5 },
                        project_factory: -> { project }, gc_schedule_factory: ->(root:) { -> { root } })
      begin
        chat.call { |notice| $stdout.puts "NOTICE: #{notice}" }
      ensure
        File.write(File.join(dir, "journal_path"), chat.chronicle.journal_path.to_s)
      end
    RUBY

    define_method(:chat_in_herdr) do |bin|
      prompts = File.join(dir, "prompts.txt")
      File.write(prompts, "first prompt\nrun the command\ny\n")
      log = File.join(dir, "output.log")
      env = { "HERDR_ENV" => "1", "HERDR_PANE_ID" => "w1:p7", "HERDR_BIN_PATH" => bin, "HERDR_SOCKET_PATH" => socket,
              "XDG_STATE_HOME" => File.join(dir, "state"), "XDG_CONFIG_HOME" => File.join(dir, "config"),
              "XDG_DATA_HOME" => File.join(dir, "data"), "TMUX" => nil, "TMUX_PANE" => nil }
      pid = Process.spawn(env, RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", child, dir,
                          chdir: dir, in: prompts, %i[out err] => log)
      _, status = Process.wait2(pid)
      [File.read(log), status]
    end

    it "reports each state and its resume command, releases once, and touches nothing else" do
      output, status = chat_in_herdr(stub_herdr)

      expect(status).to be_success, output
      expect(File.exist?(File.join(dir, "made"))).to be(true), output
      expect(reports.map { flag(_1, "--state") }).to eq(%w[working idle working blocked working idle]), output
      expect(resume_of(reports.last)).to eq(["lain", "chat", "--resume", File.read(File.join(dir, "journal_path"))])
      expect(calls.count { _1.first(2) == %w[pane release-agent] }).to eq(1)
      expect(calls.map { _1.first(2) }.uniq).to contain_exactly(%w[agent get], %w[pane report-agent],
                                                                %w[pane release-agent])
      expect(calls.flatten.grep(/herdr:|integration|plugin|config|server/)).to be_empty
    end

    it "says a failed report on the chat's own screen, never through the exe's notice block" do
      output, status = chat_in_herdr(stub_herdr(failing: [2]))

      expect(status).to be_success, output
      expect(output.lines.grep(/herdr: reporting to pane w1:p7 failed/).size).to eq(1), output
      expect(output).not_to include("NOTICE: herdr"), output
    end
  end
end
