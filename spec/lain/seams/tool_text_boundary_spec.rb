# frozen_string_literal: true

require "tmpdir"

# The seam a shell command's bytes tore an ask through. `bash` was specced by
# itself and the Timeline was specced by itself, and the raise lived in neither:
# a subprocess buffer turns ASCII-8BIT at its first high byte, even for valid
# UTF-8, and `Canonical.normalize` refuses the string on `Timeline#commit` --
# after the command ran and after the tool_use turn was already committed.
#
# So: a real command through a real {Lain::Tools::Bash}, a real {Lain::Agent}
# over a {Lain::Provider::Mock}, a real {Lain::Timeline}, and the real
# {Lain::CLI::Repl::Ask} whose refusal path is what writes `run_interrupted`.
# The Chronicle is real too; only its journal is a recorder, because the
# records it receives are the observation.
RSpec.describe "a tool result's bytes reaching a commit", :seam do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }
  let(:journal) { RecordingChannel.new }
  let(:chronicle) { Lain::CLI::Chronicle.new(journal:) }
  let(:tty) { instance_double(Lain::Frontend::TTY, render_error: nil) }
  let(:approving) do
    Lain::Middleware::Stack.new([Lain::Middleware::Gate.new(policy: Lain::Middleware::Gate::ApproveAll.new)])
  end

  def agent_for(tool, command, **input)
    toolset = Lain::Toolset.new([tool])
    chronicle.start(context:, toolset:)
    Lain::Agent.new(provider: scripted(command, input), toolset:, context:,
                    handler: Lain::Effect::Handler::Live.new, tool_middleware: approving)
  end

  def scripted(command, input)
    Lain::Provider::Mock.new(responses: [tool_response(["tu_bash", "bash", { "command" => command, **input }]),
                                         text_response("next")])
  end

  # The production frame, `attempt` then `settle`: a raise out of the ask comes
  # back as a value and is journaled as `run_interrupted`, a settled ask is not.
  def ask(agent)
    repl_ask = Lain::CLI::Repl::Ask.new(agent:, tty:, chronicle:)
    repl_ask.settle(repl_ask.attempt("run it"))
  end

  def result_block(agent)
    agent.timeline.to_a.flat_map(&:content).find { |block| block["type"] == "tool_result" }
  end

  def interruptions = journal.events.grep(Lain::Telemetry::RunInterrupted)

  describe "valid UTF-8 output a subprocess handed back as ASCII-8BIT" do
    let(:agent) { agent_for(Lain::Tools::Bash.new, %(printf '\\342\\234\\205 ok')) }

    it "commits the text and carries the ask on to its next model call" do
      expect(ask(agent)).to be_a(Lain::Response)

      block = result_block(agent)
      expect(block["is_error"]).to be(false)
      expect(block["content"]).to include("✅ ok")
      expect(agent.timeline.head.content.first["text"]).to eq("next")
      expect(interruptions).to be_empty
    end
  end

  describe "output that is not UTF-8" do
    let(:agent) { agent_for(Lain::Tools::Bash.new, %(printf 'caf\\351 au lait')) }

    it "commits an error naming bash and saying the output was not text" do
      ask(agent)

      block = result_block(agent)
      expect(block["is_error"]).to be(true)
      expect(block["content"]).to include("bash", "not text")
    end

    it "continues to the next model call and journals no run_interrupted" do
      expect(ask(agent)).to be_a(Lain::Response)

      expect(agent.timeline.head.content.first["text"]).to eq("next")
      expect(interruptions).to be_empty
    end

    # `.b` on both sides: `include?` with a broken-coderange needle answers
    # false whatever the haystack holds.
    it "commits none of the bytes it refused" do
      ask(agent)

      expect(result_block(agent)["content"].b).not_to include("\xE9".b)
    end
  end

  # mixlib embeds the partial capture in its CommandTimeout message, so the
  # bytes that tore a completed command reach the timeout path too. The injected
  # factory only shortens mixlib's hardcoded three-second TERM->KILL grace.
  describe "a command that times out after printing invalid UTF-8" do
    let(:short_grace) do
      lambda do |*args, **opts|
        Mixlib::ShellOut.new(*args, **opts).tap do |shell_out|
          def shell_out.sleep(_grace) = super(0.1)
        end
      end
    end
    let(:tool) { Lain::Tools::Bash.new(exec: Lain::Exec::Local.new(shell_out_factory: short_grace)) }
    # The `: ✅` is what makes the command itself non-ASCII, the shape whose
    # timeout message used to raise before it could say it was a timeout.
    let(:agent) { agent_for(tool, %(sh -c "printf 'caf\\351'; : ✅; sleep 5"), "timeout" => 1) }

    it "answers with an error result that says it timed out, and commits the turn" do
      expect(ask(agent)).to be_a(Lain::Response)

      expect(result_block(agent)["is_error"]).to be(true)
      expect(result_block(agent)["content"]).to include("command timed out after 1s")
      expect(interruptions).to be_empty
    end
  end
end
