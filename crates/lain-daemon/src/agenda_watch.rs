//! Which items have waited long enough to buzz a phone.
//!
//! The relay worker mints the phone's id for an item and reports each item's opening and
//! closing; this runs in the main daemon because the worker has no network. An item that is still
//! open after the delay is announced once, however often it is published again.

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::Instant;

use crate::relay::{Event, Opened};

/// How long an item waits unanswered before the phone is told.
pub(crate) const DELAY: Duration = Duration::from_secs(60);

/// Where a notice goes.
pub(crate) trait Notify: Send + Sync + 'static {
    /// Ok once the notice is delivered; the error is a line fit for the trace.
    fn notify(&self, item: &Opened) -> impl Future<Output = Result<(), String>> + Send;

    /// The 1 notice for a window that dropped `more` items, which names no single item.
    fn summarize(&self, more: usize) -> impl Future<Output = Result<(), String>> + Send;
}

/// Remembers the last failure so a topic that stays down costs 1 trace line, not 1 per item.
#[derive(Default)]
struct Trail(Option<String>);

impl Trail {
    /// The error to write to the trace, when it is not the one just written.
    fn fresh(&mut self, outcome: Result<(), String>) -> Option<String> {
        match outcome {
            Ok(()) => {
                self.0 = None;
                None
            }
            Err(error) if self.0.as_deref() == Some(&error) => None,
            Err(error) => {
                self.0 = Some(error.clone());
                Some(error)
            }
        }
    }
}

/// What a confined worker can make the daemon hold: it can forge any number of openings, so the
/// daemon bounds the items it keeps instead of trusting the worker's count.
const MAX_OPEN: usize = 512;

/// A confined worker can also forge openings that each come due, and every notice is a request
/// to a host the worker could not reach; this is what the daemon will send per window.
const MAX_POSTS: usize = 30;

const WINDOW: Duration = Duration::from_secs(60);

/// An item is acted on once: a republish is `Held`, so it neither re-arms its wait nor re-sends.
#[derive(Debug, PartialEq, Eq)]
enum Opening {
    Arm,
    Held,
    /// Dropped for want of room; `first` is true once per run of drops, so the trace says it once.
    Full {
        first: bool,
    },
}

/// A notice over the cap is dropped and never queued, so a flood cannot grow the daemon's memory.
#[derive(Debug, PartialEq, Eq)]
enum Admit {
    Send,
    /// Over the window's cap; `first` is true once per window.
    Drop {
        first: bool,
    },
}

/// Counted per window and not per item, because the cap bounds requests to a host the worker
/// could not reach itself, whoever forged them.
struct Budget {
    began: Option<Instant>,
    sent: usize,
    dropped: bool,
    /// Notices dropped and not yet reported; a window's report is owed even if the next window
    /// has begun by the time it is made.
    owed: usize,
}

impl Budget {
    fn new() -> Self {
        Self {
            began: None,
            sent: 0,
            dropped: false,
            owed: 0,
        }
    }

    /// Taken once, so each dropped notice is reported by exactly 1 summary.
    fn summary(&mut self) -> usize {
        std::mem::take(&mut self.owed)
    }

    /// The summary waits for the window to close, so a flood costs 1 extra notice and not 1 per drop.
    fn ends(&self) -> Option<Instant> {
        self.began.map(|began| began + WINDOW)
    }

    fn admit(&mut self, now: Instant) -> Admit {
        if self
            .began
            .is_none_or(|began| now.duration_since(began) >= WINDOW)
        {
            *self = Self {
                began: Some(now),
                owed: self.owed,
                ..Self::new()
            };
        }
        if self.sent < MAX_POSTS {
            self.sent += 1;
            return Admit::Send;
        }
        let first = !self.dropped;
        self.dropped = true;
        self.owed += 1;
        Admit::Drop { first }
    }
}

/// How many announced items are remembered after they close, so a chat that reconnects and
/// publishes them again is not announced twice.
const REMEMBERED: usize = 1024;

enum Phase {
    Waiting(JoinHandle<()>),
    Announced,
    /// Every phone id it had closed before the delay; a republish starts the wait again.
    Closed,
}

/// 1 item as the chat knows it, under every phone id it holds now.
struct Entry {
    item: Opened,
    ids: Vec<String>,
    phase: Phase,
    /// Which wait is running, so one that fired as its item closed and reopened is told apart.
    generation: u64,
}

/// Every item, by the chat's own twin, so the phone ids a reconnect mints stay 1 item.
#[derive(Default)]
struct Items {
    by_twin: HashMap<String, Entry>,
    twin_of: HashMap<String, String>,
    closed: VecDeque<String>,
    waits: u64,
    /// Set by the first drop for want of room, so a flood is 1 trace line, and cleared by room.
    full: bool,
}

impl Items {
    fn open(&mut self, item: Opened) -> Opening {
        // A gate 2 chats share is 1 phone id under 2 twins; the first to publish it owns it.
        if self
            .twin_of
            .get(&item.id)
            .is_some_and(|twin| *twin != item.twin)
        {
            return Opening::Held;
        }
        if !self.twin_of.contains_key(&item.id) && self.twin_of.len() >= MAX_OPEN {
            let first = !self.full;
            self.full = true;
            return Opening::Full { first };
        }
        self.full = false;
        self.twin_of.insert(item.id.clone(), item.twin.clone());
        let entry = self
            .by_twin
            .entry(item.twin.clone())
            .or_insert_with(|| Entry {
                item: item.clone(),
                ids: Vec::new(),
                phase: Phase::Closed,
                generation: 0,
            });
        if !entry.ids.contains(&item.id) {
            entry.ids.push(item.id.clone());
        }
        entry.item = item;
        if matches!(entry.phase, Phase::Closed) {
            Opening::Arm
        } else {
            Opening::Held
        }
    }

    /// Numbers the wait about to start for `twin`; a timer is acted on only while it is the latest.
    fn generation(&mut self, twin: &str) -> u64 {
        self.waits += 1;
        if let Some(entry) = self.by_twin.get_mut(twin) {
            entry.generation = self.waits;
        }
        self.waits
    }

    fn arm(&mut self, twin: &str, timer: JoinHandle<()>) {
        if let Some(entry) = self.by_twin.get_mut(twin) {
            entry.phase = Phase::Waiting(timer);
        }
    }

    /// The item settled, so a later ask under the same twin is a new ask and is announced.
    fn close(&mut self, id: &str) {
        if let Some((twin, _)) = self.release(id) {
            self.by_twin.remove(&twin);
        }
    }

    /// Every chat holding the item went away. A chat that reconnects publishes it again under the
    /// same twin, so the twin stays remembered and is not announced twice.
    fn leave(&mut self, id: &str) {
        let Some((twin, was_waiting)) = self.release(id) else {
            return;
        };
        if let Some(entry) = self.by_twin.get_mut(&twin) {
            entry.phase = if was_waiting {
                Phase::Closed
            } else {
                Phase::Announced
            };
        }
        self.closed.push_back(twin);
        while self.closed.len() > REMEMBERED {
            if let Some(forgotten) = self.closed.pop_front() {
                self.forget(&forgotten);
            }
        }
    }

    /// Drops `id` from its entry. When that was the entry's last id, returns its twin and whether
    /// a wait was running, which is cancelled.
    fn release(&mut self, id: &str) -> Option<(String, bool)> {
        let twin = self.twin_of.remove(id)?;
        let entry = self.by_twin.get_mut(&twin)?;
        entry.ids.retain(|held| held != id);
        if !entry.ids.is_empty() {
            return None;
        }
        let waiting = matches!(entry.phase, Phase::Waiting(_));
        if let Phase::Waiting(timer) = std::mem::replace(&mut entry.phase, Phase::Closed) {
            timer.abort();
        }
        Some((twin, waiting))
    }

    /// Evicted from the remembered closed items, so it is dropped announced or not; an entry that
    /// has gained ids since is open again and stays.
    fn forget(&mut self, twin: &str) {
        if self
            .by_twin
            .get(twin)
            .is_some_and(|entry| entry.ids.is_empty())
        {
            self.by_twin.remove(twin);
        }
    }

    /// The item to announce, if the wait ended with it still open.
    fn due(&mut self, twin: &str, generation: u64) -> Option<Opened> {
        let entry = self.by_twin.get_mut(twin)?;
        (entry.generation == generation && matches!(entry.phase, Phase::Waiting(_))).then(|| {
            entry.phase = Phase::Announced;
            entry.item.clone()
        })
    }

    fn stop(&mut self) {
        for entry in self.by_twin.values() {
            if let Phase::Waiting(timer) = &entry.phase {
                timer.abort();
            }
        }
    }
}

/// What the watch hears from its own timers.
enum Due {
    Item(String, u64),
    /// A window that dropped notices has closed, so the 1 summary for it is owed.
    Window,
}

/// Off the watch's own task, so a slow topic never holds the loop; a failing one writes a trace
/// line each time its error changes, so one that keeps failing alike costs 1 line and not 1 per item.
fn send(
    trail: &Arc<Mutex<Trail>>,
    notice: impl Future<Output = Result<(), String>> + Send + 'static,
) {
    let trail = Arc::clone(trail);
    tokio::spawn(async move {
        let outcome = notice.await;
        let fresh = trail
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .fresh(outcome);
        if let Some(error) = fresh {
            tracing::warn!(%error, "could not announce on ntfy");
        }
    });
}

/// Announces each item still open after `delay`, once, until `events` closes. At most
/// [`MAX_POSTS`] go out in a [`WINDOW`]; a window that dropped any ends with 1 summary, which
/// counts against no window, so a flood is at most the cap and 1 summary per window.
pub(crate) async fn run(
    mut events: mpsc::UnboundedReceiver<Event>,
    notifier: Arc<impl Notify>,
    delay: Duration,
) {
    let trail = Arc::new(Mutex::new(Trail::default()));
    let (elapsed, mut due) = mpsc::unbounded_channel::<Due>();
    let mut items = Items::default();
    let mut budget = Budget::new();
    loop {
        tokio::select! {
            event = events.recv() => match event {
                Some(Event::Opened(item)) => {
                    let twin = item.twin.clone();
                    let opening = items.open(item);
                    if let Opening::Full { first: true } = opening {
                        tracing::warn!(max = MAX_OPEN, "dropped an item opening: too many items waiting");
                    }
                    if opening == Opening::Arm {
                        let elapsed = elapsed.clone();
                        let waiting = twin.clone();
                        let generation = items.generation(&twin);
                        items.arm(&twin, tokio::spawn(async move {
                            tokio::time::sleep(delay).await;
                            let _watch_ended = elapsed.send(Due::Item(waiting, generation));
                        }));
                    }
                }
                Some(Event::Closed { id }) => items.close(&id),
                Some(Event::Left { id }) => items.leave(&id),
                None => break,
            },
            Some(due) = due.recv() => match due {
                Due::Item(twin, generation) => {
                    if let Some(item) = items.due(&twin, generation) {
                        let admitted = budget.admit(Instant::now());
                        if let Admit::Drop { first: true } = admitted {
                            tracing::warn!(max = MAX_POSTS, "dropped notices: over the cap for this window");
                            if let Some(ends) = budget.ends() {
                                let elapsed = elapsed.clone();
                                tokio::spawn(async move {
                                    tokio::time::sleep_until(ends).await;
                                    let _watch_ended = elapsed.send(Due::Window);
                                });
                            }
                        }
                        if admitted == Admit::Send {
                            let notifier = Arc::clone(&notifier);
                            send(&trail, async move { notifier.notify(&item).await });
                        }
                    }
                }
                Due::Window => {
                    let more = budget.summary();
                    if more > 0 {
                        let notifier = Arc::clone(&notifier);
                        send(&trail, async move { notifier.summarize(more).await });
                    }
                }
            },
        }
    }
    items.stop();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay::Kind;

    const AFTER: Duration = Duration::from_secs(60);

    #[derive(Default)]
    struct Recorder {
        sent: Mutex<Vec<String>>,
        summaries: Mutex<Vec<usize>>,
        failing: Mutex<bool>,
    }

    impl Notify for Recorder {
        async fn notify(&self, item: &Opened) -> Result<(), String> {
            if *self.failing.lock().expect("the flag") {
                return Err("ntfy answered 500".to_string());
            }
            self.sent.lock().expect("the list").push(item.id.clone());
            Ok(())
        }

        async fn summarize(&self, more: usize) -> Result<(), String> {
            self.summaries.lock().expect("the list").push(more);
            Ok(())
        }
    }

    impl Recorder {
        fn summaries(&self) -> Vec<usize> {
            self.summaries.lock().expect("the list").clone()
        }

        fn sent(&self) -> Vec<String> {
            let mut sent = self.sent.lock().expect("the list").clone();
            sent.sort();
            sent
        }
    }

    fn opened(id: &str) -> Event {
        reopened(id, id)
    }

    /// `id` as the phone sees it, for the item the chat knows as `twin`.
    fn reopened(id: &str, twin: &str) -> Event {
        Event::Opened(Opened {
            id: id.to_string(),
            twin: twin.to_string(),
            kind: Kind::ParkedCall,
            requester: "main".to_string(),
        })
    }

    fn closed(id: &str) -> Event {
        Event::Closed { id: id.to_string() }
    }

    fn left(id: &str) -> Event {
        Event::Left { id: id.to_string() }
    }

    /// A watch on a paused clock and the way to feed it.
    fn watch() -> (mpsc::UnboundedSender<Event>, Arc<Recorder>, JoinHandle<()>) {
        let (events, incoming) = mpsc::unbounded_channel();
        let recorder = Arc::new(Recorder::default());
        let task = tokio::spawn(run(incoming, Arc::clone(&recorder), AFTER));
        (events, recorder, task)
    }

    /// Time passes, and every task that can run does.
    async fn elapse(span: Duration) {
        tokio::time::sleep(span).await;
        for _ in 0..5 {
            tokio::task::yield_now().await;
        }
    }

    #[tokio::test(start_paused = true)]
    async fn an_item_open_at_the_delay_is_announced_once() {
        let (events, recorder, _task) = watch();
        events.send(opened("a")).expect("send");
        elapse(AFTER - Duration::from_secs(1)).await;
        assert!(recorder.sent().is_empty());
        elapse(Duration::from_secs(2)).await;
        elapse(AFTER * 3).await;
        assert_eq!(vec!["a"], recorder.sent());
    }

    #[tokio::test(start_paused = true)]
    async fn an_item_that_closes_before_the_delay_is_never_announced() {
        let (events, recorder, _task) = watch();
        events.send(opened("a")).expect("send");
        events.send(opened("b")).expect("send");
        elapse(Duration::from_secs(30)).await;
        events.send(closed("a")).expect("send");
        elapse(AFTER * 2).await;
        assert_eq!(vec!["b"], recorder.sent());
    }

    #[tokio::test(start_paused = true)]
    async fn a_publish_of_an_item_already_open_neither_rearms_nor_resends() {
        let (events, recorder, _task) = watch();
        events.send(opened("a")).expect("send");
        elapse(Duration::from_secs(45)).await;
        events.send(opened("a")).expect("send");
        elapse(Duration::from_secs(20)).await;
        assert_eq!(
            vec!["a"],
            recorder.sent(),
            "re-armed 45 s in, so it was late"
        );
        events.send(opened("a")).expect("send");
        elapse(AFTER * 3).await;
        assert_eq!(
            vec!["a"],
            recorder.sent(),
            "sent again after it was announced"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_closed_id_that_opens_again_waits_its_delay_afresh() {
        let (events, recorder, _task) = watch();
        events.send(opened("a")).expect("send");
        events.send(closed("a")).expect("send");
        events.send(opened("a")).expect("send");
        elapse(AFTER + Duration::from_secs(1)).await;
        assert_eq!(vec!["a"], recorder.sent());
    }

    #[tokio::test(start_paused = true)]
    async fn a_watch_started_after_a_restart_announces_an_item_it_has_not_seen() {
        let (first, recorded, task) = watch();
        first.send(opened("old")).expect("send");
        elapse(AFTER * 2).await;
        drop(first);
        task.await.expect("the first watch ends");
        let (second, again, _task) = watch();
        second.send(opened("new")).expect("send");
        elapse(AFTER * 2).await;
        assert_eq!(vec!["old"], recorded.sent());
        assert_eq!(vec!["new"], again.sent());
    }

    #[tokio::test(start_paused = true)]
    async fn a_chat_that_reconnects_after_its_item_was_announced_does_not_announce_it_again() {
        let (events, recorder, _task) = watch();
        events.send(reopened("old", "t")).expect("send");
        elapse(AFTER + Duration::from_secs(1)).await;
        events.send(left("old")).expect("send");
        events.send(reopened("new", "t")).expect("send");
        elapse(AFTER * 3).await;
        assert_eq!(vec!["old"], recorder.sent());
    }

    #[tokio::test(start_paused = true)]
    async fn a_reconnect_that_publishes_before_the_old_registration_leaves_keeps_the_clock_and_the_new_id()
     {
        let (events, recorder, _task) = watch();
        events.send(reopened("old", "t")).expect("send");
        elapse(Duration::from_secs(45)).await;
        events.send(reopened("new", "t")).expect("send");
        events.send(left("old")).expect("send");
        elapse(Duration::from_secs(16)).await;
        assert_eq!(
            vec!["new"],
            recorder.sent(),
            "the clock restarted at the reconnect"
        );
        elapse(AFTER * 3).await;
        assert_eq!(vec!["new"], recorder.sent());
    }

    #[tokio::test(start_paused = true)]
    async fn a_reconnect_that_leaves_before_it_republishes_is_announced_once_under_the_new_id() {
        let (events, recorder, _task) = watch();
        events.send(reopened("old", "t")).expect("send");
        elapse(Duration::from_secs(30)).await;
        events.send(left("old")).expect("send");
        events.send(reopened("new", "t")).expect("send");
        elapse(Duration::from_secs(31)).await;
        assert!(
            recorder.sent().is_empty(),
            "the cancelled wait still fired at 61 s"
        );
        elapse(Duration::from_secs(28)).await;
        assert!(
            recorder.sent().is_empty(),
            "announced before the new wait ended at 90 s"
        );
        elapse(AFTER * 3).await;
        assert_eq!(vec!["new"], recorder.sent());
    }

    #[tokio::test(start_paused = true)]
    async fn a_phone_id_reported_again_under_another_twin_stays_with_its_first_and_is_announced_once()
     {
        let (events, recorder, _task) = watch();
        events.send(reopened("gate", "a-gate")).expect("send");
        events.send(reopened("gate", "b-gate")).expect("send");
        elapse(AFTER * 3).await;
        assert_eq!(vec!["gate"], recorder.sent());
    }

    #[tokio::test(start_paused = true)]
    async fn a_flood_of_forged_openings_sends_at_most_the_cap_in_a_window_and_never_the_rest_later()
    {
        let (events, recorder, _task) = watch();
        for index in 0..MAX_POSTS * 3 {
            events
                .send(opened(&format!("forged-{index}")))
                .expect("send");
        }
        elapse(AFTER + Duration::from_secs(1)).await;
        assert_eq!(MAX_POSTS, recorder.sent().len());
        elapse(AFTER * 5).await;
        assert_eq!(
            MAX_POSTS,
            recorder.sent().len(),
            "a dropped item was sent later"
        );

        events.send(opened("honest")).expect("send");
        elapse(AFTER + Duration::from_secs(1)).await;
        assert_eq!(
            MAX_POSTS + 1,
            recorder.sent().len(),
            "the next window sent nothing"
        );
    }

    #[test]
    fn a_window_admits_the_cap_then_drops_naming_the_first_drop_only() {
        let start = Instant::now();
        let mut budget = Budget::new();
        let admitted: Vec<Admit> = (0..MAX_POSTS).map(|_| budget.admit(start)).collect();
        assert!(admitted.iter().all(|admit| *admit == Admit::Send));
        assert_eq!(Admit::Drop { first: true }, budget.admit(start));
        assert_eq!(
            Admit::Drop { first: false },
            budget.admit(start + WINDOW / 2)
        );
        assert_eq!(Admit::Send, budget.admit(start + WINDOW));
        assert_eq!(Admit::Send, budget.admit(start + WINDOW));
    }

    #[tokio::test]
    async fn items_past_the_open_cap_are_dropped_and_the_drop_is_traced_once() {
        let mut items = Items::default();
        let item = |id: String| Opened {
            twin: id.clone(),
            id,
            kind: Kind::Question,
            requester: "main".to_string(),
        };
        for index in 0..MAX_OPEN {
            let opened = item(format!("i{index}"));
            let twin = opened.twin.clone();
            assert_eq!(Opening::Arm, items.open(opened));
            items.arm(&twin, tokio::spawn(async {}));
        }
        assert_eq!(
            Opening::Full { first: true },
            items.open(item("over-1".to_string()))
        );
        assert_eq!(
            Opening::Full { first: false },
            items.open(item("over-2".to_string()))
        );
        assert_eq!(
            Opening::Held,
            items.open(item("i0".to_string())),
            "an open item stays open"
        );

        items.close("i1");
        assert_eq!(Opening::Arm, items.open(item("fits".to_string())));
        assert_eq!(
            Opening::Full { first: true },
            items.open(item("over-3".to_string()))
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_window_that_dropped_notices_ends_with_one_summary_naming_how_many() {
        let (events, recorder, _task) = watch();
        for index in 0..MAX_POSTS + 15 {
            events.send(opened(&format!("item-{index}"))).expect("send");
        }
        elapse(AFTER + Duration::from_secs(1)).await;
        assert_eq!(MAX_POSTS, recorder.sent().len());
        assert!(
            recorder.summaries().is_empty(),
            "summarised before the window closed"
        );
        elapse(WINDOW).await;
        assert_eq!(vec![15], recorder.summaries());
        elapse(AFTER * 5).await;
        assert_eq!(
            (MAX_POSTS, vec![15]),
            (recorder.sent().len(), recorder.summaries())
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_window_that_dropped_nothing_sends_no_summary() {
        let (events, recorder, _task) = watch();
        for index in 0..MAX_POSTS {
            events.send(opened(&format!("item-{index}"))).expect("send");
        }
        elapse(AFTER * 4).await;
        assert_eq!(
            (MAX_POSTS, Vec::<usize>::new()),
            (recorder.sent().len(), recorder.summaries())
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_flood_over_several_windows_is_at_most_the_cap_and_one_summary_per_window() {
        let (events, recorder, _task) = watch();
        for round in 0..3 {
            for index in 0..MAX_POSTS * 2 {
                events
                    .send(opened(&format!("r{round}-{index}")))
                    .expect("send");
            }
            elapse(AFTER * 2 + Duration::from_secs(1)).await;
        }
        assert_eq!(MAX_POSTS * 3, recorder.sent().len());
        assert_eq!(vec![MAX_POSTS; 3], recorder.summaries());
    }

    #[test]
    fn a_window_reports_what_it_dropped_once() {
        let start = Instant::now();
        let mut budget = Budget::new();
        for _ in 0..MAX_POSTS + 3 {
            budget.admit(start);
        }
        assert_eq!((3, 0), (budget.summary(), budget.summary()));
    }

    #[tokio::test(start_paused = true)]
    async fn an_item_settled_and_asked_again_under_the_same_twin_is_announced_again() {
        let (events, recorder, _task) = watch();
        events.send(reopened("first", "t")).expect("send");
        elapse(AFTER + Duration::from_secs(1)).await;
        events.send(closed("first")).expect("send");
        events.send(reopened("second", "t")).expect("send");
        elapse(AFTER * 3).await;
        assert_eq!(vec!["first", "second"], recorder.sent());
    }

    #[tokio::test]
    async fn a_wait_from_before_a_close_and_reopen_cannot_announce_the_reopened_item() {
        let mut items = Items::default();
        let item = || Opened {
            id: "a".to_string(),
            twin: "t".to_string(),
            kind: Kind::Question,
            requester: "main".to_string(),
        };
        assert_eq!(Opening::Arm, items.open(item()));
        let before = items.generation("t");
        items.arm("t", tokio::spawn(async {}));
        items.close("a");
        assert_eq!(Opening::Arm, items.open(item()));
        let after = items.generation("t");
        items.arm("t", tokio::spawn(async {}));

        assert_eq!(
            None,
            items.due("t", before),
            "the old wait announced the new item"
        );
        assert_eq!(
            Some("a".to_string()),
            items.due("t", after).map(|opened| opened.id)
        );
    }

    #[tokio::test]
    async fn a_wait_that_fired_as_its_item_left_or_was_announced_announces_nothing_more() {
        let mut items = Items::default();
        let item = Opened {
            id: "a".to_string(),
            twin: "t".to_string(),
            kind: Kind::Question,
            requester: "main".to_string(),
        };
        assert_eq!(Opening::Arm, items.open(item));
        let generation = items.generation("t");
        items.arm("t", tokio::spawn(async {}));
        assert!(items.due("t", generation).is_some());
        assert_eq!(None, items.due("t", generation), "announced twice");

        items.leave("a");
        assert_eq!(None, items.due("t", generation), "announced after leaving");
    }

    #[tokio::test]
    async fn a_settled_item_leaves_nothing_behind() {
        let mut items = Items::default();
        let item = Opened {
            id: "a".to_string(),
            twin: "t".to_string(),
            kind: Kind::Question,
            requester: "main".to_string(),
        };
        assert_eq!(Opening::Arm, items.open(item));
        items.close("a");
        assert!(items.by_twin.is_empty() && items.twin_of.is_empty());
    }

    #[tokio::test]
    async fn an_eviction_of_a_twin_that_has_since_reopened_leaves_it_open() {
        let mut items = Items::default();
        let item = |id: String| Opened {
            twin: id.clone(),
            id,
            kind: Kind::Question,
            requester: "main".to_string(),
        };
        let first = item("first".to_string());
        assert_eq!(Opening::Arm, items.open(first.clone()));
        items.arm("first", tokio::spawn(async {}));
        items.leave("first");
        assert_eq!(Opening::Arm, items.open(first.clone()));
        items.arm("first", tokio::spawn(async {}));
        for index in 0..=REMEMBERED {
            let other = item(format!("other-{index}"));
            items.open(other);
            items.leave(&format!("other-{index}"));
        }
        assert_eq!(
            Opening::Held,
            items.open(first),
            "the reopened item was forgotten"
        );
    }

    #[test]
    fn the_same_error_after_a_success_is_written_again() {
        let mut trail = Trail::default();
        let down = || Err("ntfy answered 500".to_string());
        assert!(trail.fresh(down()).is_some());
        assert_eq!(None, trail.fresh(Ok(())));
        assert!(
            trail.fresh(down()).is_some(),
            "an error after an Ok was swallowed"
        );
    }

    #[test]
    fn a_report_owed_for_a_window_survives_the_next_window_beginning() {
        let start = Instant::now();
        let mut budget = Budget::new();
        for _ in 0..MAX_POSTS + 2 {
            budget.admit(start);
        }
        assert_eq!(Admit::Send, budget.admit(start + WINDOW));
        assert_eq!(2, budget.summary());
    }

    #[tokio::test(start_paused = true)]
    async fn a_summary_counts_against_no_window() {
        let (events, recorder, _task) = watch();
        for index in 0..MAX_POSTS + 1 {
            events
                .send(opened(&format!("first-{index}")))
                .expect("send");
        }
        elapse(AFTER + Duration::from_secs(1)).await;
        // These come due after the first window closes but inside the minute its summary opens.
        for index in 0..MAX_POSTS {
            events
                .send(opened(&format!("second-{index}")))
                .expect("send");
        }
        elapse(AFTER * 2).await;
        assert_eq!(vec![1], recorder.summaries());
        assert_eq!(
            MAX_POSTS * 2,
            recorder.sent().len(),
            "the summary used a post of the next window"
        );
    }

    #[test]
    fn an_item_waits_a_minute_before_the_phone_is_told() {
        assert_eq!(Duration::from_secs(60), DELAY);
    }

    #[test]
    fn a_failure_is_written_once_until_something_else_happens() {
        let mut trail = Trail::default();
        let down = || Err("ntfy answered 500".to_string());
        assert_eq!(Some("ntfy answered 500".to_string()), trail.fresh(down()));
        assert_eq!(None, trail.fresh(down()));
        assert_eq!(
            Some("connection refused".to_string()),
            trail.fresh(Err("connection refused".to_string()))
        );
        assert_eq!(None, trail.fresh(Ok(())));
        assert_eq!(Some("ntfy answered 500".to_string()), trail.fresh(down()));
    }

    #[tokio::test(start_paused = true)]
    async fn a_topic_that_is_down_does_not_stop_the_next_item() {
        let (events, recorder, _task) = watch();
        *recorder.failing.lock().expect("the flag") = true;
        events.send(opened("a")).expect("send");
        elapse(AFTER + Duration::from_secs(1)).await;
        *recorder.failing.lock().expect("the flag") = false;
        events.send(opened("b")).expect("send");
        elapse(AFTER + Duration::from_secs(1)).await;
        assert_eq!(vec!["b"], recorder.sent());
    }
}
