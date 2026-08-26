# frozen_string_literal: true

# The loopback arm, restated as an object. Every value here is the one the
# ollama arm has answered since it was written -- the point of the card is
# that `Local` CHANGES NO MEASUREMENT, so an example that disagreed with
# today's provider would be the defect, not the fix.
RSpec.describe Lain::Provider::Ollama::Deployment::Local do
  subject(:deployment) { described_class.new }

  it_behaves_like "an ollama deployment",
                  counterpart: -> { Lain::Provider::Ollama::Deployment::Cloud.new(api_key: +"sk-counterpart") }

  it "dials the base the transport already defaults to" do
    expect(deployment.api_base).to eq(Lain::Provider::Ollama::Transport::DEFAULT_API_BASE)
  end

  it "carries no authorization: a loopback server asks for none" do
    expect(deployment.headers).to eq({})
  end

  it "is local, which is what admission and the secret-read oracle both read" do
    expect(deployment.local?).to be(true)
  end

  it "claims a loaded-runner endpoint, because /api/ps means something here" do
    expect(deployment.runner_status?).to be(true)
  end

  it "claims a model-metadata endpoint, because /api/show answers here" do
    expect(deployment.model_metadata?).to be(true)
  end

  # Pinned by DEFINITION, not by value. Both predicates answer true here, so
  # no value assertion can tell an honest implementation from
  # `alias model_metadata? runner_status?` -- and the separation is the whole
  # point: `/api/ps` reports a SERVED window, `/api/show` the GGUF's trained
  # maximum. A tidy-up that collapsed them would stay green.
  it "answers the two probe predicates from two separate definitions" do
    expect(described_class.instance_method(:model_metadata?).original_name).to eq(:model_metadata?)
  end

  # The restatement guarantee, pinned against a LITERAL. It was pinned against
  # `Provider::Ollama::CAPABILITIES` while the provider held its own list, and
  # that was right then; now that `#capabilities` delegates here and the
  # constant reads back from this class, the old form compared a value with
  # itself and would have stayed green through any change to either. The
  # literal is the only version of this assertion that can still fail.
  it "restates the arm's capability list unchanged" do
    expect(deployment.capabilities).to eq(%i[streaming thinking structured_output])
  end

  # The delegation itself, stated separately so the pair above cannot silently
  # become the same assertion twice: what an outside reader asks the PROVIDER
  # for is what this deployment answers.
  it "is what a bare provider answers when asked for its capabilities" do
    expect(Lain::Provider::Ollama.new.capabilities).to eq(described_class.new.capabilities)
  end

  it "does not cache, which is the honest flat-cost answer for a local server" do
    expect(deployment.cache_profile).to eq(Lain::CacheProfile::NO_CACHING)
  end

  # Six minutes of a model thinking is this arm's honest shape, and the vendored
  # 300/3 envelope is what the whole ollama suite is measured against.
  it "leaves the vendored envelope exactly where it was" do
    expect([deployment.request_timeout, deployment.max_retries]).to eq([300, 3])
  end

  # nil, not 1: `Provider::Admission.build` already answers 1 for a local
  # endpoint, and a DECLARED 1 here would take precedence over the locality
  # rule and hide it. "Nobody said" is the true answer.
  it "declares no admission width, leaving the locality rule in charge" do
    expect(deployment.admission_width).to be_nil
  end

  it "writes the loopback base onto a configuration" do
    config = deployment.apply(Lain::Provider::HTTP::Configuration.new)
    expect(config.ollama_api_base).to eq(Lain::Provider::Ollama::Transport::DEFAULT_API_BASE)
  end

  it "writes the vendored envelope onto a configuration, moving no measurement" do
    config = deployment.apply(Lain::Provider::HTTP::Configuration.new)
    expect([config.request_timeout, config.max_retries]).to eq([300, 3])
  end

  it "writes no api key onto a fresh configuration" do
    config = deployment.apply(Lain::Provider::HTTP::Configuration.new)
    expect(config.ollama_api_key).to be_nil
  end

  # THE EXAMPLE THAT SHOULD HAVE CAUGHT IT. The version above asserts against a
  # fresh Configuration, which is the one state where a stray key cannot exist
  # -- so it read as a guard while being blind to the only thing it guarded
  # against. A loopback config carrying an ollama.com Bearer sends that key, in
  # plaintext, to whatever is listening on port 11434. Clearing the key is
  # therefore something `Local#apply` must DO, not merely something it declines
  # to write: today's arm has no key concept at all, and `Local` has to
  # preserve that property rather than depend on nobody having set one.
  it "clears an api key another deployment left on a configuration it is handed" do
    leaked = Lain::Provider::Ollama::Deployment::Cloud.new(api_key: +"sk-must-not-survive")
    config = leaked.apply(Lain::Provider::HTTP::Configuration.new)
    expect(deployment.apply(config).ollama_api_key).to be_nil
  end

  it "does not leave the cloud base behind either, so the key and the base cannot disagree" do
    leaked = Lain::Provider::Ollama::Deployment::Cloud.new(api_key: +"sk-must-not-survive")
    config = leaked.apply(Lain::Provider::HTTP::Configuration.new)
    expect(deployment.apply(config).ollama_api_base).to eq(Lain::Provider::Ollama::Transport::DEFAULT_API_BASE)
  end
end
