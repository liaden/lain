# frozen_string_literal: true

require "stringio"

require "state_machines-mermaid" # DEV-only: the diagram never renders at runtime.

# A checked-in diagram that silently diverges from the code is worse than none,
# so it is generated, not drawn, and this spec is its drift guard: it regenerates
# the mermaid source from the live machine and diffs it against the committed
# file. Same posture as `output_discipline_spec.rb` -- enforce mechanically, do
# not document and hope.
#
# Regenerate after an intended machine change:
#   LAIN_REGENERATE=1 bundle exec rspec spec/lain/agent_state_machine_diagram_spec.rb
RSpec.describe "Agent state-machine diagram" do
  diagram_path = File.expand_path("../../docs/agent-state-machine.md", __dir__)

  # The mermaid *source* text, captured from the renderer's injected IO. Nothing
  # here touches a terminal: the renderer writes into a StringIO we own.
  def render_source
    io = StringIO.new
    StateMachines::Mermaid::Renderer.draw_machine(Lain::Agent.state_machine(:state), io:)
    io.string.chomp
  end

  # The full committed document. Both the drift check and `LAIN_REGENERATE`
  # produce it from this one function, so the file can never differ in framing --
  # only in the machine it describes.
  def document(source)
    <<~MARKDOWN
      # Agent state machine

      <!--
        GENERATED from `Lain::Agent`'s `state_machines` definition by
        spec/lain/agent_state_machine_diagram_spec.rb. Do not edit by hand.
        Regenerate:  LAIN_REGENERATE=1 bundle exec rspec spec/lain/agent_state_machine_diagram_spec.rb
        The same spec fails the build if this file drifts from the code.
      -->

      ```mermaid
      #{source}
      ```
    MARKDOWN
  end

  before do
    next unless ENV["LAIN_REGENERATE"]

    File.write(diagram_path, document(render_source))
  end

  it "has a committed diagram matching the current machine" do
    expect(File.read(diagram_path)).to eq(document(render_source))
  end

  it "would fail the build if the source drifted" do
    tampered = render_source.sub("awaiting_model", "somewhere_else")
    expect(File.read(diagram_path)).not_to eq(document(tampered))
  end

  it "renders as source text, not a rendered image" do
    expect(render_source).to start_with("stateDiagram-v2")
  end
end
