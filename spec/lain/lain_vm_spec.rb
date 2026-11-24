# frozen_string_literal: true

require "open3"

RSpec.describe "bin/lain-vm", :seam do
  let(:root) { File.expand_path("../..", __dir__) }

  it "passes its host test against real git with fake limactl and ssh" do
    output, status = Open3.capture2e(File.join(root, "bin/ci/test-lain-vm"), chdir: root)

    expect(status).to be_success, output
    expect(output).to match(/^[1-9]\d* scenarios passed, 0 failed$/)
  end
end
