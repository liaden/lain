# frozen_string_literal: true

# The suite's own hermeticity against the developer's shell, pinned. `EndpointEnv`
# is a support file that runs its deletions at LOAD time, which is early enough to
# beat `spec/lain/cli_spec.rb`'s `load exe/lain` (Thor bakes every `default:` when
# the class body evaluates) but also early enough that nothing observes it -- so
# without these examples the whole mechanism could be deleted and the suite would
# stay green on any machine that happens not to export these.
#
# It is a top-level spec rather than one under `spec/lain/` for
# `output_discipline_spec.rb`'s reason: the subject is a rule about the SUITE, not
# a class in `lib/`.
RSpec.describe "endpoint env isolation" do
  # The observable consequence, and the example that actually failed on a macOS
  # checkout whose `.envrc` pinned `LAIN_PROVIDER=bedrock`: Thor's declared
  # default for `--provider` must be the built-in one. `cli_spec.rb` asserts the
  # same value from the other side (it reads the option); this one says WHY that
  # is allowed to work.
  it "leaves no endpoint variable set, so Thor's declared defaults are the built-in ones" do
    expect(EndpointEnv::LEAKS.select { |name| ENV.key?(name) }).to be_empty
  end

  # The list is the contract. A new `EnvDefaults` reader in `exe/lain` that is not
  # added here reintroduces exactly the leak this file exists to catch, and the
  # exe is the one place that names them all.
  it "covers every LAIN_ variable exe/lain reads a default from" do
    read = File.read(File.expand_path("../exe/lain", __dir__)).scan(/"(LAIN_[A-Z_]+)"/).flatten.uniq
    expect(read).not_to be_empty
    expect(EndpointEnv::LEAKS).to include(*read)
  end

  # Scrubbing must not have cost the opt-in tiers their switch: `tags.rb` reads
  # the credentials to decide whether `:api_integration` runs at all, so deleting
  # them would silently disable that tier instead of isolating anything.
  it "leaves credentials alone, since the opt-in tiers run on them" do
    expect(EndpointEnv::LEAKS).not_to include("ANTHROPIC_API_KEY", "AWS_BEARER_TOKEN_BEDROCK")
  end

  # The deletion is process-wide, so `with_env` is how an example asks for one --
  # and it must still restore to ABSENT rather than to the developer's value.
  it "still lets with_env set one for an example, restoring it to absent after" do
    with_env("LAIN_PROVIDER" => "ollama") do
      expect(Lain::CLI::EnvDefaults.string("LAIN_PROVIDER", "anthropic")).to eq("ollama")
    end
    expect(ENV.key?("LAIN_PROVIDER")).to be(false)
  end
end
