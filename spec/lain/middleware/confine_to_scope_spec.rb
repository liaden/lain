# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Plan scope confines what a session writes and where its commands run. The
# scope is the board's, read per call, so every session judged through the
# board's stacks is confined while it stands -- a child's, and any other. The
# write tools are real, behind the guard, so "nothing was written" is a fact
# about the disk.
RSpec.describe Lain::Middleware::ConfineToScope do
  subject(:guard) { described_class.new(scope: board_scope) }

  let(:board_scope) { Struct.new(:current).new(Lain::Session::Confined.new(worker_env: spike_env, reminder: "r")) }

  around do |example|
    Dir.mktmpdir("lain-confine") do |dir|
      @base = File.realpath(dir)
      @checkout = File.join(@base, "checkout").tap { FileUtils.mkdir_p(_1) }
      @spike = File.join(@base, "spike").tap { FileUtils.mkdir_p(_1) }
      File.write(File.join(@checkout, "a.rb"), "one\n")
      File.write(File.join(@spike, "a.rb"), "one\n")
      example.run
    end
  end

  def spike_env = Lain::WorkerEnv.new(cwd: @spike, env: {}, checkout: @spike)

  # A session running in the spike, as a plan-scoped chat's and a child's do.
  def confined = Lain::Session.new(worker_env: spike_env)

  # A session still running in the checkout: nothing about it says plan.
  def unconfined = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: @checkout, env: {}))

  def call(name, input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)

  def tool(name) = { "write_file" => Lain::Tools::WriteFile, "edit_file" => Lain::Tools::EditFile }[name]

  # Downstream stands for the rest of the stack: it performs the write tools
  # for real, and says a command ran.
  def through(effect, context: confined)
    guard.call({ effect:, context: }) do |inner|
      invocation = Lain::Tool::Invocation.new(tool_use_id: effect.tool_use_id, context: inner.fetch(:context))
      real = tool(effect.name)
      inner.merge(result: real ? real.new.call(effect.input, invocation) : Lain::Tool::Result.ok("ran"))
    end.fetch(:result)
  end

  # Scenario: a write aimed at the checkout refuses
  describe "a write aimed at the checkout" do
    it "refuses a write_file with an absolute path inside the checkout, naming the scope root" do
      result = through(call("write_file", { "path" => File.join(@checkout, "y.rb"), "content" => "y" }))

      expect(result.is_error).to be(true)
      expect(result.content).to include(@spike, File.join(@checkout, "y.rb"), "Nothing was written")
      expect(File.exist?(File.join(@checkout, "y.rb"))).to be(false)
    end

    it "refuses an edit_file outside the root, leaving the file as it was" do
      result = through(call("edit_file", { "path" => File.join(@checkout, "a.rb"),
                                           "old_string" => "one", "new_string" => "two" }))

      expect(result.is_error).to be(true)
      expect(File.read(File.join(@checkout, "a.rb"))).to eq("one\n")
    end

    it "refuses a relative path that climbs out of the root" do
      result = through(call("write_file", { "path" => "../checkout/y.rb", "content" => "y" }))

      expect(result.is_error).to be(true)
      expect(File.exist?(File.join(@checkout, "y.rb"))).to be(false)
    end

    # A link the spike carries is followed by the kernel, so the path is judged
    # where it really lands.
    it "refuses a path through a link inside the root that lands outside it" do
      File.symlink(@checkout, File.join(@spike, "back"))

      result = through(call("write_file", { "path" => "back/y.rb", "content" => "y" }))

      expect(result.is_error).to be(true)
      expect(File.exist?(File.join(@checkout, "y.rb"))).to be(false)
    end
  end

  describe "a write inside the scope" do
    it "lets a relative path through, landing in the scope's directory" do
      result = through(call("write_file", { "path" => "notes.md", "content" => "spike" }))

      expect(result.is_error).to be(false)
      expect(File.read(File.join(@spike, "notes.md"))).to eq("spike")
    end
  end

  describe "a command" do
    it "refuses a bash cwd outside the root, naming it" do
      result = through(call("bash", { "command" => "touch y", "cwd" => @checkout }))

      expect(result.is_error).to be(true)
      expect(result.content).to include(@spike, "Nothing was run")
    end

    it "lets a bash call with no cwd through, since it runs in the scope" do
      expect(through(call("bash", { "command" => "touch y" })).content).to eq("ran")
    end

    it "refuses a cwd that cannot be resolved at all" do
      expect(through(call("bash", { "command" => "ls", "cwd" => "sub\0dir" })).is_error).to be(true)
    end

    it "lets a bash cwd inside the root through" do
      expect(through(call("bash", { "command" => "ls", "cwd" => "sub" })).content).to eq("ran")
    end
  end

  # The shape a child spawned around the scope would have: the board's scope
  # still confines it.
  describe "a session in the checkout, judged while the board's scope confines" do
    it "refuses its absolute write into the checkout" do
      result = through(call("write_file", { "path" => File.join(@checkout, "child.rb"), "content" => "c" }),
                       context: unconfined)

      expect(result.is_error).to be(true)
      expect(File.exist?(File.join(@checkout, "child.rb"))).to be(false)
    end

    it "refuses its relative write, which lands where that session stands" do
      result = through(call("write_file", { "path" => "child.rb", "content" => "c" }), context: unconfined)

      expect(result.is_error).to be(true)
      expect(File.exist?(File.join(@checkout, "child.rb"))).to be(false)
    end

    it "refuses a command with no cwd, which runs where that session stands" do
      expect(through(call("bash", { "command" => "touch y" }), context: unconfined).is_error).to be(true)
    end

    it "judges a call with no session behind it where the process stands" do
      expect(through(call("bash", { "command" => "ls", "cwd" => @checkout }), context: nil).is_error).to be(true)
    end
  end

  describe "a board scope that confines nothing" do
    let(:board_scope) { Struct.new(:current).new(Lain::Session::Unconfined) }

    it "passes every write and command through untouched" do
      write = through(call("write_file", { "path" => File.join(@base, "z.rb"), "content" => "z" }),
                      context: unconfined)
      command = through(call("bash", { "command" => "ls", "cwd" => @base }), context: nil)

      expect([write.is_error, command.content]).to eq([false, "ran"])
    end
  end

  it "passes a tool it does not confine, whatever it names" do
    expect(through(call("read_file", { "path" => File.join(@checkout, "a.rb") })).content).to eq("ran")
  end
end
