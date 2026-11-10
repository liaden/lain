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

  it "passes one spec file with the example count an unconfined run reports",
     budget: 60, starvable: "a nested bundler run takes minutes on a box under memory pressure" do
    argv = %w[bundle exec rspec spec/lain/price_spec.rb]
    out, err, status = confined(*argv)
    plain, = unconfined_bundle(*argv.drop(1))

    expect([status.exitstatus, examples_in(out)]).to eq([0, examples_in(plain)]), err
    expect(examples_in(out)).to be_positive
  end

  # The fence's tests skip themselves, and pass, where Landlock is not shown active, so a pass that skipped proves
  # nothing. The one UDP test binds a datagram socket, which the profile refuses on purpose.
  it "passes the fence crate's tests, none of them skipped",
     budget: 60, starvable: "a cargo test build takes minutes on a box under memory pressure" do
    out, err, status = confined(*%w[cargo test -p lain-fence --test fence --offline --
                                    --skip a_udp_send_to_a_loopback_listener_is_refused])

    expect(status.exitstatus).to eq(0), out + err
    expect(out + err).not_to include("SKIPPED")
    expect(out[/test result: ok\. (\d+) passed/, 1].to_i).to be_positive
  end
end

# A command the shell verdict abstains on runs on the string arm, where a shell decides what runs. An automatic
# allow still runs it under the workspace profile, which grants the programs the parsed stages resolved to.
RSpec.describe "A string-arm call allowed automatically, inside the workspace profile", :seam do
  around do |example|
    Dir.mktmpdir("w") do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(File.join(@root, "tmp"))
      example.run
    end
  end

  let(:fence) { Lain::Confine::Bwrap.fence_binary }
  let(:journal) { RecordingChannel.new }
  # A chat reads its lineage's writes; one begun with this example writes nothing to a toolchain.
  let(:fresh) { Lain::Shell::Executable::Fresh.for_lineage([]) }
  let(:tool) do
    probe = Lain::Confine::Probe.new(fence:, journal:)
    policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: Dir.home, cwd: @root))
    masks = Lain::Confine::MaskList.new(root: @root, policy: -> { policy })
    sandbox = Lain::Confine::Sandbox.new(root: @root, home: Dir.home, masks:, probe:, fence:, journal:,
                                         workspace: true, tmpdir: File.join(@root, "tmp"), fresh:)
    exec = sandbox.wrap(Lain::Exec::Local.new, requirer: "spec")
    sandbox.prime
    resolver = Lain::Shell::Executable::Resolver.new(root: @root, fresh:)
    Lain::Tools::Bash.new(exec:, journal:, resolver:)
  end

  before do
    skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
    skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
  end

  # The spec runs under bundler, whose env would point the call at this checkout's Gemfile.
  def worker_env
    scrubbed = %w[BUNDLE_GEMFILE RUBYOPT BUNDLER_SETUP BUNDLE_BIN_PATH RUBYLIB].to_h { [_1, nil] }
    Lain::WorkerEnv.new(cwd: @root, env: ENV.to_h.merge(scrubbed), checkout: @root)
  end

  def call(command, rung:)
    ruling = Lain::Approval::Escalation::Ruling.allow(rung:, because: "allowed automatically")
    context = Lain::Middleware::WithholdAutomaticOutput::Carried.new(Lain::Session.new(worker_env:), barred: false)
    tool.call({ command: }, Lain::Tool::Invocation.new(tool_use_id: "tu_w", context: context.ruled(ruling),
                                                       channel: Lain::Channel::Null.instance))
  end

  it "runs a bundler command the judge allowed, and the sandbox record names the granted programs" do
    File.write(File.join(@root, "Gemfile"), "source \"https://rubygems.org\"\n")

    result = call("bundle exec ruby -e 'puts 42'", rung: Lain::Approval::Judged::NAME)

    expect(result.content).to start_with("exit status: 0").and(include("42")), result.content
    sandbox = journal.events.grep(Lain::Telemetry::Sandbox).sole
    expect([sandbox.profile, sandbox.granted]).to match([:workspace, include(end_with("/bundle"))])
  end

  it "runs a command a rule allowed every time it is called" do
    File.write(File.join(@root, "hello.rb"), "puts :hello\n")

    results = Array.new(3) { call("ruby hello.rb", rung: Lain::Approval::Escalation::Rules::NAME) }

    expect(results.map(&:content)).to all(start_with("exit status: 0").and(include("hello")))
    expect(journal.events.grep(Lain::Telemetry::Sandbox).map(&:profile)).to eq(%i[workspace] * 3)
  end
end
