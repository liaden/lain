# frozen_string_literal: true

module Lain
  # A CloudEvents-shaped envelope: a small, uniform header around a kind-tagged,
  # content-addressed payload. Turn generalizes into Event(kind: :turn) -- one
  # primitive, one content-addressing scheme, one Ractor.shareable? spec, one
  # Store -- so the "everything is an event" spine is literal.
  #
  # Two distinct parent edges, git's model. `render_parent` is SINGLE (the
  # first-parent prompt/message chain the model sees; the render projection is a
  # `git log --first-parent` walk). `causal_parents` is a SET (deliberate
  # multi-parent causality: a synthesis event names the N results it folded).
  # The Store enforces referential integrity over BOTH edges.
  #
  # Identity is the content address of the envelope, so equality and dedup only
  # ever look at `#digest`. The payload is never inlined: the envelope carries
  # `payload_digest` and the payload object lives in the same Store, retrievable
  # by that digest -- large results and snapshots stay out of the header.
  class Event
    include ContentAddressed

    KINDS = %i[turn spawn message snapshot].freeze

    class InvalidKind < Error; end

    attr_reader :kind, :from, :to, :render_parent, :causal_parents,
                :correlation, :payload_digest, :digest

    # The kind coercion is shared with {Payload}: both carry the kind and both
    # owe the same closed, loud enum, so a typo fails identically wherever a kind
    # is named.
    def self.normalize_kind(kind)
      symbol = kind.to_s.to_sym
      raise InvalidKind, "kind must be one of #{KINDS.join(", ")}, got #{kind.inspect}" unless KINDS.include?(symbol)

      symbol
    end

    def initialize(kind:, payload_digest:, from: nil, to: nil,
                   render_parent: nil, causal_parents: [], correlation: nil)
      @kind = self.class.normalize_kind(kind)
      @from = Canonical.normalize(from)
      @to = Canonical.normalize(to)
      @render_parent = Canonical.normalize(render_parent)
      @causal_parents = normalize_causal(causal_parents)
      @correlation = Canonical.normalize(correlation)
      @payload_digest = Canonical.normalize(payload_digest)
      @digest = Canonical.digest(payload)
      freeze
    end

    # The exact structure that was hashed. `causal_parents` is a set, so its
    # element order must not leak into identity: Canonical preserves array order
    # (array order is meaning), which is precisely why the set is pre-sorted in
    # #normalize_causal before it reaches these bytes. Ruby<->Rust byte parity
    # depends on that pinned order.
    def payload
      {
        "kind" => kind,
        "from" => from,
        "to" => to,
        "render_parent" => render_parent,
        "causal_parents" => causal_parents,
        "correlation" => correlation,
        "payload_digest" => payload_digest
      }
    end

    def to_s
      "#<Lain::Event #{kind} #{digest[0, 19]}...>"
    end
    alias inspect to_s

    private

    # A set, normalized to canonical wire form, deduplicated, and sorted so
    # insertion order cannot change the digest. Frozen (elements and array) to
    # keep the whole Event Ractor-shareable.
    def normalize_causal(causal_parents)
      causal_parents.map { |parent| Canonical.normalize(parent) }.uniq.sort.freeze
    end
  end
end

# Payload references Event::KINDS and Event.normalize_kind, so the class body
# must load first.
require_relative "event/payload"
