# frozen_string_literal: true

require_relative "canonical"
require_relative "content_addressed"
require_relative "error"

module Lain
  # A frozen node in the Timeline: a role, its content blocks, and the digest of
  # its parent. Its own digest is the content address of those three fields.
  #
  # Hashing names the turn; it does not replace it. The full content is retained
  # here and in the Store, so nothing is lost. Comparison and deduplication are
  # cheap because they only ever look at +digest+.
  class Turn
    include ContentAddressed

    ROLES = %w[user assistant].freeze

    class InvalidRole < Error; end

    attr_reader :role, :content, :parent, :meta, :digest

    def initialize(role:, content:, parent: nil, meta: {})
      @role = normalize_role(role)
      @content = Canonical.normalize(content)
      @parent = parent&.dup&.freeze
      @meta = Canonical.normalize(meta)
      @digest = Canonical.digest(payload)
      freeze
    end

    def root?
      parent.nil?
    end

    # The exact structure that was hashed. Also what a Journal writes.
    def payload
      { "role" => role, "content" => content, "parent" => parent, "meta" => meta }
    end

    def to_s
      "#<Lain::Turn #{role} #{digest[0, 19]}...>"
    end
    alias inspect to_s

    private

    # Frozen and deduplicated: `Symbol#to_s` hands back a fresh mutable String,
    # and one unfrozen ivar is enough to make the whole Turn non-shareable.
    def normalize_role(role)
      string = -role.to_s
      raise InvalidRole, "role must be one of #{ROLES.join(", ")}, got #{string.inspect}" unless ROLES.include?(string)

      string
    end
  end
end
