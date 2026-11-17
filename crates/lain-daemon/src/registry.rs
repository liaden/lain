//! The live chats the daemon knows, each registered by its own process over its own connection.

use std::collections::{BTreeMap, HashMap};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use lain_rpc::{Peer, Push, RpcError};
use lain_wire::{OfferReply, Register};
use rmpv::Value;
use tokio::sync::{mpsc, oneshot};

/// How long `offer.send` waits for the chat to say what it did with an offer. The chat answers
/// once it has rebuilt the review's line, and a dirty tree's snapshot can take that long.
pub(crate) const OFFER_REPLY: Duration = Duration::from_secs(30);

/// How far up a caller's parents the daemon looks for a registered session.
const MAX_ANCESTORS: usize = 64;

/// Field 22 of `/proc/<pid>/stat`, counted from after the command name, as `Liveness::Probe` reads it.
const START_FIELD: usize = 19;

/// Field 4 of the same file, counted the same way.
const PARENT_FIELD: usize = 1;

const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// What the daemon reads about 1 process.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Process {
    /// The parent, when the table names one.
    pub(crate) parent: Option<u32>,
    /// The start, in `Liveness`'s grammar: clock ticks, or `u` and a UTC epoch second.
    pub(crate) start: String,
}

/// The process table the daemon asks who a caller is.
pub(crate) trait Procs: Send + Sync + 'static {
    /// The process, or None when it cannot be read.
    fn process(&self, pid: u32) -> Option<Process>;
}

/// This host's table: `/proc` where it exists, and `ps` where it does not.
pub(crate) struct ProcTable;

impl Procs for ProcTable {
    fn process(&self, pid: u32) -> Option<Process> {
        match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
            Ok(stat) => process_of_stat(&stat),
            Err(_) => process_of_ps_line(&ps(pid)?),
        }
    }
}

/// The command name may itself hold spaces and parentheses, so fields are counted after its last `)`.
fn process_of_stat(stat: &str) -> Option<Process> {
    let (_, after) = stat.rsplit_once(')')?;
    let fields: Vec<&str> = after.split_whitespace().collect();
    Some(Process {
        parent: fields.get(PARENT_FIELD)?.parse().ok(),
        start: (*fields.get(START_FIELD)?).to_string(),
    })
}

/// TZ and locale are pinned because `lstart` prints local time in the locale's words. The topic is
/// as good as a password to anyone who can post to it, and the digest hashes it, so the child
/// inherits neither.
fn ps_command(pid: u32) -> Command {
    let mut command = Command::new("ps");
    command
        .args(["-o", "ppid=", "-o", "lstart=", "-p", &pid.to_string()])
        .env("TZ", "UTC")
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .env_remove(crate::NTFY_VAR)
        .env_remove(crate::DIGEST_VAR)
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    command
}

fn ps(pid: u32) -> Option<String> {
    let output = ps_command(pid).output().ok()?;
    let text = String::from_utf8(output.stdout).ok()?;
    (output.status.success() && !text.trim().is_empty()).then_some(text)
}

/// `  4000 Tue Nov 17 10:00:00 2026`: the parent, then its start.
fn process_of_ps_line(line: &str) -> Option<Process> {
    let (parent, lstart) = line.trim_start().split_once(char::is_whitespace)?;
    Some(Process {
        parent: parent.parse().ok(),
        start: epoch_of_lstart(lstart)?,
    })
}

/// `Tue Nov 17 10:00:00 2026`, read in UTC, as `u1794909600`.
fn epoch_of_lstart(text: &str) -> Option<String> {
    let mut words = text.split_whitespace().skip(1);
    let month_name = words.next()?;
    let month = MONTHS.iter().position(|name| *name == month_name)? + 1;
    let day: i64 = words.next()?.parse().ok()?;
    let mut clock = words.next()?.split(':').map(str::parse::<i64>);
    let (hour, minute, second) = (
        clock.next()?.ok()?,
        clock.next()?.ok()?,
        clock.next()?.ok()?,
    );
    let year: i64 = words.next()?.parse().ok()?;
    let days = days_from_civil(year, i64::try_from(month).ok()?, day);
    Some(format!(
        "u{}",
        days * 86_400 + hour * 3_600 + minute * 60 + second
    ))
}

/// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// A registered chat: what it said about itself, the start the daemon read for its pid, and the
/// connection that registered it, which is where its answers are pushed.
#[derive(Clone, Debug)]
pub(crate) struct Record {
    pub(crate) register: Register,
    pub(crate) start: String,
    pub(crate) registration: u64,
    pub(crate) outlet: Option<Push>,
}

impl Record {
    /// The record as `session.list` sends it: the registration's fields plus `start`.
    pub(crate) fn to_value(&self) -> Value {
        let register = &self.register;
        let optional = |path: &Option<String>| path.as_deref().map_or(Value::Nil, Value::from);
        Value::Map(vec![
            (
                Value::from("session_id"),
                Value::from(register.session_id.as_str()),
            ),
            (Value::from("pid"), Value::from(register.pid)),
            (Value::from("start"), Value::from(self.start.as_str())),
            (Value::from("host"), Value::from(register.host.as_str())),
            (Value::from("root"), Value::from(register.root.as_str())),
            (Value::from("cwd"), Value::from(register.cwd.as_str())),
            (
                Value::from("input_socket"),
                optional(&register.input_socket),
            ),
            (Value::from("journal"), optional(&register.journal)),
            (Value::from("attended"), Value::from(register.attended)),
            (
                Value::from("started_at"),
                Value::from(register.started_at.as_str()),
            ),
        ])
    }
}

/// The live chats, keyed by session id, and the offers waiting on their replies.
pub(crate) struct Registry<P: Procs = ProcTable> {
    procs: P,
    sessions: Mutex<BTreeMap<String, Record>>,
    registrations: AtomicU64,
    departures: Mutex<Option<mpsc::UnboundedSender<u64>>>,
    offers: Mutex<HashMap<u64, Waiting>>,
    offer_ids: AtomicU64,
}

/// An offer pushed to 1 registration, which alone may reply to it.
struct Waiting {
    registration: u64,
    reply: oneshot::Sender<OfferReply>,
}

/// The chat an offer goes to, and the other attended chats in its root, newest first.
pub(crate) struct Recipients {
    pub(crate) chosen: Record,
    pub(crate) others: Vec<Record>,
}

/// 1 offer's wait for its reply. Dropping it forgets the offer, so a sender that gives up
/// leaves nothing behind.
pub(crate) struct PendingOffer<P: Procs = ProcTable> {
    registry: Arc<Registry<P>>,
    id: u64,
    reply: Option<oneshot::Receiver<OfferReply>>,
}

impl<P: Procs> PendingOffer<P> {
    pub(crate) fn id(&self) -> u64 {
        self.id
    }

    /// The chat's reply, or None when the bound passes first or the chat leaves.
    pub(crate) async fn reply(mut self, bound: Duration) -> Option<OfferReply> {
        let reply = self.reply.take()?;
        tokio::time::timeout(bound, reply).await.ok()?.ok()
    }
}

impl<P: Procs> Drop for PendingOffer<P> {
    fn drop(&mut self) {
        self.registry.offers().remove(&self.id);
    }
}

/// A session's place in the [`Registry`], held by the connection that registered it; dropping it,
/// which the server does when the connection ends, unlists the session.
pub(crate) struct Registration<P: Procs = ProcTable> {
    registry: Arc<Registry<P>>,
    session_id: String,
    root: String,
    registration: u64,
}

impl<P: Procs> Registration<P> {
    pub(crate) fn session_id(&self) -> &str {
        &self.session_id
    }

    /// The project the session registered with, which is what its published items belong to.
    pub(crate) fn root(&self) -> &str {
        &self.root
    }

    /// Unique to this registration, where a session id may be registered again once it leaves.
    pub(crate) fn registration(&self) -> u64 {
        self.registration
    }

    pub(crate) fn attach(&self, outlet: Push) {
        if let Some(record) = self.registry.sessions().get_mut(&self.session_id) {
            record.outlet = Some(outlet);
        }
    }

    /// Hands `reply` to the offer's sender, when the offer was pushed to this registration.
    pub(crate) fn reply(&self, reply: OfferReply) -> Result<(), RpcError> {
        let mut offers = self.registry.offers();
        match offers.get(&reply.offer_id) {
            Some(waiting) if waiting.registration == self.registration => {
                if let Some(waiting) = offers.remove(&reply.offer_id) {
                    let _sender_gone = waiting.reply.send(reply);
                }
                Ok(())
            }
            _ => Err(refused(
                "no_offer",
                format!(
                    "offer {} is not waiting on a reply from this session",
                    reply.offer_id
                ),
            )),
        }
    }
}

impl<P: Procs> Drop for Registration<P> {
    fn drop(&mut self) {
        self.registry.sessions().remove(&self.session_id);
        self.registry
            .offers()
            .retain(|_, waiting| waiting.registration != self.registration);
        if let Some(departures) = &*self
            .registry
            .departures
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
        {
            let _closed = departures.send(self.registration);
        }
    }
}

fn refused(code: &'static str, message: String) -> RpcError {
    RpcError::Refused { code, message }
}

impl<P: Procs> Registry<P> {
    /// An empty registry.
    pub(crate) fn new(procs: P) -> Arc<Self> {
        Arc::new(Self {
            procs,
            sessions: Mutex::new(BTreeMap::new()),
            registrations: AtomicU64::new(0),
            departures: Mutex::new(None),
            offers: Mutex::new(HashMap::new()),
            offer_ids: AtomicU64::new(0),
        })
    }

    fn offers(&self) -> MutexGuard<'_, HashMap<u64, Waiting>> {
        self.offers.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The newest attended chat in `root` by the start it registered, and the others there.
    pub(crate) fn recipients(&self, root: &str) -> Option<Recipients> {
        let mut attended: Vec<Record> = self
            .sessions()
            .values()
            .filter(|record| record.register.attended && record.register.root == root)
            .cloned()
            .collect();
        attended.sort_by(|a, b| b.register.started_at.cmp(&a.register.started_at));
        let mut attended = attended.into_iter();
        let chosen = attended.next()?;
        Some(Recipients {
            chosen,
            others: attended.collect(),
        })
    }

    /// Opens an offer to `registration`, which waits until it is replied to or dropped.
    pub(crate) fn open_offer(self: &Arc<Self>, registration: u64) -> PendingOffer<P> {
        let id = self.offer_ids.fetch_add(1, Ordering::Relaxed) + 1;
        let (sender, receiver) = oneshot::channel();
        self.offers().insert(
            id,
            Waiting {
                registration,
                reply: sender,
            },
        );
        PendingOffer {
            registry: Arc::clone(self),
            id,
            reply: Some(receiver),
        }
    }

    #[cfg(test)]
    fn pending_offers(&self) -> usize {
        self.offers().len()
    }

    /// Each registration that ends from now on, by its number.
    pub(crate) fn departures(&self) -> mpsc::UnboundedReceiver<u64> {
        let (sender, receiver) = mpsc::unbounded_channel();
        *self
            .departures
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(sender);
        receiver
    }

    fn sessions(&self) -> MutexGuard<'_, BTreeMap<String, Record>> {
        self.sessions.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Where to push to `registration` of `session_id`, while it lasts.
    pub(crate) fn outlet(&self, session_id: &str, registration: u64) -> Option<Push> {
        let sessions = self.sessions();
        let record = sessions.get(session_id)?;
        if record.registration == registration {
            record.outlet.clone()
        } else {
            None
        }
    }

    /// Every registered session, in session id order.
    pub(crate) fn list(&self) -> Vec<Record> {
        self.sessions().values().cloned().collect()
    }

    /// Lists `register` for the process on the other end of the connection. A process whose
    /// parent chain reaches a registered session, its own included, is refused. That catches a
    /// process still attached to a chat; it is not a boundary, because a double-forked `setsid`
    /// grandchild is reparented away from the chat and registers. Confinement is the control.
    /// The lineage is read before the lock, so a chat and its child registering at the same
    /// moment can both get in.
    pub(crate) fn register(
        self: &Arc<Self>,
        peer: Peer,
        register: Register,
    ) -> Result<Registration<P>, RpcError> {
        if peer.pid != Some(register.pid) {
            return Err(refused(
                "not_the_caller",
                format!(
                    "a connection from pid {} cannot register pid {}",
                    peer.pid
                        .map_or_else(|| "unknown".to_string(), |pid| pid.to_string()),
                    register.pid
                ),
            ));
        }
        let lineage = self.lineage(register.pid);
        let Some((_, start)) = lineage.first().cloned() else {
            return Err(refused(
                "no_start",
                format!("could not read the start of pid {}", register.pid),
            ));
        };
        let mut sessions = self.sessions();
        if let Some(holder) = sessions
            .values()
            .find(|record| lineage.contains(&(record.register.pid, record.start.clone())))
        {
            return Err(refused(
                "inside_a_session",
                format!(
                    "pid {} runs inside session {}, which is registered",
                    register.pid, holder.register.session_id
                ),
            ));
        }
        if sessions.contains_key(&register.session_id) {
            return Err(refused(
                "session_taken",
                format!("session {} is already registered", register.session_id),
            ));
        }
        let session_id = register.session_id.clone();
        let root = register.root.clone();
        let registration = self.registrations.fetch_add(1, Ordering::Relaxed) + 1;
        sessions.insert(
            session_id.clone(),
            Record {
                register,
                start,
                registration,
                outlet: None,
            },
        );
        Ok(Registration {
            registry: Arc::clone(self),
            session_id,
            root,
            registration,
        })
    }

    /// `pid` and its ancestors with their starts, each read once, so a pid reused since a
    /// session registered does not read as that session. The walk stops at the first process it
    /// cannot read.
    fn lineage(&self, pid: u32) -> Vec<(u32, String)> {
        let first = self.procs.process(pid).map(|process| (pid, process));
        std::iter::successors(first, |(at, process)| {
            let parent = process
                .parent
                .filter(|&parent| parent != 0 && parent != *at)?;
            self.procs.process(parent).map(|process| (parent, process))
        })
        .take(MAX_ANCESTORS)
        .map(|(at, process)| (at, process.start))
        .collect()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use lain_rpc::{Peer, RpcError};
    use lain_wire::{OfferReply, Register};

    use super::*;

    #[test]
    fn the_ps_child_is_never_handed_the_ntfy_topic_or_the_launch_digest() {
        let command = super::ps_command(1);
        let envs: Vec<_> = command.get_envs().collect();
        for name in [crate::NTFY_VAR, crate::DIGEST_VAR] {
            assert!(
                envs.iter()
                    .any(|(set, value)| *set == name && value.is_none()),
                "ps would inherit {name} from the daemon's environment"
            );
        }
    }

    const OWNER: u32 = 1000;

    #[derive(Default)]
    struct Table {
        starts: Mutex<HashMap<u32, String>>,
        parents: HashMap<u32, u32>,
        reads: Mutex<Vec<u32>>,
    }

    impl Table {
        fn with(processes: &[(u32, &str, u32)]) -> Self {
            Self {
                starts: Mutex::new(
                    processes
                        .iter()
                        .map(|&(pid, start, _)| (pid, start.to_string()))
                        .collect(),
                ),
                parents: processes
                    .iter()
                    .map(|&(pid, _, parent)| (pid, parent))
                    .collect(),
                reads: Mutex::default(),
            }
        }

        fn restart(&self, pid: u32, start: &str) {
            self.starts
                .lock()
                .expect("table")
                .insert(pid, start.to_string());
        }

        fn reads(&self) -> Vec<u32> {
            self.reads.lock().expect("table").clone()
        }
    }

    impl Procs for Table {
        fn process(&self, pid: u32) -> Option<Process> {
            self.reads.lock().expect("table").push(pid);
            let start = self.starts.lock().expect("table").get(&pid).cloned()?;
            Some(Process {
                parent: self.parents.get(&pid).copied(),
                start,
            })
        }
    }

    fn peer(pid: u32) -> Peer {
        Peer {
            uid: Some(OWNER),
            pid: Some(pid),
        }
    }

    fn register(session_id: &str, pid: u32) -> Register {
        Register {
            session_id: session_id.to_string(),
            pid,
            host: "rainbow".to_string(),
            root: "/work".to_string(),
            cwd: "/work/lib".to_string(),
            input_socket: None,
            journal: None,
            attended: true,
            started_at: "2026-11-17T10:00:00Z".to_string(),
        }
    }

    fn refusal(result: Result<Registration<Table>, RpcError>) -> (&'static str, String) {
        match result {
            Err(RpcError::Refused { code, message }) => (code, message),
            Err(other) => panic!("not a refusal: {other}"),
            Ok(_) => panic!("registered"),
        }
    }

    /// pid 1 <- 4000 <- 4242 <- 4299 <- 4300, and 5000 beside them.
    fn family() -> Arc<Registry<Table>> {
        Registry::new(Table::with(&[
            (1, "1", 0),
            (4000, "50", 1),
            (4242, "123", 4000),
            (4299, "130", 4242),
            (4300, "131", 4299),
            (5000, "140", 1),
        ]))
    }

    fn listed(registry: &Registry<Table>) -> Vec<(String, u32, String)> {
        registry
            .list()
            .iter()
            .map(|record| {
                (
                    record.register.session_id.clone(),
                    record.register.pid,
                    record.start.clone(),
                )
            })
            .collect()
    }

    #[test]
    fn a_chat_is_keyed_by_its_session_id_with_the_start_the_daemon_read() {
        let registry = family();
        let _a = registry
            .register(peer(4242), register("a", 4242))
            .expect("registered");
        assert_eq!(
            vec![("a".to_string(), 4242, "123".to_string())],
            listed(&registry)
        );
    }

    #[test]
    fn a_process_cannot_register_as_another() {
        let registry = family();
        let (code, message) = refusal(registry.register(peer(5000), register("a", 4242)));
        assert_eq!("not_the_caller", code);
        assert!(message.contains("4242"), "{message}");
        assert!(listed(&registry).is_empty());
    }

    #[test]
    fn a_peer_whose_pid_the_kernel_did_not_report_is_refused() {
        let registry = family();
        let unknown = Peer {
            uid: Some(OWNER),
            pid: None,
        };
        let (code, _) = refusal(registry.register(unknown, register("a", 4242)));
        assert_eq!("not_the_caller", code);
    }

    #[test]
    fn a_registered_sessions_descendant_is_refused_naming_the_session() {
        let registry = family();
        let _parent = registry
            .register(peer(4242), register("parent-session", 4242))
            .expect("registered");
        let (code, message) = refusal(registry.register(peer(4300), register("child", 4300)));
        assert_eq!("inside_a_session", code);
        assert!(message.contains("parent-session"), "{message}");
        assert_eq!(1, listed(&registry).len());
    }

    #[test]
    fn a_registered_process_cannot_register_a_second_session() {
        let registry = family();
        let _first = registry
            .register(peer(4242), register("first", 4242))
            .expect("registered");
        let (code, message) = refusal(registry.register(peer(4242), register("second", 4242)));
        assert_eq!("inside_a_session", code);
        assert!(message.contains("first"), "{message}");
    }

    #[test]
    fn an_unrelated_process_registers_beside_a_session() {
        let registry = family();
        let _a = registry
            .register(peer(4242), register("a", 4242))
            .expect("registered");
        let _b = registry
            .register(peer(5000), register("b", 5000))
            .expect("registered");
        assert_eq!(2, listed(&registry).len());
    }

    #[test]
    fn a_reused_pid_is_not_the_parent_session() {
        let registry = family();
        let _parent = registry
            .register(peer(4242), register("parent", 4242))
            .expect("registered");
        registry.procs.restart(4242, "999");
        registry
            .register(peer(4300), register("child", 4300))
            .expect("a reused pid is another process");
    }

    #[test]
    fn a_session_id_is_registered_once() {
        let registry = family();
        let _a = registry
            .register(peer(4242), register("a", 4242))
            .expect("registered");
        let (code, _) = refusal(registry.register(peer(5000), register("a", 5000)));
        assert_eq!("session_taken", code);
        assert_eq!(
            vec![("a".to_string(), 4242, "123".to_string())],
            listed(&registry)
        );
    }

    #[test]
    fn a_caller_whose_start_cannot_be_read_is_refused() {
        let registry = Registry::new(Table::default());
        let (code, _) = refusal(registry.register(peer(4242), register("a", 4242)));
        assert_eq!("no_start", code);
    }

    #[test]
    fn dropping_the_registration_unlists_the_session() {
        let registry = family();
        let registration = registry
            .register(peer(4242), register("a", 4242))
            .expect("registered");
        drop(registration);
        assert!(listed(&registry).is_empty());
        registry
            .register(peer(4242), register("a", 4242))
            .expect("free again");
    }

    #[test]
    fn each_ancestor_is_read_once() {
        let registry = family();
        let _child = registry
            .register(peer(4300), register("child", 4300))
            .expect("registered");
        assert_eq!(vec![4300, 4299, 4242, 4000, 1], registry.procs.reads());
    }

    #[test]
    fn the_process_table_reads_a_start_and_a_parent_the_way_liveness_does() {
        let me = std::process::id();
        let process = ProcTable.process(me).expect("our own process");
        if let Ok(stat) = std::fs::read_to_string(format!("/proc/{me}/stat")) {
            let fields: Vec<&str> = stat
                .rsplit_once(')')
                .expect("stat")
                .1
                .split_whitespace()
                .collect();
            assert_eq!(fields[19], process.start);
        } else {
            assert!(process.start.starts_with('u'), "{}", process.start);
        }
        assert_eq!(Some(std::os::unix::process::parent_id()), process.parent);
        assert!(ProcTable.process(u32::MAX).is_none());
    }

    #[test]
    fn the_process_table_refuses_a_child_of_a_registered_process() {
        let me = std::process::id();
        let parent = std::os::unix::process::parent_id();
        let registry = Registry::new(ProcTable);
        let _parent = registry
            .register(peer(parent), register("the-runner", parent))
            .expect("registered");
        match registry.register(peer(me), register("me", me)) {
            Err(RpcError::Refused { code, message }) => {
                assert_eq!("inside_a_session", code);
                assert!(message.contains("the-runner"), "{message}");
            }
            Err(other) => panic!("not a refusal: {other}"),
            Ok(_) => panic!("a child registered"),
        }
    }

    /// pids 4242, 5000 and 5001 are unrelated, so all 3 can register.
    fn neighbours() -> Arc<Registry<Table>> {
        Registry::new(Table::with(&[
            (1, "1", 0),
            (4242, "123", 1),
            (5000, "140", 1),
            (5001, "141", 1),
        ]))
    }

    fn chat(session_id: &str, pid: u32, root: &str, started_at: &str, attended: bool) -> Register {
        Register {
            root: root.to_string(),
            started_at: started_at.to_string(),
            attended,
            ..register(session_id, pid)
        }
    }

    fn reply(offer_id: u64, outcome: &str) -> OfferReply {
        OfferReply {
            offer_id,
            outcome: outcome.to_string(),
            field: None,
        }
    }

    fn names(records: &[Record]) -> Vec<String> {
        records
            .iter()
            .map(|record| record.register.session_id.clone())
            .collect()
    }

    #[test]
    fn an_offer_goes_to_the_newest_attended_chat_in_its_root_naming_the_others() {
        let registry = neighbours();
        let _nine = registry
            .register(
                peer(4242),
                chat("nine", 4242, "/work/api", "2026-11-16T09:00:00Z", true),
            )
            .expect("registered");
        let _ten = registry
            .register(
                peer(5000),
                chat("ten", 5000, "/work/api", "2026-11-16T10:00:00Z", true),
            )
            .expect("registered");
        let _eleven = registry
            .register(
                peer(5001),
                chat("eleven", 5001, "/work/api", "2026-11-16T11:00:00Z", false),
            )
            .expect("registered");
        let recipients = registry.recipients("/work/api").expect("a chat runs there");
        assert_eq!("ten", recipients.chosen.register.session_id);
        assert_eq!(vec!["nine".to_string()], names(&recipients.others));
    }

    #[test]
    fn an_offer_for_a_root_with_no_attended_chat_has_no_recipient() {
        let registry = neighbours();
        let _web = registry
            .register(
                peer(4242),
                chat("web", 4242, "/work/web", "2026-11-16T09:00:00Z", true),
            )
            .expect("registered");
        let _headless = registry
            .register(
                peer(5000),
                chat("headless", 5000, "/work/api", "2026-11-16T10:00:00Z", false),
            )
            .expect("registered");
        assert!(registry.recipients("/work/api").is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn the_offered_chats_reply_reaches_the_sender_and_the_offer_is_forgotten() {
        let registry = neighbours();
        let ten = registry
            .register(peer(4242), register("ten", 4242))
            .expect("registered");
        let pending = registry.open_offer(ten.registration());
        ten.reply(reply(pending.id(), "held"))
            .expect("its own offer");
        assert_eq!(
            Some(reply(pending.id(), "held")),
            pending.reply(OFFER_REPLY).await
        );
        assert_eq!(0, registry.pending_offers());
    }

    #[tokio::test(start_paused = true)]
    async fn a_reply_from_another_session_is_refused_and_the_offer_still_waits() {
        let registry = neighbours();
        let ten = registry
            .register(peer(4242), register("ten", 4242))
            .expect("registered");
        let other = registry
            .register(peer(5000), register("other", 5000))
            .expect("registered");
        let pending = registry.open_offer(ten.registration());
        match other.reply(reply(pending.id(), "held")) {
            Err(RpcError::Refused { code, .. }) => assert_eq!("no_offer", code),
            other => panic!("not refused: {other:?}"),
        }
        ten.reply(reply(pending.id(), "crowded"))
            .expect("its own offer");
        assert_eq!(
            Some(reply(pending.id(), "crowded")),
            pending.reply(OFFER_REPLY).await
        );
    }

    #[test]
    fn a_reply_to_no_open_offer_is_refused() {
        let registry = neighbours();
        let ten = registry
            .register(peer(4242), register("ten", 4242))
            .expect("registered");
        match ten.reply(reply(99, "held")) {
            Err(RpcError::Refused { code, .. }) => assert_eq!("no_offer", code),
            other => panic!("not refused: {other:?}"),
        }
    }

    #[tokio::test(start_paused = true)]
    async fn an_offer_unanswered_past_its_bound_is_silent_and_forgotten() {
        let registry = neighbours();
        let ten = registry
            .register(peer(4242), register("ten", 4242))
            .expect("registered");
        let pending = registry.open_offer(ten.registration());
        let id = pending.id();
        assert_eq!(None, pending.reply(OFFER_REPLY).await);
        assert_eq!(0, registry.pending_offers());
        assert!(ten.reply(reply(id, "held")).is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn an_offer_whose_session_leaves_is_silent_and_forgotten() {
        let registry = neighbours();
        let ten = registry
            .register(peer(4242), register("ten", 4242))
            .expect("registered");
        let pending = registry.open_offer(ten.registration());
        let waiting = tokio::spawn(pending.reply(OFFER_REPLY));
        tokio::task::yield_now().await;
        drop(ten);
        assert_eq!(0, registry.pending_offers());
        assert_eq!(None, waiting.await.expect("joined"));
    }

    #[test]
    fn an_offer_abandoned_by_its_sender_is_forgotten() {
        let registry = neighbours();
        let ten = registry
            .register(peer(4242), register("ten", 4242))
            .expect("registered");
        drop(registry.open_offer(ten.registration()));
        assert_eq!(0, registry.pending_offers());
    }

    #[test]
    fn a_ps_line_reads_as_its_parent_and_start() {
        assert_eq!(
            Some(Process {
                parent: Some(4000),
                start: "u1794909600".to_string(),
            }),
            process_of_ps_line(" 4000 Tue Nov 17 10:00:00 2026\n")
        );
        assert_eq!(None, process_of_ps_line(""));
        assert_eq!(None, process_of_ps_line("4000"));
    }

    #[test]
    fn an_lstart_reads_as_its_utc_epoch_second() {
        assert_eq!(
            Some("u1794909600".to_string()),
            epoch_of_lstart("Tue Nov 17 10:00:00 2026\n")
        );
        assert_eq!(
            Some("u1709251199".to_string()),
            epoch_of_lstart("Thu Feb 29 23:59:59 2024")
        );
        assert_eq!(
            Some("u1794909600".to_string()),
            epoch_of_lstart("Tue Nov 17 10:00:00 2026 UTC")
        );
        assert_eq!(None, epoch_of_lstart(""));
        assert_eq!(None, epoch_of_lstart("Tue Zzz 17 10:00:00 2026"));
    }
}
