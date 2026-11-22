# frozen_string_literal: true

require "json"
require "socket"
require "tmpdir"

RSpec.describe Lain::CLI::Wiring::IntakeBuild do
  let(:screen) do
    Class.new do
      attr_reader :said

      def initialize = @said = []
      def render_note(text) = @said << text
      def render_held(text) = @said << "held: #{text}"
      def close_prompt(_text) = nil
      def queue_prompt(_text) = nil
      def drop_prompt(_text) = nil
    end.new
  end
  let(:approve) do
    Struct.new(:name) do
      def usage = "/approve -- probe"
      def call(_args, _env) = "approved"
      def disposition = :control
      def refusal(_env) = "no pending approvals"
    end.new("approve")
  end
  let(:bound) { Lain::CLI::Command::Registry.new([approve]).bind(build_command_env) }
  let(:surface) { [nil] }
  let(:human) { Struct.new(:unused) { def history_for(_tty) = Lain::Frontend::Intake::Unrecorded }.new }
  let(:rail) do
    described_class.rail(tty: screen, human:, notes: Lain::CLI::HumanNotes::Null,
                         on_cycle: -> {}, surface: -> { surface.first && Struct.new(:commands).new(surface.first) })
  end

  def typed(text) = rail << Lain::Frontend::Intake::Line.new(text:, generation: 0)

  it "holds a line while the command surface is not assembled yet" do
    typed("/approve")

    expect(rail.held_lines).to eq(["/approve"])
  end

  it "refuses a control command that has nothing to act on, through the real registry" do
    surface[0] = bound
    typed("/approve")

    expect([screen.said, rail.held_lines]).to eq([["no pending approvals"], []])
  end

  it "holds a line the registry cannot parse rather than raising on the producer" do
    surface[0] = bound
    typed("/")

    expect(rail.held_lines).to eq(["/"])
  end

  it "holds a line the registry cannot parse on the reactor too, where a control command would run" do
    surface[0] = bound
    Sync { typed("@/create-plan") }

    expect([rail.held_lines, screen.said]).to eq([["@/create-plan"], ["held: @/create-plan"]])
  end

  it "runs a command now as a task of its own and says its outcome" do
    probe = described_class::Probe.new(bound: -> { bound }, screen:)
    Sync { probe.run_now("/approve") }

    expect(screen.said).to eq(["approved"])
  end

  it "says a command that raised, and does not kill the thread silently" do
    approve.define_singleton_method(:call) { |*| raise "boom" }
    Sync { described_class::Probe.new(bound: -> { bound }, screen:).run_now("/approve") }

    expect(screen.said).to eq(["command /approve failed: boom"])
  end

  # A pane's reader is a thread of its own with no reactor, and a command that asks a question reads the very
  # rail that thread feeds: running it there would leave the answer unreadable.
  describe "where a note is said" do
    let(:pane) do
      Class.new do
        attr_reader :said

        def initialize(takes)
          @takes = takes
          @said = []
        end

        def note(text, kind: "note")
          return 0 unless @takes

          @said << [kind, text]
          1
        end
      end
    end

    before { surface[0] = bound }

    it "says it in the pane that owns the prompt, and not in the chat" do
      input = pane.new(true)
      rail.attach(input)
      typed("/approve")

      expect([input.said, screen.said]).to eq([[["note", "no pending approvals"]], []])
    end

    it "says it once in each of two panes, and not in the chat" do
      panes = [pane.new(true), pane.new(true)]
      panes.each { |input| rail.attach(input) }
      typed("/approve")

      expect([panes.map(&:said), screen.said]).to eq([[[["note", "no pending approvals"]]] * 2, []])
    end

    it "says a held line's notice in the pane, and not in the chat" do
      input = pane.new(true)
      rail.attach(input)
      typed("plain words")

      expect([input.said, screen.said]).to eq([[["held", "plain words"]], []])
    end

    it "says a human note in the pane, and in the chat when no pane takes it" do
      screen.define_singleton_method(:render_human_note) { |text| said << "human: #{text}" }
      input = pane.new(true)
      notes = described_class::PaneNotes.new(screen)
      notes.render_human_note("one")
      notes.attached(input)
      notes.render_human_note("two")

      expect([input.said, screen.said]).to eq([[%w[human two]], ["human: one"]])
    end

    it "says it in the chat when no pane is attached" do
      typed("/approve")

      expect(screen.said).to eq(["no pending approvals"])
    end

    it "says it in the chat when the attached pane has no one connected" do
      input = pane.new(false)
      rail.attach(input)
      typed("/approve")

      expect(screen.said).to eq(["no pending approvals"])
    end

    it "says it in the chat once the pane is detached" do
      input = pane.new(true)
      rail.attach(input)
      rail.detach(input)
      typed("/approve")

      expect([input.said, screen.said]).to eq([[], ["no pending approvals"]])
    end

    it "says a command's outcome in the pane too" do
      ping = Struct.new(:name) do
        def usage = "/ping -- probe"
        def call(_args, _env) = "pong"
        def disposition = :control
        def refusal(_env) = nil
      end.new("ping")
      surface[0] = Lain::CLI::Command::Registry.new([ping]).bind(build_command_env)
      input = pane.new(true)
      rail.attach(input)
      Sync { typed("/ping") }

      expect([input.said, screen.said]).to eq([[%w[note pong]], []])
    end
  end

  describe "with the real input socket over the rail", :seam do
    let(:dir) { Dir.mktmpdir("lain-intake-build") }
    let(:sock) { File.join(dir, "in.sock") }

    after { FileUtils.remove_entry(dir) }

    it "sends a command's refusal to the connected pane as a note frame and says nothing in the chat" do
      surface[0] = bound
      socket = Lain::CLI::InputSocket.new(rail:, path: sock).bind
      Sync do |task|
        socket.start(task)
        pane = UNIXSocket.new(sock).tap { |io| io.timeout = 5 }
        pane.gets
        pane.write("#{JSON.generate({ "v" => "line", "text" => "/approve", "generation" => 0 })}\n")
        note = Enumerator.produce { JSON.parse(pane.gets.to_s) }.find { |frame| frame["v"] == "note" }
        expect([note["text"], screen.said]).to eq(["no pending approvals", []])
      ensure
        socket.stop
      end
    end
  end

  describe "a control command with something to act on, typed on a thread with no reactor" do
    let(:effect) { Struct.new(:name, :input, :tool_use_id).new("bash", { "command" => "ls" }, "tu") }
    let(:pending) do
      Lain::Approval::Parked::Queue::Pending.new(effect:, identity: Lain::Requester.main, clock: -> { 0.0 })
    end
    let(:real) do
      policy = Lain::Frontend::ApprovalPolicy.new(output: StringIO.new, reader: lambda { |asked|
        rail.read(:approval, asked)
      })
      env = instance_double(Lain::CLI::Command::Env, approvals: [pending])
      Lain::CLI::Command::Registry.new([Lain::CLI::Command::Approve.new(prompt: policy)]).bind(env)
    end

    it "is queued to the chat's reactor, which runs it while the producer returns at once" do
      surface[0] = real
      outcome = Sync do |task|
        draining = rail.attend(task)
        producer = Thread.new { typed("/approve") && :returned }
        pumped_until(task, reason: "the approval asked") { rail.published.kind == :approval }
        rail << Lain::Frontend::Intake::Line.new(text: "y", generation: rail.published.generation)
        pumped_until(task, reason: "the approval decided") { pending.decided? }
        [producer.join(3) && producer.value, pending.approved?, rail.held_lines].tap { draining.stop }
      end

      expect(outcome).to eq([:returned, true, []])
    end

    it "never blocks its producer, and keeps the line for you> where no reactor drains" do
      surface[0] = real
      producer = Thread.new { typed("/approve") && :returned }
      outcome = producer.join(3) ? producer.value : :blocked_producer
      producer.kill

      expect([outcome, rail.held_lines]).to eq([:returned, ["/approve"]])
    end
  end
end
