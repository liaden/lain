//! The daemon's own timers. Each tick starts a run the supervisor owns, so a slow one shows in
//! `run.list` and a stopped daemon leaves it to finish like any other.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use tokio::time::{MissedTickBehavior, interval};

use crate::supervisor::{Supervisor, project_root};

/// How often the review polls run: the user's, when the daemon was asked for it, and each
/// registered project's that asked.
pub(crate) const POLL_EVERY: Duration = Duration::from_secs(300);

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Tick {
    Started,
    Skipped,
    Failed,
}

/// Which polls each tick runs, and the registered roots already warned of as not projects.
pub(crate) struct Polls {
    user: bool,
    refused: BTreeSet<String>,
}

impl Polls {
    /// `user` is whether the user's own poll runs beside the projects'.
    pub(crate) fn new(user: bool) -> Self {
        Self {
            user,
            refused: BTreeSet::new(),
        }
    }

    /// 1 [`Tick`] per poll: the user's first, then each of `roots` once by its canonical path, so
    /// 2 spellings of 1 project share a poll. A root that is not a project is warned of once while
    /// it stays registered, not every 5 minutes.
    pub(crate) fn tick(&mut self, supervisor: &Arc<Supervisor>, roots: &[String]) -> Vec<Tick> {
        self.refused.retain(|root| roots.contains(root));
        let mut polled = BTreeSet::new();
        let mut ticks: Vec<Tick> = self
            .user
            .then(|| poll(supervisor, None))
            .into_iter()
            .collect();
        for root in roots {
            match project_root(root) {
                Ok(canonical) if polled.insert(canonical.clone()) => {
                    ticks.push(poll(supervisor, Some(canonical)));
                }
                Ok(_) => {}
                Err(error) => {
                    if self.refused.insert(root.clone()) {
                        tracing::warn!(%error, "did not poll a registered project");
                    }
                    ticks.push(Tick::Failed);
                }
            }
        }
        ticks
    }
}

/// A poll still running is never doubled: 2 would read the same forge twice and write the same
/// counts file.
fn poll(supervisor: &Arc<Supervisor>, root: Option<PathBuf>) -> Tick {
    if supervisor.review_poll_live(root.as_deref()) {
        tracing::info!(
            ?root,
            "skipped a review poll tick: the last poll is still running"
        );
        return Tick::Skipped;
    }
    match supervisor.start_review_poll(root) {
        Ok(_) => Tick::Started,
        Err(error) => {
            tracing::warn!(%error, "could not start a review poll");
            Tick::Failed
        }
    }
}

/// Ticks at once, then every `every`, asking `roots` afresh each time, so a project whose chat
/// registers later is polled from the next tick with no restart. A tick the daemon was too busy to
/// take is dropped, not made up in a burst.
pub(crate) async fn poll_every(
    supervisor: Arc<Supervisor>,
    every: Duration,
    user: bool,
    roots: impl Fn() -> Vec<String>,
) {
    let mut ticks = interval(every);
    ticks.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let mut polls = Polls::new(user);
    loop {
        ticks.tick().await;
        polls.tick(&supervisor, &roots());
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::*;
    use crate::supervisor::{RunKind, Settings, Supervisor};

    pub(crate) fn supervisor(script: &str) -> (tempfile::TempDir, Arc<Supervisor>) {
        let dir = tempfile::tempdir().expect("tempdir");
        // Run by `sh` rather than exec'd: another test's fork can hold the script's write
        // descriptor, and exec of a file open for writing fails with ETXTBSY.
        let lain = dir.path().join("lain");
        let script = script.replace("{dir}", dir.path().to_str().expect("utf-8"));
        std::fs::write(&lain, format!("{script}\n")).expect("script");
        let supervisor = Supervisor::new(Some(Settings {
            ruby: "/bin/sh".into(),
            lain,
            runs: dir.path().join("runs"),
            env: vec![("PATH".into(), std::env::var_os("PATH").unwrap_or_default())],
        }));
        (dir, supervisor)
    }

    /// Holds the only runtime thread while it waits, so the paused clock cannot move.
    pub(crate) async fn until(what: &str, mut done: impl FnMut() -> bool) {
        for _ in 0..1000 {
            if done() {
                return;
            }
            tokio::task::yield_now().await;
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("{what} never happened");
    }

    #[tokio::test(start_paused = true)]
    async fn a_review_poll_starts_at_0_300_and_600_seconds() {
        let (_dir, supervisor) = supervisor("exit 0");
        let task = tokio::spawn(poll_every(
            Arc::clone(&supervisor),
            Duration::from_secs(300),
            true,
            Vec::new,
        ));
        until("the poll at 0 s", || supervisor.list().len() == 1).await;
        tokio::time::advance(Duration::from_secs(299)).await;
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
        assert_eq!(1, supervisor.list().len(), "a poll before 300 s");
        tokio::time::advance(Duration::from_secs(1)).await;
        until("the poll at 300 s", || supervisor.list().len() == 2).await;
        tokio::time::advance(Duration::from_secs(300)).await;
        until("the poll at 600 s", || supervisor.list().len() == 3).await;
        task.abort();
    }

    #[derive(Clone, Default)]
    struct Trace(Arc<std::sync::Mutex<Vec<u8>>>);

    impl std::io::Write for Trace {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().expect("trace").extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_tick_while_the_last_poll_still_runs_is_skipped_with_1_trace_line() {
        let (_dir, supervisor) = supervisor("sleep 30");
        let trace = Trace::default();
        let subscriber = tracing_subscriber::fmt()
            .with_writer({
                let trace = trace.clone();
                move || trace.clone()
            })
            .finish();
        let mut polls = Polls::new(true);
        assert_eq!(vec![Tick::Started], polls.tick(&supervisor, &[]));
        let before = trace.0.lock().expect("trace").len();
        let skipped =
            tracing::subscriber::with_default(subscriber, || polls.tick(&supervisor, &[]));
        assert_eq!(vec![Tick::Skipped], skipped);
        let text =
            String::from_utf8(trace.0.lock().expect("trace")[before..].to_vec()).expect("utf-8");
        assert_eq!(1, text.lines().count(), "{text}");
        assert!(text.contains("skipped a review poll tick"), "{text}");
        assert_eq!(1, supervisor.list().len());
        let id = supervisor.list()[0].id.clone();
        supervisor.stop(&id).await.expect("stopped");
        assert_eq!(vec![Tick::Started], polls.tick(&supervisor, &[]));
        let id = supervisor.list()[1].id.clone();
        supervisor.stop(&id).await.expect("stopped");
    }

    pub(crate) fn project(dir: &tempfile::TempDir, name: &str) -> String {
        let root = dir.path().join(name);
        std::fs::create_dir_all(root.join(".git")).expect("a project");
        root.to_str().expect("utf-8").to_string()
    }

    pub(crate) fn noting() -> (tempfile::TempDir, Arc<Supervisor>, std::path::PathBuf) {
        let (dir, supervisor) = supervisor("echo \"$*|$(pwd)\" >> {dir}/polls");
        let polls = dir.path().join("polls");
        (dir, supervisor, polls)
    }

    pub(crate) fn polled(polls: &std::path::Path) -> Vec<String> {
        let mut lines: Vec<String> = std::fs::read_to_string(polls)
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect();
        lines.sort();
        lines
    }

    pub(crate) fn canonical(root: &str) -> String {
        std::path::Path::new(root)
            .canonicalize()
            .expect("canonical")
            .to_str()
            .expect("utf-8")
            .to_string()
    }

    fn roots_polled(supervisor: &Supervisor) -> Vec<Option<std::path::PathBuf>> {
        supervisor
            .list()
            .into_iter()
            .map(|run| match run.kind {
                RunKind::ReviewPoll { root } => root,
                other => panic!("not a review poll: {other:?}"),
            })
            .collect()
    }

    #[tokio::test]
    async fn a_tick_polls_the_user_and_each_root_that_asked() {
        let (dir, supervisor, polls) = noting();
        let root = project(&dir, "api");
        let ticked = Polls::new(true).tick(&supervisor, std::slice::from_ref(&root));
        assert_eq!(vec![Tick::Started, Tick::Started], ticked);
        until("both polls", || polled(&polls).len() == 2).await;
        let runs = canonical(dir.path().join("runs").to_str().expect("utf-8"));
        let root = canonical(&root);
        assert_eq!(
            vec![
                format!("queue poll --root {root}|{root}"),
                format!("queue poll|{runs}"),
            ],
            polled(&polls)
        );
    }

    #[tokio::test]
    async fn a_tick_with_no_user_poll_polls_only_the_roots() {
        let (dir, supervisor, polls) = noting();
        let root = project(&dir, "api");
        assert_eq!(
            vec![Tick::Started],
            Polls::new(false).tick(&supervisor, std::slice::from_ref(&root))
        );
        until("the root's poll", || polled(&polls).len() == 1).await;
        let root = canonical(&root);
        assert_eq!(
            vec![format!("queue poll --root {root}|{root}")],
            polled(&polls)
        );
    }

    #[tokio::test]
    async fn two_spellings_of_1_root_give_1_poll() {
        let (dir, supervisor, _polls) = noting();
        let root = project(&dir, "api");
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&root, &link).expect("a link");
        let link = link.to_str().expect("utf-8").to_string();
        assert_eq!(
            vec![Tick::Started],
            Polls::new(false).tick(&supervisor, &[root.clone(), link])
        );
        assert_eq!(
            vec![Some(std::path::PathBuf::from(canonical(&root)))],
            roots_polled(&supervisor)
        );
    }

    #[tokio::test]
    async fn a_root_that_is_not_a_project_is_not_polled() {
        let (dir, supervisor, _polls) = noting();
        let bare = dir.path().join("bare");
        std::fs::create_dir(&bare).expect("a directory");
        let bare = bare.to_str().expect("utf-8").to_string();
        assert_eq!(
            vec![Tick::Failed],
            Polls::new(false).tick(&supervisor, &[bare])
        );
        assert!(supervisor.list().is_empty());
    }

    #[tokio::test]
    async fn a_root_that_is_not_a_project_is_warned_of_once_not_every_tick() {
        let (dir, supervisor, _polls) = noting();
        let bare = dir.path().join("bare");
        std::fs::create_dir(&bare).expect("a directory");
        let bare = vec![bare.to_str().expect("utf-8").to_string()];
        let trace = Trace::default();
        let subscriber = tracing_subscriber::fmt()
            .with_writer({
                let trace = trace.clone();
                move || trace.clone()
            })
            .finish();
        let mut polls = Polls::new(false);
        let ticks = tracing::subscriber::with_default(subscriber, || {
            [
                polls.tick(&supervisor, &bare),
                polls.tick(&supervisor, &bare),
            ]
        });
        assert_eq!([vec![Tick::Failed], vec![Tick::Failed]], ticks);
        let text = String::from_utf8(trace.0.lock().expect("trace").clone()).expect("utf-8");
        assert_eq!(
            1,
            text.matches("did not poll a registered project").count(),
            "{text}"
        );
    }

    #[tokio::test]
    async fn a_bad_root_that_leaves_and_registers_again_is_warned_of_again() {
        let (dir, supervisor, _polls) = noting();
        let bare = dir.path().join("bare");
        std::fs::create_dir(&bare).expect("a directory");
        let bare = vec![bare.to_str().expect("utf-8").to_string()];
        let trace = Trace::default();
        let subscriber = tracing_subscriber::fmt()
            .with_writer({
                let trace = trace.clone();
                move || trace.clone()
            })
            .finish();
        let mut polls = Polls::new(false);
        tracing::subscriber::with_default(subscriber, || {
            polls.tick(&supervisor, &bare);
            polls.tick(&supervisor, &[]);
            assert!(polls.refused.is_empty(), "{:?}", polls.refused);
            polls.tick(&supervisor, &bare);
        });
        let text = String::from_utf8(trace.0.lock().expect("trace").clone()).expect("utf-8");
        assert_eq!(
            2,
            text.matches("did not poll a registered project").count(),
            "{text}"
        );
    }

    #[tokio::test]
    async fn a_roots_poll_still_running_is_skipped_and_the_users_still_starts() {
        let (dir, supervisor) = supervisor("sleep 30");
        let root = project(&dir, "api");
        let roots = std::slice::from_ref(&root);
        assert_eq!(
            vec![Tick::Started],
            Polls::new(false).tick(&supervisor, roots)
        );
        assert_eq!(
            vec![Tick::Started, Tick::Skipped],
            Polls::new(true).tick(&supervisor, roots)
        );
        for run in supervisor.list() {
            supervisor.stop(&run.id).await.expect("stopped");
        }
    }

    #[tokio::test(start_paused = true)]
    async fn a_root_is_polled_from_the_tick_after_it_asks_until_the_tick_after_it_leaves() {
        let (dir, supervisor) = supervisor("exit 0");
        let root = project(&dir, "api");
        let asking = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let task = tokio::spawn(poll_every(
            Arc::clone(&supervisor),
            Duration::from_secs(300),
            false,
            {
                let asking = Arc::clone(&asking);
                move || asking.lock().expect("roots").clone()
            },
        ));
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
        assert!(supervisor.list().is_empty(), "a poll with nothing asking");
        asking.lock().expect("roots").push(root.clone());
        tokio::time::advance(Duration::from_secs(300)).await;
        until("the root's poll at 300 s", || supervisor.list().len() == 1).await;
        assert_eq!(
            vec![Some(std::path::PathBuf::from(canonical(&root)))],
            roots_polled(&supervisor)
        );
        asking.lock().expect("roots").clear();
        tokio::time::advance(Duration::from_secs(300)).await;
        for _ in 0..20 {
            tokio::task::yield_now().await;
        }
        assert_eq!(
            1,
            supervisor.list().len(),
            "a poll for a root nobody asks for"
        );
        task.abort();
    }
}
