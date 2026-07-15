# Concurrency: deliberately deferred

At M1 the agent loop is strictly sequential — one request out, one response back, one tool
call resolved before the next is issued. There is no concurrency to get wrong yet, and no
model has been chosen. Parallel tools and async subagents land at **M5**, and the model gets
picked then, **with the bench in hand** rather than in advance of it. This document exists so
that decision starts from the reasoning already done, not from a blank page.

## Why this is worth thinking about before it's needed

Lain's workload is IO-bound almost everywhere: Anthropic API calls (network round trips
measured in seconds, dominated by model latency, not bandwidth), subprocess IO (`bash` tool
output arriving as a trickle over a pipe), and file reads (`read_file`, `list_files`, cassette
and journal IO). None of that consumes CPU while it waits. The CPU-bound remainder — canonical
serialization, Merkle DAG hashing, structural diffing over a Timeline — is earmarked for Rust
(`ext/lain`), not for a concurrency model in Ruby. So the question this document answers is
narrowly "how should Ruby wait on many things at once," not "how should Ruby compute many
things at once."

Three candidates exist in Ruby today: threads, fibers (via the `async` gem's fiber scheduler),
and Ractors. Each is examined below against the actual constraint that will bind first:
**cancellation**. The loop is bounded by `max_iterations`, by cost ceilings, and by user
interrupts (Ctrl-C mid-turn). Whichever model is chosen has to be able to stop in-flight work
cleanly, not just start it in parallel.

## Threads: adequate for IO, unsafe for cancellation

Ruby threads release the GVL around blocking IO, so N threads waiting on N HTTP requests or N
subprocess pipes cost nothing while blocked — this is the textbook case threads are good at,
and it would work here. The problem is stopping them.

`Thread#kill` is not safe cancellation. It can fire in the middle of anything: inside a
`Mutex#synchronize` block (leaving the mutex held, poisoning every future acquirer), or between
the `begin` and the `ensure` of a resource-cleanup block (skipping the cleanup entirely, since
`ensure` only runs if the exception delivery lands at a point where Ruby can still reach it —
and `Thread#kill` can interrupt the `ensure` itself). For a loop whose entire safety story rests
on being able to stop cleanly at an iteration ceiling, a cost ceiling, or a user interrupt,
cancellation is not a nice-to-have; it is load-bearing, and `Thread#kill` fails it.

**Fallback plan, if threads are chosen anyway:** `concurrent-ruby` gives higher-level
primitives (thread pools, futures, a `Concurrent::Map`) that at least centralize the unsafe
parts instead of hand-rolling `Thread.new`/`Thread#kill` at every call site. **Never
`concurrent-ruby-edge`** — its `Channel`, `Actor`, and `Cancellation` abstractions sit behind an
explicitly unstable API, and depending on it would be trading one unsafety for another with a
worse changelog.

## Fibers (`async`): the likely answer

The `async` gem's fiber scheduler is the most promising fit, for two reasons that follow
directly from being single-threaded.

**No lock is needed.** `Store` and `Timeline` are read from and written to inside the same OS
thread; there is no interleaving to guard against, because a fiber only yields at an explicit
IO boundary the scheduler controls. The `Monitor` `Store` currently holds (see below) would be
provably redundant, not just empirically safe, under this model.

**Cancellation is real.** `Async::Task#stop` is *structured* cancellation: it raises inside the
task at a scheduler-controlled yield point, and the task tree cancels together. This is the
property threads cannot offer, and it maps directly onto `max_iterations`, cost ceilings, and
user interrupts — the exact three cancellation triggers this loop needs.

**The blocker, stated plainly, because it has to be verified rather than assumed:**
`Mixlib::ShellOut` — the gem the `bash` tool is built on — blocks on `IO.select`
(`unix.rb:282`) and `Process.waitpid2` (`unix.rb:406`) when it waits for a child process. Ruby's
fiber scheduler only defers to `async`'s reactor if the scheduler hooks the specific blocking
call being made. If `Async` does not hook `io_select` (and `waitpid2` in particular is a
notoriously hard syscall to make fiber-aware, since it blocks in a way `IO.select` cannot
observe), then a single `bash` tool call blocks the one OS thread the whole reactor runs on —
stalling every other fiber, *including the fiber draining the Channel to the frontend*. A hung
`bash` call would freeze the UI, not just the tool call.

This has to be spiked before fibers are chosen, not assumed. **Fallback, if the spike shows
`Mixlib::ShellOut` does not cooperate:** offload shellouts to a thread (a thread pool of one
per in-flight `bash` call is fine, since threads are adequate for IO-waiting in isolation) and
keep everything else — the loop, the Timeline, the Channel drain — on fibers. That keeps the
cancellation and no-lock properties everywhere except the one call that cannot currently honor
them.

## Ractors: no, not yet

Ractors are still explicitly experimental on Ruby 4.0.5 (the interpreter prints a warning on
`Ractor.new`), and more decisively: the dependency graph this project already has — the
`anthropic` SDK, `mixlib-shellout`, the magnus FFI boundary into `ext/lain` — is not
Ractor-safe. None of those were written with Ractor's shareable-object rules in mind, and
retrofitting them is not this project's to do.

What *is* already true, and already spec'd, is that `Ractor.shareable?(turn)` returns `true` —
`Turn` and the other value objects in the Timeline are deeply frozen, with no reachable mutable
state. That spec exists as a mechanical guard on immutability (it caught a real bug: `@role`
via `Symbol#to_s` and `@digest` via string interpolation both silently produced mutable Strings
inside a supposedly-frozen object). It is not a promise that Ractors will parallelize anything.
The data model is ready; the ecosystem around it is not.

## `Store`'s `Monitor`, and why it stays for now

`Store` is guarded by a `Monitor` today. That lock is correct under a thread model (it prevents
two threads racing on the underlying Hash) and it is a no-op cost under the current strictly
sequential loop — a single fiber or a single thread taking an uncontended lock is not
measurably slower than no lock at all. So it stays.

The temptation is to swap it for `Concurrent::Map` now, on the theory that a lock-free
structure is strictly better. It would not be: `Concurrent::Map` is a bet that threads are the
eventual model, made **before** the M5 measurement that would justify that bet. If fibers turn
out to be the answer, `Concurrent::Map` buys nothing (a single-fiber reactor needs no
concurrent structure at all) and costs a dependency and an API mismatch for no reason. The
`Monitor` is the right amount of engineering for what is known today: keep the thing that is
correct under every candidate model, and change it only once the model is chosen.

`Channel` follows the same logic: it stays a thin wrapper over the C-implemented `SizedQueue`,
which is already thread-safe, already blocking in the way a producer/consumer queue should be,
and requires no bet on threads-vs-fibers to justify keeping it exactly as it is.

## Two consumers, two policies

When the Journal (M2) and the frontend-facing render loop both existed as consumers of the same
event stream, they were originally given the same delivery policy: blocking `push`, so no event
is ever silently dropped. That policy is correct for the Journal — it is the experiment record;
losing an event corrupts the run — but it is wrong for the render loop, which may freely drop
frames (a terminal repaint that misses an intermediate token is not a bug; a terminal repaint
that *blocks the agent loop* because the frontend fell behind is one).

Conflating the two consumers under one policy forced the stricter requirement onto the consumer
that did not need it. Concretely: if the render loop's queue filled up while the frontend was
slow, a blocking `push` from the drain thread would stall — and if that drain thread had also
just raised an exception mid-`push` (holding whatever the queue's internal lock was), the
result is a genuine deadlock, not a slow frame. The fix is to split delivery policy by consumer
rather than by mechanism: the Journal writes **synchronously**, under its own mutex, to its own
fd — never queued, never dropped. The `Channel` feeding the frontend becomes **drop-oldest**,
with a dropped-count marker so the UI can say "N events elided" instead of silently losing them
and pretending nothing happened.

**Verified trap, worth stating because it looked wrong at first:** `SizedQueue#pop(true)`
(non-blocking pop) raises `ThreadError` on an empty queue **regardless of whether the queue has
been closed**. The natural assumption — that a closed, empty queue's non-blocking pop would
return `nil` or raise a distinct "closed" error — is wrong. Any drain loop that tries to
distinguish "empty, keep polling" from "closed, stop polling" via the exception alone needs to
check `#closed?` explicitly; the exception class does not do that work for you.

## Where each model sits on the topology

Referring to the [topology diagram in the README](../README.md#topology):

- **Sequential (today, M1).** `lain` is one thread. Every arrow on the diagram — the HTTPS call
  to `api.anthropic.com`, the in-process FFI call into `ext/lain`, eventually the msgpack-RPC
  calls to `nvim` and `lain-core` — happens one at a time, in the loop's own call stack. Nothing
  changes about the diagram; only the loop's internals are single-shot today.
- **Threads.** Multiple `bash`/`read_file`/`grep` tool calls in one turn would each get a thread;
  the HTTPS arrow to Anthropic and any parallel subagent's own loop would be separate threads
  too. `Store`'s `Monitor` stays load-bearing. The frontend-drain arrow (Channel → TTY) becomes
  one more thread among several, which is exactly the shape that motivated splitting Journal and
  Channel delivery policy above.
- **Fibers.** The same fan-out (parallel tool calls, async subagents) happens as fibers inside
  the single OS thread `lain` already runs on. The diagram's arrows are unchanged; what changes
  is that `Store`'s lock becomes provably unnecessary rather than merely cheap, and cancellation
  of an in-flight subagent (a new dotted-line edge on the data-flow diagram, spawned with a
  fresh Timeline root) becomes `Async::Task#stop` instead of a thread being asked nicely to
  notice a flag. The one open risk is the `bash` tool's arrow into `Mixlib::ShellOut` — if the
  spike shows it does not cooperate with the fiber scheduler, that single arrow gets offloaded
  to a thread while everything else on the diagram stays on fibers.
- **Ractors.** Not on the diagram at all today, and not a near-term plan. If the ecosystem ever
  catches up, the natural fit would be `ext/lain`'s in-process FFI boundary — Rust's ownership
  model already gives it the immutability Ractors require, and `Ractor.shareable?(turn)` is
  already true. Nothing else in the dependency graph is ready.

## Summary

No model is committed. The loop stays sequential through M1 and M1b. The concurrency model is
chosen at M5 — after parallel tools and async subagents are the actual feature being built —
using the bench itself to compare candidates rather than picking one on paper. The one
prerequisite fact-finding step, the `Mixlib::ShellOut`/fiber-scheduler spike, is answered below.

## 2026-07-13 — spike result: `Mixlib::ShellOut` cooperates (5-0.1)

**Pinned versions:** ruby 4.0.5 (`+PRISM`), `async` 2.42.0, `mixlib-shellout` 3.4.10. Spike
spec: `spec/spikes/async_shellout_spike_spec.rb`, run via `LAIN_SPIKE=1 bundle exec rspec
spec/spikes`.

**Method:** inside one `Async` reactor, one task runs `Mixlib::ShellOut.new("sleep 1")
.run_command`; a second task ticks a monotonic timestamp into an array every 50ms, 30 times.
If the reactor's one OS thread is stalled inside `Mixlib::ShellOut`'s blocking calls, the
ticker records no progress for the ~1s the shellout is in flight; if the scheduler is honoring
those calls as yield points, the ticker keeps ticking at ~50ms throughout. **Scope of what was
measured:** the child is idle (`sleep 1`) — this exercises exactly the `IO.select` /
`Process.waitpid2` cooperation path that was the named risk, but *not* a stdout-flooding child
(chunked `read_nonblock` under pipe-buffer pressure) or a CPU-heavy one. The mechanism argument
below plausibly generalizes to those regimes; it was not measured here.

**Result:** cooperative, not starved. Across 8 runs (5 in a standalone prototype, 3 more after
the spec was finalized), the ticker recorded ~20 of its ~20 expected ticks *inside* the
shellout's window every time, with inter-tick gaps holding at ~50ms (max observed 51.4ms — no
gap resembling the full ~1s shellout duration). Sample from one run's raw inter-tick deltas, in
ms: `[50.4, 50.1, 50.1, 51.3, 50.2, 50.1, 50.1, 50.2, ...]` — no stall.

**Why:** `Async::Scheduler` (2.42.0) implements both `io_select` and `process_wait` hooks (`ruby
-e 'require "async"; p Async::Scheduler.instance_methods.grep(/select|wait/)'` →
`[:io_select, :io_wait, :process_wait, :wait]`). Ruby 4.0.5's core `IO.select` and
`Process.waitpid2` call into those hooks when a Fiber scheduler is set for the current thread,
so `Mixlib::ShellOut`'s `attempt_buffer_read` (`unix.rb:282`, a 10ms-timeout `IO.select` loop)
and `reap` (`unix.rb:406`, a blocking `Process.waitpid2`) both yield the OS thread back to the
reactor rather than holding it. This was the open risk named in the "Fibers" section above, and
it resolved in fibers' favor without any code change to `Mixlib::ShellOut` or `Tools::Bash`.

**Decision for stream 5-0:** no shellout-to-thread offload is needed. When 5-0.3 adopts a
concurrency model, `bash` tool calls can run as ordinary `Async` tasks alongside everything
else on fibers — the single open risk that would have forced a split model (native fiber
cooperation for everything *except* shellouts, offloaded to a thread pool) did not materialize.
This is stated as a recommendation for 5-0.3, not an adoption: this card does not touch
`Tools::Bash` or wire `async` into the agent loop. And it carries the scope caveat above:
the idle-child measurement verifies the select/waitpid cooperation path, so 5-0.3 should
re-verify under a stdout-flooding child before treating thread-offload as unnecessary in
that regime too.

**Stability note:** the result held identically across every run in both the standalone
prototype and the committed spec, with no observed flakiness — the escalation trigger for a
nondeterministic result (stop and report rather than commit) did not fire.

## 2026-07-15 — spike result: effects via Fiber vs handler objects (5-0.2)

**Pinned versions:** ruby 4.0.5 (`+PRISM`). Spike spec:
`spec/spikes/effects_fiber_spike_spec.rb`, run via `LAIN_SPIKE=1 bundle exec rspec
spec/spikes`. This answers the plan's open question ("Effects via `Fiber` vs plain handler
objects. Fibers make multi-shot resumption (speculative branching) natural but wreck stack
traces when a tool raises. The `Middleware` API is identical either way. Prototype both.") —
both halves of that claim are measured below, not assumed.

**Method:** two effect interpreters, both adapted into the exact shape
`Lain::Effect::Handler#to_app` already exposes (an `env -> env` lambda writing `:result`), driven
through the real `Lain::Middleware::Stack#call(env, &app)` boundary — not a lookalike API, the
literal one — with one real pass-through member (`Middleware::Identity`) composed into the
Stack, so the equivalence is proven through an actual composed chain link rather than the
zero-middleware fold. `Effect::Handler::Mock` stands in for "the existing handler-object interpreter"
rather than `Live`, because `Live`'s correctness-gate-3 rescue (`StandardError` →
`Tool::Result.error`) converts a raise into a message-only `Result` before either interpreter's
own calling convention could be compared — that conversion is doing its own job, not answering
this question. The fiber prototype (`Spikes::FiberEffectInterpreter` in the spec) hands the same
resolver to `Fiber.new { resolver.call(effect, context) }.resume` — the resolver's own code runs
*inside* the fiber's call stack, mirroring where a tool's code will actually execute once 5-0.3
hosts tool dispatch on `Async::Task` fibers (per 5-0.1 above), not a fake reactor invented for
this spike.

**Result 1 — equivalence holds.** Both interpreters, given the identical resolver and the
identical `Effect::ToolCall`, produce the identical `Tool::Result` through the identical
`Middleware::Stack#call(env, &app)` call. No API divergence was needed to make the fiber
prototype fit — `Middleware`'s monoid group is untouched by this question, because `to_app`'s
output is the *terminal app* a `Stack` calls, not a `Composable` member of the stack itself; the
escalation trigger for a broken monoid law did not fire.

**Result 2 — the fiber trace is measurably wrecked.** Both traces below are recorded verbatim
from the same resolver raising `"kaboom from tool"`, run through each interpreter's real
production/prototype code paths:

```
HANDLER-OBJECT (Handler::Mock) backtrace:
  capture_traces.rb:22:in 'block in <main>'
  lib/lain/effect/handler/mock.rb:42:in 'Lain::Effect::Handler::Mock#canned_for'
  lib/lain/effect/handler/mock.rb:36:in 'Lain::Effect::Handler::Mock#perform'
  lib/lain/effect/handler.rb:35:in 'Lain::Effect::Handler#call'
  lib/lain/effect/handler.rb:53:in 'block in Lain::Effect::Handler#to_app'
  lib/lain/middleware.rb:140:in 'Lain::Middleware::Stack#call'
  capture_traces.rb:32:in 'Object#run_through_stack'
  capture_traces.rb:36:in 'Object#capture_backtrace'
  capture_traces.rb:42:in '<main>'

FIBER (FiberEffectInterpreter) backtrace:
  capture_traces.rb:22:in 'block in <main>'
  capture_traces.rb:16:in 'block in Spikes::FiberEffectInterpreter#run'
```

The handler-object trace is one continuous Ruby call stack, so it reaches all the way out to
`<main>` — every frame between the raise and the top of the process is visible, including
`Middleware::Stack#call` and the driving code. The fiber trace stops at two frames: the raise
site and the `Fiber.new` block itself. `Middleware::Stack#call`, `to_app`, and everything that
called `.resume` are invisible — not because `resume` fails to re-raise (it does, correctly, at
the call site), but because `Exception#backtrace` is captured once, at raise time, by walking
*only* the stack the currently-running fiber owns. A `Fiber` has an independent call stack by
design; the resuming caller's frames were never part of it. This is exactly the "wreck stack
traces" half of the open question, now measured rather than guessed at.

**Result 3 — "multi-shot resumption" does not describe Ruby's `Fiber`.** A direct check —
resume a fiber to completion, then resume it again — raises `FiberError: attempt to resume a
terminated fiber` every time. Ruby's `Fiber` is a *single-shot* continuation: once resumed past
a suspend point (or to completion) there is no operation that rewinds it and resumes the same
suspended point again with a different injected value. The plan's open question hoped fibers
would make multi-shot resumption "natural" for speculative branching (3c-5.6); that hope does
not survive contact with the primitive. What *is* already true, and already the mechanism
3c-5.6 is specced to build on, is `Timeline#fork` — O(1), content-addressed, at the **data**
layer. Branching a trajectory into N speculative continuations was never going to be a property
of whichever object interprets one `Effect`; it is a property of the Merkle DAG the loop
appends to. Fiber-vs-handler-object is a **control**-layer choice; speculative branching is a
**data**-layer one, and the two do not bind to each other the way the open question implied.

**Recommendation, with reasons:**

1. **Keep `Effect::Handler`'s decorator chain-of-responsibility** (`Live`/`Gate`/`Mock`/`Recorded`)
   as the effect-interpretation architecture. Do not rebuild it as a `Fiber.yield`/`resume`
   coroutine dispatcher. Equivalence is exact (Result 1), so there is no behavioral gain to
   trade against the cost in Result 2 — and there is a cost Result 2 does not even fully
   capture: a decorator chain can only return or raise, while a hand-rolled coroutine
   introduces a new failure mode neither has today — a driver that forgets to `.resume` a
   fiber leaves it suspended forever, silently, rather than failing loudly.
2. **3c-5.6 (speculative branching) should build directly on `Timeline#fork`**, independent of
   whatever object is interpreting a single `Effect` at the time. Nothing about Fiber
   adoption is a prerequisite for it, per Result 3.
3. **This does not reopen or contradict 5-0.1.** Fibers remain the likely answer for *IO
   concurrency* — running several tool dispatches as parallel `Async::Task`s so one slow
   `bash` call does not stall the reactor — for the reason 5-0.1 measured. That adoption sits
   **above** `Effect::Handler#call`: 5-0.3 should wrap the *existing*, unchanged handler
   chain's dispatch in `task.async { handler.call(effect, context) }` at the
   `Agent::ToolRunner`/`Middleware` boundary, not reinterpret the handler chain itself as
   fiber-yield choreography. Handler objects stay plain, synchronous Ruby, unaware they are
   running inside a fiber — which keeps gate 3's rescue doing exactly the job it does today.
   Note honestly: once tool dispatch *does* run inside an `Async::Task` fiber for concurrency,
   an unhandled bug that somehow crosses gate 3 will see the same truncated-backtrace cost
   measured here — that is an inherent cost of hosting code on any fiber, not a cost specific
   to choosing "effects via Fiber" as the *interpretation* style, and 5-0.3 should go in with
   that cost named rather than rediscovered.
