# frozen_string_literal: true

require "openssl"
require "tmpdir"

RSpec.describe Lain::Sensitivity::Display do
  let(:channel) { RecordingChannel.new }
  let(:token) { "ghp_aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5" }

  def invocation_on(channel, context: nil) = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context:, channel:)

  describe "over a Null channel" do
    let(:display) { described_class.new(child_env: Lain::Exec::ChildEnv.new(pass: %w[FOO], env: { "FOO" => token })) }

    it "answers a Null sink for each stream" do
      sinks = display.sinks(invocation_on(Lain::Channel::Null.instance))

      expect(sinks.values_at(:stdout_sink, :stderr_sink)).to all(be_a(Lain::Sink::Null))
    end

    it "builds no secret set and no live mask" do
      allow(Lain::Sensitivity::Secrets).to receive(:for).and_call_original
      allow(Lain::Sensitivity::TextMask).to receive(:new).and_call_original
      display.sinks(invocation_on(Lain::Channel::Null.instance))

      expect(Lain::Sensitivity::Secrets).not_to have_received(:for)
      expect(Lain::Sensitivity::TextMask).not_to have_received(:new)
    end
  end

  describe "NULL" do
    it "answers a Null sink for each stream over a live channel too" do
      sinks = described_class::NULL.sinks(invocation_on(channel))

      expect(sinks.values_at(:stdout_sink, :stderr_sink)).to all(be_a(Lain::Sink::Null))
    end
  end

  it "masks a value lent to the call's context, read per call" do
    display = described_class.new(child_env: Lain::Exec::ChildEnv.new(env: {}))
    lent = { "LENT_TOKEN" => "hunterhunterhunter" }
    session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env: lent))
    sink = display.sinks(invocation_on(channel, context: session)).fetch(:stdout_sink)
    sink << "hunterhunterhunter\n"
    sink.flush

    expect(channel.events.map(&:bytes).join).to eq("<redacted:1>\n")
  end

  describe "masked live streaming through bash" do
    let(:environment) { ENV.to_h.merge("FOO" => token) }
    let(:child_env) { Lain::Exec::ChildEnv.new(pass: %w[FOO], env: environment) }
    let(:masked_tool) { Lain::Tools::Bash.new(exec: Lain::Exec::Local.new(child_env:)) }
    let(:display) { described_class.new(child_env:) }

    def placeholder(ordinal) = format(Lain::Sensitivity::Regions::PLACEHOLDER, ordinal)

    def run_masked(command, timeout: 10)
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env: environment))
      masked_tool.call({ command:, timeout: }, Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session,
                                                                          channel:, live_display: display))
    end

    def shown(stream = nil) = channel.events.select { stream.nil? || _1.stream == stream }.map(&:bytes)

    def runs_of(text) = (0..(text.bytesize - 8)).map { text.byteslice(_1, 8) }

    it "masks a passed value before it reaches the live channel" do
      run_masked("printenv FOO")

      expect(shown(:stdout).join).to eq("#{placeholder(1)}\n")
    end

    it "masks a value the session lends that the launch's environment never held" do
      lent = environment.merge("LENT_TOKEN" => "hunterhunterhunter")
      session = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env: lent))
      invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1", context: session, channel:, live_display: display)
      masked_tool.call({ command: "printenv LENT_TOKEN" }, invocation)

      expect(shown(:stdout).join).to eq("#{placeholder(1)}\n")
    end

    it "numbers stdout and stderr from one count, each on its own stream" do
      run_masked(%(sh -c 'printf "%s\\n" "$FOO"; printf "%s\\n" "$FOO" 1>&2'))

      expect([shown(:stdout).join, shown(:stderr).join].sort)
        .to eq(["#{placeholder(1)}\n", "#{placeholder(2)}\n"])
    end

    it "masks a token split across two writes a second apart" do
      run_masked(%(sh -c 'printf "#{token[0, 20]}"; sleep 1; printf "#{token[20..]}\\n"'))

      expect(shown).to all(satisfy { |bytes| runs_of(token).none? { bytes.include?(_1) } })
    end

    it "shows no line of a private key split across two writes" do
      Dir.mktmpdir do |dir|
        key = OpenSSL::PKey::RSA.new(1024).to_pem
        File.write(File.join(dir, "key.pem"), key)
        half = key.bytesize / 2
        run_masked(%(sh -c 'head -c #{half} #{dir}/key.pem; sleep 1; tail -c +#{half + 1} #{dir}/key.pem'))

        expect(shown).to all(satisfy { |bytes| key.lines[1..-2].none? { bytes.include?(_1.chomp) } })
      end
    end

    it "shows a line before the command ends" do
      arrived = {}
      timing = Object.new.tap do |observer|
        observer.define_singleton_method(:<<) { |event| arrived[event.bytes] ||= Lain::RunClock::MONOTONIC.call }
      end
      channel.observe(timing)
      run_masked(%(sh -c 'echo a; sleep 2; echo b'))
      ended = Lain::RunClock::MONOTONIC.call

      expect(ended - arrived.fetch("a\n")).to be > 1
    end

    it "masks an unterminated key at exit rather than flushing it raw" do
      Dir.mktmpdir do |dir|
        body = Array.new(1000) { |line| "#{format("%06d", line)}#{"Q" * 64}\n" }.join
        File.write(File.join(dir, "held.txt"), "-----BEGIN PRIVATE KEY-----\n#{body}")
        run_masked("cat #{dir}/held.txt")

        expect(shown.join).to eq(placeholder(1))
      end
    end

    it "shows what a timed-out command left unterminated, masked" do
      run_masked(%(sh -c 'printf "partial $FOO"; sleep 5'), timeout: 1)

      expect(shown(:stdout).join).to eq("partial #{placeholder(1)}")
    end

    it "stops the live display at its cap with one note, showing no byte printed past it" do
      cap = described_class::MaskedSink::CAP
      run_masked(%(sh -c 'head -c #{cap} /dev/zero | tr "\\0" a; head -c #{cap} /dev/zero | tr "\\0" Z'))
      note = described_class::MaskedSink::NOTE

      expect([shown(:stdout).join.count("Z"), shown(:stdout).count { _1.include?(note) }, shown(:stdout).last])
        .to match([0, 1, end_with(note)])
    end

    it "streams an output past the bound masked, and still refuses it to the model" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "big.txt"), "#{"#{"a" * 99}\n" * 200}#{token}\n")
        result = run_masked("cat #{dir}/big.txt")

        expect([shown.join.include?(token), result.content]).to match([false, include("20041 bytes")])
      end
    end
  end
end
