# frozen_string_literal: true

RSpec.describe Lain::Error do
  describe ".reason_of" do
    it "answers the errno's own reason without the path" do
      cause = Errno::EACCES.new("/secret/x")

      expect(described_class.reason_of(cause)).to eq("Permission denied")
    end

    it "lowercases for the scratch workspace's wording" do
      expect(described_class.reason_of(Errno::EROFS.new).downcase).to eq("read-only file system")
    end
  end
end
