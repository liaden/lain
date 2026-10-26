# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# The measured probe: a granted bundle install and cargo fetch resolve names through the resolver
# socket. It reaches rubygems.org and crates.io, so it runs only when asked.
RSpec.describe "A granted build tool reaches its registry through the resolver socket", :seam do
  before do
    skip("set LAIN_NETWORK_PROBE=1 to reach rubygems.org and crates.io") unless ENV["LAIN_NETWORK_PROBE"] == "1"
  end

  # The copy is a hundred megabytes, so an example that will skip does not make one.
  around do |example|
    if ENV["LAIN_NETWORK_PROBE"] == "1"
      Dir.mktmpdir("lain-workspace-grant") do |dir|
        @lease = File.realpath(dir)
        (Dir.children(source) - %w[.git target tmp references planning]).each do |entry|
          FileUtils.cp_r(File.join(source, entry), @lease)
        end
        FileUtils.mkdir_p(File.join(@lease, "tmp"))
        example.run
      end
    else
      example.run
    end
  end

  def source = File.expand_path("../../..", __dir__)

  let(:script) { File.expand_path("../../../bin/workspace-run", __dir__) }
  let(:env) do
    ENV.to_h.merge("TMPDIR" => File.join(@lease, "tmp"), "CARGO_TARGET_DIR" => File.join(@lease, "target"),
                   "LAIN_ENV_PASS" => "CARGO_TARGET_DIR")
  end

  def granted(program, *argv)
    Open3.capture3(env, RbConfig.ruby, script, "--root", @lease, "--grant", program, "--", *argv, chdir: @lease)
  end

  def calls(err) = err.scan(/^workspace-run: (connect|sendto|sendmsg|sendmmsg) (\S+) rc=(\S+)$/)

  def ports(err) = calls(err).map { _1[1][/:(\d+)\z/, 1] }.uniq

  def datagrams(err) = calls(err).map(&:first) - ["connect"]

  it "installs gems over 443 and 80 with no datagram socket" do
    _out, err, status = granted("bundle", "bundle", "install")

    expect(status.exitstatus).to eq(0), err
    expect(err).to include("workspace-run: profile grant")
    expect(ports(err) - %w[443 80]).to be_empty
    expect(datagrams(err)).to be_empty
  end

  it "fetches crates over 443 with no datagram socket" do
    _out, err, status = granted("cargo", "cargo", "fetch")

    expect(status.exitstatus).to eq(0), err
    expect(err).to include("workspace-run: profile grant")
    expect(ports(err) - %w[443]).to be_empty
    expect(datagrams(err)).to be_empty
  end
end
