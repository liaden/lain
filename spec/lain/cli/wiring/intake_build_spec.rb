# frozen_string_literal: true

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
      def perishable? = true
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

  it "refuses a perishable command that has nothing to answer, through the real registry" do
    surface[0] = bound
    typed("/approve")

    expect([screen.said, rail.held_lines]).to eq([["no pending approvals"], []])
  end

  it "holds a line the registry cannot parse rather than raising on the producer" do
    surface[0] = bound
    typed("/")

    expect(rail.held_lines).to eq(["/"])
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
  describe "a perishable command with something to answer, typed on a thread with no reactor" do
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
