# frozen_string_literal: true

RSpec.describe Lain::Shell::Executable::MountedFresh do
  let(:host) { instance_double(Lain::Shell::Executable::Fresh, fresh?: true) }
  let(:fresh) { described_class.new(mounts: ["/work/proj"], host:) }

  it "is never fresh for an image path" do
    expect(fresh.fresh?("/usr/bin/ls")).to be(false)
  end

  it "asks the session for a mounted path" do
    expect(fresh.fresh?("/work/proj/bin/tool")).to be(true)
  end

  it "does not take a sibling directory for a mounted one" do
    expect(fresh.fresh?("/work/proj2/bin/tool")).to be(false)
  end
end
