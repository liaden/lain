# frozen_string_literal: true

require "timeout"

# Two real `lain up` cockpits on one machine: different projects, one shared XDG tree, each on its
# own tmux socket, each replaying its own recorded turn.
RSpec.describe "two cockpits on one machine", :e2e do
  def prompts
    { "a" => "Reply with the single word alpha and nothing else.",
      "b" => "Reply with the single word bravo, then count from one to five in words." }
  end

  def flags = %w[--provider ollama --model qwen3:4b --seed 1 --temperature 0]

  def patience = E2E::Cassette.recording? ? 300 : 20

  def key_of(sandbox) = Lain::Paths.new(env: sandbox.env).project_hash(sandbox.project.to_s)

  def answers?(cockpit)
    Timeout.timeout(15) { cockpit.editor.evaluate("1+1") == 2 }
  rescue Timeout::Error
    raise "a cockpit editor did not evaluate 1+1 within 15s"
  end

  # A swap file collides only with a dirty peer, so the first cockpit's scratch buffer is made dirty
  # before the second boots.
  def dirty_scratch_buffer(cockpit)
    scratch = "bufnr('lain-cockpit://start')"
    cockpit.editor.command("call setbufline(#{scratch}, 1, 'dirty')")
    return if cockpit.editor.evaluate("getbufvar(#{scratch}, '&modified')").to_i.positive?

    raise "the scratch buffer is still unmodified"
  end

  def spent(cockpit) = cockpit.state.fetch("run_tokens")

  def billed(cockpit)
    cockpit.session.records("turn_usage").sum { |record| record.fetch("usage").values.grep(Integer).sum }
  end

  def run_turn(cockpit, prompt)
    cockpit.type(prompt)
    cockpit.session.wait_for("turn_usage", timeout: patience) { |record| record["stop_reason"] == "end_turn" }
    wait_until(timeout: patience, reason: "the status feed to count the turn") do
      cockpit.state["run_tokens"].to_i.positive?
    end
  end

  def observe(cockpit_a, cockpit_b)
    { panes: [cockpit_a.capture(:editor), cockpit_b.capture(:editor)],
      spent: [spent(cockpit_a), spent(cockpit_b)], billed: [billed(cockpit_a), billed(cockpit_b)] }
  end

  once(:journey) do
    E2E::Cassette.serve("two_cockpits_a") do |upstream_a, _cassette_a|
      E2E::Cassette.serve("two_cockpits_b") do |upstream_b, _cassette_b|
        first = E2E::Sandbox.create
        second = E2E::Sandbox.create(share_state_with: first, project: "proj-b")
        cockpit_a = E2E::Cockpit.start(first, upstream_a, *flags)
        run_turn(cockpit_a, prompts.fetch("a"))
        dirty_scratch_buffer(cockpit_a)
        cockpit_b = E2E::Cockpit.start(second, upstream_b, *flags, boot_seconds: 15)
        both_answer = [answers?(cockpit_a), answers?(cockpit_b)]
        run_turn(cockpit_b, prompts.fetch("b"))
        seen = observe(cockpit_a, cockpit_b)
        cockpit_a.stop
        seen.merge(both_answer:, after_stop: answers?(cockpit_b),
                   keys: [key_of(first), key_of(second)],
                   state_dirs: Dir.glob(first.state_home.join("lain", "status", "*").to_s).map { |d| File.basename(d) })
      ensure
        cockpit_b&.stop
        cockpit_a&.stop
      end
    end
  end

  it "answers an RPC evaluate from both editors" do
    expect(journey.fetch(:both_answer)).to eq([true, true])
  end

  it "shows no swap file collision in either editor pane" do
    expect(journey.fetch(:panes).join).not_to include("E325")
  end

  it "keeps one status feed per project, each with its own run's tokens" do
    expect(journey.fetch(:state_dirs)).to match_array(journey.fetch(:keys))
    expect(journey.fetch(:spent)).to eq(journey.fetch(:billed))
    expect(journey.fetch(:spent).uniq.size).to eq(2)
  end

  it "leaves the second cockpit's editor answering after the first stops" do
    expect(journey.fetch(:after_stop)).to be(true)
  end
end
