//! The messages the phone and lain exchange through the relay.
//!
//! Structs encode as msgpack maps and enums as one-key maps (`{"Hold": {...}}`),
//! so Ruby's msgpack gem reads and writes the same bytes.
#![forbid(unsafe_code)]
#![deny(missing_docs)]

use serde::{Deserialize, Serialize, de::DeserializeOwned};

/// Bumped on any change a peer running the old version cannot read.
pub const WIRE_VERSION: u32 = 1;

/// The first message of a phone connection.
///
/// Encode with [`encode`] (named maps); positional arrays do not decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hello {
    /// The sender's [`WIRE_VERSION`].
    pub wire_version: u32,
    /// The shared secret the relay checks before sending anything.
    pub token: String,
    /// The last delta cursor the phone saw.
    pub cursor: u64,
}

/// One thing waiting on a human.
///
/// Encode with [`encode`] (named maps); positional arrays do not decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum AgendaItem {
    /// A tool call parked for approval.
    ParkedCall {
        /// Agenda id.
        id: String,
        /// The agent that asked.
        requester: String,
        /// Tool name.
        tool: String,
        /// The call's input as text.
        input: String,
        /// Working directory the call runs in.
        cwd: String,
        /// Why it was parked.
        why: String,
        /// Whether a human already postponed it.
        postponed: bool,
        /// Unix seconds when it was asked.
        asked_at: i64,
    },
    /// A wave gate: one question covering every issue in the wave.
    GateQuestion {
        /// Agenda id.
        id: String,
        /// The agent that asked.
        requester: String,
        /// Epic slug.
        epic: String,
        /// Gate stage.
        stage: String,
        /// The issue ids the gate covers.
        issues: Vec<String>,
        /// The question text.
        question: String,
        /// Unix seconds when it was asked.
        asked_at: i64,
    },
    /// A free question to the human.
    Question {
        /// Agenda id.
        id: String,
        /// The agent that asked.
        requester: String,
        /// The question text.
        question: String,
        /// Suggested answers.
        options: Vec<String>,
        /// Unix seconds when it was asked.
        asked_at: i64,
    },
}

/// A human's decision, each with an optional note.
///
/// Encode with [`encode`] (named maps); positional arrays do not decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Verdict {
    /// Let it proceed.
    Approve {
        /// Optional note.
        #[serde(default)]
        note: Option<String>,
    },
    /// Keep it waiting.
    Hold {
        /// Optional note.
        #[serde(default)]
        note: Option<String>,
    },
    /// Refuse it.
    Deny {
        /// Optional note.
        #[serde(default)]
        note: Option<String>,
    },
}

/// The phone's reply to one agenda item.
///
/// Encode with [`encode`] (named maps); positional arrays do not decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum Answer {
    /// Reply to a parked call.
    Call {
        /// The agenda id answered.
        id: String,
        /// The decision.
        verdict: Verdict,
    },
    /// Reply to a wave gate, a verdict per issue id.
    Gate {
        /// The agenda id answered.
        id: String,
        /// Issue id and its verdict.
        verdicts: Vec<(String, Verdict)>,
    },
    /// Reply to a question: a chosen option, free text, or both.
    Question {
        /// The agenda id answered.
        id: String,
        /// The chosen option.
        #[serde(default)]
        option: Option<String>,
        /// Free text.
        #[serde(default)]
        text: Option<String>,
    },
}

/// What changed in the agenda since a cursor.
///
/// Encode with [`encode`] (named maps); positional arrays do not decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Delta {
    /// The cursor after this delta.
    pub cursor: u64,
    /// Items that appeared.
    pub added: Vec<AgendaItem>,
    /// Ids of items that no longer wait.
    pub settled: Vec<String>,
}

/// Encodes a message with named struct fields.
pub fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>, rmp_serde::encode::Error> {
    rmp_serde::to_vec_named(value)
}

/// Decodes a message encoded by [`encode`] or by Ruby's msgpack gem; a non-map is an error.
///
/// Only the top level is checked, so a positional struct nested in a map still decodes.
pub fn decode<T: DeserializeOwned>(bytes: &[u8]) -> Result<T, rmp_serde::decode::Error> {
    // serde would accept a positional array for a struct; the wire is maps only.
    if !matches!(bytes.first(), Some(0x80..=0x8f | 0xde | 0xdf)) {
        return Err(rmp_serde::decode::Error::Syntax(
            "message must be a msgpack map".to_string(),
        ));
    }
    rmp_serde::from_slice(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(format!("{name}.msgpack"))
    }

    fn blessing() -> bool {
        std::env::var("LAIN_WIRE_BLESS").is_ok_and(|v| v == "1")
    }

    fn committed(name: &str) -> Vec<u8> {
        std::fs::read(fixture(name)).expect("fixture committed")
    }

    #[test]
    fn a_stale_bless_flag_fails_loudly() {
        assert!(
            !blessing(),
            "fixtures rewritten; re-run without LAIN_WIRE_BLESS"
        );
    }

    fn s(v: &str) -> String {
        v.to_string()
    }

    fn check<T>(name: &str, value: T)
    where
        T: serde::Serialize + serde::de::DeserializeOwned + PartialEq + std::fmt::Debug,
    {
        let bytes = encode(&value).expect("encode");
        if blessing() {
            std::fs::write(fixture(name), &bytes).expect("bless");
        }
        let committed = std::fs::read(fixture(name)).expect("fixture committed");
        assert_eq!(bytes, committed, "{name} encodes to the committed bytes");
        assert_eq!(decode::<T>(&committed).expect("decode"), value);
    }

    fn call() -> AgendaItem {
        AgendaItem::ParkedCall {
            id: s("c1"),
            requester: s("main"),
            tool: s("bash"),
            input: s("ls -la"),
            cwd: s("/work"),
            why: s("outside bounds"),
            postponed: true,
            asked_at: 1_700_000_000,
        }
    }

    fn gate() -> AgendaItem {
        AgendaItem::GateQuestion {
            id: s("g1"),
            requester: s("coordinator"),
            epic: s("nyotes"),
            stage: s("wave"),
            issues: vec![s("a"), s("b"), s("c")],
            question: s("merge the wave?"),
            asked_at: 1_700_000_001,
        }
    }

    fn question() -> AgendaItem {
        AgendaItem::Question {
            id: s("q1"),
            requester: s("main"),
            question: s("which branch?"),
            options: vec![s("main"), s("dev")],
            asked_at: 1_700_000_002,
        }
    }

    #[test]
    fn hello_round_trips() {
        check(
            "hello",
            Hello {
                wire_version: WIRE_VERSION,
                token: s("tok"),
                cursor: 7,
            },
        );
    }

    #[test]
    fn agenda_items_round_trip() {
        check("agenda_parked_call", call());
        check("agenda_gate_question", gate());
        check("agenda_question", question());
    }

    #[test]
    fn delta_round_trips() {
        check(
            "delta",
            Delta {
                cursor: 9,
                added: vec![call(), gate(), question()],
                settled: vec![s("old")],
            },
        );
    }

    #[test]
    fn answers_round_trip() {
        check(
            "answer_call",
            Answer::Call {
                id: s("c1"),
                verdict: Verdict::Deny {
                    note: Some(s("no")),
                },
            },
        );
        check(
            "answer_gate",
            Answer::Gate {
                id: s("g1"),
                verdicts: vec![
                    (s("a"), Verdict::Approve { note: None }),
                    (
                        s("b"),
                        Verdict::Hold {
                            note: Some(s("later")),
                        },
                    ),
                    (s("c"), Verdict::Deny { note: None }),
                ],
            },
        );
        check(
            "answer_question",
            Answer::Question {
                id: s("q1"),
                option: Some(s("dev")),
                text: None,
            },
        );
    }

    #[test]
    fn a_wave_gate_is_one_item_with_a_verdict_per_issue() {
        let AgendaItem::GateQuestion { issues, .. } = gate() else {
            panic!("not a gate");
        };
        assert_eq!(issues, vec![s("a"), s("b"), s("c")]);
        let Answer::Gate { verdicts, .. } = decode::<Answer>(&committed("answer_gate")).unwrap()
        else {
            panic!("not a gate answer");
        };
        let ids: Vec<&str> = verdicts.iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, ["a", "b", "c"]);
    }

    #[test]
    fn a_newer_hello_decodes_and_differs_from_ours() {
        let hello: Hello = decode(&committed("hello_v2")).expect("decode");
        assert_eq!(hello.wire_version, 2);
        assert_ne!(hello.wire_version, WIRE_VERSION);
    }

    #[test]
    fn an_unknown_variant_is_an_error() {
        assert!(decode::<AgendaItem>(&committed("agenda_unknown_variant")).is_err());
    }

    #[test]
    fn an_unknown_extra_field_is_ignored() {
        let hello: Hello = decode(&committed("hello_extra_field")).expect("decode");
        assert_eq!(
            hello,
            Hello {
                wire_version: WIRE_VERSION,
                token: s("tok"),
                cursor: 7
            }
        );
    }

    #[test]
    fn an_absent_option_key_decodes_as_none() {
        let verdict: Verdict = decode(&committed("verdict_note_absent")).expect("decode");
        assert_eq!(verdict, Verdict::Approve { note: None });
        let answer: Answer = decode(&committed("answer_question_absent")).expect("decode");
        assert_eq!(
            answer,
            Answer::Question {
                id: s("q1"),
                option: None,
                text: None
            }
        );
    }

    #[test]
    fn a_map16_message_decodes() {
        let bytes = committed("hello_map16");
        assert_eq!(bytes[0], 0xde);
        let hello: Hello = decode(&bytes).expect("decode");
        assert_eq!(hello.wire_version, WIRE_VERSION);
    }

    #[test]
    fn positional_array_bytes_are_rejected() {
        assert!(decode::<Hello>(&committed("hello_positional")).is_err());
    }
}
