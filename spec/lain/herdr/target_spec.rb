# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "shellwords"
require "tmpdir"

RSpec.describe Lain::Herdr::Target do
  let(:dir) { @dir ||= Dir.mktmpdir("herdr-target") }
  let(:calls) { File.join(dir, "calls") }
  let(:socket_path) { File.join(dir, "herdr.sock") }
  let(:no_spawn) { ->(*argv, **) { raise "spawned #{argv.inspect}" } }

  after { FileUtils.remove_entry(@dir) if @dir }

  def stub_herdr(answer, stream: 1, status: 0, delay: 0)
    path = File.join(dir, "herdr")
    File.write(path, <<~SH, perm: 0o755)
      #!/bin/sh
      echo "$* socket=$HERDR_SOCKET_PATH" >> #{calls.shellescape}
      sleep #{delay}
      printf '%s\\n' #{JSON.generate(answer).shellescape} >&#{stream}
      exit #{status}
    SH
    path
  end

  # herdr 0.9.5 prints every error reply on stderr and exits 1.
  def stub_refusal(answer) = stub_herdr(answer, stream: 2, status: 1)

  def stub_not_found = stub_refusal(not_found)

  def herdr_calls = File.exist?(calls) ? File.readlines(calls, chomp: true) : []

  # The shapes herdr 0.9.5 printed for `agent get`.
  def agent_info(name)
    agent = { "agent" => name, "pane_id" => "w1:p7" }.compact
    { "id" => "cli:agent:get", "result" => { "type" => "agent_info", "agent" => agent } }
  end

  def not_found
    { "error" => { "code" => "agent_not_found", "message" => "agent target w1:p7 not found" }, "id" => "cli:agent:get" }
  end

  def herdr_env(bin)
    { "HERDR_ENV" => "1", "HERDR_PANE_ID" => "w1:p7", "HERDR_BIN_PATH" => bin, "HERDR_SOCKET_PATH" => socket_path }
  end

  describe "Resolver#current, from a herdr pane with no tmux" do
    it "names that pane, binary and socket" do
      bin = stub_not_found
      target = described_class::Resolver.new(env: herdr_env(bin), interactive: true).current

      expect(target).to eq(described_class.new(bin:, pane: "w1:p7", socket: socket_path, via: :env))
    end

    it "asks herdr who holds the pane over that pane's socket" do
      bin = stub_not_found
      described_class::Resolver.new(env: herdr_env(bin), interactive: true).current

      expect(herdr_calls).to eq(["agent get w1:p7 socket=#{socket_path}"])
    end

    it "answers nothing for a non-interactive chat, whatever HERDR_* says" do
      resolver = described_class::Resolver.new(env: herdr_env("/bin/false"), interactive: false, shell_out: no_spawn)

      expect(resolver.current).to be_nil
    end

    it "answers nothing and spawns nothing with no HERDR_ENV and no TMUX" do
      resolver = described_class::Resolver.new(env: {}, interactive: true, shell_out: no_spawn)

      expect(resolver.current).to be_nil
    end

    it "answers nothing and spawns nothing when the 3 paths are set but HERDR_ENV is not" do
      env = herdr_env("/bin/false").except("HERDR_ENV")
      resolver = described_class::Resolver.new(env:, interactive: true, shell_out: no_spawn)

      expect(resolver.current).to be_nil
    end

    it "answers nothing when HERDR_ENV is set but a path is missing" do
      env = herdr_env("/bin/false").except("HERDR_SOCKET_PATH")
      resolver = described_class::Resolver.new(env:, interactive: true, shell_out: no_spawn)

      expect(resolver.current).to be_nil
    end
  end

  describe "Resolver#current, on who holds the pane" do
    let(:notes) { StringIO.new }

    def resolver_on(bin) = described_class::Resolver.new(env: herdr_env(bin), interactive: true, notes:)

    def resolve(answer, times: 1)
      resolver = resolver_on(stub_herdr(answer))
      Array.new(times) { resolver.current }
    end

    it "is that pane when lain already holds it" do
      expect(resolve(agent_info("lain")).first&.pane).to eq("w1:p7")
    end

    it "is that pane when a lain agent named for its role and spawn holds it" do
      expect(resolve(agent_info("lain-dev-3f2a")).first&.pane).to eq("w1:p7")
    end

    it "is absent when an agent whose name merely starts with the letters lain holds it" do
      expect(resolve(agent_info("lainbot"))).to eq([nil])
    end

    it "is that pane when herdr refuses with agent_not_found on stderr and exit 1" do
      expect(resolver_on(stub_not_found).current&.pane).to eq("w1:p7")
    end

    it "is absent when herdr refuses for any other reason" do
      ambiguous = { "error" => { "code" => "agent_target_ambiguous", "message" => "w1:p7" }, "id" => "cli:agent:get" }

      expect(resolver_on(stub_refusal(ambiguous)).current).to be_nil
    end

    it "is absent when herdr answers with no agent in its result" do
      expect(resolve({ "id" => "cli:agent:get", "result" => { "type" => "agent_info" } })).to eq([nil])
    end

    it "asks herdr once and notes once when several threads ask at the same moment" do
      resolver = resolver_on(stub_herdr(agent_info("claude"), delay: 0.3))
      Array.new(3) { Thread.new { resolver.current } }.each(&:join)

      expect([herdr_calls.size, notes.string.lines.size]).to eq([1, 1])
    end

    it "is absent when another agent holds it" do
      expect(resolve(agent_info("claude"))).to eq([nil])
    end

    it "notes once that the pane belongs to that agent, and never asks herdr again" do
      resolve(agent_info("claude"), times: 3)

      expect([notes.string.lines.size, notes.string, herdr_calls.size])
        .to match([1, a_string_including("claude"), 1])
    end

    it "treats an agent herdr detects but cannot name as holding the pane" do
      expect(resolve(agent_info(nil))).to eq([nil])
    end

    it "is absent when herdr answers something it cannot read" do
      expect(resolve("not json")).to eq([nil])
    end

    it "is absent when the herdr binary is gone" do
      env = herdr_env(File.join(dir, "missing-herdr"))

      expect(described_class::Resolver.new(env:, interactive: true, notes:).current).to be_nil
    end

    it "notes once that herdr did not answer, however often it is asked" do
      resolver = resolver_on(File.join(dir, "missing-herdr"))
      2.times { resolver.current }

      expect([notes.string.lines.size, notes.string]).to match([1, a_string_including("herdr did not answer", "w1:p7")])
    end

    it "notes that herdr did not answer when its reply cannot be read" do
      resolve("not json")

      expect(notes.string).to include("herdr did not answer")
    end

    it "lets the note's reader ask again without asking herdr again" do
      reentrant = Struct.new(:resolver, :seen) do
        def puts(line) = self.seen = [line, resolver.current]
      end.new
      reentrant.resolver = described_class::Resolver.new(env: herdr_env(stub_herdr(agent_info("claude"))),
                                                         interactive: true, notes: reentrant)

      expect([reentrant.resolver.current, reentrant.seen, herdr_calls.size])
        .to match([nil, [a_string_including("claude"), nil], 1])
    end

    it "asks herdr once for a free pane however often it is asked" do
      resolver = resolver_on(stub_not_found)
      3.times { resolver.current }

      expect(herdr_calls.size).to eq(1)
    end
  end

  describe "#to_option" do
    it "reads back as the same pane, binary and socket, via the cockpit" do
      target = described_class.new(bin: "/opt/herdr bin", pane: "w1:p9", socket: socket_path, via: :env)

      expect(described_class.from_option(target.to_option)).to eq(target.with(via: :cockpit))
    end

    it "reads nothing back from an empty option" do
      expect(described_class.from_option("")).to be_nil
    end

    it "reads nothing back from JSON that is not an object" do
      expect(["null", "1", '"x"', "[]"].map { |text| described_class.from_option(text) }).to all(be_nil)
    end

    it "reads nothing back from an empty or non-string field" do
      fields = { "bin" => "herdr", "pane" => "w1:p9", "socket" => socket_path }
      broken = [fields.merge("pane" => ""), fields.merge("bin" => 5), fields.except("socket")]

      expect(broken.map { |option| described_class.from_option(JSON.generate(option)) }).to all(be_nil)
    end
  end

  describe "#environment" do
    it "points a herdr child at the target's socket" do
      target = described_class.new(bin: "herdr", pane: "w1:p9", socket: socket_path, via: :env)

      expect(target.environment).to eq("HERDR_SOCKET_PATH" => socket_path)
    end
  end

  describe "Resolver#current inside the cockpit", :seam do
    before { skip("tmux not found on PATH") unless system("tmux", "-V", out: File::NULL, err: File::NULL) }

    let(:server) { "ht#{Process.pid}#{rand(10_000)}" }
    let(:tmux_env) { { "TMUX_TMPDIR" => dir } }

    around do |example|
      example.run
    ensure
      Open3.capture3(tmux_env, "tmux", "-L", server, "kill-server")
    end

    def tmux!(*argv)
      out, err, status = Open3.capture3(tmux_env, "tmux", "-L", server, *argv)
      raise "tmux #{argv.first} failed: #{err}" unless status.success?

      out.strip
    end

    def socket_of = tmux!("display-message", "-p", "\#{socket_path}")

    def cockpit(chat_herdr:)
      chat = tmux!("new-session", "-d", "-s", "lain", "-P", "-F", "\#{pane_id}", "sleep 600")
      fork_pane = tmux!("new-window", "-d", "-t", "lain", "-P", "-F", "\#{pane_id}", "sleep 600")
      tmux!("set-option", "-t", "lain", "@lain_chat_pane", chat)
      tmux!("set-option", "-t", "lain", described_class::OPTION, chat_herdr.to_option)
      [chat, fork_pane]
    end

    def inside(pane, inherited) = inherited.merge("TMUX" => "#{socket_of},1,0", "TMUX_PANE" => pane)

    it "gives the chat pane what lain up recorded, whatever HERDR_PANE_ID it inherited" do
      recorded = described_class.new(bin: stub_not_found, pane: "w1:p9", socket: socket_path, via: :env)
      chat, = cockpit(chat_herdr: recorded)
      env = inside(chat, herdr_env("/bin/false"))

      expect(described_class::Resolver.new(env:, interactive: true).current).to eq(recorded.with(via: :cockpit))
    end

    it "gives another pane of the cockpit nothing" do
      recorded = described_class.new(bin: stub_not_found, pane: "w1:p9", socket: socket_path, via: :env)
      _, fork_pane = cockpit(chat_herdr: recorded)
      env = inside(fork_pane, herdr_env(recorded.bin))

      expect([described_class::Resolver.new(env:, interactive: true).current, herdr_calls]).to eq([nil, []])
    end

    it "gives the chat pane nothing when lain up recorded no herdr pane" do
      chat = tmux!("new-session", "-d", "-s", "lain", "-P", "-F", "\#{pane_id}", "sleep 600")
      tmux!("set-option", "-t", "lain", "@lain_chat_pane", chat)
      env = inside(chat, herdr_env(stub_not_found))

      expect([described_class::Resolver.new(env:, interactive: true).current, herdr_calls]).to eq([nil, []])
    end
  end

  describe "the spec environment" do
    it "carries no HERDR_ name" do
      expect(ENV.keys.grep(/\AHERDR_/)).to be_empty
    end
  end
end
