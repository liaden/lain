# frozen_string_literal: true

# Described by NAME rather than by the value, because {Lain::Context::Identity}
# is an INSTANCE: `RSpec.describe` on it renders every example under the
# combinator's heap address, which changes each run and so cannot be passed to
# `--example`, cannot be replayed by `--only-failures`, and cannot be recorded
# as a flake.
RSpec.describe "Lain::Context::Identity" do
  subject(:identity) { Lain::Context::Identity }

  it "passes the message list through unchanged" do
    messages = [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }]
    expect(identity.call(messages)).to eq(messages)
  end

  it "declares no capabilities" do
    expect(identity.requires).to eq([])
  end
end
