//! The live chats the daemon knows, each registered by its own process over its own connection.

use std::collections::BTreeMap;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use lain_rpc::{Peer, RpcError};
use lain_wire::Register;
use rmpv::Value;

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

/// TZ and locale are pinned because `lstart` prints local time in the locale's words.
fn ps(pid: u32) -> Option<String> {
    let output = Command::new("ps")
        .args(["-o", "ppid=", "-o", "lstart=", "-p", &pid.to_string()])
        .env("TZ", "UTC")
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
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

/// A registered chat: what it said about itself, and the start the daemon read for its pid.
#[derive(Clone, Debug)]
pub(crate) struct Record {
    pub(crate) register: Register,
    pub(crate) start: String,
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

/// The live chats, keyed by session id.
pub(crate) struct Registry<P: Procs = ProcTable> {
    procs: P,
    sessions: Mutex<BTreeMap<String, Record>>,
}

/// A session's place in the [`Registry`], held by the connection that registered it; dropping it,
/// which the server does when the connection ends, unlists the session.
pub(crate) struct Registration<P: Procs = ProcTable> {
    registry: Arc<Registry<P>>,
    session_id: String,
}

impl<P: Procs> Drop for Registration<P> {
    fn drop(&mut self) {
        self.registry.sessions().remove(&self.session_id);
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
        })
    }

    fn sessions(&self) -> MutexGuard<'_, BTreeMap<String, Record>> {
        self.sessions.lock().unwrap_or_else(PoisonError::into_inner)
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
        sessions.insert(session_id.clone(), Record { register, start });
        Ok(Registration {
            registry: Arc::clone(self),
            session_id,
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
    use lain_wire::Register;

    use super::*;

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
