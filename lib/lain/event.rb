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
  # the addressed header. A locally constructed event additionally CARRIES the
  # {Payload} it addresses (see {.turn} and `#carried_payload`), so reading
  # `#content` costs no Store round trip and a writer stores that same object
  # rather than rebuilding it; an envelope rebuilt from digests alone is
  # detached and says so loudly.
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
                :correlation, :payload_digest, :body, :carried_payload, :digest

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
    # root or on a turn built outside any chain. `causal_parents` defaults to the
    # empty set, so an ordinary turn hashes exactly as before; the assistant
    # commit populates it with the turn's folded mailbox messages (decision 2),
    # the first production writer of causal edges onto a :turn -- read from the
    # frozen per-turn {Context::Mailbox::Snapshot} the render also folded, never
    # from the live log, or the edge would claim a message the prompt never saw.
    def self.turn(role:, content:, parent: nil, meta: {}, correlation: nil, causal_parents: [])
      payload = Payload.new(kind: :turn, body: { "role" => normalize_role(role),
                                                 "content" => content, "meta" => meta })
      new(kind: :turn, carried_payload: payload, render_parent: parent, correlation:, causal_parents:)
    end

    def initialize(kind:, payload_digest: nil, body: nil, carried_payload: nil, from: nil, to: nil,
                   render_parent: nil, causal_parents: [], correlation: nil)
      @kind = self.class.normalize_kind(kind)
      @from = Canonical.normalize(from)
      @to = Canonical.normalize(to)
      @render_parent = Canonical.normalize(render_parent)
      @causal_parents = normalize_causal(causal_parents)
      @correlation = Canonical.normalize(correlation)
      resolve_payload(carried_payload, payload_digest, body)
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

    # A carried {Payload} IS the payload address and body, so the digest-only
    # path stays as it was, and an envelope with no payload at all refuses
    # loudly -- making payload_digest optional lost the required-keyword
    # ArgumentError, and this guard replaces it.
    def resolve_payload(carried_payload, payload_digest, body)
      return carry(carried_payload, payload_digest, body) unless carried_payload.nil?

      raise ArgumentError, "an Event needs its payload: pass payload_digest or carried_payload" if
        payload_digest.nil?

      @carried_payload = nil
      @payload_digest = Canonical.normalize(payload_digest)
      @body = Canonical.normalize(body)
    end

    # The carried Payload's digest and (already-normalized) body are reused,
    # never recomputed -- which is why one Timeline#commit runs Canonical.digest
    # exactly twice. A separately passed digest or body could only agree
    # (noise) or disagree (a bug), so both together refuse.
    def carry(payload, payload_digest, body)
      raise ArgumentError, "carried_payload already names the digest and body; pass one, not both" if
        payload_digest || body

      @carried_payload = payload
      @payload_digest = payload.digest
      @body = payload.body
    end

    def fetch_body(key)
      if body.nil?
        raise Detached, "#{self} carries no body; it lives in the Store under #{payload_digest}. " \
                        "This envelope was rebuilt from digests alone -- fetch that payload through " \
                        "a Store, or build it via Event.turn to carry one"
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
# ChainWriter reopens Event to nest itself and references Payload (the
# payload-then-envelope write), so it loads after Payload.
require_relative "event/chain_writer"
# Projection reopens Event to nest itself; its Usage/Timeline references resolve
# at call time, so those units may load after this one.
require_relative "event/projection"
