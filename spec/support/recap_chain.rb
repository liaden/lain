# frozen_string_literal: true

# A compacted chain as a provider is handed it: 13 alternating turns whose head
# the elide strategy replaces with a framed recap, so the first message is one.
module RecapChain
  module_function

  # @return [Array<Hash>] the derived chain's messages, a recap first
  def messages
    history = (0...13).inject(Lain::Dag::Factory.timeline(store: Lain::Dag::Factory.store)) do |line, index|
      line.commit(role: index.even? ? "user" : "assistant", content: [{ "type" => "text", "text" => "turn #{index}" }])
    end
    Lain::Compaction::Derivation.new(strategy: Lain::Compaction::Strategy::Elide.new, keep_last: 3)
                                .derive(history).messages
  end

  # @param value [Object] a wire body, or any part of one
  # @return [Array<String>] every Hash key at any depth, as a String
  def keys_anywhere(value)
    case value
    when Hash then value.keys.map(&:to_s) + value.values.flat_map { keys_anywhere(_1) }
    when Array then value.flat_map { keys_anywhere(_1) }
    else []
    end
  end
end
