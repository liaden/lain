# frozen_string_literal: true

require "tmpdir"
require "socket"

RSpec.describe Lain::Chores::Queue, :seam do
  let(:dir) { Dir.mktmpdir("lain-chores") }
  let(:file) { File.join(dir, "TODOS.md") }
  let(:lock) { Lain::FileLock.new(File.join(dir, "chores.lock")) }
  let(:queue) { described_class.at(dir, lock:) }
  let(:body) { "# Chores\n- [ ] fix the thing\n- [ ] [research] compare x and y\n- [x] done already\n" }

  before { File.write(file, body) }

  after { FileUtils.remove_entry(dir) }

  def host = Regexp.escape(Socket.gethostname)

  def dead_pid
    pid = fork { exit!(0) }
    Process.wait(pid)
    pid
  end

  it "loads the open items in file order, tagged" do
    pairs = queue.open.map { |item| [item.text, item.tag] }

    expect(pairs).to eq([["fix the thing", nil], ["compare x and y", "research"]])
  end

  it "has nothing open when the file is absent" do
    FileUtils.rm_f(file)

    expect(queue.open).to eq([])
  end

  it "keeps every other line verbatim when it claims" do
    queue.claim(queue.open.first)

    lines = File.readlines(file, chomp: true)
    expect(lines.values_at(0, 2, 3)).to eq(["# Chores", "- [ ] [research] compare x and y", "- [x] done already"])
  end

  it "writes a claim line a reload sees as claimed and live" do
    claimed = queue.claim(queue.open.first)

    expect(File.readlines(file, chomp: true)[1])
      .to match(/\A- \[~\] fix the thing  <!-- lain pid=#{Process.pid} start=\S+ host=#{host} since=\S+ -->\z/)
    expect(claimed.state).to eq(:claimed)
    expect(queue.open.map(&:text)).to eq(["compare x and y"])
  end

  it "keeps an item's id through a claim" do
    item = queue.open.first

    expect(queue.claim(item).id).to eq(item.id)
  end

  it "offers a claim whose pid is gone as abandoned, and a claim takes it again" do
    File.write(file, "- [~] fix  <!-- lain pid=#{dead_pid} start=1 host=#{Socket.gethostname} since=s -->
")

    abandoned = queue.open.first
    expect(abandoned.state).to eq(:abandoned)
    expect(queue.claim(abandoned).claim.pid).to eq(Process.pid)
  end

  it "treats a claim on another host as live" do
    File.write(file, "- [~] fix  <!-- lain pid=1 start=1 host=elsewhere-box since=s -->\n")

    expect(queue.open).to eq([])
  end

  it "refuses an item claimed meanwhile, by name" do
    item = queue.open.first
    described_class.at(dir, lock:).claim(item)

    expect { queue.claim(item) }.to raise_error(Lain::Chores::Queue::Taken, /fix the thing/)
  end

  it "applies a claim to bytes a human edited, and refuses when the line is gone" do
    item = queue.open.first
    File.write(file, "- [ ] added above\n#{body}")
    queue.claim(item)

    expect(File.read(file)).to start_with("- [ ] added above\n# Chores\n- [~] fix the thing")

    File.write(file, "- [ ] something else\n")
    expect { queue.claim(item) }.to raise_error(Lain::Chores::Queue::Taken)
  end

  # The claimants stay alive until both have answered: a claimant that exited would leave an abandoned claim.
  it "lets exactly 1 of 2 processes claim an item, losing no line" do
    item = queue.open.first
    release, gate = IO.pipe
    children = Array.new(2) { claimant(item, release, gate) }
    outcomes = children.map { |_, reader| reader.gets.chomp }
    gate.close
    children.map(&:first).each { |pid| Process.wait(pid) }

    expect(outcomes.sort).to eq(%w[claimed taken])
    expect(File.readlines(file, chomp: true).map { |l| l.sub(/  <!--.*/, "").sub("[~]", "[ ]") })
      .to eq(body.lines(chomp: true))
  end

  def claimant(item, release, gate)
    reader, writer = IO.pipe
    pid = fork do
      [reader, gate].each(&:close)
      writer.puts(claim_outcome(item))
      writer.flush
      release.read
    ensure
      exit!(0)
    end
    writer.close
    [pid, reader]
  end

  def claim_outcome(item)
    described_class.at(dir, lock: Lain::FileLock.new(File.join(dir, "chores.lock"))).claim(item) && "claimed"
  rescue Lain::Chores::Queue::Taken
    "taken"
  end

  it "finishes a claim as done with a note" do
    queue.finish(queue.claim(queue.open.first), outcome: :done, note: "landed abc123")

    expect(File.readlines(file, chomp: true)[1]).to eq("- [x] fix the thing  <!-- landed abc123 -->")
  end

  it "finishes a claim as failed, and a note cannot close its own comment" do
    queue.finish(queue.claim(queue.open.first), outcome: :failed, note: "broke --> badly")

    expect(File.readlines(file, chomp: true)[1]).to match(/\A- \[!\] fix the thing  <!-- broke .* badly -->\z/)
    expect(File.readlines(file, chomp: true)[1].scan("-->").size).to eq(1)
  end

  it "keeps the file mode through a rewrite" do
    File.chmod(0o640, file)
    queue.claim(queue.open.first)

    expect(File.stat(file).mode & 0o777).to eq(0o640)
  end

  it "builds its default lock under the state home, one per project" do
    Dir.mktmpdir("lain-state") do |state|
      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => state, "HOME" => dir })
      described_class.at(dir, paths:).claim(queue.open.first)

      expect(Dir.glob(File.join(state, "lain", "chores", "*", "queue.lock"))).not_to be_empty
    end
  end

  it "makes a claim wait while another process holds the lock" do
    waited = Thread::Queue.new
    rival = Lain::FileLock.new(File.join(dir, "chores.lock"), interval: 0.001, sleeper: ->(_) { waited << :waiting })
    item = queue.open.first
    claimer = nil
    lock.hold do
      claimer = Thread.new { described_class.at(dir, lock: rival).claim(item) }
      expect(waited.pop(timeout: 5)).to eq(:waiting)
      expect(File.read(file)).to eq(body)
    end

    claimer.join
    expect(File.read(file)).to include("- [~] fix the thing")
  end

  it "replaces the file by rename, so a reader never sees a half-written one" do
    inode = File.stat(file).ino
    queue.claim(queue.open.first)

    expect(File.stat(file).ino).not_to eq(inode)
    expect(Dir.children(dir).sort).to eq(%w[TODOS.md chores.lock])
  end

  it "leaves the original bytes and no temp file when the rename fails" do
    allow(File).to receive(:rename).and_raise(Errno::EIO)

    expect { queue.claim(queue.open.first) }.to raise_error(Errno::EIO)
    expect(File.read(file)).to eq(body)
    expect(Dir.children(dir).sort).to eq(%w[TODOS.md chores.lock])
  end

  it "collapses whitespace in a note onto one line" do
    queue.finish(queue.claim(queue.open.first), outcome: :done, note: "a\nb")

    expect(File.readlines(file, chomp: true)[1]).to eq("- [x] fix the thing  <!-- a b -->")
  end

  it "reads every item with its state" do
    queue.claim(queue.open.first)

    expect(queue.items.map { |item| [item.text, item.state] })
      .to eq([["fix the thing", :claimed], ["compare x and y", :open], ["done already", :done]])
  end

  it "never takes or abandons a [~] line that carries no lain claim" do
    File.write(file, "- [~] my own work in progress\n")

    item = queue.items.first
    expect([item.state, queue.open]).to eq([:claimed, []])
    expect { queue.claim(item) }.to raise_error(Lain::Chores::Queue::Taken)
  end

  it "offers a [~] line whose lain note no longer parses as abandoned, and a claim takes it again" do
    File.write(file, "- [~] fix  <!-- lain pid=1 start=abc host=box since=s -->\n")

    expect(queue.open.map(&:state)).to eq([:abandoned])
    expect(queue.claim(queue.open.first).claim.pid).to eq(Process.pid)
  end

  it "leaves a [~] line alone whose comment is a human's, lain-prefixed or not" do
    File.write(file, "- [~] mine  <!-- remember to review -->\n- [~] also mine  <!-- lain pid=3 is slow -->\n")

    expect(queue.items.map(&:state)).to eq(%i[claimed claimed])
    expect(queue.open).to eq([])
  end

  it "gives identical texts distinct ids, so each can be claimed alone" do
    File.write(file, "- [ ] dup\n- [ ] dup\n")
    first, second = queue.open

    expect(first.id).not_to eq(second.id)
    queue.claim(second)
    expect(File.readlines(file, chomp: true)).to match(["- [ ] dup", /\A- \[~\] dup  <!--/])
  end

  it "rewrites the target of a symlinked chore file and leaves the link" do
    real = File.join(dir, "real.md")
    File.rename(file, real)
    File.symlink(real, file)
    queue.claim(queue.open.first)

    expect(File.symlink?(file)).to be(true)
    expect(File.read(real)).to include("- [~] fix the thing")
  end

  it "names a file that is not valid UTF-8" do
    File.binwrite(file, "- [ ] caf\xE9\n")

    expect { queue.open }.to raise_error(Lain::Chores::Queue::Unreadable, /UTF-8/)
  end

  describe "#append" do
    it "writes the open line inside the lock, after a final newline it adds when missing" do
      File.write(file, "- [ ] one")
      seen = []
      path = file
      lock = Object.new
      lock.define_singleton_method(:hold) do |&block|
        seen << File.read(path)
        block.call.tap { seen << File.read(path) }
      end

      line = described_class.at(dir, lock:).append("two")

      expect([line, seen]).to eq(["- [ ] two", ["- [ ] one", "- [ ] one\n- [ ] two\n"]])
    end

    it "ends the new line with CRLF in a CRLF file" do
      File.binwrite(file, "- [ ] one\r\n- [ ] two")

      queue.append("three")

      expect(File.binread(file)).to eq("- [ ] one\r\n- [ ] two\r\n- [ ] three\r\n")
    end

    it "refuses text that would read back as a note" do
      expect { queue.append("fix <!-- lain pid=1 -->") }.to raise_error(Lain::Error, /<!--/)
      expect(File.read(file)).to eq(body)
    end

    it "keeps a file that already ends in a newline as it was" do
      queue.append("tidy")

      expect(File.read(file)).to eq("#{body}- [ ] tidy\n")
    end
  end
end
