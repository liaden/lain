# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A directory lent to one agent's bounds, inside the reader sandbox: the real
# mask list over a real policy, bwrap, Landlock and the fence. The lend reaches
# the sandbox on the call's own request, so a sibling whose bounds lend nothing
# is bound nothing.
RSpec.describe "A read lent to one agent's bounds", :seam do
  let(:fence) { Lain::Confine::Bwrap.fence_binary }
  let(:journal) { RecordingChannel.new }
  let(:policy) do
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: @home, cwd: @repo, root: @repo),
                                  home: @home, root: @repo)
  end
  let(:sandboxed) do
    masks = Lain::Confine::MaskList.new(root: @repo, policy: -> { policy }, journal:)
    Lain::Confine::Sandbox.new(root: @repo, home: @home, masks:, fence:, journal:,
                               probe: Lain::Confine::Probe.new(fence:, journal:))
                          .wrap(Lain::Exec::Local.new, requirer: "Spec")
  end

  around do |example|
    Dir.mktmpdir("lain-lent-read") do |dir|
      @base = File.realpath(dir)
      @home, @repo, @refs, @secrets = %w[home repo data/refs data/secrets].map { File.join(@base, _1) }
      FileUtils.mkdir_p([@home, @repo, @refs, @secrets])
      SeedRepo.git(@repo, "init", "-q")
      File.write(File.join(@refs, "notes.md"), "zq_notes_mark\n")
      File.write(File.join(@refs, ".env"), "zq_env_mark\n")
      File.write(File.join(@secrets, "plan.md"), "zq_secrets_mark\n")
      File.write(File.join(@home, "profile.md"), "zq_home_mark\n")
      example.run
    end
  end

  before do
    skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace].all? { File.executable?(_1) }
    skip("lain-fence is not built at #{fence} -- run `bundle exec rake compile`") unless File.executable?(fence)
    skip("bwrap cannot make a user namespace on this host") unless
      system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
  end

  # bwrap binds no lent path, and Landlock refuses one the root bind still shows, as a tmpdir under home is.
  def unread = /No such file or directory|Permission denied/

  def lending(dir) = policy.bounds | Lain::Sensitivity::Bounds.of(reads: [dir])

  def run_contained(command, bounds:)
    ruling = Lain::Approval::Escalation::Ruling.allow(rung: "surfaces", because: "spec", authority: :human,
                                                      contained: true)
    request = Lain::Confine::Request.new(ruling:, executables: [], cwd: @repo, root: @repo, tool_use_id: "toolu_1",
                                         bounds:)
    sandboxed.call(command:, cwd: @repo, env: {}, timeout: 10, confinement: request)
  end

  it "binds the lent directory read-only with its masks standing, and binds nothing for a sibling" do
    command = "cat #{File.join(@refs, "notes.md")}; cat #{File.join(@refs, ".env")}"

    lent = run_contained(command, bounds: lending(@refs))
    sibling = run_contained("cat #{File.join(@refs, "notes.md")}", bounds: policy.bounds)

    expect(lent.stdout).to include("zq_notes_mark"), lent.stderr
    expect(lent.stdout).not_to include("zq_env_mark")
    expect([sibling.stdout, sibling.stderr]).to match(["", unread])
  end

  it "refuses to write into the lent directory" do
    written = run_contained("echo x >> #{File.join(@refs, "notes.md")}", bounds: lending(@refs))

    expect(written.exit_status).not_to eq(0)
    expect(File.read(File.join(@refs, "notes.md"))).to eq("zq_notes_mark\n")
  end

  {
    "the home directory" => [:@home, "profile.md", "it is the home directory or holds it"],
    "an ancestor of the project root" => [:@base, "data/secrets/plan.md", "it holds the project root"],
    "a directory classified other than ordinary" => [:@secrets, "plan.md", "its path is classified gated"]
  }.each do |what, (dir, file, reason)|
    it "refuses a lend of #{what} with a reason, and binds nothing" do
      lent = instance_variable_get(dir)
      result = run_contained("cat #{File.join(lent, file)}", bounds: lending(lent))

      expect(result.stdout).to eq("")
      expect(result.stderr).to match(unread).and include("not read: #{lent} (#{reason})")
    end
  end
end
