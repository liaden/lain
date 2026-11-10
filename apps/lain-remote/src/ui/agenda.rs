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

/// Newest first; the sort is stable, so items asked in the same second show the later arrival first.
pub fn rows(items: &[AgendaItem], now: i64) -> Vec<Row> {
  let mut views: Vec<_> = items.iter().rev().map(ItemView::of).collect();
  views.sort_by_key(|view| std::cmp::Reverse(view.asked_at));
  views
    .into_iter()
    .map(|view| Row {
      age: age(now - view.asked_at),
      id: view.id,
      kind: view.kind,
      requester: view.requester,
    })
    .collect()
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
  let listed = rows(&items, now);
  rsx! {
    if listed.is_empty() {
      p { "Nothing is waiting." }
    }
    for row in listed {
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

#[cfg(test)]
mod tests {
  use lain_wire::AgendaItem;

  use super::{age, rows};

  fn question(id: &str, requester: &str, asked_at: i64) -> AgendaItem {
    AgendaItem::Question {
      id: id.to_string(),
      requester: requester.to_string(),
      question: "which branch?".to_string(),
      options: vec![],
      asked_at,
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

  #[test]
  fn an_age_uses_the_largest_whole_unit() {
    assert_eq!("0s", age(-5));
    assert_eq!("59s", age(59));
    assert_eq!("1m", age(60));
    assert_eq!("2h", age(7_200 + 59));
    assert_eq!("3d", age(3 * 86_400));
  }
}
