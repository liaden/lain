//! What the relay remembers: the items open now, the recent deltas that led
//! there, and the recent answers phones sent, each numbered by a cursor so a
//! reader resumes after the last one it saw.
//!
//! Everything is bounded. The open items are the snapshot; the delta tail
//! behind it is cut at [`MAX_TAIL`] entries or [`TAIL_BYTES`], and a reader
//! whose cursor falls outside what is kept gets the snapshot as a reset. Every
//! reply stays under [`REPLY_BUDGET`], which is below the 1 MiB frame
//! ceiling a reader enforces, so a reader catching up loops by cursor instead
//! of failing on one frame it can never read.
//!
//! A delta, an answer or a whole agenda over the budget is refused when it
//! arrives, rather than split: a delta is one change and must land whole, and
//! the snapshot must fit one reply for a reset to be one frame.

use std::collections::{HashSet, VecDeque};
use std::time::Duration;

use lain_wire::{AgendaItem, Answer, Delta};
use serde::Serialize;
use tokio::sync::watch;

/// The most bytes of messages one reply carries; the rest of the 1 MiB frame is headroom.
pub(crate) const REPLY_BUDGET: usize = 768 << 10;

/// The most deltas, and the most answers, kept behind the head.
pub(crate) const MAX_TAIL: usize = 1024;

/// The most bytes of deltas, and of answers, kept behind the head.
const TAIL_BYTES: usize = 4 * REPLY_BUDGET;

/// How many settled ids are remembered, so a late replay still reads as settled.
const MAX_CLOSED: usize = 1024;

/// How long a `*.next` call waits before answering with nothing new. A
/// reader that drops mid-wait frees its connection when the connection closes.
pub(crate) const LONG_POLL: Duration = Duration::from_secs(30);

pub(crate) struct Agenda {
    log: watch::Sender<Log>,
    epoch: u64,
}

impl Default for Agenda {
    fn default() -> Self {
        Self {
            log: watch::Sender::new(Log::default()),
            epoch: fresh_epoch(),
        }
    }
}

/// Random per process, from the seed std draws for its hash maps.
fn fresh_epoch() -> u64 {
    use std::hash::BuildHasher;
    std::collections::hash_map::RandomState::new().hash_one(std::process::id())
}

/// Why the relay refused a message.
#[derive(Debug)]
pub(crate) enum Refusal {
    AlreadySettled(String),
    NotOpen(String),
    TooLarge { what: &'static str, bytes: usize },
    Unencodable,
}

/// A checked message with its encoded size, which the reply budget counts.
#[derive(Clone)]
struct Measured<T> {
    message: T,
    bytes: usize,
}

impl<T: Serialize> Measured<T> {
    fn of(message: T) -> Result<Self, Refusal> {
        let bytes = lain_wire::encode(&message)
            .map_err(|_| Refusal::Unencodable)?
            .len();
        Ok(Self { message, bytes })
    }
}

/// Messages numbered from 1, the oldest dropped past [`MAX_TAIL`] or [`TAIL_BYTES`].
struct Tail<T> {
    head: u64,
    kept: VecDeque<Measured<T>>,
    bytes: usize,
}

impl<T> Default for Tail<T> {
    fn default() -> Self {
        Self {
            head: 0,
            kept: VecDeque::new(),
            bytes: 0,
        }
    }
}

impl<T> Tail<T> {
    /// The cursor just before the oldest message kept.
    fn base(&self) -> u64 {
        self.head - count(self.kept.len())
    }

    fn keeps(&self, cursor: u64) -> bool {
        (self.base()..=self.head).contains(&cursor)
    }
}

impl<T: Clone> Tail<T> {
    fn push(&mut self, message: Measured<T>) -> u64 {
        self.head += 1;
        self.bytes += message.bytes;
        self.kept.push_back(message);
        while self.kept.len() > MAX_TAIL || self.bytes > TAIL_BYTES {
            if let Some(dropped) = self.kept.pop_front() {
                self.bytes -= dropped.bytes;
            }
        }
        self.head
    }

    /// The messages after `cursor` that fit the budget, and the last one's cursor.
    /// The first always fits: nothing over the budget is ever kept.
    fn page_after(&self, cursor: u64) -> (u64, Vec<T>) {
        let skip = usize::try_from(cursor - self.base()).unwrap_or(usize::MAX);
        let mut spent = 0;
        let page: Vec<T> = self
            .kept
            .iter()
            .skip(skip)
            .take_while(|kept| {
                spent += kept.bytes;
                spent <= REPLY_BUDGET
            })
            .map(|kept| kept.message.clone())
            .collect();
        (cursor + count(page.len()), page)
    }
}

struct Open {
    id: String,
    item: Measured<AgendaItem>,
    answered: bool,
}

#[derive(Default)]
struct Log {
    deltas: Tail<Delta>,
    answers: Tail<Answer>,
    open: Vec<Open>,
    open_bytes: usize,
    closed: VecDeque<String>,
    closed_ids: HashSet<String>,
}

impl Log {
    fn close(&mut self, id: &str) {
        if let Some(index) = self.open.iter().position(|open| open.id == id) {
            let open = self.open.remove(index);
            self.open_bytes -= open.item.bytes;
        }
        if self.closed_ids.insert(id.to_string()) {
            self.closed.push_back(id.to_string());
        }
        if self.closed.len() > MAX_CLOSED
            && let Some(forgotten) = self.closed.pop_front()
        {
            self.closed_ids.remove(&forgotten);
        }
    }

    fn reopen(&mut self, id: &str, item: Measured<AgendaItem>) {
        if let Some(index) = self.open.iter().position(|open| open.id == id) {
            let replaced = self.open.remove(index);
            self.open_bytes -= replaced.item.bytes;
        }
        if self.closed_ids.remove(id) {
            self.closed.retain(|closed| closed != id);
        }
        self.open_bytes += item.bytes;
        self.open.push(Open {
            id: id.to_string(),
            item,
            answered: false,
        });
    }

    /// The bytes the open items would take after `delta`, counted before it is applied.
    fn open_bytes_after(&self, delta: &Delta, added: &[Measured<AgendaItem>]) -> usize {
        let leaving: HashSet<&str> = delta
            .settled
            .iter()
            .map(String::as_str)
            .chain(delta.added.iter().map(id_of_item))
            .collect();
        let kept: usize = self
            .open
            .iter()
            .filter(|open| !leaving.contains(open.id.as_str()))
            .map(|open| open.item.bytes)
            .sum();
        let settled_now: HashSet<&str> = delta.settled.iter().map(String::as_str).collect();
        kept + delta
            .added
            .iter()
            .zip(added)
            .filter(|(item, _)| !settled_now.contains(id_of_item(item)))
            .map(|(_, encoded)| encoded.bytes)
            .sum::<usize>()
    }

    /// One delta adding every open item, at the head.
    fn snapshot(&self) -> Delta {
        Delta {
            cursor: self.deltas.head,
            added: self
                .open
                .iter()
                .map(|open| open.item.message.clone())
                .collect(),
            settled: vec![],
        }
    }
}

/// One `*.next` reply before the relay names its epoch: for deltas, a
/// reset carries the snapshot alone and the reader drops what it held.
pub(crate) struct Page<T> {
    pub(crate) reset: bool,
    pub(crate) cursor: u64,
    pub(crate) messages: Vec<T>,
}

impl Agenda {
    pub(crate) fn epoch(&self) -> u64 {
        self.epoch
    }

    pub(crate) fn head(&self) -> u64 {
        self.log.borrow().deltas.head
    }

    /// The relay numbers deltas itself, so a phone's cursor means the same
    /// thing whatever lain put in the field. Returns the delta's cursor.
    pub(crate) fn publish(&self, delta: Delta) -> Result<u64, Refusal> {
        let added = delta
            .added
            .iter()
            .cloned()
            .map(Measured::of)
            .collect::<Result<Vec<_>, _>>()?;
        let mut outcome = Err(Refusal::Unencodable);
        self.log.send_if_modified(|log| {
            outcome = Self::apply(log, delta, added);
            outcome.is_ok()
        });
        outcome
    }

    fn apply(
        log: &mut Log,
        delta: Delta,
        added: Vec<Measured<AgendaItem>>,
    ) -> Result<u64, Refusal> {
        let stamped = Measured::of(Delta {
            cursor: log.deltas.head + 1,
            ..delta.clone()
        })?;
        within_budget("the delta is", stamped.bytes)?;
        within_budget("the agenda would be", log.open_bytes_after(&delta, &added))?;
        for (item, encoded) in delta.added.iter().zip(added) {
            log.reopen(id_of_item(item), encoded);
        }
        for id in &delta.settled {
            log.close(id);
        }
        Ok(log.deltas.push(stamped))
    }

    /// The deltas after `cursor`, waiting up to [`LONG_POLL`] for one. A cursor
    /// this relay cannot continue from gets the snapshot at once.
    pub(crate) async fn deltas_after(&self, cursor: u64, epoch: Option<u64>) -> Page<Delta> {
        let mut log = self.log.subscribe();
        let ready =
            log.wait_for(|log| self.stale(&log.deltas, cursor, epoch) || log.deltas.head > cursor);
        match tokio::time::timeout(LONG_POLL, ready).await {
            Ok(Ok(log)) if self.stale(&log.deltas, cursor, epoch) => Page {
                reset: true,
                cursor: log.deltas.head,
                messages: vec![log.snapshot()],
            },
            Ok(Ok(log)) => {
                let (cursor, messages) = log.deltas.page_after(cursor);
                Page {
                    reset: false,
                    cursor,
                    messages,
                }
            }
            Ok(Err(_)) | Err(_) => Page {
                reset: false,
                cursor,
                messages: Vec::new(),
            },
        }
    }

    /// Accepted only for an item open now and not yet answered.
    pub(crate) fn answer(&self, answer: &Answer) -> Result<(), Refusal> {
        let id = id_of_answer(answer);
        let encoded = Measured::of(answer.clone())?;
        within_budget("the answer is", encoded.bytes)?;
        let mut outcome = Ok(());
        self.log.send_if_modified(|log| {
            let open = log.open.iter_mut().find(|open| open.id == id);
            outcome = match open {
                Some(open) if !open.answered => {
                    open.answered = true;
                    Ok(())
                }
                Some(_) => Err(Refusal::AlreadySettled(id.to_string())),
                None if log.closed_ids.contains(id) => Err(Refusal::AlreadySettled(id.to_string())),
                None => Err(Refusal::NotOpen(id.to_string())),
            };
            if outcome.is_ok() {
                log.answers.push(encoded);
            }
            outcome.is_ok()
        });
        outcome
    }

    /// The answers after `cursor`, waiting up to [`LONG_POLL`] for one. A
    /// cursor this relay cannot continue from resets to the oldest answer kept.
    pub(crate) async fn answers_after(&self, cursor: u64, epoch: Option<u64>) -> Page<Answer> {
        let mut log = self.log.subscribe();
        let ready = log
            .wait_for(|log| self.stale(&log.answers, cursor, epoch) || log.answers.head > cursor);
        match tokio::time::timeout(LONG_POLL, ready).await {
            Ok(Ok(log)) => {
                let reset = self.stale(&log.answers, cursor, epoch);
                let from = if reset { log.answers.base() } else { cursor };
                let (cursor, messages) = log.answers.page_after(from);
                Page {
                    reset,
                    cursor,
                    messages,
                }
            }
            Ok(Err(_)) | Err(_) => Page {
                reset: false,
                cursor,
                messages: Vec::new(),
            },
        }
    }

    /// A cursor from another relay process, past the head, or older than the
    /// tail. A reader with no epoch yet is fresh only at cursor 0.
    fn stale<T>(&self, tail: &Tail<T>, cursor: u64, epoch: Option<u64>) -> bool {
        let foreign = epoch.map_or(cursor != 0, |epoch| epoch != self.epoch);
        foreign || !tail.keeps(cursor)
    }
}

fn within_budget(what: &'static str, bytes: usize) -> Result<(), Refusal> {
    if bytes > REPLY_BUDGET {
        Err(Refusal::TooLarge { what, bytes })
    } else {
        Ok(())
    }
}

fn count(len: usize) -> u64 {
    u64::try_from(len).unwrap_or(u64::MAX)
}

fn id_of_item(item: &AgendaItem) -> &str {
    match item {
        AgendaItem::ParkedCall { id, .. }
        | AgendaItem::GateQuestion { id, .. }
        | AgendaItem::Question { id, .. } => id,
    }
}

fn id_of_answer(answer: &Answer) -> &str {
    match answer {
        Answer::Call { id, .. } | Answer::Gate { id, .. } | Answer::Question { id, .. } => id,
    }
}
