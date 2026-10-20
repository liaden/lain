# frozen_string_literal: true

RSpec.describe Lain::Sensitivity::Secrets do
  let(:token) { "ghp_aB3dE5gH7jK9mN1pQ3sT5vX7zA9cE1gI3kM5" }

  def session_lending(env) = Lain::Session.new(worker_env: Lain::WorkerEnv.new(cwd: Dir.pwd, env:))

  it "lists a value the call's context lends" do
    secrets = described_class.for(child_env: Lain::Exec::ChildEnv.new(env: {}),
                                  context: session_lending("LENT_TOKEN" => "hunterhunterhunter"))

    expect(secrets).to include("hunterhunterhunter")
  end

  it "lists a passed launch value the context never lent" do
    child_env = Lain::Exec::ChildEnv.new(pass: %w[FOO], env: { "FOO" => token })

    expect(described_class.for(child_env:, context: session_lending({}))).to include(token)
  end

  it "reads a missing context as the null session" do
    child_env = Lain::Exec::ChildEnv.new(pass: %w[FOO], env: { "FOO" => token })

    expect(described_class.for(child_env:, context: nil)).to include(token)
  end
end
