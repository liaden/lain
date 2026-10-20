# frozen_string_literal: true

RSpec.describe Lain::Middleware::ParsedCommand do
  subject(:middleware) { described_class.new(home: "/home/u") }

  let(:context) { Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: "/p", env: {})) }

  def bash(input) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input:)

  def run(effect)
    seen = nil
    middleware.call(Lain::Middleware::Env.wrap({ effect:, context: })) { |env| (seen = env).merge(result: :done) }
    seen
  end

  it "hands the next member the parse of a bash call's command" do
    named = run(bash({ "command" => "cat a", "cwd" => "sub" })).fetch(:named)

    expect(named.paths.map(&:resolved)).to eq(%w[/p/sub/a])
  end

  it "gives the context the same parse, for the policy that is asked only a context" do
    env = run(bash({ "command" => "cat a" }))

    expect(env[:context].parsed_command).to equal(env.fetch(:named))
  end

  it "carries an unreadable parse when a bash call names no command" do
    expect(run(bash({})).fetch(:named)).to equal(Lain::Shell::Named::UNREADABLE)
  end

  it "leaves a call to another tool as it came" do
    read = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => "a" })

    expect(run(read)[:named]).to be_nil
  end

  it "reads an approval around a bash call as the call" do
    wrapped = Lain::Effect::Approval.new(effect: bash({ "command" => "cat a" }))

    expect(run(wrapped).fetch(:named).paths.map(&:resolved)).to eq(%w[/p/a])
  end
end
