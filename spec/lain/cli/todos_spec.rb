# frozen_string_literal: true

require "tmpdir"
require "stringio"
require "socket"

load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI::Todos)

RSpec.describe Lain::CLI::Todos do
  around do |example|
    Dir.mktmpdir("lain-todos-cli") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@dir, "state") }) }
  let(:project) { Lain::Project.new(root: @dir, cwd: @dir, kind: :project, detected_by: :git) }
  let(:file) { File.join(@dir, "TODOS.md") }
  let(:sink) { StringIO.new }
  let(:queue) { Lain::Chores::Queue.at(@dir, paths:) }
  let(:body) { "# Chores\n- [ ] one\n- [ ] two\n- [ ] three\n" }

  before { File.write(file, body) }

  # A runner that takes the next open item and settles it with a canned status, as the real one does.
  def runner(statuses, taking: queue)
    Class.new do
      include Enumerable

      define_method(:each) do |&block|
        statuses.each do |status|
          item = taking.claim(taking.open.first)
          raise Interrupt if status == :interrupt

          block.call(Lain::Chores::Outcome.new(item:, status:, session: nil, sha: nil, note: status.to_s))
        end
      end
    end.new
  end

  def todos(runner) = described_class.new(project:, paths:, sink:, runner:)

  describe "#drain" do
    it "takes at most max_items outcomes in file order, one line each, and exits 0 when all landed" do
      status = todos(runner(%i[landed researched landed])).drain(max_items: 2)

      expect([status, sink.string.lines.map { |line| line[/one|two|three/] }]).to eq([0, %w[one two]])
    end

    it "exits 1 when any outcome failed" do
      expect(todos(runner(%i[landed failed])).drain).to eq(1)
    end

    it "refuses a negative max_items by name before taking anything" do
      expect { todos(runner(%i[landed])).drain(max_items: -1) }.to raise_error(Lain::Error, /max-items/)
      expect(queue.open.size).to eq(3)
    end

    it "accepts a factory for the runner" do
      expect(todos(-> { runner(%i[landed]) }).drain).to eq(0)
    end

    it "exits 130 on Interrupt and leaves the item claimed" do
      status = todos(runner(%i[interrupt])).drain

      expect([status, queue.items.first.state]).to eq([130, :claimed])
    end
  end

  describe "#status" do
    let(:body) { "- [ ] open one\n- [x] done one\n- [!] failed one\n- [ ] claimed one\n" }

    it "counts the items and names each claim's pid, host and liveness" do
      queue.claim(queue.open.last)

      text = todos(runner([])).status

      expect(text).to include("open 1", "claimed 1", "done 1", "failed 1")
      expect(text.lines.last).to eq("~ claimed one (pid #{Process.pid} on #{Socket.gethostname}, live)")
    end

    it "says a claim whose pid is gone is not live" do
      pid = fork { exit!(0) }
      Process.wait(pid)
      File.write(file, "- [~] left behind  <!-- lain pid=#{pid} start=1 host=#{Socket.gethostname} since=s -->\n")

      text = todos(runner([])).status

      expect(text).to include("abandoned 1", "~ left behind (pid #{pid} on #{Socket.gethostname}, not live)")
    end
  end

  describe "#add" do
    it "appends an open line and changes nothing else" do
      line = todos(runner([])).add("tidy the README")

      expect([line, File.read(file)]).to eq(["- [ ] tidy the README", "#{body}- [ ] tidy the README\n"])
    end

    it "starts a new line when the file lacks a final newline" do
      File.write(file, "- [ ] one")

      todos(runner([])).add("two")

      expect(File.read(file)).to eq("- [ ] one\n- [ ] two\n")
    end

    it "refuses empty text" do
      expect { todos(runner([])).add("  ") }.to raise_error(Lain::Error, /empty/)
    end
  end
end
