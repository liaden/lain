# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "openssl"
require "securerandom"

RSpec.describe Lain::Sensitivity::RailsCredentials do
  let(:reports) { [] }

  around do |example|
    Dir.mktmpdir("lain-rails-credentials") { |made| (@root = File.realpath(made)) and example.run }
  end

  # Sealed the way Rails seals credentials, without ActiveSupport: loading it here would
  # put its JSON extensions into every later example in the worker.
  def seal(yaml, key)
    cipher = OpenSSL::Cipher.new("aes-128-gcm").encrypt
    cipher.key = [key].pack("H*")
    iv = cipher.random_iv
    cipher.auth_data = ""
    data = cipher.update(Marshal.dump(yaml)) + cipher.final
    [data, iv, cipher.auth_tag].map { [_1].pack("m0") }.join("--")
  end

  def generate_key = SecureRandom.hex(16)

  def encrypt(yaml, path, key_path: nil, key: generate_key)
    FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
    if key_path
      FileUtils.mkdir_p(File.dirname(File.join(@root, key_path)))
      File.write(File.join(@root, key_path), key)
    end
    File.write(File.join(@root, path), seal(yaml, key))
    key
  end

  # ActiveSupport reads ENV[] and lain's code reads ENV.fetch, so both answer.
  def env_key_is(value)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with("RAILS_MASTER_KEY").and_return(value)
    allow(ENV).to receive(:fetch).with("RAILS_MASTER_KEY", nil).and_return(value)
  end

  def leaves(**) = described_class.new(root: @root, report: reports.method(:<<), **).leaves

  it "knows a leaf of the credentials under config/master.key" do
    encrypt("signing:\n  value: synthetic-leaf-4f9a2c\n", "config/credentials.yml.enc", key_path: "config/master.key")

    expect(leaves).to include("synthetic-leaf-4f9a2c")
  end

  it "knows the leaves of a per-environment file under its own key" do
    encrypt("api:\n  token: development-token-77\n", "config/credentials/development.yml.enc",
            key_path: "config/credentials/development.key")

    expect(leaves).to include("development-token-77")
  end

  it "knows leaves nested in arrays" do
    encrypt("hosts:\n  - first-secret-host\n  - second-secret-host\n", "config/credentials.yml.enc",
            key_path: "config/master.key")

    expect(leaves).to include("first-secret-host", "second-secret-host")
  end

  it "decrypts with RAILS_MASTER_KEY from lain's own env when no key file exists" do
    key = encrypt("signing:\n  value: env-keyed-leaf-91\n", "config/credentials.yml.enc",
                  key_path: "config/master.key")
    FileUtils.rm(File.join(@root, "config/master.key"))
    env_key_is(key)

    expect(leaves).to include("env-keyed-leaf-91")
  end

  it "falls back to the key file when a stale RAILS_MASTER_KEY from another app does not decrypt" do
    encrypt("signing:\n  value: file-keyed-leaf-33\n", "config/credentials.yml.enc", key_path: "config/master.key")
    env_key_is(generate_key)

    expect(leaves).to include("file-keyed-leaf-33")
    expect(reports).to eq([])
  end

  it "falls back to RAILS_MASTER_KEY when the key file does not decrypt" do
    key = encrypt("signing:\n  value: env-fallback-leaf-8\n", "config/credentials.yml.enc",
                  key_path: "config/master.key")
    File.write(File.join(@root, "config/master.key"), generate_key)
    env_key_is(key)

    expect(leaves).to include("env-fallback-leaf-8")
  end

  it "re-reads a file rotated in place with its mtime restored" do
    subject = described_class.new(root: @root)
    key = encrypt("a: first-secret-aaaa\n", "config/credentials.yml.enc", key_path: "config/master.key")
    path = File.join(@root, "config/credentials.yml.enc")
    stamp = File.stat(path).mtime
    subject.leaves
    File.write(path, seal("a: other-secret-bbbb
", key))
    File.utime(stamp, stamp, path)

    expect(subject.leaves).to eq(["other-secret-bbbb"])
  end

  it "re-reads when only the env key changes" do
    encrypt("a: env-change-leaf-1\n", "config/credentials.yml.enc", key_path: "config/master.key")
    subject = described_class.new(root: @root)
    subject.leaves
    env_key_is("0" * 32)
    allow(OpenSSL::Cipher).to receive(:new).and_call_original

    subject.leaves

    expect(OpenSSL::Cipher).to have_received(:new).at_least(:once)
  end

  it "re-reads when only a key file changes" do
    key = encrypt("a: key-change-leaf-1\n", "config/credentials.yml.enc", key_path: "config/master.key")
    subject = described_class.new(root: @root)
    expect(subject.leaves).to eq(["key-change-leaf-1"])
    key_file = File.join(@root, "config/master.key")
    stamp = File.stat(key_file).mtime
    File.write(key_file, "#{key} ")
    File.utime(stamp, stamp, key_file)
    allow(OpenSSL::Cipher).to receive(:new).and_call_original

    subject.leaves

    expect(OpenSSL::Cipher).to have_received(:new).at_least(:once)
  end

  it "re-reads when only a file's size changes under a restored mtime" do
    encrypt("a: size-change-leaf-1\n", "config/credentials.yml.enc", key_path: "config/master.key")
    subject = described_class.new(root: @root)
    subject.leaves
    path = File.join(@root, "config/credentials.yml.enc")
    stamp = File.stat(path).mtime
    File.write(path, "#{File.read(path)}x")
    File.utime(stamp, stamp, path)
    allow(OpenSSL::Cipher).to receive(:new).and_call_original

    subject.leaves

    expect(OpenSSL::Cipher).to have_received(:new).at_least(:once)
  end

  it "decrypts an unchanged file once and again after it changes" do
    key = encrypt("a: first-leaf-value\n", "config/credentials.yml.enc", key_path: "config/master.key")
    subject = described_class.new(root: @root)
    allow(OpenSSL::Cipher).to receive(:new).and_call_original

    first = [subject.leaves, subject.leaves]
    encrypt("a: second-leaf-value-longer\n", "config/credentials.yml.enc", key_path: "config/master.key", key:)

    expect(first).to eq([["first-leaf-value"], ["first-leaf-value"]])
    expect(OpenSSL::Cipher).to have_received(:new).at_least(:once)
    expect(subject.leaves).to eq(["second-leaf-value-longer"])
  end

  it "does not decrypt again while no credentials file has changed" do
    encrypt("a: stable-leaf-value\n", "config/credentials.yml.enc", key_path: "config/master.key")
    subject = described_class.new(root: @root)
    subject.leaves
    allow(OpenSSL::Cipher).to receive(:new).and_call_original

    subject.leaves

    expect(OpenSSL::Cipher).not_to have_received(:new)
  end

  it "adds nothing and names only the file when the key does not match" do
    encrypt("signing:\n  value: unreachable-leaf-55\n", "config/credentials.yml.enc", key_path: "config/master.key")
    wrong = generate_key
    File.write(File.join(@root, "config/master.key"), wrong)

    subject = described_class.new(root: @root, report: reports.method(:<<))

    expect([subject.leaves, subject.leaves]).to eq([[], []])
    expect(reports).to eq(["config/credentials.yml.enc did not decrypt"])
    expect(reports.join).not_to include(wrong)
  end

  it "says nothing when a file has no key at all" do
    encrypt("signing:\n  value: keyless-leaf-12\n", "config/credentials.yml.enc", key_path: "config/master.key")
    FileUtils.rm(File.join(@root, "config/master.key"))

    expect([leaves, reports]).to eq([[], []])
  end

  it "does not know booleans, numbers or an environment name" do
    encrypt(<<~YAML, "config/credentials.yml.enc", key_path: "config/master.key")
      flag: true
      count: 3
      env: development
      stage: production
      wide: "123456789012"
      short: abc
      tiny: tiny-ky
      real: kept-secret-value
    YAML

    expect(leaves).to eq(["kept-secret-value"])
  end

  it "keeps a plain lowercase word, because a password can be one" do
    encrypt("password: sunflowers\n", "config/credentials.yml.enc", key_path: "config/master.key")

    expect(leaves).to eq(["sunflowers"])
  end

  it "knows nothing of a project with no credentials" do
    expect(leaves).to eq([])
  end

  it "returns frozen leaves" do
    encrypt("a: frozen-leaf-value\n", "config/credentials.yml.enc", key_path: "config/master.key")

    expect(leaves).to be_frozen
  end

  it "keeps a string leaf when a date and a timestamp sit beside it" do
    encrypt("expires: 2026-01-01\nat: 2026-01-01 10:00:00 Z\nreal: dated-secret-value\n", "config/credentials.yml.enc",
            key_path: "config/master.key")

    expect(leaves).to eq(["dated-secret-value"])
  end

  it "knows a symbol leaf as the text Rails prints" do
    encrypt("sym: :symbolvalue1\n", "config/credentials.yml.enc", key_path: "config/master.key")

    expect(leaves).to eq(["symbolvalue1"])
  end

  it "reads a leaf an alias repeats" do
    encrypt("base: &base alias-leaf-value-1\ncopy: *base\n", "config/credentials.yml.enc",
            key_path: "config/master.key")

    expect(leaves).to eq(["alias-leaf-value-1"])
  end

  it "decrypts with a key file that ends in a newline" do
    encrypt("a: newline-key-leaf-1\n", "config/credentials.yml.enc", key_path: "config/master.key")
    key_file = File.join(@root, "config/master.key")
    File.write(key_file, "#{File.read(key_file)}\n")

    expect(leaves).to eq(["newline-key-leaf-1"])
  end

  describe "a credentials file whose sealed parts were altered" do
    def tamper
      path = File.join(@root, "config/credentials.yml.enc")
      data, iv, tag = File.read(path).split("--").map { _1.unpack1("m") }
      data, iv, tag = yield(data, iv, tag)
      File.write(path, [data, iv, tag].map { [_1].pack("m0") }.join("--"))
    end

    before { encrypt("a: tamper-leaf-value-1\n", "config/credentials.yml.enc", key_path: "config/master.key") }

    it "adds nothing and reports once for a flipped ciphertext byte" do
      tamper { |data, iv, tag| [data.dup.tap { _1.setbyte(0, _1.getbyte(0) ^ 1) }, iv, tag] }
      subject = described_class.new(root: @root, report: reports.method(:<<))

      expect([subject.leaves, reports]).to eq([[], ["config/credentials.yml.enc did not decrypt"]])
    end

    it "adds nothing and reports once for a tag cut to 1 byte" do
      tamper { |data, iv, tag| [data, iv, tag.byteslice(0, 1)] }
      subject = described_class.new(root: @root, report: reports.method(:<<))

      expect([subject.leaves, reports]).to eq([[], ["config/credentials.yml.enc did not decrypt"]])
    end
  end

  describe ".unmarshal" do
    it "reads a marshalled String of any length and refuses every other marshalled value" do
      long = "x" * 300
      expect([Marshal.dump("abc"), Marshal.dump(long), Marshal.dump("é".b)].map { described_class.unmarshal(_1) })
        .to eq(["abc", long, "é".b.force_encoding(Encoding::UTF_8)])
      [Marshal.dump({ a: 1 }), Marshal.dump(Object.new), Marshal.dump(:sym),
       Marshal.dump("abc")[0...-1], "\x04\b\"\x0aab".b, "\x04\b\"\x05ab".b, "\x04\b\"\xff\x01a".b].each do |bytes|
        expect { described_class.unmarshal(bytes) }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".seal" do
    it "seals text in the format its reader opens, under the key it is given" do
      key = generate_key
      FileUtils.mkdir_p(File.join(@root, "config"))
      File.write(File.join(@root, "config/master.key"), key)
      File.write(File.join(@root, "config/credentials.yml.enc"),
                 described_class.seal("a:\n  b: sealed-here-leaf-5\n", key:))

      expect([leaves, reports]).to eq([["sealed-here-leaf-5"], []])
    end
  end

  # A fresh ruby, so what an earlier example loaded cannot hide a load here.
  it "reads the leaves without loading ActiveSupport's JSON extensions, which reshape every later to_json" do
    encrypt("a: fresh-ruby-leaf-1\n", "config/credentials.yml.enc", key_path: "config/master.key")
    script = <<~RUBY
      before = $LOADED_FEATURES.grep(%r{core_ext/object/json}).size
      leaves = Lain::Sensitivity::RailsCredentials.new(root: #{@root.inspect}).leaves
      puts before, $LOADED_FEATURES.grep(%r{core_ext/object/json}).size, leaves.inspect
    RUBY

    expect(FreshRuby.run(script).lines(chomp: true)).to eq(["0", "0", ["fresh-ruby-leaf-1"].inspect])
  end
end
