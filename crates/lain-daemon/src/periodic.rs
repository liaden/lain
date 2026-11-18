//! The daemon's own timers. Each tick starts a run the supervisor owns, so a slow one shows in
//! `run.list` and a stopped daemon leaves it to finish like any other.

use std::sync::Arc;
use std::time::Duration;

use tokio::time::{MissedTickBehavior, interval};

use crate::supervisor::Supervisor;

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Tick {
    Started,
    Skipped,
    Failed,
}

/// A poll still running is never doubled: 2 would read the same forge twice and write the same
/// counts file.
pub(crate) fn tick(supervisor: &Arc<Supervisor>) -> Tick {
    if supervisor.review_poll_live() {
        tracing::info!("skipped a review poll tick: the last poll is still running");
        return Tick::Skipped;
    }
    match supervisor.start_review_poll() {
        Ok(_) => Tick::Started,
        Err(error) => {
            tracing::warn!(%error, "could not start a review poll");
            Tick::Failed
        }
    }
}

/// Ticks at once, then every `every`. A tick the daemon was too busy to take is dropped, not made
/// up in a burst.
pub(crate) async fn poll_every(supervisor: Arc<Supervisor>, every: Duration) {
    let mut ticks = interval(every);
    ticks.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        ticks.tick().await;
        tick(&supervisor);
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::*;
    use crate::supervisor::{Settings, Supervisor};

    fn supervisor(script: &str) -> (tempfile::TempDir, Arc<Supervisor>) {
        let dir = tempfile::tempdir().expect("tempdir");
        // Run by `sh` rather than exec'd: another test's fork can hold the script's write
        // descriptor, and exec of a file open for writing fails with ETXTBSY.
        let lain = dir.path().join("lain");
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
    async fn until(what: &str, mut done: impl FnMut() -> bool) {
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
        assert_eq!(Tick::Started, tick(&supervisor));
        let before = trace.0.lock().expect("trace").len();
        let skipped = tracing::subscriber::with_default(subscriber, || tick(&supervisor));
        assert_eq!(Tick::Skipped, skipped);
        let text =
            String::from_utf8(trace.0.lock().expect("trace")[before..].to_vec()).expect("utf-8");
        assert_eq!(1, text.lines().count(), "{text}");
        assert!(text.contains("skipped a review poll tick"), "{text}");
        assert_eq!(1, supervisor.list().len());
        let id = supervisor.list()[0].id.clone();
        supervisor.stop(&id).await.expect("stopped");
        assert_eq!(Tick::Started, tick(&supervisor));
        let id = supervisor.list()[1].id.clone();
        supervisor.stop(&id).await.expect("stopped");
    }
}
