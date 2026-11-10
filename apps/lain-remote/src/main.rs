mod client;
mod ui {
  pub mod agenda;
  pub mod item;
  pub mod settings;
}

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use client::Session;
use dioxus::prelude::*;
use lain_wire::{AgendaItem, Answer};
use ui::agenda::Agenda;
use ui::item::{Item, outcome};
use ui::settings::{Settings, SettingsForm, default_path};

fn main() {
  dioxus::launch(App);
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Screen {
  Agenda,
  Item(String),
  Settings,
}

fn initial_settings() -> Option<Settings> {
  default_path().and_then(|path| Settings::load(&path)).or_else(|| {
    let addr = std::env::var("LAIN_REMOTE_ADDR").ok()?;
    let token = std::env::var("LAIN_REMOTE_TOKEN").ok()?;
    Settings::from_form(None, &addr, &token).ok()
  })
}

async fn connect(settings: &Settings) -> Result<Session, String> {
  Session::connect(settings.socket_addr(), settings.token())
    .await
    .map_err(|error| error.to_string())
}

/// One long poll. The session reconnects with its cursor by itself, so only a failed first connect needs a fresh one.
async fn read_agenda(settings: &Settings, session: &mut Option<Session>) -> Result<Vec<AgendaItem>, String> {
  if session.is_none() {
    *session = Some(connect(settings).await?);
  }
  let Some(session) = session else { return Err("not connected".to_string()) };
  session.next().await.map_err(|error| error.to_string())?;
  Ok(session.items().to_vec())
}

fn now() -> i64 {
  SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .map_or(0, |elapsed| i64::try_from(elapsed.as_secs()).unwrap_or(0))
}

const RETRY_AFTER: Duration = Duration::from_secs(3);

#[component]
fn App() -> Element {
  let mut items = use_signal(Vec::<AgendaItem>::new);
  let mut status = use_signal(String::new);
  let mut notice = use_signal(String::new);
  let mut settings = use_signal(initial_settings);
  let mut screen = use_signal(|| if settings.peek().is_some() { Screen::Agenda } else { Screen::Settings });

  // Reading `settings` here restarts the loop, and drops its session, when the pairing changes.
  use_resource(move || async move {
    let Some(paired) = settings() else { return };
    let mut session = None;
    loop {
      match read_agenda(&paired, &mut session).await {
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

  let send = move |answer: Answer| {
    let Some(paired) = settings.peek().clone() else { return };
    spawn(async move {
      // A connection of its own, because the reader's long poll in flight cannot be cancelled to send.
      let sent = match connect(&paired).await {
        Ok(mut session) => session.answer(&answer).await.map_err(|error| error.to_string()),
        Err(message) => Err(message),
      };
      let result = outcome(sent);
      notice.set(result.notice);
      if result.close {
        screen.set(Screen::Agenda);
      }
    });
  };

  let shown = match screen() {
    Screen::Agenda => rsx! {
      Agenda { items: items(), now: now(), open: move |id| {
          notice.set(String::new());
          screen.set(Screen::Item(id));
        } }
    },
    Screen::Item(id) => match items().into_iter().find(|item| ui::item::ItemView::of(item).id == id) {
      Some(item) => rsx! {
        Item { item, notice: notice(), send, close: move |()| screen.set(Screen::Agenda) }
      },
      None => rsx! {
        p { "That item is no longer waiting." }
        button { onclick: move |_| screen.set(Screen::Agenda), "Back" }
      },
    },
    Screen::Settings => rsx! {
      SettingsForm {
        current: settings(),
        save: move |saved: Settings| {
          if let Some(path) = default_path()
            && let Err(error) = saved.save(&path)
          {
            status.set(format!("could not save settings: {error}"));
          }
          settings.set(Some(saved));
          screen.set(Screen::Agenda);
        },
        close: move |()| screen.set(Screen::Agenda),
      }
    },
  };

  rsx! {
    h1 { "Lain Remote" }
    button { onclick: move |_| screen.set(Screen::Settings), "Settings" }
    p { "{status}" }
    {shown}
  }
}
