//! Runs a pure job with the GVL released, so other Ruby threads keep running and
//! a kill, a raise or an Async stop reaches the job through its unblocking
//! function instead of waiting for it to end. A binding calls [`without_gvl`];
//! its job polls [`Cancel::requested`] and gives up with [`Halted`].
//!
//! The `void*` both callbacks get is a slot index into `TABLE`, never a
//! pointer, so `run` and `stop` are safe fns and the one `unsafe` block is the
//! `rb_nogvl` call in `ffi.rs`.
//!
//! A wakeup or a trapped signal fires the unblocking function too, and raises
//! nothing, so a halted job runs again from scratch. `MAX_QUIET_RETURNS` bounds
//! that: past it the job runs with the GVL held, so a stream of wakeups cannot
//! keep it from finishing.

use std::any::Any;
use std::cell::Cell;
use std::ffi::c_void;
use std::mem;
use std::os::raw::c_int;
use std::panic::{self, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, Once, PoisonError};

#[cfg(not(test))]
mod ffi;
#[cfg(not(test))]
pub use ffi::without_gvl;

/// Borrows the slot's flag rather than owning it, so a job cannot outlive the
/// slot it was given or keep a stop request for a later call.
pub struct Cancel<'a> {
    flag: &'a AtomicBool,
}

impl<'a> Cancel<'a> {
    pub(crate) fn watching(flag: &'a AtomicBool) -> Self {
        Self { flag }
    }

    /// One relaxed load, so a hot loop can afford it every few dozen iterations.
    pub fn requested(&self) -> bool {
        self.flag.load(Ordering::Relaxed)
    }
}

/// A unit error rather than a variant of the binding's own error, so a stop can
/// never be mistaken for a refusal the binding would raise.
#[derive(Debug, PartialEq, Eq)]
pub struct Halted;

#[derive(Debug)]
enum Outcome<T> {
    Done(T),
    Halted,
    /// `rb_nogvl` found an interrupt pending and never called the job.
    NotRun,
    Panicked(String),
}

type Answer = Box<dyn Any + Send>;

type Work = dyn FnOnce(&Cancel<'_>) -> Result<Answer, Halted> + Send;

/// The answer's type is erased so one static table serves every binding.
struct Job(Box<Work>);

impl Job {
    fn new<T, W>(work: W) -> Self
    where
        T: Send + 'static,
        W: FnOnce(&Cancel<'_>) -> Result<T, Halted> + Send + 'static,
    {
        Self(Box::new(move |cancel: &Cancel<'_>| {
            work(cancel).map(|answer| Box::new(answer) as Answer)
        }))
    }

    fn answer(self, flag: &AtomicBool) -> Outcome<Answer> {
        match quietly(|| (self.0)(&Cancel::watching(flag))) {
            Ok(Ok(answer)) => Outcome::Done(answer),
            Ok(Err(Halted)) => Outcome::Halted,
            Err(payload) => Outcome::Panicked(panic_message(payload.as_ref())),
        }
    }
}

impl Outcome<Answer> {
    fn typed<T: 'static>(self) -> Outcome<T> {
        match self {
            Outcome::Done(answer) => answer.downcast::<T>().map_or_else(
                |_| Outcome::Panicked("a job answered a type its caller did not ask for".into()),
                |answer| Outcome::Done(*answer),
            ),
            Outcome::Halted => Outcome::Halted,
            Outcome::NotRun => Outcome::NotRun,
            Outcome::Panicked(message) => Outcome::Panicked(message),
        }
    }
}

/// Runs `work` on the calling thread with nothing able to stop it. A job that
/// halts anyway would be run again forever, so that becomes a failure.
fn held<T, W>(work: W) -> Outcome<T>
where
    T: Send + 'static,
    W: FnOnce(&Cancel<'_>) -> Result<T, Halted> + Send + 'static,
{
    match Job::new(work).answer(&AtomicBool::new(false)) {
        Outcome::Halted => Outcome::Panicked("a job halted with no cancel asked for".into()),
        other => other.typed(),
    }
}

enum Slot {
    Empty,
    Pending(Job),
    Done(Outcome<Answer>),
}

/// More calls than this in flight at once run with the GVL held.
const SLOTS: usize = 64;

/// Static because `rb_nogvl` callbacks get only the integer, and a static has
/// no lifetime for a late callback to outlive.
static TABLE: Slots<SLOTS> = Slots::new();

struct Slots<const N: usize> {
    cancel: [AtomicBool; N],
    taken: [AtomicBool; N],
    jobs: [Mutex<Slot>; N],
}

impl<const N: usize> Slots<N> {
    const fn new() -> Self {
        Self {
            cancel: [const { AtomicBool::new(false) }; N],
            taken: [const { AtomicBool::new(false) }; N],
            jobs: [const { Mutex::new(Slot::Empty) }; N],
        }
    }

    fn claim(&self) -> Option<Claim<'_, N>> {
        let index = (0..N).find(|&index| {
            self.taken[index]
                .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
                .is_ok()
        })?;
        // When the main thread is the only living thread, Ruby's signal handler
        // reads the unblocking function without a lock, so a stop meant for this
        // slot's last call can land after this store and halt the new call once.
        // That costs 1 quiet restart; the flag is a static, so it is not unsafe.
        self.cancel[index].store(false, Ordering::Relaxed);
        Some(Claim { table: self, index })
    }

    /// A slot is only ever locked by its claimer and by `run`, never while a
    /// job runs, so a poisoned lock holds no half-written state worth refusing.
    fn slot(&self, index: usize) -> MutexGuard<'_, Slot> {
        self.jobs[index]
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    fn run_at(&self, index: usize) {
        let Some(flag) = self.cancel.get(index) else {
            return;
        };
        let taken = mem::replace(&mut *self.slot(index), Slot::Empty);
        let restored = match taken {
            Slot::Pending(job) => Slot::Done(job.answer(flag)),
            other => other,
        };
        *self.slot(index) = restored;
    }

    fn halt_at(&self, index: usize) {
        if let Some(flag) = self.cancel.get(index) {
            flag.store(true, Ordering::Relaxed);
        }
    }
}

/// Held until dropped, which empties and frees the slot on every path.
struct Claim<'a, const N: usize> {
    table: &'a Slots<N>,
    index: usize,
}

impl<const N: usize> Claim<'_, N> {
    fn put(&self, job: Job) {
        *self.table.slot(self.index) = Slot::Pending(job);
    }

    /// The slot's index in the shape `rb_nogvl` passes to its callbacks.
    fn data(&self) -> *mut c_void {
        std::ptr::without_provenance_mut(self.index)
    }

    fn outcome(&self) -> Outcome<Answer> {
        match mem::replace(&mut *self.table.slot(self.index), Slot::Empty) {
            Slot::Done(outcome) => outcome,
            Slot::Empty | Slot::Pending(_) => Outcome::NotRun,
        }
    }
}

impl<const N: usize> Drop for Claim<'_, N> {
    fn drop(&mut self) {
        *self.table.slot(self.index) = Slot::Empty;
        self.table.taken[self.index].store(false, Ordering::Release);
    }
}

/// `rb_nogvl`'s function. Any index past the table does nothing.
extern "C" fn run(data: *mut c_void) -> *mut c_void {
    TABLE.run_at(data.addr());
    std::ptr::null_mut()
}

/// `rb_nogvl`'s unblocking function. It may run inside a signal handler, so it
/// only stores an atomic: no lock, no allocation.
extern "C" fn stop(data: *mut c_void) {
    TABLE.halt_at(data.addr());
}

/// Each quiet return can waste up to a whole search, and in the app the only
/// source is a trapped signal on the main thread, which comes in short bursts
/// (a terminal resize). 4 rides out such a burst and caps the waste at 4 partial
/// searches before the call gives up being cancellable.
const MAX_QUIET_RETURNS: usize = 4;

#[derive(Default)]
struct Attempts {
    quiet: usize,
}

impl Attempts {
    fn release(&self) -> bool {
        self.quiet < MAX_QUIET_RETURNS
    }

    fn returned_quietly(&mut self) {
        self.quiet += 1;
    }
}

/// INTR_FAIL so `rb_nogvl` runs no interrupt check of its own, which could
/// longjmp through Rust frames; `without_gvl` checks with `thread_check_ints`.
/// Summed rather than or-ed, since the 2 are distinct bits and a sum gives a
/// mutation sweep no equivalent operator to swap in.
fn flags() -> c_int {
    let asked = [rb_sys::RB_NOGVL_INTR_FAIL, rb_sys::RB_NOGVL_UBF_ASYNC_SAFE];
    asked.iter().sum::<u32>() as c_int
}

thread_local! {
    static QUIET: Cell<bool> = const { Cell::new(false) };
}

static QUIET_HOOK: Once = Once::new();

/// Wraps the current panic hook so it stays silent for a panic `quietly`
/// catches: that panic becomes a Ruby exception, and a line on stderr would
/// scribble over the cockpit.
fn install_quiet_hook() {
    let previous = panic::take_hook();
    panic::set_hook(Box::new(move |info| {
        if !QUIET.try_with(Cell::get).unwrap_or(false) {
            previous(info);
        }
    }));
}

/// The job is dropped on a panic and nothing reads its state afterwards, which
/// is why asserting unwind safety holds.
fn quietly<T>(work: impl FnOnce() -> T) -> std::thread::Result<T> {
    QUIET_HOOK.call_once(install_quiet_hook);
    let was = QUIET.try_with(|quiet| quiet.replace(true)).unwrap_or(false);
    let result = panic::catch_unwind(AssertUnwindSafe(work));
    QUIET.try_with(|quiet| quiet.set(was)).ok();
    result
}

fn panic_message(payload: &(dyn Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|text| (*text).to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "a panic with no message".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;

    impl<const N: usize> Claim<'_, N> {
        fn halt(&self) {
            self.table.halt_at(self.index);
        }

        fn run(&self) {
            self.table.run_at(self.index);
        }
    }

    fn answers(value: u32) -> Job {
        Job::new(move |_: &Cancel<'_>| Ok(value))
    }

    fn halts_when_asked() -> Job {
        Job::new(|cancel: &Cancel<'_>| {
            if cancel.requested() {
                Err(Halted)
            } else {
                Ok(1_u32)
            }
        })
    }

    const PANIC_MARKER: &str = "nogvl test panic marker";

    #[test]
    fn a_job_run_through_its_slot_answers_its_value() {
        let table: Slots<4> = Slots::new();
        let claim = table.claim().unwrap();
        claim.put(answers(42));
        claim.run();
        assert!(matches!(claim.outcome().typed::<u32>(), Outcome::Done(42)));
    }

    #[test]
    fn a_slot_whose_job_never_ran_reports_not_run() {
        let table: Slots<4> = Slots::new();
        let claim = table.claim().unwrap();
        claim.put(answers(1));
        assert!(matches!(claim.outcome(), Outcome::NotRun));
    }

    #[test]
    fn the_unblocking_function_halts_only_its_own_slot() {
        let table: Slots<4> = Slots::new();
        let (mine, other) = (table.claim().unwrap(), table.claim().unwrap());
        mine.put(halts_when_asked());
        other.put(halts_when_asked());
        mine.halt();
        mine.run();
        other.run();
        assert!(matches!(mine.outcome(), Outcome::Halted));
        assert!(matches!(other.outcome().typed::<u32>(), Outcome::Done(1)));
    }

    #[test]
    fn a_new_claim_starts_with_its_flag_lowered() {
        let table: Slots<1> = Slots::new();
        let first = table.claim().unwrap();
        first.halt();
        drop(first);

        let again = table.claim().unwrap();
        again.put(halts_when_asked());
        again.run();
        assert!(matches!(again.outcome().typed::<u32>(), Outcome::Done(1)));
    }

    #[test]
    fn a_panicking_job_becomes_an_outcome_carrying_its_message() {
        let table: Slots<1> = Slots::new();
        let claim = table.claim().unwrap();
        claim.put(Job::new(|_: &Cancel<'_>| -> Result<u32, Halted> {
            panic!("{}", PANIC_MARKER)
        }));
        claim.run();
        assert!(
            matches!(claim.outcome(), Outcome::Panicked(message) if message.contains(PANIC_MARKER))
        );
    }

    #[test]
    fn a_panic_carrying_a_string_keeps_its_message() {
        let payload: Box<dyn Any + Send> = Box::new(String::from("owned message"));
        assert_eq!(panic_message(payload.as_ref()), "owned message");
        let payload: Box<dyn Any + Send> = Box::new(7_u8);
        assert_eq!(panic_message(payload.as_ref()), "a panic with no message");
    }

    #[test]
    fn a_poisoned_slot_still_runs_and_answers() {
        let table: &'static Slots<1> = Box::leak(Box::new(Slots::new()));
        let claim = table.claim().unwrap();
        let poisoner = std::thread::spawn(move || {
            let _held = table.jobs[0].lock().unwrap();
            panic!("poison the slot");
        });
        assert!(poisoner.join().is_err());
        assert!(table.jobs[0].is_poisoned());

        claim.put(answers(3));
        claim.run();
        assert!(matches!(claim.outcome().typed::<u32>(), Outcome::Done(3)));
    }

    #[test]
    fn the_callbacks_reach_the_static_table() {
        let claim = TABLE.claim().unwrap();
        claim.put(halts_when_asked());
        stop(claim.data());
        assert!(run(claim.data()).is_null());
        assert!(matches!(claim.outcome(), Outcome::Halted));
    }

    #[test]
    fn callbacks_given_an_index_past_the_table_do_nothing() {
        stop(std::ptr::without_provenance_mut(SLOTS));
        assert!(run(std::ptr::without_provenance_mut(SLOTS + 7)).is_null());
    }

    #[test]
    fn running_a_slot_twice_keeps_its_first_outcome() {
        let table: Slots<1> = Slots::new();
        let claim = table.claim().unwrap();
        claim.put(answers(5));
        claim.run();
        claim.run();
        assert!(matches!(claim.outcome().typed::<u32>(), Outcome::Done(5)));
    }

    #[test]
    fn a_full_table_refuses_a_claim_until_one_is_released() {
        let table: Slots<2> = Slots::new();
        let first = table.claim().unwrap();
        let second = table.claim().unwrap();
        assert_ne!(first.data(), second.data());
        assert!(table.claim().is_none());
        drop(first);
        assert!(table.claim().is_some());
    }

    #[test]
    fn a_released_claim_leaves_its_slot_empty() {
        let table: Slots<1> = Slots::new();
        let claim = table.claim().unwrap();
        claim.put(answers(1));
        claim.run();
        drop(claim);
        assert!(matches!(*table.slot(0), Slot::Empty));
    }

    #[test]
    fn an_answer_of_another_type_is_a_failure_not_a_panic() {
        let table: Slots<1> = Slots::new();
        let claim = table.claim().unwrap();
        claim.put(answers(1));
        claim.run();
        assert!(matches!(
            claim.outcome().typed::<String>(),
            Outcome::Panicked(_)
        ));
    }

    #[test]
    fn held_runs_the_job_to_its_answer() {
        assert!(matches!(held(|_: &Cancel<'_>| Ok(9_u32)), Outcome::Done(9)));
    }

    #[test]
    fn a_held_job_that_halts_unasked_fails_rather_than_retrying() {
        let halted = held(|_: &Cancel<'_>| -> Result<u32, Halted> { Err(Halted) });
        assert!(matches!(halted, Outcome::Panicked(_)));
    }

    #[test]
    fn attempts_release_the_lock_until_the_bound_then_hold_it() {
        let mut attempts = Attempts::default();
        for _ in 0..MAX_QUIET_RETURNS {
            assert!(attempts.release());
            attempts.returned_quietly();
        }
        assert!(!attempts.release());
    }

    static HOOK_SAW_MARKER: AtomicUsize = AtomicUsize::new(0);

    #[test]
    fn a_quiet_panic_skips_the_previous_hook_and_a_loud_one_reaches_it() {
        let quiet_marker = "nogvl quiet hook marker";
        let loud_marker = "nogvl loud hook marker";
        let previous = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            let text = info.to_string();
            if text.contains(quiet_marker) || text.contains(loud_marker) {
                HOOK_SAW_MARKER.fetch_add(1, Ordering::SeqCst);
            } else {
                previous(info);
            }
        }));
        // Another test may have installed the quiet hook first; wrap this one too.
        install_quiet_hook();
        assert!(quietly(|| panic!("{quiet_marker}")).is_err());
        assert_eq!(HOOK_SAW_MARKER.load(Ordering::SeqCst), 0);

        assert!(panic::catch_unwind(|| panic!("{loud_marker}")).is_err());
        assert_eq!(HOOK_SAW_MARKER.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn rb_nogvl_is_asked_to_skip_its_interrupt_checks_and_told_the_ubf_is_signal_safe() {
        let flags = flags() as u32;
        assert_ne!(flags & rb_sys::RB_NOGVL_INTR_FAIL, 0);
        assert_ne!(flags & rb_sys::RB_NOGVL_UBF_ASYNC_SAFE, 0);
        assert_eq!(flags & rb_sys::RB_NOGVL_OFFLOAD_SAFE, 0);
        assert_eq!(
            flags,
            rb_sys::RB_NOGVL_INTR_FAIL | rb_sys::RB_NOGVL_UBF_ASYNC_SAFE
        );
    }

    #[test]
    fn quietly_answers_what_its_closure_returns() {
        assert_eq!(quietly(|| 6 * 7).ok(), Some(42));
    }
}
