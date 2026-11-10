mod client;

use client::{Error, Session};
use dioxus::prelude::*;
use futures_util::StreamExt;
use lain_wire::{AgendaItem, Answer};

fn main() {
  dioxus::launch(App);
}

fn pairing() -> Result<(std::net::SocketAddr, String), String> {
  let addr = std::env::var("LAIN_REMOTE_ADDR").map_err(|_| "set LAIN_REMOTE_ADDR to the relay's address:port")?;
  let token = std::env::var("LAIN_REMOTE_TOKEN").map_err(|_| "set LAIN_REMOTE_TOKEN to the pairing token")?;
  let addr = addr.parse().map_err(|_| format!("{addr} is not an address:port"))?;
  Ok((addr, token))
}

async fn connect() -> Result<Session, String> {
  let (addr, token) = pairing()?;
  Session::connect(addr, &token).await.map_err(|error: Error| error.to_string())
}

/// One long poll. The session reconnects with its cursor by itself, so only a failed first connect needs a fresh one.
async fn read_agenda(session: &mut Option<Session>) -> Result<Vec<AgendaItem>, String> {
  if session.is_none() {
    *session = Some(connect().await?);
  }
  let Some(session) = session else { return Err("not connected".to_string()) };
  session.next().await.map_err(|error| error.to_string())?;
  Ok(session.items().to_vec())
}

const RETRY_AFTER: std::time::Duration = std::time::Duration::from_secs(3);

// Reading and answering get a connection each, because a long poll in flight cannot be cancelled to send.
#[component]
fn App() -> Element {
  let mut items = use_signal(Vec::<AgendaItem>::new);
  let mut status = use_signal(String::new);

  use_future(move || async move {
    let mut session = None;
    loop {
      match read_agenda(&mut session).await {
        Ok(waiting) => {
          items.set(waiting);
          status.set(String::new());
        }
        Err(message) => {
          status.set(format!("reconnecting: {message}"));
          tokio::time::sleep(RETRY_AFTER).await;
        }
      }
    }
  });

  let answers = use_coroutine(move |mut queue: UnboundedReceiver<Answer>| async move {
    match connect().await {
      Err(message) => status.set(message),
      Ok(mut session) => {
        while let Some(answer) = queue.next().await {
          if let Err(error) = session.answer(&answer).await {
            status.set(error.to_string());
          }
        }
      }
    }
  });

  rsx! {
    h1 { "Lain Remote" }
    p { "{status}" }
    for item in items.read().iter() {
      Waiting { item: item.clone(), answers }
    }
  }
}

#[component]
fn Waiting(item: AgendaItem, answers: Coroutine<Answer>) -> Element {
  match item {
    AgendaItem::Question { id, question, options, .. } => rsx! {
      div {
        p { {question} }
        for option in options {
          button {
            onclick: {
              let (id, option) = (id.clone(), option.clone());
              move |_| answers.send(Answer::Question { id: id.clone(), option: Some(option.clone()), text: None, device: None })
            },
            {option.clone()}
          }
        }
      }
    },
    AgendaItem::ParkedCall { tool, input, .. } => rsx! { p { "{tool} {input}" } },
    AgendaItem::GateQuestion { question, .. } => rsx! { p { {question} } },
  }
}
