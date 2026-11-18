# The stall clock

`Provider::HTTP::Streaming::StallClock`, in
`lib/lain/provider/http/streaming/faraday_handlers.rb`. This file is the long-form record
behind that class; the class's own docstring keeps only the invariants a reader has to have
in front of them while editing it.

The clock bounds the silence between body chunks, which tells a stalled stream from a slow one.
A shorter total timeout cannot, because a local model thinking for 6 minutes is a real shape.
The clock arms on the first tick, so prompt evaluation keeps the `request_timeout` budget it has
always had.

## Why the clock is split between a middleware and `on_data`

A Faraday middleware cannot see an inter-chunk gap: by the time its `call` returns, the body is
finished. So the clock is split at the only line where each half is knowable: the middleware
(`Connection::MiddlewareStack::StallProtection`) owns the request's scope, and the `on_data`
proc owns the ticks.

## Why the clock lives in the Faraday request context

`Faraday::Env#stream_response` calls `request.on_data.call(chunk, size, self)` at both its call
sites, so every chunk arrives carrying its own env, and `env.request.context` is the per-request
hash both transports already thread a collaborator through (`retry_attempt` in
`Ollama::Transport`, `wal_frame` in `Anthropic::Transport`). The bytes' own request therefore
answers "whose clock is this chunk's", whoever delivers them.

The clock reached the request context through 2 wrong slots. They are kept here because any
future ambient-storage idea should be read against them.

- A thread variable gave 2 live streams one slot to fight over. Lain streams a parent turn
  and a subagent turn as sibling tasks on 1 reactor thread, so the second watch displaced the
  first, the first's chunks then ticked the second's clock, and the displaced clock (never
  ticked again) fired against a stream that was healthy.
- Fiber storage fixed that and caused a subtler bug: `Fiber[]` is inherited copy-on-write by
  every fiber and thread born under a live watch, so a child held its parent's clock without ever
  having watched it, and presence in the slot proved nothing. That needed an ownership check (a
  clock answers only to the fiber that watched it), and the ownership check made the adapter's
  choice of dispatch fiber a hard dependency.

A request context retires that last assumption: that the Faraday adapter dispatches `on_data` on
the fiber that called it. This holds for `:net_http`, which is every provider's actual adapter,
but `faraday_adapter` is a configuration option. Under fiber storage, an adapter that ran the body
callback on a fiber or a thread of its own answered `Null` on every chunk. Stall protection was
then silently off with a green suite, the worst failure a safety feature can have. It was measured
at 0.4 s of silence against a 0.15 s grace, undetected.

Two smaller points follow. Non-LIFO completion is a non-issue: sibling streams hold different
requests, so no teardown can wipe a sibling's slot, and `#unwatch`'s restore only hands a caller's
own context back exactly as it was found. The invariant `Streaming#flush_stream` depends on, that
a finished watch leaves `Null` behind, is kept by that same restore.

## The stop/fire race

Both deliveries are asynchronous (`Thread#raise` and `Fiber::Scheduler#fiber_interrupt` alike),
so `#fire` queues an interrupt while holding the mutex, and a monitor that expires in the instant
before the block returns is aiming at a request that has already finished. The race is bounded, not eliminated. The shared mutex
guarantees that a fire can only be issued while `@state` is `:waiting`, and `#stop` ends that
state under the same mutex. So every interrupt still in flight when `#stop` returns is one `#stop`
knows about, because it read `:stalled` on the way past. That is the whole disarm, so
nothing needs a token on the exception.

## The 5 places the async raise can land

Four of the 5 are wanted. `#stalled?` short-circuits on the suspension count, written and read
under the same mutex, so the monitor cannot fire while the consumer holds a chunk, which matters
more under a reactor, where the consumer's own code may yield to the event loop mid-chunk.

1. **Blocked in the socket read.** Intended; the stall is real.
2. **Blocked on the mutex in `#suspend`**, which drops the chunk that just arrived. Also correct,
   because the grace had already expired before it landed.
3. **Blocked on the mutex, or on the monitor's join, in `#stop`**, which `#unwatch` discards.
4. **`Delivery::ToFiber#collect`**, which closes the reactor's own hazard. `fiber_interrupt` is
   deferred: the reactor delivers when it next resumes the fiber, and a queued interrupt cannot be
   recalled, so without this place a stream completing on the grace boundary would be interrupted
   in its NEXT tool call or its next turn. A completing stream that knows an interrupt is coming
   therefore spends one turn of the event loop taking delivery of it.
5. **The request's own post-body code** (unwanted), still inside `#watch`'s `yield` after the last
   `#receiving` has resumed. The suspension count does not cover it (it guards only the region a
   chunk is being delivered in), and neither does `#unwatch`, which has not been reached yet. This
   place is not designed away: the clock gets no end-of-body signal, so it cannot
   tell the middleware stack unwinding below `StallProtection` from upstream silence, and it
   charges that tail the same grace it charges a gap.

   The grace bounds it: at the shipped 30 s the tail would have to run silent for 30 s,
   so it has never been observed on a real stream. It is easy to reach deliberately: a
   `Thread.pass` tail took it 140 times in 300 rounds at a twentieth-second grace and 133 at a
   hundredth, in one run, and the rate wanders because it is a race. Do not write a clock
   spec that assumes it away. On the reactor path it is closed anyway: the same tail completed
   300 of 300 under `Delivery::ToFiber`, because `#collect` takes delivery unless the tail reaches
   the event loop first. Closing it needs an end-of-body tick, which changes the scope/tick
   split above and leaves the class itself alone.

Before the delivery became a suspended region, the exception could land anywhere the request
happened to be, the consumer's own code included.

## Still owed

An absent clock at tick time answers `Null` rather than raising, so a request whose middleware
never ran is unprotected forever and silently. Under fiber storage that needed a misconfigured
adapter to reach; on the request context it needs only a stack assembled without
`Connection::MiddlewareStack::StallProtection`. The ambient half of the guard is delivered and the
loud half is not. An unprotected stream with a green suite is the failure this class exists to prevent.
