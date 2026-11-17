# frozen_string_literal: true

require "tmpdir"

# A restart of the chat pane keeps the human's keyboard: the `lain input` pane
# outlives the chat it was talking to and finds the next one on the same path.
# A real InputSocket and a real InputPane over a real Unix socket, because the
# difference between a restart and a quit is a frame, and a double would
# decide it for us.
RSpec.describe Lain::CLI::InputSocket, :seam do
  let(:dir) { Dir.mktmpdir("lain-restart") }
  let(:path) { File.join(dir, "input.sock") }
  let(:rails) { [] }
  let(:pipe) { IO.pipe }
  let(:keyboard) { pipe.last }
  let(:screen) { StringIO.new }
  let(:tty) do
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: screen, pastel: Pastel.new(enabled: false),
                            history_path: File.join(dir, "history"), state_path: File.join(dir, "state.json"))
  end
  let(:pane) { Lain::Frontend::InputPane.new(path:, tty:, input: pipe.first, tick: 0.01) }

  after do
    @running&.kill&.join(5)
    pipe.each { |io| io.close unless io.closed? }
    FileUtils.remove_entry(dir)
  end

  def chat
    rail = Lain::Frontend::Intake.new
    queue_log = Lain::Review::Queue::Log.new(paths: Lain::Paths.new(env: { "XDG_STATE_HOME" => dir }))
    socket = described_class.new(rail:, path:, header: -> { "" }, tick: 0.01, log: queue_log).bind.start(nil)
    [socket, rail]
  end

  def settles(within: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    Enumerator.produce { sleep(0.005) && yield }
              .find { |answer| !answer.nil? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline }
  end

  def typed_at(rail, text)
    answered = Thread::Queue.new
    Thread.new { answered.push(rail.read(:you, "you> ")) }
    settles { rail.published.kind == :you || nil }
    settles { screen.string.include?("you> ") || nil }
    keyboard.write("#{text}\n")
    answered.pop(timeout: 5)
  end

  it "keeps the pane waiting, and reconnected to the next chat, when a socket stops without a goodbye" do
    first, first_rail = chat
    @running = Thread.new { pane.run }
    heard = typed_at(first_rail, "before")
    first.stop(goodbye: false)
    second, second_rail = chat

    expect([heard, typed_at(second_rail, "after")]).to eq(%w[before after])
    second.stop
  end

  it "ends the pane when the socket stops with its goodbye" do
    socket, rail = chat
    @running = Thread.new { pane.run }
    typed_at(rail, "hello")
    socket.stop

    expect(@running.join(5)&.value).to eq(0)
  end
end
