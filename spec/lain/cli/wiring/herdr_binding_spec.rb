# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "stringio"
require "tmpdir"

RSpec.describe Lain::CLI::Wiring::HerdrBinding do
  let(:root) { @root ||= File.realpath(Dir.mktmpdir("herdr-binding")) }
  let(:calls_path) { File.join(root, "calls") }
  let(:notes) { Lain::Herdr::HeldNotes.new }
  let(:clock) { instance_double(Lain::RunClock, elapsed: 0.0) }
  let(:screen) { [] }
  let(:tty) do
    said = screen
    Object.new.tap { |tty| tty.define_singleton_method(:render_warning) { |line| said << line } }
  end

  after { FileUtils.remove_entry(@root) if @root }

  def stub_herdr(status: 0)
    File.join(root, "herdr").tap do |path|
      File.write(path, "#!/bin/sh\nprintf '%s\\037' \"$@\" >> #{calls_path.shellescape}\necho >> " \
                       "#{calls_path.shellescape}\nexit #{status}\n", perm: 0o755)
    end
  end

  def nobody = Struct.new(:current).new(nil)

  def reporter(bin)
    target = Lain::Herdr::Target.new(bin:, pane: "w1:p7", socket: File.join(root, "s.sock"), via: :env)
    resolver = Object.new.tap { |answer| answer.define_singleton_method(:current) { target } }
    session = instance_double(Lain::CLI::Chronicle, journal_path: File.join(root, "s.ndjson"))
    Lain::Herdr::Reporter.new(resolver:, session:, root:, notes:)
  end

  def commit_env(value)
    File.write(File.join(root, ".env"), "APP_PW=#{value}\n")
    git = ->(*args) { system(SeedRepo::SCRUB, "git", "-C", root, *args, exception: true) }
    git.call("init", "-q")
    git.call("add", ".env")
    git.call("-c", "user.email=a@b", "-c", "user.name=a", "commit", "-qm", "x")
  end

  # The chat's own secret Source: what the project's committed .env holds, read from git history.
  def chat_secrets
    home = File.join(root, "home").tap { Dir.mkdir(_1) }
    commit_env("zq7Rk2mWvP9x")
    policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:), home:, root:)
    history = Lain::Sensitivity::HistoryLiterals.new(root:, policy:).prime
    Lain::Sensitivity::Secrets::Source.new(child_env: Lain::Exec::ChildEnv.new(env: {}), history:)
  end

  def build_terminal(binding, secrets)
    built = binding.tty_factory(->(**) { tty })
    built.call(tmux: Lain::Frontend::TTY::Notifier.for_chat(secrets, root, env: {}, output: StringIO.new))
  end

  def report(subject, summary)
    tracker = Lain::AgentStates::Tracker.new(clock:)
    tracker.on_change(&subject)
    tracker << Lain::Telemetry::AwaitingHuman.new(kind: "approval", ref: "c1", summary:, requester: "agent",
                                                  tool: "bash", tool_use_id: "c1", spawn: nil)
    subject.release
  end

  def messages
    calls = File.readlines(calls_path, chomp: true).map { _1.split("\x1f") }
    calls.select { _1.include?("--message") }.map { _1[_1.index("--message") + 1] }
  end

  it "masks a reported summary with the chat's own secrets once the terminal is built" do
    subject = reporter(stub_herdr)
    build_terminal(described_class.new(notes:, reporter: subject, resolver: nobody), chat_secrets)
    report(subject, "bash: psql --password zq7Rk2mWvP9x")

    expect(messages.sole).to start_with("bash: psql --password")
    expect(messages.sole).not_to include("zq7Rk2mWvP9x")
  end

  it "says a note held before the terminal existed, and every later one, through the terminal's warning" do
    subject = reporter(stub_herdr(status: 1))
    notes.puts("held before the terminal")
    build_terminal(described_class.new(notes:, reporter: subject, resolver: nobody), Lain::Sensitivity::Secrets::Source::DEFAULT)
    report(subject, "bash")

    expect(screen.first).to eq("held before the terminal")
    expect(screen.drop(1).grep(/reporting to pane w1:p7 failed/).size).to eq(1)
  end

  it "hands back the terminal the factory built" do
    expect(build_terminal(described_class.new(notes:, reporter: reporter(stub_herdr), resolver: nobody), [])).to be(tty)
  end

  it "hands back the reporter it was built with, and a null one when built without a launch" do
    subject = reporter(stub_herdr)

    expect(described_class.new(notes:, reporter: subject, resolver: nobody).reporter).to be(subject)
    expect(described_class::Null.new.reporter).to eq(Lain::Herdr::Reporter::Null.new)
  end

  describe "#focus" do
    def resolver_for(bin)
      target = Lain::Herdr::Target.new(bin:, pane: "w1:p7", socket: File.join(root, "s.sock"), via: :env)
      Struct.new(:current).new(target)
    end

    def binding_for(resolver, env: {}) = described_class.new(notes:, reporter: reporter(stub_herdr), resolver:, env:)

    it "answers herdr's focus for the pane the resolver names" do
      bin = File.join(root, "focused-herdr")
      File.write(bin, "#!/bin/sh\necho '{\"result\":{\"agent\":{\"focused\":true}}}'\n", perm: 0o755)

      expect(binding_for(resolver_for(bin)).focus.focused?).to be(true)
    end

    it "is not focused when no herdr pane resolves and the environment is outside tmux" do
      expect(binding_for(Struct.new(:current).new(nil)).focus.focused?).to be(false)
    end
  end

  describe "Null" do
    it "defaults to the stock terminal" do
      expect(described_class::Null.new(env: {}).tty_factory).to eq(Lain::Frontend::TTY.public_method(:new))
    end

    it "answers tmux focus from the environment" do
      expect(described_class::Null.new(env: {}).focus.focused?).to be(false)
    end

    it "hands back the terminal factory it was given" do
      factory = ->(**) { :tty }

      expect(described_class::Null.new(tty_factory: factory).tty_factory.call).to eq(:tty)
    end
  end
end
