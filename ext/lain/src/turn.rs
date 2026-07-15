//! Pure, libruby-free node of the Timeline DAG.
//!
//! A [`TurnData`] is a role, its normalized content, the digest of its parent,
//! and its meta -- with its own digest being the content address of exactly
//! those four fields, computed the same way `Lain::Turn` does. Nothing here
//! touches `magnus`, so the digest and role rules are unit-tested without an
//! embedded Ruby VM; the FFI wrapper in `lib.rs` reads Ruby values into a
//! `TurnData` and hands the frozen, `Ractor.shareable?` handle back.

use crate::canonical::{self, Canon, build_object};
use crate::digest::Digest;
use std::sync::Arc;

/// A wire role. A `Turn` is a message, and only these two are messages. Replaces
/// the former `ROLES: [&str; 2]` + `validate_role` pair: the type now IS the
/// closed set, so an unknown role cannot be represented, and the role list any
/// message derives (see [`Role::names`]) is single-sourced from these variants.
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

    /// The comma-joined role list an error message names (`user, assistant`),
    /// derived from [`Role::ALL`] rather than hardcoded, so a third role added to
    /// the enum shows up in the message with no second edit.
    pub fn names() -> String {
        Self::ALL
            .iter()
            .map(|role| role.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    }
}

/// Validate a role string against the wire roles, mapping an unknown one onto the
/// same [`InvalidRole`] whose `Display` is the FFI-visible message.
impl TryFrom<&str> for Role {
    type Error = InvalidRole;

    fn try_from(role: &str) -> Result<Self, InvalidRole> {
        Self::ALL
            .into_iter()
            .find(|candidate| candidate.as_str() == role)
            .ok_or_else(|| InvalidRole(role.to_string()))
    }
}

/// An immutable Timeline node. Shared through an `Arc` so a `Store` and any
/// number of `Timeline` handles name the same node without copying its subtree.
#[derive(Debug, Clone)]
pub struct TurnData {
    pub role: Role,
    pub content: Canon,
    pub parent: Option<Digest>,
    pub meta: Canon,
    pub digest: Digest,
}

// Compile-time shareability canary: `Turn`'s `frozen_shareable` promise (see
// `lib.rs`) is honest only if `TurnData` holds no interior mutability, and a
// `Cell`/`RefCell` regression would make it `!Sync` without any runtime
// signal. This catches that class of regression at compile time. It canNOT
// catch a `Mutex`/atomic field -- those ARE `Sync` despite being interior
// mutability -- so `Mutex`/atomic additions stay prose-audited, same as the
// `bm25.rs` module doc.
const _: fn() = || {
    fn assert_sync<T: Sync>() {}
    assert_sync::<TurnData>();
};

impl TurnData {
    /// Build a node, computing its content address from the four fields exactly
    /// as `Canonical.digest(payload)` does. Returned in an `Arc` because that is
    /// how every holder references it.
    pub fn new(role: Role, content: Canon, parent: Option<Digest>, meta: Canon) -> Arc<Self> {
        // `canonical::digest` returns the raw `String`; wrapping it here is the
        // one place a computed digest enters the type. canonical.rs stays
        // `String`-returning so its byte-parity tests need no change.
        let digest = Digest::from(canonical::digest(&payload_canon(
            &role, &content, &parent, &meta,
        )));
        Arc::new(Self {
            role,
            content,
            parent,
            meta,
            digest,
        })
    }

    /// The exact structure that was hashed -- what a Journal writes, and what the
    /// FFI `payload` method renders back into a Ruby Hash.
    pub fn payload_canon(&self) -> Canon {
        payload_canon(&self.role, &self.content, &self.parent, &self.meta)
    }

    pub fn root(&self) -> bool {
        self.parent.is_none()
    }
}

fn payload_canon(role: &Role, content: &Canon, parent: &Option<Digest>, meta: &Canon) -> Canon {
    let parent_canon = match parent {
        // `Display` writes the raw digest text, so the serialized parent bytes
        // are unchanged from when this field was a bare `String`.
        Some(digest) => Canon::Str(digest.to_string()),
        None => Canon::Null,
    };
    let pairs = vec![
        ("role".to_string(), Canon::Str(role.as_str().to_string())),
        ("content".to_string(), content.clone()),
        ("parent".to_string(), parent_canon),
        ("meta".to_string(), meta.clone()),
    ];
    // The four keys are literals and distinct, so build_object cannot report an
    // ambiguous key here.
    Canon::Object(build_object(pairs).expect("payload keys are distinct"))
}

/// A role string that is not one of the [`Role`] variants.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvalidRole(pub String);

/// Hand-implemented rather than `#[derive(thiserror::Error)]`: the message
/// interpolates [`Role::names`], and a derive's `#[error(...)]` attribute can
/// only hold a literal format string -- hardcoding "user, assistant" there would
/// double-source the role list against the enum. This Display text IS the
/// FFI-visible message: `lib.rs`'s `read_role` raise site passes
/// `invalid.to_string()` straight into the raised `Turn::InvalidRole`.
impl std::fmt::Display for InvalidRole {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "role must be one of {}, got {:?}", Role::names(), self.0)
    }
}

impl std::error::Error for InvalidRole {}

#[cfg(test)]
mod tests {
    use super::*;

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

    fn turn(role: Role, body: &str) -> Arc<TurnData> {
        TurnData::new(role, text(body), None, empty_meta())
    }

    #[test]
    fn digest_is_a_prefixed_content_address() {
        assert!(turn(Role::User, "hi").digest.starts_with("blake3:"));
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
        let root = TurnData::new(Role::User, text("hi"), None, empty_meta());
        let child = TurnData::new(
            Role::User,
            text("hi"),
            Some(Digest::from("blake3:abc".to_string())),
            empty_meta(),
        );
        assert_ne!(root.digest, child.digest);
    }

    #[test]
    fn digest_changes_with_meta() {
        let bare = TurnData::new(Role::User, text("hi"), None, empty_meta());
        let tagged = TurnData::new(
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
        );
        assert_ne!(bare.digest, tagged.digest);
    }

    #[test]
    fn root_has_no_parent() {
        assert!(turn(Role::User, "hi").root());
    }

    #[test]
    fn payload_canon_is_the_four_sorted_fields() {
        let node = TurnData::new(
            Role::User,
            text("hi"),
            Some(Digest::from("blake3:abc".to_string())),
            Canon::Object(vec![]),
        );
        // Keys sorted: content, meta, parent, role -- what Canonical.digest hashes.
        assert_eq!(
            canonical::dump(&node.payload_canon()),
            r#"{"content":[{"text":"hi","type":"text"}],"meta":{},"parent":"blake3:abc","role":"user"}"#
        );
    }

    #[test]
    fn parses_wire_roles_and_rejects_the_rest() {
        assert_eq!(Role::try_from("user"), Ok(Role::User));
        assert_eq!(Role::try_from("assistant"), Ok(Role::Assistant));
        assert_eq!(
            Role::try_from("system"),
            Err(InvalidRole("system".to_string()))
        );
    }

    #[test]
    fn role_as_str_is_the_wire_string() {
        assert_eq!(Role::User.as_str(), "user");
        assert_eq!(Role::Assistant.as_str(), "assistant");
    }

    #[test]
    fn role_names_is_the_comma_joined_list() {
        assert_eq!(Role::names(), "user, assistant");
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
