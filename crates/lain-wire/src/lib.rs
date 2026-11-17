//! The messages the phone and lain exchange through the relay.
//!
//! Structs encode as msgpack maps and enums as one-key maps (`{"Hold": {...}}`),
//! so Ruby's msgpack gem reads and writes the same bytes.
#![forbid(unsafe_code)]
#![deny(missing_docs)]

use serde::{Deserialize, Serialize, de::DeserializeOwned};

/// Bumped on any change a peer running the old version cannot read.
pub const WIRE_VERSION: u32 = 2;

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

/// One thing waiting on a human, and the session it waits in.
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
        /// The session that asked; a daemon's relay overwrites it with the registration's.
        session: String,
        /// That session's project root; a daemon's relay overwrites it with the registration's.
        project: String,
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
        /// The session that asked; a daemon's relay overwrites it with the registration's.
        session: String,
        /// That session's project root; a daemon's relay overwrites it with the registration's.
        project: String,
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
        /// The session that asked; a daemon's relay overwrites it with the registration's.
        session: String,
        /// That session's project root; a daemon's relay overwrites it with the registration's.
        project: String,
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
        /// The paired device that gave it; the relay stamps it, whatever the phone claimed.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        device: Option<String>,
    },
    /// Reply to a wave gate, a verdict per issue id.
    Gate {
        /// The agenda id answered.
        id: String,
        /// Issue id and its verdict.
        verdicts: Vec<(String, Verdict)>,
        /// The paired device that gave it; the relay stamps it, whatever the phone claimed.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        device: Option<String>,
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
        /// The paired device that gave it; the relay stamps it, whatever the phone claimed.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        device: Option<String>,
    },
}

impl Answer {
    /// The same answer, naming `device` as the one that gave it.
    #[must_use]
    pub fn stamped_by(mut self, device: &str) -> Self {
        let (Self::Call { device: slot, .. }
        | Self::Gate { device: slot, .. }
        | Self::Question { device: slot, .. }) = &mut self;
        *slot = Some(device.to_string());
        self
    }
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

/// The relay's reply to an admitted [`Hello`].
///
/// Encode with [`encode`] (named maps); positional arrays do not decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Welcome {
    /// The relay's [`WIRE_VERSION`].
    pub wire_version: u32,
    /// The newest delta cursor.
    pub head: u64,
    /// Random per relay process; a cursor from another epoch is reset.
    pub epoch: u64,
}

/// Where a reader resumes: the param of `agenda.next` and `answers.next`.
///
/// Encode with [`encode`] (named maps); positional arrays do not decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cursor {
    /// The last cursor the reader saw, 0 for none.
    pub cursor: u64,
    /// The epoch that cursor came from; absent until the reader has seen one.
    #[serde(default)]
    pub epoch: Option<u64>,
}

/// The relay's reply to `agenda.next`.
///
/// Encode with [`encode`] (named maps); positional arrays do not decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgendaPage {
    /// The relay's epoch.
    pub epoch: u64,
    /// The cursor to ask from next.
    pub cursor: u64,
    /// When true, drop what you hold: `deltas` is one delta adding every open item.
    pub reset: bool,
    /// The deltas after the asked cursor, as many as fit one reply.
    pub deltas: Vec<Delta>,
}

/// The relay's reply to `answers.next`.
///
/// Encode with [`encode`] (named maps); positional arrays do not decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AnswersPage {
    /// The relay's epoch.
    pub epoch: u64,
    /// The cursor to ask from next.
    pub cursor: u64,
    /// When true, the asked cursor was not kept and some answers may be gone.
    pub reset: bool,
    /// The answers after the asked cursor, as many as fit one reply.
    pub answers: Vec<Answer>,
}

/// A chat's `session.register` to the daemon: who it is and where it runs.
///
/// Encode with [`encode`] (named maps); positional arrays do not decode.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Register {
    /// The chat's journal stem.
    pub session_id: String,
    /// The chat's process, which must be the process on the other end of the connection.
    pub pid: u32,
    /// The host the chat runs on.
    pub host: String,
    /// The project root.
    pub root: String,
    /// The chat's working directory.
    pub cwd: String,
    /// The chat's input socket; absent for a headless chat.
    #[serde(default)]
    pub input_socket: Option<String>,
    /// The chat's journal; absent for a `--no-journal` chat.
    #[serde(default)]
    pub journal: Option<String>,
    /// Whether a human is at the chat's terminal.
    pub attended: bool,
    /// When the chat started, as the chat writes it.
    pub started_at: String,
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

    const SESSION: &str = "2026-11-17T10-00-00-abc";

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
            session: s(SESSION),
            project: s("/work"),
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
            session: s(SESSION),
            project: s("/work"),
        }
    }

    fn question() -> AgendaItem {
        AgendaItem::Question {
            id: s("q1"),
            requester: s("main"),
            question: s("which branch?"),
            options: vec![s("main"), s("dev")],
            asked_at: 1_700_000_002,
            session: s(SESSION),
            project: s("/work"),
        }
    }

    #[test]
    fn hello_round_trips() {
        check(
            "hello",
            Hello {
                wire_version: 1,
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
                device: None,
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
                device: None,
            },
        );
        check(
            "answer_question",
            Answer::Question {
                id: s("q1"),
                option: Some(s("dev")),
                text: None,
                device: None,
            },
        );
    }

    #[test]
    fn an_answer_carries_the_device_that_gave_it() {
        check(
            "answer_call_device",
            Answer::Call {
                id: s("c1"),
                verdict: Verdict::Approve { note: None },
                device: Some(s("pixel")),
            },
        );
    }

    #[test]
    fn a_device_stamp_replaces_any_device_the_answer_claimed() {
        let claimed = Answer::Gate {
            id: s("g1"),
            verdicts: vec![],
            device: Some(s("someone-else")),
        };
        assert_eq!(
            Answer::Gate {
                id: s("g1"),
                verdicts: vec![],
                device: Some(s("pixel")),
            },
            claimed.stamped_by("pixel")
        );
    }

    #[test]
    fn welcome_round_trips() {
        check(
            "welcome",
            Welcome {
                wire_version: 1,
                head: 9,
                epoch: 0x9e37_79b9_7f4a_7c15,
            },
        );
    }

    #[test]
    fn cursor_round_trips_with_and_without_an_epoch() {
        check(
            "cursor",
            Cursor {
                cursor: 7,
                epoch: Some(0x9e37_79b9_7f4a_7c15),
            },
        );
        check(
            "cursor_fresh",
            Cursor {
                cursor: 0,
                epoch: None,
            },
        );
    }

    #[test]
    fn a_cursor_without_an_epoch_key_is_fresh() {
        let cursor: Cursor = decode(&committed("cursor_epoch_absent")).expect("decode");
        assert_eq!(
            cursor,
            Cursor {
                cursor: 0,
                epoch: None
            }
        );
    }

    #[test]
    fn agenda_page_round_trips() {
        check(
            "agenda_page",
            AgendaPage {
                epoch: 0x9e37_79b9_7f4a_7c15,
                cursor: 9,
                reset: false,
                deltas: vec![Delta {
                    cursor: 9,
                    added: vec![call(), gate(), question()],
                    settled: vec![s("old")],
                }],
            },
        );
    }

    #[test]
    fn answers_page_round_trips() {
        check(
            "answers_page",
            AnswersPage {
                epoch: 0x9e37_79b9_7f4a_7c15,
                cursor: 2,
                reset: true,
                answers: vec![
                    Answer::Call {
                        id: s("c1"),
                        verdict: Verdict::Approve { note: None },
                        device: None,
                    },
                    Answer::Question {
                        id: s("q1"),
                        option: Some(s("dev")),
                        text: None,
                        device: None,
                    },
                ],
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
    fn an_older_and_a_newer_hello_decode_and_differ_from_ours() {
        let versions: Vec<u32> = ["hello", "hello_v3"]
            .iter()
            .map(|name| {
                decode::<Hello>(&committed(name))
                    .expect("decode")
                    .wire_version
            })
            .collect();
        assert_eq!(vec![1, 3], versions);
        assert!(!versions.contains(&WIRE_VERSION));
    }

    #[test]
    fn an_item_without_its_session_or_without_its_project_is_an_error() {
        #[derive(Serialize)]
        enum Partial {
            ParkedCall {
                id: String,
                requester: String,
                tool: String,
                input: String,
                cwd: String,
                why: String,
                postponed: bool,
                asked_at: i64,
                #[serde(skip_serializing_if = "Option::is_none")]
                session: Option<String>,
                #[serde(skip_serializing_if = "Option::is_none")]
                project: Option<String>,
            },
        }
        let lacking = |session: Option<&str>, project: Option<&str>| {
            encode(&Partial::ParkedCall {
                id: s("c1"),
                requester: s("main"),
                tool: s("bash"),
                input: s("ls -la"),
                cwd: s("/work"),
                why: s("outside bounds"),
                postponed: true,
                asked_at: 1_700_000_000,
                session: session.map(s),
                project: project.map(s),
            })
            .expect("encode")
        };
        let decoded = [
            decode::<AgendaItem>(&lacking(None, Some("/work"))).is_err(),
            decode::<AgendaItem>(&lacking(Some(SESSION), None)).is_err(),
        ];
        assert_eq!([true, true], decoded);
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
                wire_version: 1,
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
                text: None,
                device: None,
            }
        );
    }

    #[test]
    fn a_map16_message_decodes() {
        let bytes = committed("hello_map16");
        assert_eq!(bytes[0], 0xde);
        let hello: Hello = decode(&bytes).expect("decode");
        assert_eq!(hello.wire_version, 1);
    }

    fn register() -> Register {
        Register {
            session_id: s("2026-11-17T10-00-00-abc"),
            pid: 4242,
            host: s("rainbow"),
            root: s("/work"),
            cwd: s("/work/lib"),
            input_socket: Some(s("/run/lain/input.sock")),
            journal: Some(s("/work/.lain/sessions/abc.ndjson")),
            attended: true,
            started_at: s("2026-11-17T10:00:00Z"),
        }
    }

    #[test]
    fn register_round_trips() {
        let register = register();
        let bytes = encode(&register).expect("encode");
        assert_eq!(decode::<Register>(&bytes).expect("decode"), register);
    }

    #[test]
    fn a_register_without_its_optional_paths_decodes_them_as_none() {
        #[derive(Serialize)]
        struct Headless {
            session_id: String,
            pid: u32,
            host: String,
            root: String,
            cwd: String,
            attended: bool,
            started_at: String,
        }
        let bytes = encode(&Headless {
            session_id: s("2026-11-17T10-00-00-abc"),
            pid: 4242,
            host: s("rainbow"),
            root: s("/work"),
            cwd: s("/work/lib"),
            attended: false,
            started_at: s("2026-11-17T10:00:00Z"),
        })
        .expect("encode");
        let register: Register = decode(&bytes).expect("decode");
        assert_eq!(None, register.input_socket);
        assert_eq!(None, register.journal);
        assert!(!register.attended);
    }

    #[test]
    fn positional_array_bytes_are_rejected() {
        assert!(decode::<Hello>(&committed("hello_positional")).is_err());
    }
}
