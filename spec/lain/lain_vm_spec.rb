# frozen_string_literal: true

require "open3"

RSpec.describe "bin/lain-vm", :seam do
  root = File.expand_path("../..", __dir__)
  host_test = File.join(root, "bin/ci/test-lain-vm")
  # 1 example per group keeps each under the watchdog budget on a loaded box; the whole run took 16 s alone.
  groups = 6
  listed = lambda do |*selection|
    output, status = Open3.capture2e(host_test, "--list", *selection, chdir: root)
    raise "could not list scenarios: #{output}" unless status.success?

    output.split("\n")
  end

  it "splits its host test into groups that hold every scenario exactly once" do
    every = listed.call
    in_groups = (1..groups).flat_map { listed.call("#{_1}/#{groups}") }

    expect(every).not_to be_empty
    expect(in_groups.tally.values.uniq).to eq([1])
    expect(in_groups.sort).to eq(every.sort)
  end

  (1..groups).each do |group|
    it "passes group #{group} of #{groups} of its host test against real git with fake limactl and ssh" do
      expected = listed.call("#{group}/#{groups}")
      output, status = Open3.capture2e(host_test, "#{group}/#{groups}", chdir: root)

      expect(status).to be_success, output
      expect(output.scan(/^ok   (\S+)$/).flatten.sort).to eq(expected.sort)
      expect(output).to match(/^#{expected.size} scenarios passed, 0 failed$/)
    end
  end
end
