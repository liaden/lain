use dioxus::prelude::*;
use lain_wire::AgendaItem;

use super::item::ItemView;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
  pub id: String,
  pub kind: &'static str,
  pub requester: String,
  pub age: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Group {
  pub project: String,
  pub session: String,
  pub rows: Vec<Row>,
}

/// A group sits where its newest item sits, so the listing's order stays the newest-first order `placed_rows` gives.
pub fn groups(items: &[AgendaItem], now: i64) -> Vec<Group> {
  placed_rows(items, now)
    .into_iter()
    .fold(Vec::new(), |mut grouped: Vec<Group>, ((project, session), row)| {
      match grouped
        .iter_mut()
        .find(|group| group.project == project && group.session == session)
      {
        Some(group) => group.rows.push(row),
        None => grouped.push(Group { project, session, rows: vec![row] }),
      }
      grouped
    })
}

/// Newest first; the sort is stable, so items asked in the same second show the later arrival first.
fn placed_rows(items: &[AgendaItem], now: i64) -> Vec<((String, String), Row)> {
  let mut views: Vec<_> = items.iter().rev().map(|item| (place(item), ItemView::of(item))).collect();
  views.sort_by_key(|(_, view)| std::cmp::Reverse(view.asked_at));
  views
    .into_iter()
    .map(|(place, view)| {
      let row = Row {
        age: age(now - view.asked_at),
        id: view.id,
        kind: view.kind,
        requester: view.requester,
      };
      (place, row)
    })
    .collect()
}

fn place(item: &AgendaItem) -> (String, String) {
  match item {
    AgendaItem::ParkedCall { project, session, .. }
    | AgendaItem::GateQuestion { project, session, .. }
    | AgendaItem::Question { project, session, .. } => (project.clone(), session.clone()),
  }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Opening {
  Select(String),
  Settled(String),
}

const ITEM_LINK: &str = "lain-remote://item/";

/// The one place a `lain-remote://item/<id>` URL is read; `None` means the URL is not an item link.
fn link_id(url: &str) -> Option<String> {
  let scheme = url.get(..ITEM_LINK.len()).filter(|head| head.eq_ignore_ascii_case(ITEM_LINK))?;
  let rest = url.get(scheme.len()..)?;
  let path = rest.split(['?', '#']).next()?;
  let id = path.strip_suffix('/').unwrap_or(path);
  if id.is_empty() || id.contains('/') {
    return None;
  }
  percent_decode(id)
}

// ntfy.rb url-encodes the id, and the url crate is not a direct dependency.
fn percent_decode(text: &str) -> Option<String> {
  let mut bytes = text.bytes();
  let mut decoded = Vec::new();
  while let Some(byte) = bytes.next() {
    if byte == b'%' {
      let high = hex(bytes.next()?)?;
      let low = hex(bytes.next()?)?;
      decoded.push(high * 16 + low);
    } else {
      decoded.push(byte);
    }
  }
  String::from_utf8(decoded).ok().filter(|id| !id.is_empty())
}

fn hex(digit: u8) -> Option<u8> {
  char::from(digit).to_digit(16).and_then(|value| u8::try_from(value).ok())
}

fn opening(items: &[AgendaItem], id: String) -> Opening {
  if items.iter().any(|item| ItemView::of(item).id == id) {
    Opening::Select(id)
  } else {
    Opening::Settled(id)
  }
}

#[cfg(test)]
pub fn open_link(items: &[AgendaItem], url: &str) -> Option<Opening> {
  link_id(url).map(|id| opening(items, id))
}

/// At most 1 link waits, because a link tapped before the first page cannot be told live from settled.
#[derive(Debug, Default)]
pub struct Links {
  pending: Option<String>,
}

impl Links {
  /// Takes the first item link of an event and ignores the rest; an event with none leaves the held link alone.
  pub fn hold(&mut self, urls: &[&str]) {
    if let Some(id) = urls.iter().find_map(|url| link_id(url)) {
      self.pending = Some(id);
    }
  }

  pub fn is_waiting(&self) -> bool {
    self.pending.is_some()
  }

  pub fn ready(&mut self, items: &[AgendaItem], page_in: bool, paired: bool) -> Option<Opening> {
    if page_in && paired {
      self.pending.take().map(|id| opening(items, id))
    } else {
      None
    }
  }
}

pub fn age(seconds: i64) -> String {
  let seconds = seconds.max(0);
  match seconds {
    0..60 => format!("{seconds}s"),
    60..3_600 => format!("{}m", seconds / 60),
    3_600..86_400 => format!("{}h", seconds / 3_600),
    _ => format!("{}d", seconds / 86_400),
  }
}

#[component]
pub fn Agenda(items: Vec<AgendaItem>, now: i64, open: EventHandler<String>) -> Element {
  let listed = groups(&items, now);
  rsx! {
    if listed.is_empty() {
      p { "Nothing is waiting." }
    }
    for group in listed {
      h2 { "{group.project} / {group.session}" }
      for row in group.rows {
        div {
          onclick: {
            let id = row.id.clone();
            move |_| open.call(id.clone())
          },
          "{row.kind} from {row.requester}, {row.age} ago"
        }
      }
    }
  }
}

#[cfg(test)]
mod tests {
  use lain_wire::AgendaItem;

  use super::{Links, Opening, Row, age, groups, open_link, placed_rows};

  fn rows(items: &[AgendaItem], now: i64) -> Vec<Row> {
    placed_rows(items, now).into_iter().map(|(_, row)| row).collect()
  }

  fn question(id: &str, requester: &str, asked_at: i64) -> AgendaItem {
    AgendaItem::Question {
      id: id.to_string(),
      requester: requester.to_string(),
      question: "which branch?".to_string(),
      options: vec![],
      asked_at,
      session: "s1".to_string(),
      project: "/work".to_string(),
    }
  }

  fn call(id: &str, asked_at: i64) -> AgendaItem {
    AgendaItem::ParkedCall {
      id: id.to_string(),
      requester: "builder".to_string(),
      tool: "bash".to_string(),
      input: "cargo test".to_string(),
      cwd: "/work".to_string(),
      why: "judge could not settle".to_string(),
      postponed: false,
      asked_at,
      session: "s1".to_string(),
      project: "/work".to_string(),
    }
  }

  #[test]
  fn lists_items_newest_first_with_kind_requester_and_age() {
    let items = [
      question("old", "main", 1_000),
      call("mid", 1_500),
      question("new", "reviewer", 1_900),
    ];

    let listed = rows(&items, 2_000);

    let ids: Vec<_> = listed.iter().map(|row| row.id.as_str()).collect();
    assert_eq!(vec!["new", "mid", "old"], ids);
    let newest = listed.first().expect("a row");
    assert_eq!("question", newest.kind);
    assert_eq!("reviewer", newest.requester);
    assert_eq!("1m", newest.age);
    assert_eq!("parked call", listed.get(1).expect("a row").kind);
  }

  #[test]
  fn arrival_order_does_not_decide_the_listing() {
    let items = [
      call("mid", 1_500),
      question("new", "main", 1_900),
      question("old", "main", 1_000),
    ];

    let ids: Vec<_> = rows(&items, 2_000).into_iter().map(|row| row.id).collect();

    assert_eq!(vec!["new", "mid", "old"], ids);
  }

  #[test]
  fn items_asked_in_the_same_second_keep_the_later_arrival_first() {
    let items = [question("first", "main", 1_000), question("second", "main", 1_000)];

    let ids: Vec<_> = rows(&items, 1_000).into_iter().map(|row| row.id).collect();

    assert_eq!(vec!["second", "first"], ids);
  }

  fn placed(item: AgendaItem, session: &str, project: &str) -> AgendaItem {
    match item {
      AgendaItem::Question { id, requester, question, options, asked_at, .. } => AgendaItem::Question {
        id,
        requester,
        question,
        options,
        asked_at,
        session: session.to_string(),
        project: project.to_string(),
      },
      other => other,
    }
  }

  #[test]
  fn items_group_under_their_project_and_session_newest_group_first() {
    let items = [
      placed(question("a1", "main", 1_000), "s1", "/one"),
      placed(question("b1", "main", 1_900), "s2", "/two"),
      placed(question("a2", "main", 1_500), "s1", "/one"),
    ];

    let grouped = groups(&items, 2_000);

    let shape: Vec<_> = grouped
      .iter()
      .map(|group| {
        let ids: Vec<_> = group.rows.iter().map(|row| row.id.as_str()).collect();
        (group.project.as_str(), group.session.as_str(), ids)
      })
      .collect();
    assert_eq!(vec![("/two", "s2", vec!["b1"]), ("/one", "s1", vec!["a2", "a1"])], shape);
  }

  #[test]
  fn one_session_in_two_projects_is_two_groups() {
    let items = [
      placed(question("a", "main", 1_000), "s1", "/one"),
      placed(question("b", "main", 1_100), "s1", "/two"),
    ];

    assert_eq!(2, groups(&items, 2_000).len());
  }

  #[test]
  fn a_link_to_a_waiting_item_selects_it() {
    let items = [question("live", "main", 1_000)];

    assert_eq!(
      Some(Opening::Select("live".to_string())),
      open_link(&items, "lain-remote://item/live")
    );
  }

  #[test]
  fn a_link_to_a_settled_or_unknown_item_says_it_is_settled() {
    let items = [question("live", "main", 1_000)];

    assert_eq!(
      Some(Opening::Settled("gone".to_string())),
      open_link(&items, "lain-remote://item/gone")
    );
  }

  #[test]
  fn a_url_that_is_not_an_item_link_is_ignored() {
    let items = [question("live", "main", 1_000)];

    assert_eq!(None, open_link(&items, "https://item/live"));
    assert_eq!(None, open_link(&items, "lain-remote://settings"));
    assert_eq!(None, open_link(&items, "lain-remote://item/live/extra"));
    assert_eq!(None, open_link(&items, "lain-remote://item/"));
    assert_eq!(None, open_link(&items, "lain-remote://item/?x=1"));
  }

  #[test]
  fn a_link_is_read_the_way_ntfy_writes_it() {
    let items = [question("7", "main", 1_000), question("a b", "main", 1_000)];
    let select = |id: &str| Some(Opening::Select(id.to_string()));

    for (url, expected) in [
      ("lain-remote://item/%37", select("7")),
      ("lain-remote://item/a%20b", select("a b")),
      ("lain-remote://item/7?x=1", select("7")),
      ("lain-remote://item/7#f", select("7")),
      ("lain-remote://item/7/", select("7")),
      ("LAIN-REMOTE://item/7", select("7")),
      ("lain-remote://item/%zz", None),
      ("lain-remote://item/%ff", None),
    ] {
      assert_eq!(expected, open_link(&items, url), "{url}");
    }
  }

  #[test]
  fn sessions_of_one_project_are_separate_groups() {
    let items = [
      placed(question("a", "main", 1_000), "s1", "/one"),
      placed(question("b", "main", 1_100), "s2", "/one"),
    ];

    assert_eq!(2, groups(&items, 2_000).len());
  }

  #[test]
  fn a_link_waits_for_the_first_page_and_for_pairing() {
    let items = [question("7", "main", 1_000)];
    let mut links = Links::default();
    links.hold(&["lain-remote://item/7"]);

    assert_eq!(None, links.ready(&[], false, true));
    assert_eq!(None, links.ready(&items, true, false));
    assert_eq!(Some(Opening::Select("7".to_string())), links.ready(&items, true, true));
    assert_eq!(None, links.ready(&items, true, true), "a resolved link is not resolved twice");
  }

  #[test]
  fn a_link_to_a_settled_item_resolves_as_settled_once_the_page_is_in() {
    let mut links = Links::default();
    links.hold(&["lain-remote://item/gone"]);

    assert_eq!(Some(Opening::Settled("gone".to_string())), links.ready(&[], true, true));
  }

  #[test]
  fn the_first_link_of_one_event_wins() {
    let items = [question("1", "main", 1_000), question("2", "main", 1_000)];
    let mut links = Links::default();

    links.hold(&["https://example.com", "lain-remote://item/1", "lain-remote://item/2"]);

    assert_eq!(Some(Opening::Select("1".to_string())), links.ready(&items, true, true));
  }

  #[test]
  fn only_the_newest_held_link_is_kept() {
    let items = [
      question("1", "main", 1_000),
      question("2", "main", 1_000),
      question("3", "main", 1_000),
    ];
    let mut links = Links::default();

    links.hold(&["https://example.com", "lain-remote://item/1", "lain-remote://item/2"]);
    links.hold(&["lain-remote://item/3"]);
    links.hold(&["https://example.com"]);

    assert_eq!(Some(Opening::Select("3".to_string())), links.ready(&items, true, true));
  }

  #[test]
  fn an_age_uses_the_largest_whole_unit() {
    assert_eq!("0s", age(-5));
    assert_eq!("59s", age(59));
    assert_eq!("1m", age(60));
    assert_eq!("2h", age(7_200 + 59));
    assert_eq!("3d", age(3 * 86_400));
  }
}
