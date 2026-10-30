# frozen_string_literal: true

# Counts digest calls through a spy rather than reading the chain, so a cache that stops hitting shows as a number.
# Spied at digest_bytes, which every digest ends in, since the chain hashes bytes it dumped itself.
module PrefixDigests
  def digests_during
    count = 0
    allow(Lain::Canonical).to receive(:digest_bytes).and_wrap_original do |original, bytes|
      count += 1
      original.call(bytes)
    end
    yield
    count
  end
end

RSpec.configure { |config| config.include(PrefixDigests) }
