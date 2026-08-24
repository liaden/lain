# frozen_string_literal: true

# The deployment protocol, asked once of both implementations instead of
# restated in two files. {Lain::Provider::Ollama::Deployment::Local} and
# {Lain::Provider::Ollama::Deployment::Cloud} share no superclass -- they are
# told apart by what they ANSWER, not by what they inherit -- so this group is
# the only written-down copy of the message set, and a third deployment that
# forgets one of them fails here rather than at the first turn against a real
# endpoint.
#
# It pins SHAPE, never a value: every concrete answer (the base, the header,
# the width) is what distinguishes the two, and belongs in each sibling's own
# file. The one exception is `apply`, whose shape IS a value question -- a
# deployment that answered a `request_timeout` and then failed to write it
# would satisfy every other example here.
#
# Include with a subject named `deployment`, and a `counterpart:` callable
# answering the OTHER deployment -- the mixed-state property below is the one
# thing that cannot be asked of an arm in isolation, and it is the property a
# stray credential hides in. Included from both siblings, it covers both
# orders.
#
# The callable runs through `instance_exec` for `store_laws.rb`'s reason: a
# Proc literal in a `describe` body closes over the example GROUP, not an
# instance, so any helper it names has to be rebound to the real example.
# NOT named `config`: an example below binds a local `config` for the
# Configuration it is testing, and an `it` block closes over THIS parameter --
# so the assignment would reach out and clobber the options Hash for every
# example that ran after it, in seed order. `options` cannot collide.
RSpec.shared_examples "an ollama deployment" do |options|
  def fresh_config = Lain::Provider::HTTP::Configuration.new

  def configuration_state(configured)
    [
      configured.ollama_api_base,
      configured.ollama_api_key,
      configured.request_timeout,
      configured.max_retries
    ]
  end

  let(:counterpart) { instance_exec(&options.fetch(:counterpart)) }

  it "states an endpoint with an http scheme and a host to send a request to" do
    uri = URI.parse(deployment.api_base)
    expect([uri.scheme, uri.host]).to match([a_string_matching(/\Ahttps?\z/), a_string_matching(/\S/)])
  end

  # Deliberately NOT "and every key and value is a String": `Local`'s Hash is
  # empty, so `all(be_a(String))` passes over nothing and the assertion reads
  # as coverage it does not have. The shape of a populated header set is
  # {Cloud}'s own business, and is asserted there.
  it "answers a frozen headers Hash" do
    expect(deployment.headers).to be_a(Hash).and be_frozen
  end

  # Not implied by the deployment-level check below: a frozen Hash holding an
  # unfrozen String is itself unshareable, and that is exactly what an
  # interpolated `"Bearer #{key}"` without a `.freeze` produces.
  it "answers headers that are themselves deeply frozen" do
    expect(Ractor.shareable?(deployment.headers)).to be(true)
  end

  it "hands back the SAME headers object every call, so no request rebuilds it" do
    expect(deployment.headers).to equal(deployment.headers)
  end

  # Two probe predicates, not one: `/api/ps` lists LOADED RUNNERS and
  # `/api/show` reports the weights' TRAINED maximum. They are different
  # endpoints answering different questions, and both are reached eagerly at
  # launch, so a deployment has to be able to disown them separately.
  it "answers locality and both probe predicates as booleans, not as truthy values" do
    expect([deployment.local?, deployment.runner_status?, deployment.model_metadata?])
      .to all(be(true).or(be(false)))
  end

  it "answers a frozen capability list of symbols" do
    expect(deployment.capabilities).to be_frozen.and all(be_a(Symbol))
  end

  it "answers a cache profile, never a bare Hash" do
    expect(deployment.cache_profile).to be_a(Lain::CacheProfile)
  end

  it "answers a positive request timeout and a non-negative retry count" do
    expect([deployment.request_timeout.positive?, deployment.max_retries.negative?]).to eq([true, false])
  end

  it "answers an admission width that is either unstated or a real ceiling" do
    width = deployment.admission_width
    expect(width.nil? || (width.is_a?(Integer) && width.positive?)).to be(true)
  end

  it "writes the endpoint and the retry envelope it declared onto a fresh configuration" do
    written = deployment.apply(fresh_config)
    expect([written.ollama_api_base, written.request_timeout, written.max_retries])
      .to eq([deployment.api_base, deployment.request_timeout, deployment.max_retries])
  end

  # THE MIXED-STATE PROPERTY, and it is the one that cannot be asked of an arm
  # on its own. A configuration must always describe exactly ONE deployment. A
  # partial write -- any field left to whatever ran before -- pairs one arm's
  # endpoint with another's credential, and the dangerous direction is not
  # hypothetical: a cloud key left behind a loopback base sends an ollama.com
  # Bearer to `http://localhost:11434`, in plaintext, to whatever is listening.
  #
  # Stated as "indistinguishable from a fresh apply" rather than as a list of
  # expected values, so it stays true of every field the protocol grows later
  # without this group having to learn their names.
  it "leaves a configuration describing only itself, whatever configured it first" do
    reused = deployment.apply(counterpart.apply(fresh_config))
    expect(configuration_state(reused)).to eq(configuration_state(deployment.apply(fresh_config)))
  end

  it "leaves no field of the other deployment behind, including the credential" do
    reused = deployment.apply(counterpart.apply(fresh_config))
    expect(reused.ollama_api_key).to eq(deployment.apply(fresh_config).ollama_api_key)
  end

  # Applying twice must be the same as applying once: `apply` states a complete
  # position, so it cannot depend on what it found.
  it "is idempotent, because it writes a position rather than a difference" do
    once = configuration_state(deployment.apply(fresh_config))
    twice = configuration_state(deployment.apply(deployment.apply(fresh_config)))
    expect(twice).to eq(once)
  end

  it "hands back the configuration it was given, so a caller can keep composing" do
    given = fresh_config
    expect(deployment.apply(given)).to equal(given)
  end

  # CLAUDE.md's mechanical statement of "no reachable mutable state". The
  # headers Hash is the one that can go wrong here: rebuilt per call it is
  # unfrozen, and a deployment outlives the provider call that reads it.
  it "holds no reachable mutable state" do
    expect(Ractor.shareable?(deployment)).to be(true)
  end
end
