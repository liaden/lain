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

use std::collections::hash_map::RandomState;
use std::collections::{HashMap, HashSet, VecDeque};
use std::hash::BuildHasher;
use std::time::Duration;

use lain_wire::{AgendaItem, Answer, Delta};
use serde::{Deserialize, Serialize};
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
    RandomState::new().hash_one(std::process::id())
}

/// The session that published an item, as the daemon's registry knows it, never as the item
/// claims. `registration` tells apart 2 registrations of 1 session id, one leaving as the next
/// arrives.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Stamp {
    pub(crate) session: String,
    pub(crate) project: String,
    pub(crate) registration: u64,
    /// The chat's process, which a chat keeps across its reconnects and a restarted chat does not.
    pub(crate) pid: u32,
}

/// What kind of thing waits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Kind {
    ParkedCall,
    GateQuestion,
    Question,
}

/// An item the phone can now open: its id, and the 2 fields a title is made of. Nothing of the
/// item's text, project, session or directory is here, so none can reach a topic.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Opened {
    pub(crate) id: String,
    /// A one-way fingerprint of the publishing chat and its own id for the item, the same across
    /// a chat's reconnects, where the phone's `id` is not.
    pub(crate) twin: String,
    pub(crate) kind: Kind,
    pub(crate) requester: String,
}

/// One change in what the phone's agenda holds.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub(crate) enum Event {
    Opened(Opened),
    /// The item settled: answered, or withdrawn by the chat that held it.
    Closed {
        id: String,
    },
    /// Every chat holding the item went away, which a reconnecting chat then undoes.
    Left {
        id: String,
    },
}

/// What a requester is cut to before it goes anywhere, so a forged one is not held whole.
pub(crate) const REQUESTER_CHARS: usize = 64;

impl Event {
    /// The shape `Log::mint` and `twin` make and nothing else: the daemon holds these as keys and
    /// puts the id in a header, and the worker that reports them is confined, not trusted.
    pub(crate) fn well_formed(&self) -> bool {
        let hex = |text: &str, len: usize| {
            text.len() == len
                && text
                    .bytes()
                    .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        };
        match self {
            Self::Opened(opened) => hex(&opened.id, 16) && hex(&opened.twin, 64),
            Self::Closed { id } | Self::Left { id } => hex(id, 16),
        }
    }

    /// The same event with its requester cut to [`REQUESTER_CHARS`].
    pub(crate) fn bounded(self) -> Self {
        match self {
            Self::Opened(opened) => Self::Opened(Opened {
                requester: opened.requester.chars().take(REQUESTER_CHARS).collect(),
                ..opened
            }),
            other @ (Self::Closed { .. } | Self::Left { .. }) => other,
        }
    }
}

/// A publish's cursor, and what it opened and closed on the phone's agenda.
pub(crate) struct Published {
    pub(crate) cursor: u64,
    pub(crate) events: Vec<Event>,
}

/// Where the phone's answer to an item goes: the session that holds it, under its own id.
#[derive(Debug)]
pub(crate) struct Route {
    pub(crate) stamp: Stamp,
    pub(crate) local: String,
}

/// Why the relay refused a message.
#[derive(Debug)]
pub(crate) enum Refusal {
    AlreadySettled(String),
    NotOpen(String),
    TooLarge { what: &'static str, bytes: usize },
    Unencodable,
    BadKey,
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

/// A registration of the daemon's and the id it gave an item; a relay on its own socket has no
/// registrations, and its ids are the phone's.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Holder {
    registration: Option<u64>,
    local: String,
}

/// An item under the id the phone sees. Its holders are oldest first, and an answer goes to the
/// last: 2 sessions hold 1 item only when both published it under 1 gate key.
struct Open {
    id: String,
    item: Measured<AgendaItem>,
    holders: Vec<(Holder, Option<Stamp>)>,
    key: Option<String>,
    answered: bool,
}

/// 1 item a publish adds, under the id the phone will see.
struct Added {
    id: String,
    holder: Holder,
    key: Option<String>,
    item: Measured<AgendaItem>,
}

#[derive(Default)]
struct Log {
    deltas: Tail<Delta>,
    answers: Tail<Answer>,
    open: Vec<Open>,
    open_bytes: usize,
    closed: VecDeque<String>,
    closed_ids: HashSet<String>,
    held: HashMap<Holder, String>,
    keys: HashMap<String, String>,
    minted: u64,
    mint: RandomState,
}

impl Log {
    /// The phone sees a fresh id that names no session; a publisher's own ids may collide.
    fn mint(&mut self) -> String {
        loop {
            self.minted += 1;
            let id = format!("{:016x}", self.mint.hash_one(self.minted));
            if !self.closed_ids.contains(&id) && !self.open.iter().any(|open| open.id == id) {
                return id;
            }
        }
    }

    fn holders_of(&self, id: &str) -> Vec<Holder> {
        self.open
            .iter()
            .find(|open| open.id == id)
            .map(|open| {
                open.holders
                    .iter()
                    .map(|(holder, _)| holder.clone())
                    .collect()
            })
            .unwrap_or_default()
    }

    fn close(&mut self, id: &str) {
        if let Some(index) = self.open.iter().position(|open| open.id == id) {
            let open = self.open.remove(index);
            self.open_bytes -= open.item.bytes;
            for (holder, _) in &open.holders {
                self.held.remove(holder);
            }
            if let Some(key) = &open.key {
                self.keys.remove(key);
            }
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

    /// `added` becomes the item's content, and its holder the newest.
    fn hold(&mut self, added: Added, stamp: Option<&Stamp>) {
        if self.closed_ids.remove(&added.id) {
            self.closed.retain(|closed| *closed != added.id);
        }
        self.held.insert(added.holder.clone(), added.id.clone());
        if let Some(key) = &added.key {
            self.keys.insert(key.clone(), added.id.clone());
        }
        let holder = (added.holder, stamp.cloned());
        match self.open.iter_mut().find(|open| open.id == added.id) {
            Some(open) => {
                self.open_bytes = self.open_bytes - open.item.bytes + added.item.bytes;
                open.item = added.item;
                open.holders.retain(|(held, _)| *held != holder.0);
                open.holders.push(holder);
                open.key = open.key.take().or(added.key);
                open.answered = false;
            }
            None => {
                self.open_bytes += added.item.bytes;
                self.open.push(Open {
                    id: added.id,
                    item: added.item,
                    holders: vec![holder],
                    key: added.key,
                    answered: false,
                });
            }
        }
    }

    fn release(&mut self, holder: &Holder) {
        if let Some(id) = self.held.remove(holder)
            && let Some(open) = self.open.iter_mut().find(|open| open.id == id)
        {
            open.holders.retain(|(held, _)| held != holder);
        }
    }

    /// The bytes the open items would take after `delta`, counted before it is applied.
    fn open_bytes_after(&self, delta: &Delta, added: &[Added]) -> usize {
        let leaving: HashSet<&str> = delta
            .settled
            .iter()
            .map(String::as_str)
            .chain(added.iter().map(|added| added.id.as_str()))
            .collect();
        let kept: usize = self
            .open
            .iter()
            .filter(|open| !leaving.contains(open.id.as_str()))
            .map(|open| open.item.bytes)
            .sum();
        let settled_now: HashSet<&str> = delta.settled.iter().map(String::as_str).collect();
        let mut counted = HashSet::new();
        kept + added
            .iter()
            .rev()
            .filter(|added| !settled_now.contains(added.id.as_str()) && counted.insert(&added.id))
            .map(|added| added.item.bytes)
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

    /// The relay numbers deltas itself, so a phone's cursor means the same thing whatever lain
    /// put in the field. `stamp` names the registration publishing, none for a relay on its own
    /// socket; `keys` maps a gate question's own id to the gate key it is shared under. Returns
    /// the delta's cursor, and the items it opened and closed when a registration published it.
    pub(crate) fn publish(
        &self,
        delta: &Delta,
        stamp: Option<&Stamp>,
        keys: &HashMap<String, String>,
    ) -> Result<Published, Refusal> {
        let gates: HashSet<&str> = delta
            .added
            .iter()
            .filter(|item| matches!(item, AgendaItem::GateQuestion { .. }))
            .map(id_of_item)
            .collect();
        if keys.keys().any(|local| !gates.contains(local.as_str())) {
            return Err(Refusal::BadKey);
        }
        let mut outcome = Err(Refusal::Unencodable);
        self.log.send_if_modified(|log| {
            outcome = Self::apply(log, delta, stamp, keys);
            outcome.is_ok()
        });
        outcome
    }

    fn apply(
        log: &mut Log,
        delta: &Delta,
        stamp: Option<&Stamp>,
        keys: &HashMap<String, String>,
    ) -> Result<Published, Refusal> {
        let registration = stamp.map(|stamp| stamp.registration);
        let holder = |local: &str| Holder {
            registration,
            local: local.to_string(),
        };
        let mut added: Vec<Added> = Vec::new();
        for item in &delta.added {
            let local = id_of_item(item);
            let key = keys.get(local).cloned();
            let known = added
                .iter()
                .find(|earlier| {
                    earlier.holder.local == local || (key.is_some() && earlier.key == key)
                })
                .map(|earlier| earlier.id.clone())
                .or_else(|| log.held.get(&holder(local)).cloned())
                .or_else(|| key.as_ref().and_then(|key| log.keys.get(key).cloned()));
            let id = match (known, registration) {
                (Some(id), _) => id,
                (None, None) => local.to_string(),
                (None, Some(_)) => log.mint(),
            };
            added.push(Added {
                item: Measured::of(phone_facing(item.clone(), &id, stamp))?,
                id,
                holder: holder(local),
                key,
            });
        }
        let mut holders: HashMap<String, Vec<Holder>> = HashMap::new();
        for each in &added {
            let now = holders
                .entry(each.id.clone())
                .or_insert_with(|| log.holders_of(&each.id));
            now.retain(|held| *held != each.holder);
            now.push(each.holder.clone());
        }
        let mut released = Vec::new();
        let mut settled = Vec::new();
        for local in &delta.settled {
            let leaving = holder(local);
            let id = added
                .iter()
                .rev()
                .find(|each| each.holder == leaving)
                .map(|each| each.id.clone())
                .or_else(|| log.held.get(&leaving).cloned());
            match (id, registration) {
                (Some(id), _) => {
                    let now = holders
                        .entry(id.clone())
                        .or_insert_with(|| log.holders_of(&id));
                    now.retain(|held| *held != leaving);
                    if now.is_empty() {
                        settled.push(id);
                    }
                    released.push(leaving);
                }
                (None, None) => settled.push(local.clone()),
                (None, Some(_)) => {}
            }
        }
        let phone = Delta {
            cursor: log.deltas.head + 1,
            added: added.iter().map(|each| each.item.message.clone()).collect(),
            settled,
        };
        let stamped = Measured::of(phone.clone())?;
        within_budget("the delta is", stamped.bytes)?;
        within_budget("the agenda would be", log.open_bytes_after(&phone, &added))?;
        let events = stamp.map_or_else(Vec::new, |stamp| events_of(log, &added, &phone, stamp));
        for each in added {
            log.hold(each, stamp);
        }
        for holder in &released {
            log.release(holder);
        }
        for id in &phone.settled {
            log.close(id);
        }
        Ok(Published {
            cursor: log.deltas.push(stamped),
            events,
        })
    }

    /// Every item `registration` held is let go, and an item nobody holds after that is settled.
    /// Returns a `Left` event for each item nobody holds any longer.
    pub(crate) fn leave(&self, registration: u64) -> Vec<Event> {
        let mut closed = Vec::new();
        self.log.send_if_modified(|log| {
            let leaving: Vec<Holder> = log
                .held
                .keys()
                .filter(|holder| holder.registration == Some(registration))
                .cloned()
                .collect();
            let mut settled = Vec::new();
            for holder in &leaving {
                let id = log.held.get(holder).cloned();
                log.release(holder);
                if let Some(id) = id
                    && log.holders_of(&id).is_empty()
                {
                    settled.push(id);
                }
            }
            for id in &settled {
                log.close(id);
            }
            closed = settled
                .iter()
                .map(|id| Event::Left { id: id.clone() })
                .collect();
            if settled.is_empty() {
                return false;
            }
            let delta = Delta {
                cursor: log.deltas.head + 1,
                added: vec![],
                settled,
            };
            match Measured::of(delta) {
                Ok(stamped) => {
                    log.deltas.push(stamped);
                    true
                }
                Err(_) => false,
            }
        });
        closed
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

    /// Accepted only for an item open now and not yet answered. Returns where it goes: its newest
    /// holder, when that is a registration of the daemon's.
    pub(crate) fn answer(&self, answer: &Answer) -> Result<Option<Route>, Refusal> {
        let id = id_of_answer(answer);
        let encoded = Measured::of(answer.clone())?;
        within_budget("the answer is", encoded.bytes)?;
        let mut outcome = Ok(None);
        self.log.send_if_modified(|log| {
            let open = log.open.iter_mut().find(|open| open.id == id);
            outcome = match open {
                Some(open) if !open.answered => {
                    open.answered = true;
                    Ok(open.holders.last().and_then(|(holder, stamp)| {
                        Some(Route {
                            stamp: stamp.clone()?,
                            local: holder.local.clone(),
                        })
                    }))
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

/// What `phone` changes for whoever follows the agenda by item: each id newly open, once, and each
/// id that settled. An item the registration published again, or a gate another chat already
/// holds, is open already and is not news.
fn events_of(log: &Log, added: &[Added], phone: &Delta, stamp: &Stamp) -> Vec<Event> {
    let mut seen = HashSet::new();
    let opened = added
        .iter()
        .filter(|each| !phone.settled.contains(&each.id))
        .filter(|each| !log.open.iter().any(|open| open.id == each.id))
        .filter(|each| seen.insert(each.id.as_str()))
        .map(|each| {
            let (kind, requester) = match &each.item.message {
                AgendaItem::ParkedCall { requester, .. } => (Kind::ParkedCall, requester),
                AgendaItem::GateQuestion { requester, .. } => (Kind::GateQuestion, requester),
                AgendaItem::Question { requester, .. } => (Kind::Question, requester),
            };
            Event::Opened(Opened {
                id: each.id.clone(),
                twin: twin_of(each, stamp),
                kind,
                requester: requester.clone(),
            })
        });
    let closed = phone
        .settled
        .iter()
        .map(|id| Event::Closed { id: id.clone() });
    opened.chain(closed).collect()
}

/// A gate is 1 item to every chat holding it under its key, so its twin comes from the key and
/// not from whichever chat published it first; any other item is the publishing chat's own.
fn twin_of(each: &Added, stamp: &Stamp) -> String {
    match (&each.item.message, &each.key) {
        (AgendaItem::GateQuestion { .. }, Some(key)) => digest_of(&[b"gate", key.as_bytes()]),
        _ => twin(stamp, &each.holder.local),
    }
}

/// The chat's own name for an item, one-way hashed: the same across the chat's reconnects, which
/// mint the phone a new id, and naming nothing to a reader of the hash.
fn twin(stamp: &Stamp, local: &str) -> String {
    digest_of(&[
        stamp.session.as_bytes(),
        &stamp.pid.to_le_bytes(),
        local.as_bytes(),
    ])
}

/// Each part length-prefixed, so no 2 splits of the same bytes hash alike.
fn digest_of(parts: &[&[u8]]) -> String {
    let mut hasher = blake3::Hasher::new();
    for part in parts {
        hasher.update(&part.len().to_le_bytes());
        hasher.update(part);
    }
    hasher.finalize().to_hex().to_string()
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

/// `item` under the id the phone sees, naming the session and project `stamp` registered, whatever
/// the item claimed. A relay on its own socket has no registrations and keeps the publisher's.
fn phone_facing(mut item: AgendaItem, phone_id: &str, stamp: Option<&Stamp>) -> AgendaItem {
    let (AgendaItem::ParkedCall {
        id,
        session,
        project,
        ..
    }
    | AgendaItem::GateQuestion {
        id,
        session,
        project,
        ..
    }
    | AgendaItem::Question {
        id,
        session,
        project,
        ..
    }) = &mut item;
    phone_id.clone_into(id);
    if let Some(stamp) = stamp {
        stamp.session.clone_into(session);
        stamp.project.clone_into(project);
    }
    item
}

/// `answer` under `local`, the id its session gave the item.
pub(crate) fn with_answer_id(mut answer: Answer, local: &str) -> Answer {
    let (Answer::Call { id, .. } | Answer::Gate { id, .. } | Answer::Question { id, .. }) =
        &mut answer;
    local.clone_into(id);
    answer
}

fn id_of_answer(answer: &Answer) -> &str {
    match answer {
        Answer::Call { id, .. } | Answer::Gate { id, .. } | Answer::Question { id, .. } => id,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stamp(session: &str, pid: u32) -> Stamp {
        Stamp {
            session: session.to_string(),
            project: "/work".to_string(),
            registration: 1,
            pid,
        }
    }

    #[test]
    fn two_local_ids_of_one_session_and_process_are_two_twins() {
        assert_ne!(twin(&stamp("a", 7), "1"), twin(&stamp("a", 7), "2"));
    }

    #[test]
    fn chats_whose_fields_would_run_together_are_not_one_twin() {
        // The same bytes once the session, the pid's 4 bytes and the local id are joined with no lengths.
        assert_ne!(
            twin(&stamp("a", 0x6362), "x\0\0\0\0"),
            twin(&stamp("abc", 0x0078_0000), "\0\0\0")
        );
    }

    #[test]
    fn an_event_round_trips_over_the_wire_codec() {
        let event = Event::Opened(Opened {
            id: "a".into(),
            twin: "t".into(),
            kind: Kind::ParkedCall,
            requester: "main".into(),
        });
        let bytes = lain_wire::encode(&event).expect("encode");
        assert_eq!(event, lain_wire::decode::<Event>(&bytes).expect("decode"));
        let bytes = lain_wire::encode(&Event::Closed { id: "a".into() }).expect("encode");
        assert_eq!(
            Event::Closed { id: "a".into() },
            lain_wire::decode::<Event>(&bytes).expect("decode")
        );
    }
}
