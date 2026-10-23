# frozen_string_literal: true

# Counts digest calls through a spy rather than reading the chain, so a cache that stops hitting shows as a number.
module PrefixDigests
  def digests_during
    count = 0
    allow(Lain::Canonical).to receive(:digest).and_wrap_original do |original, value|
      count += 1
      original.call(value)
    end
    yield
    count
  end
end

RSpec.configure { |config| config.include(PrefixDigests) }
