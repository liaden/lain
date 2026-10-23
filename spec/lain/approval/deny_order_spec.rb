# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Whether any later source (a user's middleware, a remembered answer, an
# approval level) can loosen a refusal an earlier one made final.
RSpec.describe "deny order" do
  let(:journal) { [] }
  let(:chronicle) { Lain::CLI::ToolGuard.detached(journal:).chronicle }
  let(:project_config) { %(approval do\n  deny_tool "write_file"\n  deny_tool "bash"\nend\n) }
  let(:user_config) { "middleware { tool { |env, &down| down.call(env) } }\n" }
  let(:denied) { Lain::Config::Builder.evaluate(project_config, path: "/p/.lain/config.rb").approval.deny_tools }
  let(:passing) do
    Lain::Config::Builder.evaluate(user_config, path: "/u/config.rb",
                                                verbs: Lain::Config::Builder::USER_VERBS).middleware
  end
  let(:board) do
    inputs = Lain::CLI::ToolGuard.detached(journal:).guard_inputs
    Struct.new(:guard_inputs).new(inputs.with(denied_tools: denied, middleware: passing))
  end
  let(:context) { nil }

  def call_of(name, input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name:, input:)

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  describe "a project deny_tool against a user middleware that allows the call" do
    let(:effect) { call_of("write_file", { "path" => File.join(@dir, "out.txt"), "content" => "x" }) }
    let(:stack) { Lain::CLI::ToolGuard.stack(chronicle, board) }

    it_behaves_like "a deny is never loosened"

    it "has the user's middleware in the stack it is judged through" do
      expect(stack.to_a.map(&:class)).to include(Lain::Middleware::Inline)
    end
  end

  describe "a spawned child's stack" do
    let(:checkout) { File.join(@dir, "checkout").tap { |path| FileUtils.mkdir_p(path) } }
    let(:worker_env) { Lain::WorkerEnv.default.with(cwd: checkout, checkout:) }
    let(:context) { Lain::Session.new(worker_env:) }
    let(:effect) { call_of("bash", { "command" => "echo hi" }) }
    let(:stack) do
      Lain::CLI::ToolGuard.child_stack(chronicle, board, worker_env, requester: "researcher")
    end

    it_behaves_like "a deny is never loosened"
  end

  describe "a remembered allow beside a remembered deny of one call shape" do
    let(:input) { { "command" => "rm -rf build" } }
    let(:remembered) do
      entry = Lain::Approval::Remembered::Entry.new(tool: "bash", input:)
      Lain::Approval::Remembered.new(allow: [entry], deny: [entry])
    end
    let(:ladder) do
      rules = Lain::Approval::Escalation::Rules.new(rules: [remembered], tools: Lain::Toolset.new([Lain::Tools::Bash.new]),
                                                    faults: Lain::Approval::Escalation::Faults.new(journal))
      Lain::Approval::Escalation.new([rules], journal:, label: "ask")
    end

    it "rules a final deny from the rules rung" do
      ruling = ladder.rule(call_of("bash", input), nil)

      expect(ruling).to have_attributes(deny?: true, final?: true, rung: "rules")
    end
  end

  describe "a user's config.rb" do
    def user(source)
      Lain::Config::Builder.evaluate(source, path: "/u/config.rb", verbs: Lain::Config::Builder::USER_VERBS)
    end

    it "cannot declare approval rules" do
      expect { user(%(approval do\n  deny_tool "bash"\nend\n)) }
        .to raise_error(Lain::Config::Refusal, /approval belongs in a project's/)
    end

    it "cannot declare deny_tool on its own" do
      expect { user(%(deny_tool "bash"\n)) }
        .to raise_error(Lain::Config::Refusal, /deny_tool; known verbs: middleware, keys/)
    end
  end

  describe "a command the shell verdict refuses by name" do
    let(:verdict) { Lain::Shell::Verdict.new(capability_set: Lain::Shell::Exclusions.new(patterns: ["rm"])) }
    let(:toolset) { Lain::Toolset.new([Lain::Tools::Bash.new(verdict:)]) }
    let(:effect) { call_of("bash", { "command" => "rm -rf build" }) }

    def ruling_under(approval)
      board = Lain::CLI::Switchboard.new(journal:, model: "m", toolset:, verdict:, approval:)
      board.guard_inputs.policy.rule(effect, nil)
    end

    %i[ask auto bypass].each do |approval|
      it "answers the same final triage deny under #{approval}" do
        expect(ruling_under(approval)).to have_attributes(deny?: true, final?: true, rung: "triage")
      end
    end
  end
end
