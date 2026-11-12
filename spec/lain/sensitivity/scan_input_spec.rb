# frozen_string_literal: true

require "openssl"
require "tmpdir"

RSpec.describe Lain::Sensitivity::ScanInput do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:policy) { Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: @dir, cwd: @dir)) }
  let(:integrity) { "sha512-#{[OpenSSL::Digest.digest("SHA512", "a")].pack("m0")}" }

  before do
    File.write(File.join(@dir, "package-lock.json"), %({"integrity": "#{integrity}"}\n))
    File.write(File.join(@dir, "notes.txt"), "notes\n")
  end

  def of(command, secrets: [])
    parse = Lain::Shell::Parse.new.call(command)
    named = Lain::Shell::Named.for_input({ "command" => command }, cwd: @dir, home: nil, parsed: parse)
    described_class.of_bash(%({"integrity": "#{integrity}"}\n), parse:, named:, policy:, secrets:)
  end

  describe ".of_bash" do
    it "calls a command that reads only a lockfile one over checksums" do
      expect(of("cat package-lock.json").checksums).to be(true)
    end

    it "carries the call's known values" do
      expect(of("cat package-lock.json", secrets: Set["abc123lowentropyvalue"]).literals)
        .to eq(["abc123lowentropyvalue"])
    end

    it "gives no exemption to a command that also reads another file" do
      expect(of("cat package-lock.json notes.txt").checksums).to be(false)
    end

    it "gives no exemption to a command that names no file" do
      expect(of("pwd").checksums).to be(false)
    end

    it "gives no exemption to a search, which reads below the root it names" do
      expect(of("find package-lock.json").checksums).to be(false)
    end

    it "leaves out a file the command writes" do
      expect(of("cat package-lock.json > out.txt").checksums).to be(true)
    end

    it "leaves out a word it only guesses is a path" do
      expect(of("head -n5 package-lock.json").checksums).to be(true)
    end

    # Each reads notes.txt through a stage lain cannot read, so no path it names says what the output holds.
    { "a python one-liner" => %q(cat package-lock.json; python3 -c "print(open('notes.txt').read())"),
      "a ruby one-liner" => %q(cat package-lock.json; ruby -e 'puts File.read("notes.txt")'),
      "an exported variable" => 'cat package-lock.json "$F"' }.each do |what, command|
      it "gives no exemption to a lockfile read beside #{what}" do
        expect(of(command).checksums).to be(false)
      end
    end

    %w[env printenv /usr/bin/env].each do |program|
      it "gives no exemption to a lockfile read beside #{program}, which prints the environment" do
        expect(of("cat package-lock.json; #{program}").checksums).to be(false)
      end
    end
  end

  describe "#regions" do
    it "excuses a checksum behind a checksum key only over checksums" do
      lockfile = of("cat package-lock.json")

      expect(lockfile.regions).to be_empty
      expect(lockfile.with(checksums: false).regions).not_to be_empty
    end
  end

  describe "#over" do
    it "is the same scan over another text" do
      expect(of("cat package-lock.json").over("x\n")).to have_attributes(text: "x\n", checksums: true)
    end
  end
end
