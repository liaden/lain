# frozen_string_literal: true

module Lain
  # A provider's prompt-cache economics, promoted to a first-class value so a
  # cache-aware compaction scheduler (planning/specs/cache-aware-compaction.md,
  # CAC-3/CAC-4) can read real numbers instead of a hardcoded constant.
  #
  # * `ttl` -- sliding-window seconds; any cache hit resets the clock, and no
  #   activity for this long means the prefix is cold. 0 for a provider with no
  #   cache to go cold.
  # * `min_prefix_tokens` -- below this many tokens the wire caches nothing,
  #   silently (Anthropic's documented behavior; verified, see CLAUDE.md).
  # * `write_multiplier`/`read_multiplier` -- cost relative to one plain,
  #   uncached input token. 1.0/1.0 is the honest value for a provider that
  #   does not cache at all: no premium to write, no discount to read.
  # * `tiered_invalidation` -- true when a message-only rewrite (compaction)
  #   leaves the tools+system cache tier intact, so the scheduler knows a
  #   forced-warm compaction pays a partial rebuild, not a full one.
  #
  # This is the neutral home for what used to be two separate per-provider
  # Hash constants (`Provider::Anthropic::CACHE_PROFILE`,
  # `Provider::Ollama::NO_CACHING_PROFILE`); every {Provider} now answers
  # `#cache_profile` with one of the instances below instead.
  CacheProfile = Data.define(:ttl, :min_prefix_tokens, :write_multiplier, :read_multiplier, :tiered_invalidation)

  # Reopened, NOT a `Data.define ... do` block: a constant defined inside that
  # block resolves against the enclosing module (`Lain`), not the Data class
  # itself -- the trap `Request::SYSTEM_PREFIX` documents (CLAUDE.md).
  class CacheProfile
    # Anthropic's minimum cacheable prefix (Opus 4.8/4.7, verified via the
    # claude-api skill): a prompt that ends under this many tokens silently
    # does not cache, with no error. The one home for the constant that
    # {Tool::SpawnPolicy::PrefixStrategy::SiblingTemplate} used to define
    # locally -- re-exported there so existing references keep resolving.
    MINIMUM_CACHEABLE_TOKENS = 4096

    # Hash-shaped `[]` access for the duck-typed consumers that predate this
    # value -- {StatusFeed#slide_cache_deadline} and {Compaction::Cold} both
    # read a provider's cache profile as `profile[:ttl]` without caring about
    # the concrete type, so a CacheProfile has to be a drop-in replacement
    # for the Hash they used to receive, not a breaking one. Scoped to the
    # Data's own `members`, though: an unknown key is a caller bug (a typo,
    # or reaching for a method that merely happens to exist, e.g.
    # `profile[:frozen?]`), not a legitimate Hash-shaped read, so it raises
    # the same way `Hash#fetch` would rather than silently dispatching an
    # arbitrary method.
    def [](key)
      raise KeyError, "key not found: #{key.inspect} (valid fields: #{members.join(", ")})" unless members.include?(key)

      public_send(key)
    end

    # Duck-typed Hash coercion (`Hash#merge`, keyword-splat `**profile`) --
    # completes the same "quacks like the Hash it replaced" contract {#[]}
    # and {#==} serve.
    def to_hash = to_h

    # A CacheProfile and a plain Hash carrying the same fields are the SAME
    # fact about a provider's cache economics: `Provider::Anthropic`'s and
    # `Provider::Ollama`'s specs were written against the old per-provider
    # Hash constants and compare `#cache_profile` to a Hash literal via `eq`
    # -- promoting the return value to this first-class type must not force
    # a rewrite of those pins. Falls through to Data's own class+fields
    # equality for anything that is not a Hash.
    def ==(other)
      other.is_a?(Hash) ? to_h == other : super
    end

    # #== treats a same-content Hash as equal (above), so #hash MUST agree --
    # otherwise `profile == hash` while `profile.hash != hash.hash` is
    # exactly the landmine Ruby's own hash/eql? contract warns against.
    # Delegating to `to_h.hash` is what keeps them consistent: a Hash's
    # `#hash` is a pure function of its content, so two hashes that are `==`
    # (a CacheProfile's `#to_h`, and whatever Hash or CacheProfile it was
    # compared against) already hash identically.
    def hash = to_h.hash

    # The Anthropic Messages API shape: default 5-minute sliding TTL, 1.25x to
    # write, ~0.1x to read, tiered (tools -> system -> messages) so a
    # message-only rewrite survives the tools+system prefix. Shared verbatim
    # by every Anthropic-wire-compatible backend (AnthropicRaw, Bedrock,
    # BedrockRaw) so their numbers cannot drift from the oracle's -- same
    # constant, not a copy. Data instances are already frozen on
    # construction, so no explicit `.freeze` is needed here or below.
    ANTHROPIC = new(
      ttl: 300,
      min_prefix_tokens: MINIMUM_CACHEABLE_TOKENS,
      write_multiplier: 1.25,
      read_multiplier: 0.1,
      tiered_invalidation: true
    )

    # The honest answer for a provider with no prompt cache at all (Ollama's
    # native path today, and Mock's default): no TTL to go cold, no prefix
    # length that ever caches, and flat cost -- neither a write premium nor a
    # read discount.
    NO_CACHING = new(
      ttl: 0,
      min_prefix_tokens: Float::INFINITY,
      write_multiplier: 1.0,
      read_multiplier: 1.0,
      tiered_invalidation: false
    )
  end
end
