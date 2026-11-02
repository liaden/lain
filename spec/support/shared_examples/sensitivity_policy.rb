# frozen_string_literal: true

# What Policy, Policy::Confined and Policy::Null all answer: the same public
# messages, each with the same signature. A message added to one class fails
# the other two here, and a signature that drifts fails the class that drifted.
#
# `own:` names state a wrapper holds that the policies it wraps do not (Confined's
# roots, write roots, policy and both outside questions), and `lacks:` names that
# same state in the specs of the classes that must not answer it. Neither is a
# place to park a message.
#
# A `delegate` is resolved to its target's signature. `swallows: true` is for the
# Null alone: its `**` stands for the contract's keywords, and any other class
# must name every keyword it takes.
#
# Example:
#   RSpec.describe Lain::Sensitivity::Policy::Null do
#     include_examples "a sensitivity policy", policy_factory: -> { described_class.instance }
#   end
RSpec.shared_examples "a sensitivity policy" do |config|
  policy_factory = config.fetch(:policy_factory)
  own = config.fetch(:own, [])
  lacks = config.fetch(:lacks, [])
  swallows = config.fetch(:swallows, false)

  # message => [positional kinds, { keyword => :keyreq | :key }]
  contract = {
    gates?: [%i[req], { cwd: :keyreq, within: :key }],
    denial: [%i[req], { cwd: :keyreq, named: :key }],
    classify: [%i[req], { within: :key }],
    judge: [%i[req], { cwd: :keyreq, within: :key }],
    confined: [[], { roots: :keyreq }],
    home: [[], {}],
    root: [[], {}],
    read_roots: [[], {}],
    file_facts: [[], {}],
    related?: [%i[req], {}],
    checksums?: [%i[req], { within: :keyreq }],
    in_related_tree?: [%i[req], {}],
    related_directories: [[], {}],
    filter: [[], {}],
    mask_paths: [%i[req], { cwd: :keyreq, within: :key }],
    marks: [%i[req], {}],
    lifts: [%i[req], {}]
  }.freeze

  keyword_kinds = %i[key keyreq].freeze

  let(:contract_policy) { instance_exec(&policy_factory) }

  def contract_publics(klass) = klass.public_instance_methods - Object.public_instance_methods

  def contract_signature(object, message)
    parameters = object.method(message).parameters
    return parameters unless parameters.map(&:first) == %i[rest keyrest block]

    target = %i[@sensitivity @policy].filter_map { object.instance_variable_get(_1) }.first
    contract_signature(target, message)
  end

  it "answers every message a sibling policy answers" do
    siblings = [Lain::Sensitivity::Policy, Lain::Sensitivity::Policy::Confined, Lain::Sensitivity::Policy::Null]
    wanted = siblings.flat_map { contract_publics(_1) }.uniq - own - lacks
    answered = contract_publics(contract_policy.class)
    missing = wanted - answered
    expect(missing).to be_empty, "does not answer #{missing.inspect}, which a sibling policy does"
    expect(answered & lacks).to be_empty, "answers #{answered & lacks}, which only a wrapper holds"
  end

  contract.each do |message, (positional, keywords)|
    it "answers ##{message} with the signature the group states" do
      parameters = contract_signature(contract_policy, message)
      explicit = parameters.select { keyword_kinds.include?(_1.first) }.to_h { [_1.last, _1.first] }
      keyrest = parameters.any? { _1.first == :keyrest }
      swallowed = keyrest && swallows ? keywords.keys : []

      expect(parameters.map(&:first) & %i[req opt rest]).to eq(positional)
      expect(keyrest && !swallows).to be(false), "takes ** where it must name its keywords"
      expect(explicit.to_a - keywords.to_a).to be_empty
      expect(keywords.keys - explicit.keys - swallowed).to be_empty, "no keyword for #{keywords.keys - explicit.keys}"
    end
  end
end
