# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tmpdir"

RSpec.describe Lain::Herdr::Focus do
  let(:dir) { @dir ||= Dir.mktmpdir("herdr-focus") }
  let(:calls) { File.join(dir, "calls") }

  after { FileUtils.remove_entry(@dir) if @dir }

  def stub_herdr(body, status: 0)
    File.join(dir, "herdr").tap do |path|
      File.write(path, "#!/bin/sh\necho \"$@ socket=$HERDR_SOCKET_PATH\" >> #{calls.shellescape}\n" \
                       "#{body}\nexit #{status}\n", perm: 0o755)
    end
  end

  def agent(focused) = %({"id":"cli:agent:get","result":{"agent":{"agent":"lain-x","focused":#{focused}}}})

  def focus(bin)
    described_class.new(target: Lain::Herdr::Target.new(bin:, pane: "w1:p7", socket: "/s.sock", via: :env))
  end

  it "is focused when herdr says the pane is focused" do
    expect(focus(stub_herdr("echo '#{agent(true)}'")).focused?).to be(true)
  end

  it "is not focused when herdr says the pane is not" do
    expect(focus(stub_herdr("echo '#{agent(false)}'")).focused?).to be(false)
  end

  it "asks about the pane over that pane's socket" do
    focus(stub_herdr("echo '#{agent(true)}'")).focused?

    expect(File.readlines(calls, chomp: true)).to eq(["agent get w1:p7 socket=/s.sock"])
  end

  it "is not focused when the answer carries no focused field" do
    expect(focus(stub_herdr(%q(echo '{"result":{"agent":{"agent":"lain-x"}}}'))).focused?).to be(false)
  end

  it "is not focused when focused is a string, not true" do
    expect(focus(stub_herdr(%q(echo '{"result":{"agent":{"focused":"yes"}}}'))).focused?).to be(false)
  end

  it "is not focused when the stub exits 1" do
    expect(focus(stub_herdr("echo '#{agent(true)}'", status: 1)).focused?).to be(false)
  end

  it "is not focused when the answer is not JSON" do
    expect(focus(stub_herdr("echo nonsense")).focused?).to be(false)
  end

  it "is not focused when the binary is missing" do
    expect(focus(File.join(dir, "absent")).focused?).to be(false)
  end
end
