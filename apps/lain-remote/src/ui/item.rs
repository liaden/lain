use dioxus::prelude::*;
use lain_wire::{AgendaItem, Answer, Verdict};

/// One way to answer an item.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reply {
  Approve,
  Hold,
  Deny,
  Option(String),
  Text,
}

impl Reply {
  pub fn label(&self) -> &str {
    match self {
      Self::Approve => "Approve",
      Self::Hold => "Hold",
      Self::Deny => "Deny",
      Self::Option(option) => option,
      Self::Text => "Send text",
    }
  }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Field {
  pub label: &'static str,
  pub value: String,
}

/// What the item screen shows, apart from how it is drawn.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemView {
  pub id: String,
  pub kind: &'static str,
  pub requester: String,
  pub asked_at: i64,
  pub fields: Vec<Field>,
  pub replies: Vec<Reply>,
}

fn field(label: &'static str, value: &str) -> Field {
  Field { label, value: value.to_string() }
}

impl ItemView {
  pub fn of(item: &AgendaItem) -> Self {
    let verdicts = vec![Reply::Approve, Reply::Hold, Reply::Deny];
    match item {
      AgendaItem::ParkedCall { id, requester, tool, input, cwd, why, asked_at, .. } => Self {
        id: id.clone(),
        kind: "parked call",
        requester: requester.clone(),
        asked_at: *asked_at,
        fields: vec![
          field("command", &format!("{tool} {input}")),
          field("cwd", cwd),
          field("requester", requester),
          field("reason", why),
        ],
        replies: verdicts,
      },
      AgendaItem::GateQuestion {
        id,
        requester,
        epic,
        stage,
        issues,
        question,
        asked_at,
      } => Self {
        id: id.clone(),
        kind: "gate",
        requester: requester.clone(),
        asked_at: *asked_at,
        fields: std::iter::once(field("question", question))
          .chain(issues.iter().map(|issue| field("issue", issue)))
          .chain([
            field("epic", epic),
            field("stage", stage),
            field("requester", requester),
          ])
          .collect(),
        replies: verdicts,
      },
      AgendaItem::Question { id, requester, question, options, asked_at } => Self {
        id: id.clone(),
        kind: "question",
        requester: requester.clone(),
        asked_at: *asked_at,
        fields: vec![field("question", question), field("requester", requester)],
        replies: options.iter().cloned().map(Reply::Option).chain([Reply::Text]).collect(),
      },
    }
  }
}

fn note_of(note: &str) -> Option<String> {
  Some(note.trim()).filter(|note| !note.is_empty()).map(str::to_string)
}

fn verdict(reply: &Reply, note: &str) -> Option<Verdict> {
  let note = note_of(note);
  match reply {
    Reply::Approve => Some(Verdict::Approve { note }),
    Reply::Hold => Some(Verdict::Hold { note }),
    Reply::Deny => Some(Verdict::Deny { note }),
    Reply::Option(_) | Reply::Text => None,
  }
}

/// None when the item cannot take that reply.
pub fn answer(item: &AgendaItem, reply: &Reply, note: &str) -> Option<Answer> {
  match item {
    AgendaItem::ParkedCall { id, .. } => Some(Answer::Call {
      id: id.clone(),
      verdict: verdict(reply, note)?,
      device: None,
    }),
    AgendaItem::GateQuestion { id, issues, .. } => {
      let verdict = verdict(reply, note)?;
      Some(Answer::Gate {
        id: id.clone(),
        verdicts: issues.iter().map(|issue| (issue.clone(), verdict.clone())).collect(),
        device: None,
      })
    }
    AgendaItem::Question { id, .. } => match reply {
      Reply::Option(option) => Some(Answer::Question {
        id: id.clone(),
        option: Some(option.clone()),
        text: note_of(note),
        device: None,
      }),
      Reply::Text => Some(Answer::Question {
        id: id.clone(),
        option: None,
        text: Some(note_of(note)?),
        device: None,
      }),
      Reply::Approve | Reply::Hold | Reply::Deny => None,
    },
  }
}

/// What the item screen does once the relay has accepted or refused an answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outcome {
  pub close: bool,
  pub notice: String,
}

pub fn outcome(result: Result<(), String>) -> Outcome {
  match result {
    Ok(()) => Outcome { close: true, notice: String::new() },
    Err(message) => Outcome {
      close: false,
      notice: format!("answer failed: {message}"),
    },
  }
}

#[component]
pub fn Item(item: AgendaItem, notice: String, send: EventHandler<Answer>, close: EventHandler<()>) -> Element {
  let view = ItemView::of(&item);
  let mut note = use_signal(String::new);

  rsx! {
    h2 { "{view.kind}" }
    for field in view.fields {
      p { b { "{field.label}: " } "{field.value}" }
    }
    p { {notice} }
    input { placeholder: "note", value: "{note}", oninput: move |event| note.set(event.value()) }
    for reply in view.replies {
      button {
        onclick: {
          let (item, reply) = (item.clone(), reply.clone());
          move |_| {
            if let Some(answer) = answer(&item, &reply, &note.read()) {
              send.call(answer);
            }
          }
        },
        "{reply.label()}"
      }
    }
    button { onclick: move |_| close.call(()), "Back" }
  }
}

#[cfg(test)]
mod tests {
  use lain_wire::{AgendaItem, Answer, Verdict};

  use super::{ItemView, Reply, answer, outcome};

  fn parked_call() -> AgendaItem {
    AgendaItem::ParkedCall {
      id: "c1".to_string(),
      requester: "builder".to_string(),
      tool: "bash".to_string(),
      input: "rm -rf build".to_string(),
      cwd: "/work/tree".to_string(),
      why: "the judge could not settle it".to_string(),
      postponed: false,
      asked_at: 1,
    }
  }

  fn gate() -> AgendaItem {
    AgendaItem::GateQuestion {
      id: "g1".to_string(),
      requester: "coordinator".to_string(),
      epic: "nyotes".to_string(),
      stage: "wave".to_string(),
      issues: vec!["i1".to_string(), "i2".to_string()],
      question: "land the wave?".to_string(),
      asked_at: 1,
    }
  }

  fn question() -> AgendaItem {
    AgendaItem::Question {
      id: "q1".to_string(),
      requester: "main".to_string(),
      question: "which branch?".to_string(),
      options: vec!["main".to_string(), "dev".to_string()],
      asked_at: 1,
    }
  }

  fn value_of(view: &ItemView, label: &str) -> Option<String> {
    view
      .fields
      .iter()
      .find(|field| field.label == label)
      .map(|field| field.value.clone())
  }

  #[test]
  fn a_parked_call_shows_command_cwd_requester_and_reason() {
    let view = ItemView::of(&parked_call());

    assert_eq!(Some("bash rm -rf build".to_string()), value_of(&view, "command"));
    assert_eq!(Some("/work/tree".to_string()), value_of(&view, "cwd"));
    assert_eq!(Some("builder".to_string()), value_of(&view, "requester"));
    assert_eq!(Some("the judge could not settle it".to_string()), value_of(&view, "reason"));
  }

  #[test]
  fn a_gate_shows_its_question_then_each_issue_on_its_own_line() {
    let view = ItemView::of(&gate());

    assert_eq!(Some("land the wave?".to_string()), value_of(&view, "question"));
    let issues: Vec<_> = view
      .fields
      .iter()
      .filter(|field| field.label == "issue")
      .map(|field| field.value.as_str())
      .collect();
    assert_eq!(vec!["i1", "i2"], issues);
    let position = |label| view.fields.iter().position(|field| field.label == label);
    assert!(position("question") < position("issue"), "the question comes first");
  }

  #[test]
  fn a_failed_answer_keeps_the_item_open_and_says_why() {
    let failed = outcome(Err("connection refused".to_string()));

    assert!(!failed.close);
    assert_eq!("answer failed: connection refused", failed.notice);
  }

  #[test]
  fn a_confirmed_answer_closes_the_item() {
    let sent = outcome(Ok(()));

    assert!(sent.close);
    assert_eq!("", sent.notice);
  }

  #[test]
  fn free_text_with_a_blank_note_sends_nothing() {
    assert_eq!(None, answer(&question(), &Reply::Text, ""));
    assert_eq!(None, answer(&question(), &Reply::Text, "  \n "));
  }

  #[test]
  fn each_kind_offers_the_replies_it_can_take() {
    assert_eq!(
      vec![Reply::Approve, Reply::Hold, Reply::Deny],
      ItemView::of(&parked_call()).replies
    );
    assert_eq!(vec![Reply::Approve, Reply::Hold, Reply::Deny], ItemView::of(&gate()).replies);
    assert_eq!(
      vec![
        Reply::Option("main".to_string()),
        Reply::Option("dev".to_string()),
        Reply::Text
      ],
      ItemView::of(&question()).replies
    );
  }

  #[test]
  fn deny_with_a_note_answers_the_call_with_that_note() {
    let sent = answer(&parked_call(), &Reply::Deny, "wrong tree");

    assert_eq!(
      Some(Answer::Call {
        id: "c1".to_string(),
        verdict: Verdict::Deny { note: Some("wrong tree".to_string()) },
        device: None,
      }),
      sent
    );
  }

  #[test]
  fn a_blank_note_is_no_note() {
    let sent = answer(&parked_call(), &Reply::Approve, "   ");

    assert_eq!(
      Some(Answer::Call {
        id: "c1".to_string(),
        verdict: Verdict::Approve { note: None },
        device: None,
      }),
      sent
    );
  }

  #[test]
  fn a_gate_verdict_covers_every_issue() {
    let sent = answer(&gate(), &Reply::Hold, "later");

    let note = Some("later".to_string());
    assert_eq!(
      Some(Answer::Gate {
        id: "g1".to_string(),
        verdicts: vec![
          ("i1".to_string(), Verdict::Hold { note: note.clone() }),
          ("i2".to_string(), Verdict::Hold { note }),
        ],
        device: None,
      }),
      sent
    );
  }

  #[test]
  fn a_question_takes_an_option_or_free_text() {
    assert_eq!(
      Some(Answer::Question {
        id: "q1".to_string(),
        option: Some("dev".to_string()),
        text: None,
        device: None,
      }),
      answer(&question(), &Reply::Option("dev".to_string()), "")
    );
    assert_eq!(
      Some(Answer::Question {
        id: "q1".to_string(),
        option: None,
        text: Some("a new branch".to_string()),
        device: None,
      }),
      answer(&question(), &Reply::Text, "a new branch")
    );
  }

  #[test]
  fn a_reply_the_item_cannot_take_sends_nothing() {
    assert_eq!(None, answer(&question(), &Reply::Deny, ""));
    assert_eq!(None, answer(&parked_call(), &Reply::Text, "x"));
  }
}
