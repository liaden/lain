//! Pure, libruby-free port of the `Lain::Event` envelope (TL-2's shape).
//!
//! An [`EventData`] is the CloudEvents-shaped envelope Ruby collapsed `Turn`
//! into: a small, uniform header (kind, from/to, the two parent edges,
//! correlation) around a kind-tagged, content-addressed [`PayloadData`]. The
//! envelope's digest is the content address of exactly the seven header fields
//! -- the payload is never inlined INTO the address; the envelope hashes
//! `payload_digest`, and the payload body rides along as carried state (the
//! same "locally constructed events CARRY their payload" rule as Ruby's
//! `Event#carried_payload`, so `content`/`meta` reads cost nothing).
//!
//! Byte parity is the whole point: both digests here -- payload and envelope --
//! must equal `Lain::Canonical.digest` over the structures `Event#payload` and
//! `Event::Payload#payload` build, byte for byte. `rust/turn_spec.rb` pins that
//! cross-implementation; the tests below pin the exact serialized bytes against
//! vectors computed with the Ruby implementation.
//!
//! Nothing here touches `magnus`, so the digest scheme, the kind/role enums,
//! and the causal-parent normalization are unit-tested without an embedded
//! Ruby VM; the FFI wrapper in `lib.rs` reads Ruby values into an `EventData`
//! and hands the frozen, `Ractor.shareable?` handle back.

use crate::canonical::{self, Canon};
use crate::digest::Digest;
use std::sync::Arc;

/// A wire role. A :turn's body carries a message, and only these two are
/// messages. The type IS the closed set, so an unknown role cannot be
/// represented, and the role list any message derives (see [`Role::names`]) is
/// single-sourced from these variants.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
}

impl Role {
    /// Every role, in wire order. The one source the error message and the
    /// `TryFrom` below both read, so they cannot drift.
    pub const ALL: [Role; 2] = [Role::User, Role::Assistant];

    /// The wire string. This IS the serialized role byte-for-byte -- the digest
    /// is taken over it -- so it must never change for an existing variant.
    pub fn as_str(self) -> &'static str {
        match self {
            Role::User => "user",
            Role::Assistant => "assistant",
        }
    }

    /// The comma-joined role list an error message names (`user, assistant`).
    ///
    /// A constant rather than a join over [`Role::ALL`], because the list is
    /// fixed at compile time and rebuilding a `Vec` and a `String` per raised
    /// error bought nothing. It stays a *function* because both call sites
    /// spell it `Role::names()`, and a bare `pub const NAMES` does not answer
    /// to that syntax; `const` on the `fn` adds nothing today beyond stating
    /// that the value is available at compile time -- a plain `fn` compiles
    /// identically, and nothing calls this in a const context. It is still
    /// single-sourced from the enum -- by `role_names_is_the_comma_joined_list`,
    /// which joins [`Role::ALL`] and fails the moment a variant is added here
    /// without being named below.
    pub const fn names() -> &'static str {
        "user, assistant"
    }
}

/// Validate a role string against the wire roles, mapping an unknown one onto the
/// same [`InvalidRole`] whose `Display` is the FFI-visible message.
impl std::str::FromStr for Role {
    type Err = InvalidRole;

    fn from_str(role: &str) -> Result<Self, InvalidRole> {
        Self::ALL
            .into_iter()
            .find(|candidate| candidate.as_str() == role)
            .ok_or_else(|| InvalidRole(role.to_string()))
    }
}

/// A role string that is not one of the [`Role`] variants.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvalidRole(pub String);

/// Hand-implemented rather than `#[derive(thiserror::Error)]`, and that is a
/// deferral, not a reason: `#[error("role must be one of {}, got {:?}",
/// Role::names(), .0)]` takes trailing format arguments and would produce these
/// exact bytes. It is left alone because the card that converted `prompt.rs`
/// scoped itself there and asked for a tight diff here. This Display text IS the
/// FFI-visible message: `lib.rs`'s `read_role` raise site passes
/// `invalid.to_string()` straight into the raised `Turn::InvalidRole`.
impl std::fmt::Display for InvalidRole {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "role must be one of {}, got {:?}", Role::names(), self.0)
    }
}

impl std::error::Error for InvalidRole {}

/// The closed, loud kind enum both the envelope and the payload share --
/// `Lain::Event::KINDS`, as a type. As with [`Role`], an unknown kind cannot be
/// represented, and the wire string below is what both digests hash over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Turn,
    Spawn,
    Message,
    Snapshot,
}

impl Kind {
    /// Every kind, in `Event::KINDS` order.
    pub const ALL: [Kind; 4] = [Kind::Turn, Kind::Spawn, Kind::Message, Kind::Snapshot];

    /// The wire string -- the serialized kind byte-for-byte in BOTH content
    /// addresses (payload and envelope), so it must never change for an
    /// existing variant.
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Turn => "turn",
            Kind::Spawn => "spawn",
            Kind::Message => "message",
            Kind::Snapshot => "snapshot",
        }
    }
}

impl std::str::FromStr for Kind {
    type Err = InvalidKind;

    fn from_str(kind: &str) -> Result<Self, InvalidKind> {
        Kind::ALL
            .into_iter()
            .find(|candidate| candidate.as_str() == kind)
            .ok_or_else(|| InvalidKind(kind.to_string()))
    }
}

/// A kind string that is not one of the [`Kind`] variants. Its `Display` is the
/// message Ruby's `Event.normalize_kind` raises, minus the quoting of the
/// offender, which the FFI layer adds from the original Ruby value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvalidKind(pub String);

impl InvalidKind {
    pub fn message(&self, got: &str) -> String {
        let names = Kind::ALL.map(Kind::as_str).join(", ");
        format!("kind must be one of {names}, got {got}")
    }
}

/// The kind-tagged body an [`EventData`] references by digest -- the port of
/// `Lain::Event::Payload`. Content-addressed on its own so large results and
/// snapshots never inline into the envelope header. `body` is already-canonical
/// wire form ([`Canon`]), so the digest is stable by construction.
#[derive(Debug, Clone)]
pub struct PayloadData {
    pub kind: Kind,
    pub body: Canon,
    pub digest: Digest,
}

impl PayloadData {
    /// Build a payload, computing its content address over `{"body":..,
    /// "kind":..}` exactly as `Canonical.digest(payload.payload)` does. The
    /// hashed structure itself is the free [`payload_canon`] below.
    pub fn new(kind: Kind, body: Canon) -> Arc<Self> {
        let digest = Digest::from(canonical::digest(&payload_canon(kind, &body)));
        Arc::new(Self { kind, body, digest })
    }
}

fn payload_canon(kind: Kind, body: &Canon) -> Canon {
    // Keys are literals, written in the sorted order `Canonical.dump` requires,
    // so this needs neither the duplicate scan nor the `.expect()` that
    // discharged its impossible `Err`. See `Canon::object_from_sorted`.
    Canon::object_from_sorted([
        ("body", body.clone()),
        ("kind", Canon::Str(kind.as_str().to_string())),
    ])
}

/// An immutable node of the Timeline DAG, now wearing the full envelope. Two
/// distinct parent edges, git's model: `render_parent` is SINGLE (the
/// first-parent chain every `dag.rs` walk follows -- the render meet is
/// unchanged by this port), `causal_parents` is a SET (pre-sorted and deduped in
/// [`normalize_causal`], because `Canonical` preserves array order and set
/// element order must not leak into identity). Shared through an `Arc` so a
/// `Store` and any number of `Timeline` handles name the same node without
/// copying its subtree.
///
/// `payload` is `None` on a DETACHED envelope, one rebuilt from digests alone:
/// its address is whole, but its body lives elsewhere under `payload_digest`
/// and every body reader refuses rather than answer for it.
#[derive(Debug, Clone)]
pub struct EventData {
    pub kind: Kind,
    pub from: Option<String>,
    pub to: Option<String>,
    pub render_parent: Option<Digest>,
    pub causal_parents: Vec<Digest>,
    pub correlation: Option<Digest>,
    pub payload_digest: Digest,
    pub payload: Option<Arc<PayloadData>>,
    pub digest: Digest,
}

// Compile-time shareability canary: `Turn`'s `frozen_shareable` promise (see
// `lib.rs`) is honest only if `EventData` holds no interior mutability, and a
// `Cell`/`RefCell` regression would make it `!Sync` without any runtime
// signal. This catches that class of regression at compile time. It canNOT
// catch a `Mutex`/atomic field -- those ARE `Sync` despite being interior
// mutability -- so `Mutex`/atomic additions stay prose-audited, same as the
// `bm25.rs` module doc.
const _: fn() = || {
    fn assert_sync<T: Sync>() {}
    assert_sync::<EventData>();
};

impl EventData {
    /// The :turn constructor -- what `TurnData::new` was, re-keyed to the
    /// envelope scheme. Role, content, and meta form the out-of-line payload
    /// body; `parent` is the single render edge; `correlation` names the chain
    /// by its root event digest (the FFI `Timeline::commit` derives it, exactly
    /// as Ruby's `Timeline#commit` does through `ChainWriter.correlation_of`).
    pub fn turn(
        role: Role,
        content: Canon,
        parent: Option<Digest>,
        meta: Canon,
        correlation: Option<Digest>,
        causal_parents: Vec<Digest>,
    ) -> Arc<Self> {
        // Literal keys in sorted order -- see payload_canon.
        let body = Canon::object_from_sorted([
            ("content", content),
            ("meta", meta),
            ("role", Canon::Str(role.as_str().to_string())),
        ]);
        Self::new(
            None,
            None,
            parent,
            causal_parents,
            correlation,
            PayloadData::new(Kind::Turn, body),
        )
    }

    /// Build an envelope around an already-built payload, computing the content
    /// address of the seven header fields exactly as `Canonical.digest` over
    /// `Event#payload` does. The envelope's kind is READ FROM the carried
    /// payload rather than passed separately: Ruby documents envelope/payload
    /// kind agreement as "the constructor's responsibility, not something the
    /// digest can cross-check" -- here the disagreement is unrepresentable.
    /// Returned in an `Arc` because that is how every holder references it.
    pub fn new(
        from: Option<String>,
        to: Option<String>,
        render_parent: Option<Digest>,
        causal_parents: Vec<Digest>,
        correlation: Option<Digest>,
        payload: Arc<PayloadData>,
    ) -> Arc<Self> {
        let header = Header {
            kind: payload.kind,
            from,
            to,
            render_parent,
            causal_parents,
            correlation,
            payload_digest: payload.digest.clone(),
        };
        Arc::new(header.address(Some(payload)))
    }

    /// An envelope rebuilt from digests alone: the same address the carrying
    /// envelope has, with no body to read. Here the kind cannot come from a
    /// payload, so it is the caller's, as in Ruby's `Event.new`.
    pub fn detached(
        kind: Kind,
        from: Option<String>,
        to: Option<String>,
        render_parent: Option<Digest>,
        causal_parents: Vec<Digest>,
        correlation: Option<Digest>,
        payload_digest: Digest,
    ) -> Arc<Self> {
        let header = Header {
            kind,
            from,
            to,
            render_parent,
            causal_parents,
            correlation,
            payload_digest,
        };
        Arc::new(header.address(None))
    }

    /// This envelope carrying `payload`, or `None` when `payload` is not the
    /// body this address names: a different digest, or a different kind.
    pub fn attach(&self, payload: &Arc<PayloadData>) -> Option<Arc<Self>> {
        (payload.digest == self.payload_digest && payload.kind == self.kind).then(|| {
            Arc::new(Self {
                payload: Some(Arc::clone(payload)),
                ..self.clone()
            })
        })
    }

    /// The exact envelope structure that was hashed -- what a Journal writes,
    /// and what the FFI `payload` method renders back into a Ruby Hash. The
    /// carried body is deliberately absent: it is addressed through
    /// `payload_digest`, never inlined here.
    pub fn payload_canon(&self) -> Canon {
        envelope_canon(
            self.kind,
            &self.from,
            &self.to,
            &self.render_parent,
            &self.causal_parents,
            &self.correlation,
            &self.payload_digest,
        )
    }

    pub fn root(&self) -> bool {
        self.render_parent.is_none()
    }

    /// The carried payload body, or `None` on a detached envelope.
    pub fn body(&self) -> Option<&Canon> {
        self.payload.as_ref().map(|payload| &payload.body)
    }

    /// A field of the carried payload body, or `None` when the envelope is
    /// detached, or the body is not an object or lacks the key. The :turn
    /// constructor always writes `role`, `content`, and `meta`; the FFI
    /// readers tell a detached envelope from a missing field and raise on both
    /// rather than materializing `nil`.
    pub fn body_field(&self, key: &str) -> Option<&Canon> {
        match self.body()? {
            Canon::Object(pairs) => pairs
                .iter()
                .find(|(candidate, _)| candidate == key)
                .map(|(_, value)| value),
            _ => None,
        }
    }

    /// The body's role text, when present -- always, for a :turn built through
    /// [`EventData::turn`].
    pub fn role_str(&self) -> Option<&str> {
        match self.body_field("role") {
            Some(Canon::Str(role)) => Some(role),
            _ => None,
        }
    }
}

/// The seven addressed fields, before the address is taken. One place builds
/// an envelope from them, so the carrying and the detached constructors cannot
/// come to hash differently.
struct Header {
    kind: Kind,
    from: Option<String>,
    to: Option<String>,
    render_parent: Option<Digest>,
    causal_parents: Vec<Digest>,
    correlation: Option<Digest>,
    payload_digest: Digest,
}

impl Header {
    fn address(self, payload: Option<Arc<PayloadData>>) -> EventData {
        let causal_parents = normalize_causal(self.causal_parents);
        let digest = Digest::from(canonical::digest(&envelope_canon(
            self.kind,
            &self.from,
            &self.to,
            &self.render_parent,
            &causal_parents,
            &self.correlation,
            &self.payload_digest,
        )));
        EventData {
            kind: self.kind,
            from: self.from,
            to: self.to,
            render_parent: self.render_parent,
            causal_parents,
            correlation: self.correlation,
            payload_digest: self.payload_digest,
            payload,
            digest,
        }
    }
}

/// A set, deduplicated and sorted so insertion order cannot change the digest
/// -- the same pinned order Ruby's `Event#normalize_causal` establishes
/// (`uniq.sort`; sort-then-dedup is the same set in the same order). Byte
/// order: Ruby sorts `String#<=>`, which is exactly what `Digest`'s derived
/// `Ord` delegates to.
fn normalize_causal(mut causal_parents: Vec<Digest>) -> Vec<Digest> {
    causal_parents.sort();
    causal_parents.dedup();
    causal_parents
}

fn optional_text(value: &Option<String>) -> Canon {
    match value {
        Some(text) => Canon::Str(text.clone()),
        None => Canon::Null,
    }
}

fn optional_digest(value: &Option<Digest>) -> Canon {
    match value {
        // `Display` writes the raw digest text, so the serialized bytes match
        // the Ruby String the digest field normalizes to.
        Some(digest) => Canon::Str(digest.to_string()),
        None => Canon::Null,
    }
}

fn envelope_canon(
    kind: Kind,
    from: &Option<String>,
    to: &Option<String>,
    render_parent: &Option<Digest>,
    causal_parents: &[Digest],
    correlation: &Option<Digest>,
    payload_digest: &Digest,
) -> Canon {
    let causal = Canon::Array(
        causal_parents
            .iter()
            .map(|digest| Canon::Str(digest.to_string()))
            .collect(),
    );
    // The seven keys are literals in sorted order -- see payload_canon.
    Canon::object_from_sorted([
        ("causal_parents", causal),
        ("correlation", optional_digest(correlation)),
        ("from", optional_text(from)),
        ("kind", Canon::Str(kind.as_str().to_string())),
        ("payload_digest", Canon::Str(payload_digest.to_string())),
        ("render_parent", optional_digest(render_parent)),
        ("to", optional_text(to)),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canonical::build_object;

    fn text(body: &str) -> Canon {
        Canon::Array(vec![Canon::Object(
            build_object(vec![
                ("type".to_string(), Canon::Str("text".to_string())),
                ("text".to_string(), Canon::Str(body.to_string())),
            ])
            .unwrap(),
        )])
    }

    fn empty_meta() -> Canon {
        Canon::Object(vec![])
    }

    fn turn(role: Role, body: &str) -> Arc<EventData> {
        EventData::turn(role, text(body), None, empty_meta(), None, Vec::new())
    }

    fn digest(text: &str) -> Digest {
        Digest::from(text.to_string())
    }

    fn carried(node: &EventData) -> &PayloadData {
        node.payload
            .as_deref()
            .expect("a built turn carries its payload")
    }

    fn detached_twin(node: &EventData) -> Arc<EventData> {
        EventData::detached(
            node.kind,
            node.from.clone(),
            node.to.clone(),
            node.render_parent.clone(),
            node.causal_parents.clone(),
            node.correlation.clone(),
            node.payload_digest.clone(),
        )
    }

    #[test]
    fn a_detached_envelope_has_the_carrying_envelopes_address_and_no_body() {
        let whole = turn(Role::User, "hi");
        let detached = detached_twin(&whole);
        assert_eq!(detached.digest, whole.digest);
        assert!(detached.body().is_none());
        assert_eq!(detached.role_str(), None);
        assert_eq!(detached.body_field("content"), None);
    }

    #[test]
    fn attaching_its_own_payload_makes_a_detached_envelope_whole() {
        let whole = turn(Role::User, "hi");
        let attached = detached_twin(&whole)
            .attach(whole.payload.as_ref().expect("carried"))
            .expect("its own payload");
        assert_eq!(attached.digest, whole.digest);
        assert_eq!(attached.body(), whole.body());
    }

    #[test]
    fn attach_refuses_a_payload_the_address_does_not_name() {
        let whole = turn(Role::User, "hi");
        let other = turn(Role::User, "bye");
        let own = whole.payload.as_ref().expect("carried");
        let mislabelled = EventData::detached(
            Kind::Message,
            None,
            None,
            None,
            Vec::new(),
            None,
            whole.payload_digest.clone(),
        );
        assert!(
            detached_twin(&whole)
                .attach(other.payload.as_ref().expect("carried"))
                .is_none()
        );
        assert!(mislabelled.attach(own).is_none());
    }

    #[test]
    fn digest_is_a_prefixed_content_address() {
        assert!(turn(Role::User, "hi").digest.starts_with("blake3:"));
        assert!(
            PayloadData::new(Kind::Turn, empty_meta())
                .digest
                .starts_with("blake3:")
        );
    }

    #[test]
    fn digest_is_identical_for_identical_content() {
        assert_eq!(turn(Role::User, "hi").digest, turn(Role::User, "hi").digest);
    }

    #[test]
    fn digest_changes_with_content() {
        assert_ne!(
            turn(Role::User, "hi").digest,
            turn(Role::User, "bye").digest
        );
    }

    #[test]
    fn digest_changes_with_role() {
        assert_ne!(
            turn(Role::User, "hi").digest,
            turn(Role::Assistant, "hi").digest
        );
    }

    #[test]
    fn digest_changes_with_parent() {
        let root = turn(Role::User, "hi");
        let child = EventData::turn(
            Role::User,
            text("hi"),
            Some(digest("blake3:abc")),
            empty_meta(),
            None,
            Vec::new(),
        );
        assert_ne!(root.digest, child.digest);
    }

    #[test]
    fn digest_changes_with_meta() {
        let bare = turn(Role::User, "hi");
        let tagged = EventData::turn(
            Role::User,
            text("hi"),
            None,
            Canon::Object(
                build_object(vec![(
                    "spawned_from".to_string(),
                    Canon::Str("blake3:abc".to_string()),
                )])
                .unwrap(),
            ),
            None,
            Vec::new(),
        );
        assert_ne!(bare.digest, tagged.digest);
    }

    #[test]
    fn digest_changes_with_correlation_and_causal_parents() {
        let bare = turn(Role::User, "hi");
        let correlated = EventData::turn(
            Role::User,
            text("hi"),
            None,
            empty_meta(),
            Some(digest("blake3:root")),
            Vec::new(),
        );
        let caused = EventData::turn(
            Role::User,
            text("hi"),
            None,
            empty_meta(),
            None,
            vec![digest("blake3:msg")],
        );
        assert_ne!(bare.digest, correlated.digest);
        assert_ne!(bare.digest, caused.digest);
        assert_ne!(correlated.digest, caused.digest);
    }

    #[test]
    fn root_has_no_render_parent() {
        assert!(turn(Role::User, "hi").root());
    }

    #[test]
    fn body_fields_read_from_the_carried_payload() {
        let node = turn(Role::User, "hi");
        assert_eq!(node.role_str(), Some("user"));
        assert_eq!(node.body_field("content"), Some(&text("hi")));
        assert_eq!(node.body_field("meta"), Some(&empty_meta()));
        assert_eq!(node.body_field("absent"), None);
    }

    #[test]
    fn causal_parents_are_deduped_and_sorted_regardless_of_input_order() {
        let node = EventData::turn(
            Role::User,
            text("hi"),
            None,
            empty_meta(),
            None,
            vec![digest("blake3:b"), digest("blake3:a"), digest("blake3:b")],
        );
        assert_eq!(
            node.causal_parents,
            vec![digest("blake3:a"), digest("blake3:b")]
        );
    }

    // The envelope is the exact structure Ruby's `Event#payload` builds; these
    // bytes were computed with the Ruby implementation (`Canonical.dump(
    // Event.turn(...).payload)`), so this is the byte half of the parity the
    // rspec digest-equality example pins live.
    #[test]
    fn envelope_canon_matches_the_ruby_bytes() {
        let node = EventData::turn(
            Role::User,
            text("hi"),
            Some(digest("blake3:abc")),
            Canon::Object(
                build_object(vec![(
                    "spawned_from".to_string(),
                    Canon::Str("blake3:xyz".to_string()),
                )])
                .unwrap(),
            ),
            None,
            Vec::new(),
        );
        let carried = carried(&node);
        assert_eq!(
            canonical::dump(&payload_canon(carried.kind, &carried.body)),
            r#"{"body":{"content":[{"text":"hi","type":"text"}],"meta":{"spawned_from":"blake3:xyz"},"role":"user"},"kind":"turn"}"#
        );
        assert_eq!(
            carried.digest.as_str(),
            "blake3:57f67b4a16c45bbbcc86e1173fe7456a80085d6d3f23d63022a6f3950b457091"
        );
        assert_eq!(
            canonical::dump(&node.payload_canon()),
            r#"{"causal_parents":[],"correlation":null,"from":null,"kind":"turn","payload_digest":"blake3:57f67b4a16c45bbbcc86e1173fe7456a80085d6d3f23d63022a6f3950b457091","render_parent":"blake3:abc","to":null}"#
        );
        assert_eq!(
            node.digest.as_str(),
            "blake3:46c1b458bc6aa2e197ae24dfa416fdeb1eac59cce48050298fb19a3dafaa9b9f"
        );
    }

    fn keys_of(canon: &Canon) -> Vec<&str> {
        match canon {
            Canon::Object(pairs) => pairs.iter().map(|(key, _)| key.as_str()).collect(),
            other => panic!("expected an object, got {other:?}"),
        }
    }

    // `Canon::object_from_sorted` trusts its caller to write keys in sorted
    // order, and these three constructors ARE that caller. The golden-bytes
    // test above would catch a mis-sort for the turn shape it happens to build;
    // this states each key list directly, so the precondition is a named,
    // readable assertion rather than a side effect of a digest vector.
    #[test]
    fn the_three_literal_key_lists_are_written_in_sorted_order() {
        let node = turn(Role::User, "hi");
        let payload = payload_canon(carried(&node).kind, &carried(&node).body);
        let envelope = node.payload_canon();
        let lists = [
            keys_of(&payload),
            keys_of(&carried(&node).body),
            keys_of(&envelope),
        ];
        assert_eq!(lists[0], ["body", "kind"]);
        assert_eq!(lists[1], ["content", "meta", "role"]);
        assert_eq!(
            lists[2],
            [
                "causal_parents",
                "correlation",
                "from",
                "kind",
                "payload_digest",
                "render_parent",
                "to"
            ]
        );
        for list in &lists {
            assert!(
                list.windows(2).all(|pair| pair[0] < pair[1]),
                "keys must be strictly increasing: {list:?}"
            );
        }
    }

    // Same Ruby-computed vector, exercising the correlation and causal-parent
    // fields (input order b, a, b -- the digest is over the sorted, deduped
    // set).
    #[test]
    fn correlated_envelope_digest_matches_the_ruby_vector() {
        let node = EventData::turn(
            Role::User,
            text("hi"),
            None,
            empty_meta(),
            Some(digest("blake3:root")),
            vec![digest("blake3:b"), digest("blake3:a"), digest("blake3:b")],
        );
        assert_eq!(
            node.digest.as_str(),
            "blake3:fdaced8133acf9fe2b2fdb273d6481d7953ab07eee71932530daec533f373789"
        );
    }

    // Every KINDS member payload-hashes to Ruby's bytes: vectors computed with
    // `Lain::Event::Payload.new(kind:, body: {"x" => 1})`.
    #[test]
    fn payload_digest_matches_the_ruby_vector_for_every_kind() {
        let body = || {
            Canon::Object(
                build_object(vec![("x".to_string(), Canon::Num("1".to_string()))]).unwrap(),
            )
        };
        let expected = [
            (
                Kind::Turn,
                "blake3:e4aaae9a99ade23399d3fc9ed7548adfee4b8a0626a19d9329ce760a124ea348",
            ),
            (
                Kind::Spawn,
                "blake3:53099e0c0250e0a695e7cefb45c687a18fb23fd8ebf0527b3f4dc19b72d4d2bb",
            ),
            (
                Kind::Message,
                "blake3:157ae5cb2225f6fcdeacff2c7e8631cbcd6d061cee502c299659b3d18379ceb1",
            ),
            (
                Kind::Snapshot,
                "blake3:6f938f31cb054b9fa64be1b5939c852c2173d2edd073b353834e08b351be177d",
            ),
        ];
        for (kind, vector) in expected {
            let payload = PayloadData::new(kind, body());
            assert_eq!(
                canonical::dump(&payload_canon(payload.kind, &payload.body)),
                format!(r#"{{"body":{{"x":1}},"kind":"{}"}}"#, kind.as_str())
            );
            assert_eq!(payload.digest.as_str(), vector, "kind {:?}", kind);
        }
    }

    #[test]
    fn parses_wire_kinds_and_rejects_the_rest() {
        for kind in Kind::ALL {
            assert_eq!(kind.as_str().parse::<Kind>(), Ok(kind));
        }
        let invalid = "bogus".parse::<Kind>().unwrap_err();
        assert_eq!(
            invalid.message(":bogus"),
            "kind must be one of turn, spawn, message, snapshot, got :bogus"
        );
    }

    #[test]
    fn kind_as_str_is_the_wire_string() {
        assert_eq!(
            Kind::ALL.map(Kind::as_str),
            ["turn", "spawn", "message", "snapshot"]
        );
    }

    #[test]
    fn parses_wire_roles_and_rejects_the_rest() {
        assert_eq!("user".parse::<Role>(), Ok(Role::User));
        assert_eq!("assistant".parse::<Role>(), Ok(Role::Assistant));
        assert_eq!(
            "system".parse::<Role>(),
            Err(InvalidRole("system".to_string()))
        );
    }

    #[test]
    fn role_as_str_is_the_wire_string() {
        assert_eq!(Role::User.as_str(), "user");
        assert_eq!(Role::Assistant.as_str(), "assistant");
    }

    // The join over `Role::ALL` that used to run at every raise site lives
    // HERE instead, so the list stays single-sourced from the enum without
    // rebuilding it per error: a third variant fails this test until the
    // constant names it too.
    #[test]
    fn role_names_is_the_comma_joined_list() {
        assert_eq!(Role::names(), "user, assistant");
        assert_eq!(
            Role::names(),
            Role::ALL
                .iter()
                .map(|role| role.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    // Display IS the FFI-visible message: `lib.rs`'s `read_role` raise site
    // raises `invalid.to_string()` verbatim. Pin the exact text so the Ruby
    // side's pinned error message cannot drift from this Display.
    #[test]
    fn invalid_role_display_is_the_exact_ffi_message() {
        assert_eq!(
            InvalidRole("system".to_string()).to_string(),
            r#"role must be one of user, assistant, got "system""#
        );
    }

    #[test]
    fn invalid_role_is_a_std_error() {
        let boxed: Box<dyn std::error::Error> = Box::new(InvalidRole("system".to_string()));
        assert_eq!(
            boxed.to_string(),
            r#"role must be one of user, assistant, got "system""#
        );
    }
}
