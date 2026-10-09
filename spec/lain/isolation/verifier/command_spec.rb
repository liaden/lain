# frozen_string_literal: true

require "fileutils"
require "pathname"
require "shellwords"
require "tmpdir"

# Runs real commands through the production construction path, in a plain
# directory standing in for a checkout: the command never asks git anything.
RSpec.describe Lain::Isolation::Verifier::Command, :seam do
  around do |example|
    Dir.mktmpdir("lain-verifier-command") do |dir|
      @dir = File.realpath(dir)
      FileUtils.mkdir_p(checkout)
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state"), "HOME" => @dir }) }
  let(:checkout) { File.join(@dir, "checkout") }
  let(:sha) { "0123456789ab#{"f" * 28}" }
  let(:candidate) { Lain::Isolation::Candidate.new(sha:, path: checkout) }

  def verifier(argv, **table)
    settings = { "verify" => argv }.merge(table.transform_keys(&:to_s))
    Lain::Isolation::Verifier.from(Lain::Config::Isolation.from(settings, path: nil), paths:)
  end

  def gone?(pid)
    Process.kill(0, pid)
    File.read("/proc/#{pid}/stat").split[2] == "Z"
  rescue Errno::ESRCH, Errno::ENOENT
    true
  end

  it "fails with the last 40 lines of what the command printed" do
    verification = verifier(["sh", "-c", "seq 1 100; exit 1"]).call(candidate)

    lines = verification.detail.lines.map(&:strip)
    expect([verification.outcome, verification.tip]).to eq([:failed, sha])
    expect(lines).to include("61", "100")
    expect(lines).not_to include("60")
  end

  it "keeps a failure's detail readable when the command printed bytes that are not UTF-8" do
    verification = verifier(["sh", "-c", "printf 'caf\\303\\251 \\377\\n'; exit 2"]).call(candidate)

    expect([verification.detail.valid_encoding?, verification.detail]).to match([true, /café /])
  end

  it "keeps the stdout summary when stderr is noisy, each stream's tail labelled" do
    script = "echo '3 examples, 1 failure'; i=0; while [ $i -lt 45 ]; do echo noise >&2; i=$((i+1)); done; exit 1"

    detail = verifier(["sh", "-c", script]).call(candidate).detail

    expect(detail).to match(/stdout.*\n3 examples, 1 failure\n.*stderr.*\n(noise\n){40}\z/m)
  end

  it "fails a program that cannot run, naming the command as a shell would spell it" do
    argv = [File.join(@dir, "no-such-suite"), "a b"]

    verification = verifier(argv).call(candidate)

    expect([verification.outcome, verification.detail])
      .to match([:failed, /\A`#{Regexp.escape(Shellwords.join(argv))}` could not run: No such file/])
  end

  it "fails a command killed by a signal, saying so" do
    verification = verifier(["sh", "-c", "echo dying; kill -9 $$"]).call(candidate)

    expect([verification.outcome, verification.detail]).to match([:failed, /killed by a signal.*dying/m])
  end

  it "fails a candidate whose path is not a directory, creating nothing there" do
    missing = File.join(@dir, "gone")

    verification = verifier(%w[true]).call(Lain::Isolation::Candidate.new(sha:, path: missing))

    expect([verification.outcome, verification.detail, File.exist?(missing)])
      .to match([:failed, /#{Regexp.escape(missing)}.*not a directory/, false])
  end

  it "fails, rather than raising, when the checkout's tmp is a file" do
    File.write(File.join(checkout, "tmp"), "in the way")

    verification = verifier(%w[true]).call(candidate)

    expect([verification.outcome, verification.detail]).to match([:failed, /could not run: File exists/])
  end

  it "runs in the expanded checkout when the candidate names it relatively" do
    relative = Lain::Isolation::Candidate.new(sha:, path: Pathname(checkout).relative_path_from(Dir.pwd).to_s)

    tmp = File.join(checkout, "tmp", "lain-verify-0123456789ab")
    script = "test \"$PWD\" = #{checkout} && test \"$TMPDIR\" = #{tmp} && test -d #{tmp}"

    verification = verifier(["sh", "-c", script]).call(relative)

    expect(verification.outcome).to eq(:passed)
  end

  it "fails a command over its timeout, naming it, and leaves nothing of it running" do
    pid_file = File.join(@dir, "child.pid")

    script = "echo started; sleep 5 & echo $! > #{pid_file}; wait"
    verification = verifier(["sh", "-c", script], verify_timeout: 1).call(candidate)

    expect([verification.outcome, verification.detail]).to match([:failed, /timed out.*\nstarted\n/m])
    pid = Integer(File.read(pid_file))
    expect(wait_until(reason: "the timed-out command's child to die") { gone?(pid) }).to be(true)
  end

  it "gives the command its own TMPDIR under the checkout and no GIT_ context, then removes it" do
    out = File.join(@dir, "env.out")
    script = "printf '%s\\n' \"$TMPDIR\" \"${GIT_INDEX_FILE-absent}\" > #{out}; test -d \"$TMPDIR\""

    verification = with_env("GIT_INDEX_FILE" => "/elsewhere/index") { verifier(["sh", "-c", script]).call(candidate) }

    tmp = File.join(checkout, "tmp", "lain-verify-0123456789ab")
    expect([verification.outcome, File.readlines(out, chomp: true), File.exist?(tmp)])
      .to eq([:passed, [tmp, "absent"], false])
  end

  it "hides the caller's GIT_OBJECT_DIRECTORY from the command" do
    out = File.join(@dir, "objects.out")
    script = "printf '%s' \"${GIT_OBJECT_DIRECTORY-absent}\" > #{out}"

    with_env("GIT_OBJECT_DIRECTORY" => "/elsewhere/objects") { verifier(["sh", "-c", script]).call(candidate) }

    expect(File.read(out)).to eq("absent")
  end

  it "runs while holding the suite lock" do
    lock = File.join(paths.state_home, "locks", "suite.lock")

    verification = verifier(["sh", "-c", "grep -q pid=#{Process.pid} #{lock}"]).call(candidate)

    expect(verification.outcome).to eq(:passed)
  end
end
