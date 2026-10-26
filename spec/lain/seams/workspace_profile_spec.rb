# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# A project's own tests run inside the workspace profile: a throwaway copy of this repo, the mise ruby
# and cargo, the real sandbox. The copy has no .git, because a linked worktree's .git is a pointer and
# the specs would drive git against the original's admin dir.
RSpec.describe "A project's own tests inside the workspace profile", :seam do
  around do |example|
    # A short name: the fence test binds a Unix socket beneath the call's TMPDIR, and SUN_LEN is 108 bytes.
    Dir.mktmpdir("w") do |dir|
      @lease = File.realpath(dir)
      (Dir.children(source) - %w[.git target tmp references planning]).each do |entry|
        FileUtils.cp_r(File.join(source, entry), @lease)
      end
      FileUtils.mkdir_p([File.join(@lease, "tmp"), File.join(@lease, "target")])
      example.run
    end
  end

  def source = File.expand_path("../../..", __dir__)

  let(:script) { File.join(source, "bin/workspace-run") }
  let(:fence) { Lain::Confine::Bwrap.fence_binary }
  # The target dir exists before the call because the profile runs only a target/ that is already there.
  let(:env) do
    ENV.to_h.merge("TMPDIR" => File.join(@lease, "tmp"), "CARGO_TARGET_DIR" => File.join(@lease, "target"),
                   "CARGO_NET_OFFLINE" => "true", "LAIN_ENV_PASS" => "CARGO_TARGET_DIR,CARGO_NET_OFFLINE")
  end

  before do
    skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
    skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
  end

  # This ruby runs both, since a script's `env ruby` could reach a mise shim on some PATH.
  def confined(*argv) = Open3.capture3(env, RbConfig.ruby, script, "--root", @lease, "--", *argv, chdir: @lease)

  def unconfined_bundle(*args)
    Open3.capture3(env.except("BUNDLE_GEMFILE", "RUBYOPT"), RbConfig.ruby, Gem.bin_path("bundler", "bundle"), *args,
                   chdir: @lease)
  end

  def examples_in(output) = output[/(\d+) examples?, /, 1].to_i

  it "passes one spec file with the example count an unconfined run reports" do
    argv = %w[bundle exec rspec spec/lain/price_spec.rb]
    out, err, status = confined(*argv)
    plain, = unconfined_bundle(*argv.drop(1))

    expect([status.exitstatus, examples_in(out)]).to eq([0, examples_in(plain)]), err
    expect(examples_in(out)).to be_positive
  end

  # The fence's tests skip themselves, and pass, where Landlock is not shown active, so a pass that skipped proves
  # nothing. The one UDP test binds a datagram socket, which the profile refuses on purpose.
  it "passes the fence crate's tests, none of them skipped" do
    out, err, status = confined(*%w[cargo test -p lain-fence --test fence --offline --
                                    --skip a_udp_send_to_a_loopback_listener_is_refused])

    expect(status.exitstatus).to eq(0), out + err
    expect(out + err).not_to include("SKIPPED")
    expect(out[/test result: ok\. (\d+) passed/, 1].to_i).to be_positive
  end
end
