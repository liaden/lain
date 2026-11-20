# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Confine::Decoys do
  subject(:decoys) { described_class.new }

  around do |example|
    Dir.mktmpdir("lain-decoys") { |made| (@root = File.realpath(made)) and example.run }
  end

  def at(path) = File.join(@root, path)

  def plant(*paths)
    paths.each do |path|
      FileUtils.mkdir_p(File.dirname(at(path)))
      File.write(at(path), "real #{path}\n")
    end
  end

  let(:master_key) { at("config/master.key") }
  let(:credentials) { at("config/credentials.yml.enc") }

  describe "#bytes_for" do
    it "answers an empty file for a mask that is no Rails key or credentials" do
      expect(%w[.env config/server.key config/credentials.yml].map { decoys.bytes_for(at(_1), masks: [at(_1)]) })
        .to eq(["", "", ""])
    end

    it "answers a random 32-hex key for a masked Rails key, the same one in every instance" do
      key = decoys.bytes_for(master_key, masks: [master_key])

      expect(key).to match(/\A\h{32}\z/)
      expect(described_class.new.bytes_for(at("config/credentials/production.key"), masks: [])).to eq(key)
    end

    it "answers {} sealed under the decoy key for credentials whose key is masked" do
      plant("config/credentials.yml.enc")
      key = decoys.bytes_for(master_key, masks: [master_key, credentials])
      sealed = decoys.bytes_for(credentials, masks: [master_key, credentials])
      File.write(credentials, sealed)
      File.write(master_key, key)

      expect(sealed).to match(%r{\A[A-Za-z0-9+/=]+--[A-Za-z0-9+/=]+--[A-Za-z0-9+/=]+\z})
      reports = []
      expect(Lain::Sensitivity::RailsCredentials.new(root: @root, report: reports.method(:<<)).leaves).to eq([])
      expect(reports).to eq([])
    end

    it "answers decoy credentials for a per-environment pair" do
      env_key = at("config/credentials/staging.key")
      env_file = at("config/credentials/staging.yml.enc")

      expect(decoys.bytes_for(env_file, masks: [env_key, env_file]))
        .to eq(decoys.bytes_for(credentials, masks: [master_key]))
    end

    it "pairs an environment named credentials with its own key, not the master key" do
      env_key = at("config/credentials/credentials.key")
      env_file = at("config/credentials/credentials.yml.enc")

      expect([decoys.bytes_for(env_file, masks: [env_key]), decoys.bytes_for(env_file, masks: [master_key])])
        .to eq([decoys.bytes_for(credentials, masks: [master_key]), ""])
    end

    it "answers an empty file for credentials whose key is not masked" do
      expect(decoys.bytes_for(credentials, masks: [credentials])).to eq("")
    end
  end

  describe "#partners" do
    it "names the credentials beside a masked key, which a real file under a decoy key would fail" do
      plant("config/credentials.yml.enc", "config/credentials/test.yml.enc")

      expect(decoys.partners([master_key, at("config/credentials/test.key")]))
        .to eq([credentials, at("config/credentials/test.yml.enc")])
    end

    it "names none that is masked already, missing, or beside no masked key" do
      plant("config/credentials.yml.enc", "config/credentials/test.yml.enc")

      expect(decoys.partners([master_key, credentials, at("config/credentials/prod.key"), at(".env")])).to eq([])
    end
  end

  # A fresh ruby, so the real ActiveSupport reads the decoy without its JSON extensions reaching this worker.
  it "is read as empty credentials by Rails's own EncryptedConfiguration" do
    plant("config/credentials.yml.enc")
    masks = [master_key, credentials]
    File.write(master_key, decoys.bytes_for(master_key, masks:))
    File.write(credentials, decoys.bytes_for(credentials, masks:))
    script = <<~RUBY
      require "active_support"
      require "active_support/encrypted_configuration"
      config = ActiveSupport::EncryptedConfiguration.new(
        config_path: #{credentials.inspect}, key_path: #{master_key.inspect}, env_key: "LAIN_SPEC_NO_KEY",
        raise_if_missing_key: true
      ).config
      p config.to_h
    RUBY

    expect(FreshRuby.run(script).chomp).to eq("{}")
  end

  it "builds its decoy without loading ActiveSupport's JSON extensions, which reshape every later to_json" do
    script = <<~RUBY
      decoys = Lain::Confine::Decoys.new
      sealed = decoys.bytes_for("/p/config/credentials.yml.enc", masks: ["/p/config/master.key"])
      puts sealed.include?("--"), $LOADED_FEATURES.grep(%r{active_support/(core_ext/object/json|encrypted_)}).size
    RUBY

    expect(FreshRuby.run(script).lines(chomp: true)).to eq(%w[true 0])
  end
end
