# frozen_string_literal: true

module Lain
  # A provider's prompt-cache economics as a value, so a cache-aware compaction
  # scheduler reads real numbers rather than a hardcoded constant. The neutral
  # home for what were per-provider Hash constants; every {Provider} answers
  # `#cache_profile` with one of the instances below.
  #
  # * `ttl` -- sliding-window seconds; any hit resets the clock, and this long
  #   without activity means the prefix is cold. 0 where there is no cache.
  # * `min_prefix_tokens` -- below this the wire caches nothing, SILENTLY
  #   (Anthropic's documented behavior; verified, see CLAUDE.md).
  # * `write_multiplier`/`read_multiplier` -- cost relative to one plain,
  #   uncached input token. 1.0/1.0 is the honest value for a provider that does
  #   not cache: no premium to write, no discount to read.
  # * `tiered_invalidation` -- true when a message-only rewrite leaves the
  #   tools+system tier intact, so the scheduler knows a forced-warm compaction
  #   pays a partial rebuild, not a full one.
  CacheProfile = Data.define(:ttl, :min_prefix_tokens, :write_multiplier, :read_multiplier, :tiered_invalidation)

  class CacheProfile
    # Reopened, NOT a `Data.define ... do` block: a constant defined inside that
    # block resolves against the enclosing module (`Lain`), not the Data class
    # itself -- the trap `Request::SYSTEM_PREFIX` documents (CLAUDE.md).

    # Anthropic's minimum cacheable prefix (Opus 4.8/4.7, verified via the
    # claude-api skill): a prompt ending under this many tokens silently does not
    # cache, with no error. Re-exported from
    # {Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate}, which used to own it.
    MINIMUM_CACHEABLE_TOKENS = 4096

    # Hash-shaped access for the duck-typed consumers that predate this value:
    # {StatusFeed#slide_cache_deadline} and {Compaction::Cold} read a profile as
    # `profile[:ttl]` without caring about the type, so this must be a drop-in
    # for the Hash they used to receive. Scoped to the Data's own `members`,
    # though -- an unknown key is a caller bug (a typo, or reaching for a method
    # that merely happens to exist, `profile[:frozen?]`), so it raises the way
    # `Hash#fetch` would rather than dispatching an arbitrary method.
    def [](key)
      raise KeyError, "key not found: #{key.inspect} (valid fields: #{members.join(", ")})" unless members.include?(key)

      public_send(key)
    end

    # Duck-typed Hash coercion (`Hash#merge`, keyword-splat `**profile`),
    # completing the same "quacks like the Hash it replaced" contract.
    def to_hash = to_h

    # A CacheProfile and a plain Hash of the same fields are the SAME fact about
    # a provider's cache economics: the provider specs were written against the
    # old per-provider Hash constants and compare `#cache_profile` to a Hash
    # literal, and promoting the return value must not force a rewrite of those
    # pins. Falls through to Data's class+fields equality otherwise.
    def ==(other)
      other.is_a?(Hash) ? to_h == other : super
    end

    # #== treats a same-content Hash as equal, so #hash MUST agree or
    # `profile == hash` with differing hashes is exactly the landmine Ruby's
    # hash/eql? contract warns about. A Hash's `#hash` is a pure function of its
    # content, so delegating keeps the two consistent by construction.
    def hash = to_h.hash

    # The Anthropic Messages API shape: 5-minute sliding TTL, 1.25x to write,
    # ~0.1x to read, tiered (tools -> system -> messages) so a message-only
    # rewrite survives the tools+system prefix. Shared by every
    # Anthropic-wire-compatible backend as the SAME constant, not a copy, so
    # their numbers cannot drift from the oracle's. Data instances freeze on
    # construction, so no explicit `.freeze` is needed here or below.
    ANTHROPIC = new(
      ttl: 300,
      min_prefix_tokens: MINIMUM_CACHEABLE_TOKENS,
      write_multiplier: 1.25,
      read_multiplier: 0.1,
      tiered_invalidation: true
    )

    # The honest answer for a provider with no prompt cache at all (Ollama's
    # native path, Mock's default): no TTL to go cold, no prefix length that ever
    # caches, and flat cost -- no write premium, no read discount.
    NO_CACHING = new(
      ttl: 0,
      min_prefix_tokens: Float::INFINITY,
      write_multiplier: 1.0,
      read_multiplier: 1.0,
      tiered_invalidation: false
    )
  end
end
