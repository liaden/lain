# frozen_string_literal: true

require "tmpdir"

# Real process groups, made and signalled here; every child names its own
# TMPDIR, so a run whose own TMPDIR is a verify's marks nothing by accident.
RSpec.describe Lain::Isolation::Verifier::StaleGroup, :seam do
  around do |example|
    Dir.mktmpdir("lain-stale-group") do |dir|
      @dir = File.realpath(dir)
      example.run
    ensure
      reapers.each_key { |pid| stopped(pid) }
    end
  end

  let(:notices) { [] }
  let(:reapers) { {} }
  let(:probe) { Lain::Liveness::Probe.new }
  let(:plain) { { "TMPDIR" => @dir } }
  let(:marked) { { "TMPDIR" => File.join(@dir, "checkout", "tmp", "lain-verify-0123456789ab") } }

  def stale_group(**) = described_class.new(notice: notices.method(:<<), grace: 0.3, **)

  def group(env, script)
    pid = Process.spawn(env, "sh", "-c", script, pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
    reapers[pid] = Process.detach(pid)
    pid
  end

  def exited(pid) = reapers.fetch(pid).join

  def line(pgid, start) = "pid=999999999 command=lain land drain verify_pgid=#{pgid} start=#{start}"

  def gone?(pid)
    Process.kill(0, pid)
    false
  rescue Errno::ESRCH
    true
  end

  def group_gone?(pgid)
    Process.kill(0, -pgid)
    false
  rescue Errno::ESRCH
    true
  end

  def stopped(pid)
    Process.kill(:KILL, -pid)
  rescue Errno::ESRCH
    nil
  end

  def ready(pid) = wait_until(reason: "the group #{pid} to start") { probe.start_of(pid) != "-" && pid }

  it "marks a group with its pgid and its leader's start" do
    pid = ready(group(plain, "exec sleep 60"))

    expect(stale_group.mark(pid)).to eq("verify_pgid=#{pid} start=#{probe.start_of(pid)}")
  end

  it "stops a group whose leader's start still matches, saying so" do
    pid = ready(group(plain, "exec sleep 60"))

    stale_group.call(line(pid, probe.start_of(pid)))

    expect(group_gone?(pid)).to be(true)
    expect(notices).to contain_exactly(a_string_including("stopped verify group #{pid}"))
  end

  it "reads the recorded group off the line's end, whatever the command before it holds" do
    pid = ready(group(plain, "exec sleep 60"))
    decoy = "pid=999999999 command=lain verify_pgid=1 start=2 verify_pgid=#{pid} start=#{probe.start_of(pid)}"

    stale_group.call(decoy)

    expect(notices).to contain_exactly(a_string_including("stopped verify group #{pid}"))
  end

  it "KILLs a group that ignores TERM" do
    trapped = File.join(@dir, "trapped")
    pid = group(plain, "trap '' TERM; sleep 60 & echo $! > #{trapped}; wait")
    wait_until(reason: "the group to ignore TERM") { File.size?(trapped) }

    stale_group.call(line(pid, probe.start_of(pid)))

    expect(group_gone?(pid)).to be(true)
    expect(notices).to contain_exactly(a_string_including("stopped verify group #{pid}"))
  end

  it "says when a group could not be stopped" do
    pid = ready(group(plain, "exec sleep 60"))
    deaf = ->(signal, target) { Process.kill(signal, target) if signal == 0 }

    stale_group(signal: deaf).call(line(pid, probe.start_of(pid)))

    expect([gone?(pid), notices]).to match([false, [a_string_including("could not be stopped", "group #{pid}")]])
  end

  it "stops a group under a reused pid when a member carries a verify's TMPDIR" do
    pid = ready(group(marked, "exec sleep 60"))

    stale_group.call(line(pid, Integer(probe.start_of(pid)) + 1))

    expect(notices).to contain_exactly(a_string_including("stopped verify group #{pid}"))
  end

  it "stops a group whose leader is gone when a member carries a verify's TMPDIR" do
    leader = group(marked, "sleep 60 & echo $! > #{@dir}/member")
    exited(leader)
    member = Integer(File.read(File.join(@dir, "member")))

    stale_group.call(line(leader, 1))

    expect([wait_until(reason: "the member to die") { gone?(member) }, notices])
      .to match([true, [a_string_including("stopped verify group #{leader}")]])
  end

  it "leaves alone a group whose leader is gone when no member carries a verify's TMPDIR" do
    leader = group(plain, "sleep 60 & echo $! > #{@dir}/member")
    exited(leader)

    stale_group.call(line(leader, 1))

    expect([gone?(Integer(File.read(File.join(@dir, "member")))), notices]).to eq([false, []])
  end

  it "leaves alone an unmarked group while a marked process runs in another group" do
    recorded = ready(group(plain, "exec sleep 60"))
    elsewhere = ready(group(marked, "exec sleep 60"))

    stale_group.call(line(recorded, Integer(probe.start_of(recorded)) + 1))

    expect([gone?(recorded), gone?(elsewhere), notices]).to eq([false, false, []])
  end

  it "kills nothing and says so when the start time cannot be read" do
    pid = ready(group(marked, "exec sleep 60"))

    stale_group(proc_root: File.join(@dir, "no-proc")).call(line(pid, probe.start_of(pid)))

    expect([gone?(pid), notices]).to match([false, [a_string_including("verify group #{pid}", "left it running")]])
  end

  it "does nothing for a holder that died before its verify started" do
    stale_group.call("pid=999999999 command=lain land drain")

    expect(notices).to be_empty
  end
end
