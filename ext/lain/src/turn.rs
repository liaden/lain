//! Pure, libruby-free node of the Timeline DAG.
//!
//! A [`TurnData`] is a role, its normalized content, the digest of its parent,
//! and its meta -- with its own digest being the content address of exactly
//! those four fields, computed the same way `Lain::Turn` does. Nothing here
//! touches `magnus`, so the digest and role rules are unit-tested without an
//! embedded Ruby VM; the FFI wrapper in `lib.rs` reads Ruby values into a
//! `TurnData` and hands the frozen, `Ractor.shareable?` handle back.

use crate::canonical::{self, build_object, Canon};
use std::sync::Arc;

/// The two wire roles. A `Turn` is a message, and only these two are messages.
pub const ROLES: [&str; 2] = ["user", "assistant"];

/// An immutable Timeline node. Shared through an `Arc` so a `Store` and any
/// number of `Timeline` handles name the same node without copying its subtree.
#[derive(Debug, Clone)]
pub struct TurnData {
    pub role: String,
    pub content: Canon,
    pub parent: Option<String>,
    pub meta: Canon,
    pub digest: String,
}

impl TurnData {
    /// Build a node, computing its content address from the four fields exactly
    /// as `Canonical.digest(payload)` does. Returned in an `Arc` because that is
    /// how every holder references it.
    pub fn new(role: String, content: Canon, parent: Option<String>, meta: Canon) -> Arc<Self> {
        let digest = canonical::digest(&payload_canon(&role, &content, &parent, &meta));
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

fn payload_canon(role: &str, content: &Canon, parent: &Option<String>, meta: &Canon) -> Canon {
    let parent_canon = match parent {
        Some(digest) => Canon::Str(digest.clone()),
        None => Canon::Null,
    };
    let pairs = vec![
        ("role".to_string(), Canon::Str(role.to_string())),
        ("content".to_string(), content.clone()),
        ("parent".to_string(), parent_canon),
        ("meta".to_string(), meta.clone()),
    ];
    // The four keys are literals and distinct, so build_object cannot report an
    // ambiguous key here.
    Canon::Object(build_object(pairs).expect("payload keys are distinct"))
}

/// A role that is not one of [`ROLES`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InvalidRole(pub String);

/// Validate a role string against the two wire roles.
pub fn validate_role(role: &str) -> Result<String, InvalidRole> {
    if ROLES.contains(&role) {
        Ok(role.to_string())
    } else {
        Err(InvalidRole(role.to_string()))
    }
}

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

    fn turn(role: &str, body: &str) -> Arc<TurnData> {
        TurnData::new(role.to_string(), text(body), None, empty_meta())
    }

    #[test]
    fn digest_is_a_prefixed_content_address() {
        assert!(turn("user", "hi").digest.starts_with("blake3:"));
    }

    #[test]
    fn digest_is_identical_for_identical_content() {
        assert_eq!(turn("user", "hi").digest, turn("user", "hi").digest);
    }

    #[test]
    fn digest_changes_with_content() {
        assert_ne!(turn("user", "hi").digest, turn("user", "bye").digest);
    }

    #[test]
    fn digest_changes_with_role() {
        assert_ne!(turn("user", "hi").digest, turn("assistant", "hi").digest);
    }

    #[test]
    fn digest_changes_with_parent() {
        let root = TurnData::new("user".to_string(), text("hi"), None, empty_meta());
        let child = TurnData::new(
            "user".to_string(),
            text("hi"),
            Some("blake3:abc".to_string()),
            empty_meta(),
        );
        assert_ne!(root.digest, child.digest);
    }

    #[test]
    fn digest_changes_with_meta() {
        let bare = TurnData::new("user".to_string(), text("hi"), None, empty_meta());
        let tagged = TurnData::new(
            "user".to_string(),
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
        assert!(turn("user", "hi").root());
    }

    #[test]
    fn payload_canon_is_the_four_sorted_fields() {
        let node = TurnData::new(
            "user".to_string(),
            text("hi"),
            Some("blake3:abc".to_string()),
            Canon::Object(vec![]),
        );
        // Keys sorted: content, meta, parent, role -- what Canonical.digest hashes.
        assert_eq!(
            canonical::dump(&node.payload_canon()),
            r#"{"content":[{"text":"hi","type":"text"}],"meta":{},"parent":"blake3:abc","role":"user"}"#
        );
    }

    #[test]
    fn validates_roles() {
        assert_eq!(validate_role("user"), Ok("user".to_string()));
        assert_eq!(validate_role("assistant"), Ok("assistant".to_string()));
        assert_eq!(
            validate_role("system"),
            Err(InvalidRole("system".to_string()))
        );
    }
}
