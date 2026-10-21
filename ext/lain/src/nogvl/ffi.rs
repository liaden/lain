//! The magnus side of `nogvl`, in its own file because `cargo test` cannot
//! compile it and a mutation sweep over it could only report misses.

use super::{Attempts, Cancel, Halted, Job, Outcome, TABLE, flags, held, run, stop};
use magnus::{Error, Ruby};

/// Runs the job `prepare` builds with the GVL released, and answers its value.
///
/// `prepare` copies everything the job needs out of Ruby objects, so the job
/// touches none. It runs once per attempt, so no Rust state is held across
/// `thread_check_ints`, the one call into Ruby between attempts. A kill or a
/// raise leaves through that call as an `Err`; a panic is a `RuntimeError`.
pub fn without_gvl<T, W>(ruby: &Ruby, prepare: impl FnMut() -> Result<W, Error>) -> Result<T, Error>
where
    T: Send + 'static,
    W: FnOnce(&Cancel<'_>) -> Result<T, Halted> + Send + 'static,
{
    without_gvl_when(ruby, true, prepare)
}

/// [`without_gvl`], except that with `release` false the job runs once with
/// the GVL held, under a cancel never raised and without taking a slot. The
/// caller passes false for work too small to be worth a release.
pub fn without_gvl_when<T, W>(
    ruby: &Ruby,
    release: bool,
    mut prepare: impl FnMut() -> Result<W, Error>,
) -> Result<T, Error>
where
    T: Send + 'static,
    W: FnOnce(&Cancel<'_>) -> Result<T, Halted> + Send + 'static,
{
    let mut attempts = Attempts::new(release);
    loop {
        let work = prepare()?;
        let outcome = if attempts.release() {
            released(ruby, work)
        } else {
            held(work)
        };
        match outcome {
            Outcome::Done(answer) => return Ok(answer),
            Outcome::Panicked(message) => {
                return Err(Error::new(ruby.exception_runtime_error(), message));
            }
            Outcome::Halted | Outcome::NotRun => {
                ruby.thread_check_ints()?;
                attempts.returned_quietly();
            }
        }
    }
}

/// `_ruby` is unused but required: a `&Ruby` exists only on a Ruby thread
/// holding the GVL, which is the precondition the SAFETY comment rests on.
fn released<T, W>(_ruby: &Ruby, work: W) -> Outcome<T>
where
    T: Send + 'static,
    W: FnOnce(&Cancel<'_>) -> Result<T, Halted> + Send + 'static,
{
    let Some(claim) = TABLE.claim() else {
        return held(work);
    };
    claim.put(Job::new(work));
    // SAFETY: the `&Ruby` this fn takes witnesses that the calling thread is a
    // Ruby thread holding the GVL, which rb_nogvl requires. `W: Send` keeps
    // every magnus value out of the job (none is `Send`), so nothing runs
    // against Ruby while the GVL is released. Both callbacks are safe fns that
    // read the slot index from the pointer's address and never dereference it;
    // `run` catches every panic, so none unwinds into C; `stop` only stores an
    // atomic, the async-signal safety UBF_ASYNC_SAFE promises. INTR_FAIL makes
    // rb_nogvl skip its own interrupt checks, so no longjmp crosses this frame.
    unsafe {
        rb_sys::rb_nogvl(Some(run), claim.data(), Some(stop), claim.data(), flags());
    }
    claim.outcome().typed()
}
