# frozen_string_literal: true

RSpec.describe Lain::Notices do
  let(:bin) { Dir.mktmpdir("lain-notices-bin") }

  after { FileUtils.remove_entry(bin) }

  def install(name)
    path = File.join(bin, name)
    File.write(path, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, path)
    path
  end

  describe ".for" do
    it "is a Null, spawning nothing, when notify-feed is not on PATH" do
      notices = described_class.for(env: { "PATH" => bin })

      expect(notices).to be_a(Lain::Notices::Null)
      expect(notices.call("lain", "title", "body")).to be_nil
    end

    it "is a Feed over the notify-feed found on PATH" do
      install("notify-feed")

      expect(described_class.for(env: { "PATH" => bin })).to be_a(Lain::Notices::Feed)
    end

    it "is a Feed over the program the user named" do
      expect(described_class.for(env: { "PATH" => bin }, program: "/opt/feed")).to be_a(Lain::Notices::Feed)
    end

    it "is a Null when PATH is unset" do
      expect(described_class.for(env: {})).to be_a(Lain::Notices::Null)
    end
  end
end
