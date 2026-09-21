# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"

# `lain chat < prompts.txt`: stdin is a REGULAR FILE, whose offset every process
# holding the descriptor shares. `Mixlib::ShellOut` forks, and the child's
# `STDIN.reopen` hands back what its copy of the parent's read buffer held by
# seeking that shared descriptor -- so the chat, which read stdin buffered,
# re-read its own prompts once a prompt made the model run bash through the
# string arm.
#
# Driven in a CHILD process whose real stdin is the file, because the defect
# lives in the process's own descriptor 0 and a spec process cannot lend its.
# The chat is the one the exe wires, with the model replaced.
module StdinRegularFile
  LIB = File.expand_path("../../../lib", __dir__)

  CHILD = <<~'RUBY'
    require "lain"

    dir = ARGV.fetch(0)
    text = ->(words) { Lain::Response.new(content: [{ "type" => "text", "text" => words }], stop_reason: :end_turn) }
    bash = { "type" => "tool_use", "id" => "tu_bash", "name" => "bash",
             "input" => { "command" => "echo \"$(printf ran)\"" } }
    provider = Lain::Provider::Mock.new(responses: [text.call("one"),
                                                    Lain::Response.new(content: [bash], stop_reason: :tool_use),
                                                    text.call("ran it"), text.call("three"), text.call("unexpected")])
    backend = Class.new(Lain::CLI::Backend) do
      define_method(:provider) { |**| provider }
    end.new({ provider: "ollama", model: nil, max_tokens: 64 }, root: Dir.pwd)
    wiring = Lain::CLI::Wiring.new(
      options: { grace: 5 }, chronicle: Lain::CLI::Chronicle::Null.new,
      paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => dir, "HOME" => dir }),
      status_feed: Lain::StatusFeed.new(path: File.join(dir, "state.json")),
      project: Lain::Project.new(root: dir, cwd: dir, kind: :project, detected_by: :flag),
      tty_factory: lambda { |channel:, **|
        Lain::Frontend::TTY.new(channel:, pastel: Pastel.new(enabled: false), history_path: File.join(dir, "history"),
                                state_path: File.join(dir, "state.json"))
      }
    )
    begin
      wiring.run(backend:, resumed: nil, nvim: nil)
    ensure
      wiring.conductor&.close(reason: :exit)
      said = JSON.parse(JSON.generate(provider.last_request&.messages.to_a))
      asked = said.select { |message| message["role"] == "user" }.flat_map { |message| Array(message["content"]) }
                  .select { |block| block.is_a?(Hash) && block["type"] == "text" }.map { |block| block["text"] }
      File.write(File.join(dir, "asked.json"), JSON.generate(asked))
    end
  RUBY

  # The prompts, in the order the file holds them, and the `y` the second
  # prompt's gated call is answered with.
  PROMPTS = "first prompt\nrun the command\ny\nthird prompt\n"

  def self.run(dir)
    path = File.join(dir, "prompts.txt")
    File.write(path, PROMPTS)
    log = File.join(dir, "output.log")
    pid = Process.spawn(RbConfig.ruby, "-I", LIB, "-e", CHILD, dir, in: path, %i[out err] => log)
    _, status = Process.wait2(pid)
    asked = File.join(dir, "asked.json")
    [File.exist?(asked) ? JSON.parse(File.read(asked)) : nil, File.read(log), status]
  end
end

# The same shared offset one layer down, with no chat and nothing re-seating
# descriptor 0: a process that has read stdin buffered runs a command through
# the string arm, then reads on. A runner that reopened stdin in a forked child
# would seek the shared offset back, and the lines after the first would be
# read twice.
module StdinRegularFileArm
  CHILD = <<~RUBY
    require "json"
    require "lain"

    lines = [$stdin.gets]
    Lain::Exec::Local.new.call(command: ARGV.fetch(0), cwd: Dir.pwd, env: ENV.to_h, timeout: 10)
    File.write(ARGV.fetch(1), JSON.generate(lines + $stdin.each_line.to_a))
  RUBY

  def self.run(dir, command)
    path = File.join(dir, "lines.txt")
    File.write(path, "one\ntwo\nthree\n")
    read = File.join(dir, "read.json")
    log = File.join(dir, "output.log")
    pid = Process.spawn(RbConfig.ruby, "-I", StdinRegularFile::LIB, "-e", CHILD, command, read,
                        in: path, %i[out err] => log)
    _, status = Process.wait2(pid)
    [File.exist?(read) ? JSON.parse(File.read(read)) : nil, File.read(log), status]
  end
end

RSpec.describe "a chat whose stdin is a regular file", :seam do
  it "asks each prompt exactly once, in file order, across a bash call through the string arm" do
    Dir.mktmpdir do |dir|
      asked, output, status = StdinRegularFile.run(dir)

      expect(status).to be_success, output
      expect(asked).to eq(["first prompt", "run the command", "third prompt"]), output
      expect(output).to include("ran")
    end
  end

  it "leaves the shared offset where the reader left it, across a command through the string arm" do
    Dir.mktmpdir do |dir|
      read, output, status = StdinRegularFileArm.run(dir, %(echo "$(printf ran)"))

      expect(status).to be_success, output
      expect(read).to eq(%W[one\n two\n three\n]), output
    end
  end
end
