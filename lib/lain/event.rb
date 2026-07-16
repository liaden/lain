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
  # ever look at `#digest`. The payload is never inlined INTO THE ADDRESS: the
  # envelope hashes `payload_digest`, and the payload object lives in the same
  # Store, retrievable by that digest -- large results and snapshots stay out of
  # the addressed header. A locally constructed event additionally CARRIES its
  # body (see {.turn}), so reading `#content` costs no Store round trip; an
  # envelope rebuilt from digests alone is detached and says so loudly.
  class Event
    include ContentAddressed

    KINDS = %i[turn spawn message snapshot].freeze
    ROLES = %w[user assistant].freeze

    class InvalidKind < Error; end
    class InvalidRole < Error; end

    # Asking a digests-only envelope for a body field is a caller bug, not a
    # nil: the body exists, in the Store, under `payload_digest`.
    class Detached < Error; end

    attr_reader :kind, :from, :to, :render_parent, :causal_parents,
                :correlation, :payload_digest, :body, :digest

    # The kind coercion is shared with {Payload}: both carry the kind and both
    # owe the same closed, loud enum, so a typo fails identically wherever a kind
    # is named.
    def self.normalize_kind(kind)
      symbol = kind.to_s.to_sym
      raise InvalidKind, "kind must be one of #{KINDS.join(", ")}, got #{kind.inspect}" unless KINDS.include?(symbol)

      symbol
    end

    # Frozen and deduplicated: `Symbol#to_s` hands back a fresh mutable String,
    # and one unfrozen String is enough to break Ractor shareability downstream.
    def self.normalize_role(role)
      string = -role.to_s
      raise InvalidRole, "role must be one of #{ROLES.join(", ")}, got #{string.inspect}" unless ROLES.include?(string)

      string
    end

    # The :turn constructor -- what `Turn.new` was. Role, content, and meta form
    # the out-of-line {Payload} body (meta stays inside the content address, via
    # the body digest, because it carries causal lineage like "spawned_from");
    # `parent` is the single render edge. `correlation` names the chain by its
    # root event digest -- {Timeline#commit} derives it, so it is nil only on a
    # root or on a turn built outside any chain.
    def self.turn(role:, content:, parent: nil, meta: {}, correlation: nil)
      payload = Payload.new(kind: :turn, body: { "role" => normalize_role(role),
                                                 "content" => content, "meta" => meta })
      new(kind: :turn, payload_digest: payload.digest, body: payload.body,
          render_parent: parent, correlation:)
    end

    def initialize(kind:, payload_digest:, body: nil, from: nil, to: nil,
                   render_parent: nil, causal_parents: [], correlation: nil)
      @kind = self.class.normalize_kind(kind)
      @from = Canonical.normalize(from)
      @to = Canonical.normalize(to)
      @render_parent = Canonical.normalize(render_parent)
      @causal_parents = normalize_causal(causal_parents)
      @correlation = Canonical.normalize(correlation)
      @payload_digest = Canonical.normalize(payload_digest)
      @body = Canonical.normalize(body)
      @digest = Canonical.digest(payload)
      freeze
    end

    # The exact structure that was hashed. `causal_parents` is a set, so its
    # element order must not leak into identity: Canonical preserves array order
    # (array order is meaning), which is precisely why the set is pre-sorted in
    # #normalize_causal before it reaches these bytes. Ruby<->Rust byte parity
    # depends on that pinned order. The carried `body` is deliberately absent:
    # it is addressed through `payload_digest`, never inlined here.
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

    # The former Turn reader surface: the render chain is the first-parent walk,
    # so `parent` IS the render edge, and the body fields read from the carried
    # payload.
    alias parent render_parent

    def root?
      render_parent.nil?
    end

    def role = fetch_body("role")

    def content = fetch_body("content")

    def meta = fetch_body("meta")

    def to_s
      "#<Lain::Event #{kind} #{digest[0, 19]}...>"
    end
    alias inspect to_s

    private

    def fetch_body(key)
      if body.nil?
        raise Detached, "#{self} carries no body; #{payload_digest} addresses it, but out-of-line " \
                        "payload storage is deferred -- rebuild the event from its body fields " \
                        "(e.g. Event.turn) to carry one"
      end

      body.fetch(key)
    end

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
