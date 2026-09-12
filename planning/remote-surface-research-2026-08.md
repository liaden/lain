# The remote surface: research

> ⚠️ **LLM-generated synthesis** (Claude, 2026-08-26). Provenance is mixed, so it is marked
> per class:
> - **Repo reads.** Every `file:line` below comes from a read of the working tree on
>   2026-08-26, branch `survey/dogfood-2026-08-25`, at `64cf02cb`. Quoted comments are
>   verbatim.
> - **Not verified here.** Every claim about Tailscale, Android, Dioxus, and battery or
>   wake behaviour. No spike was run, no APK was built, no socket was opened. These come
>   from prior knowledge, and §8 lists them so a reader can tell them apart from the
>   repo reads without checking each one.
> - **Inferred.** The tiering in §5, the slices in §10, and every reading of what a repo
>   fact means for this design. Those are Claude's. §7 records the two places Joel ruled,
>   in his words.
>
> Nothing here has been built. §6 is where the thinking sits, not a plan.

---

## 1. The question, as asked

Joel, 2026-08-26, opening:

> I would like to create a sideloaded android app using rust (similar to ../belle-curves and
> ../pitchcraft) so that I could remotely be able to approve requests when I am not at my
> desktop. My idea here is that I have tailscale so I should be able to safely/securely do
> communication directly between the two parts even if I am at the park with the kids.
>
> Lets look at our ROADMAP.md and the state of the code and see how well we see this fitting
> into our architecture and how we would extend our architecture if we choose to pursue this
> path.

Then:

> I think that the automode does need to work with the remote approval approach right?

And on the lost-device risk:

> On the lost phone: it doesn't happen often, and I could forcibly eject it from my tailscale
> network when it happens.

Then, widening the scope:

> Before we get to the doc, I want us to discuss the app's usage beyond just approval. It might
> be nice for us to longer term give visibility into what is happening when the dev is remote
> such as allowing teh user to "chat remotely" and be able to see the history of things or
> where things are at. How does that affect our perspective on things?

That last message is the one that settles the shape. An approval remote and a remote frontend
want different wires, and building the first without deciding the second is how you get the
wrong one. §6.2.

---

## 2. What lain already has

Most of the local half exists. Read of the repo on 2026-08-26.

### 2.1 The approval queue is already multi-surface

`Approval::Queue` (`lib/lain/approval/queue.rb`, 384 lines) was built for N surfaces racing over
one parked set, and the doctrine is written down in the file. `Pending#decide`
(`queue.rb:184`) is single-shot with first-answer-wins, and its comment says two surfaces
racing over one pending is "normal operation, so the loser's answer is a quiet no-op here".
`#each` (`queue.rb:288`) exposes the parked list to any observer without draining the arrival
queue that the one consuming surface uses.

`decide(verdict, surface:)` takes a free String. A remote decision can journal as
`"phone:<node>"` with no change to the queue, to `Effect::Handler::Gate`, or to
`Approval::Escalation`. Attribution is free.

Five surfaces can watch one queue today (`lib/lain/cli/repl/approval_surfaces.rb`): the TTY
prompt, the desktop notifier, the editor's list, and two opt-in LLM oracles. `#watch`
(`approval_surfaces.rb:104`) spawns one fiber per live surface and hands the set back for the
caller's `ensure` to stop.

The bound is `DEFAULT_TIMEOUT = 300` (`queue.rb:40`), and an expired window is a denial signed
`TIMEOUT_SURFACE` (`queue.rb:30`). Its comment: "Generous because the answerer is a human at a
terminal; the point is a bound, not a hurry."

### 2.2 `Lain::Notify` is the working template for an out-of-band surface

> **DELETED 2026-09-12.** `lib/lain/notify.rb` no longer exists: a reachability audit found the
> desktop surface unreached by anything but its own wiring, and simplify-03 removed it along with
> `--desktop`, `LAIN_DESKTOP` and `PaneCommand::CONSENT_ENV`. **This section is kept as a design
> record, not as a pointer to live code** — every line and file reference below is to
> `main` before that commit, and `git log -- lib/lain/notify.rb` is where the template now lives.
> Nothing else about this research changes: the four problems listed here are still the four a
> remote surface has to solve, and the queue-side facts in §2.1 are unaffected. A phone surface
> built from this section must now port the solutions rather than subclass or copy a live file.

`lib/lain/notify.rb` (about 800 lines) was a dunstify surface, and it already solved the
problems a remote surface would otherwise rediscover:

- It **dispatches** a notification per parked pending and drains finished ones on a later pass,
  because `dunstify -A` blocks for the full window. Waiting inline meant one approval per
  window however many a turn gated (QA round 5, F24).
- It chooses its own correlation id (`-r`, `HANDLE_ID_FLOOR` at `notify.rb:152`) rather than
  reading a handle back off stdout.
- `#withdraw_settled` (`notify.rb:498`) closes the popup of any pending a sibling surface
  settled while the notifier was still blocked on it.
- The verdict crosses back to the reactor **as data**, and the sweep fiber applies it, because
  `Pending#decide`'s lock-free single-shot resolution is a fiber argument that two OS threads do
  not satisfy, and `Promise#resolve` from a foreign thread is a `FiberError`.

A socket-backed surface has the same shape with one simplification: if the socket is read on an
`async` fiber rather than a Thread, the thread bridge disappears entirely.

### 2.3 There are already two frontends, and a fan-out built for a third

`ARCHITECTURE.md` line 19: "Two frontends subscribe to one Journal, and the agent knows about
neither."

`CLI::JournalTee` (`lib/lain/cli/journal_tee.rb:52`) writes the durable Journal leg first, then
attempts every live-view sink, swallowing only `ClosedQueueError` from a sink
(`journal_tee.rb:70`). The comment names the case: quitting Neovim closes its `Channel`.
Closing a phone app is the same event.

`Channel::DropOldest` (`lib/lain/channel/drop_oldest.rb:48`) is the frontend's overflow policy:
drop the oldest event and surface a `Telemetry::Dropped` marker carrying the count, rather than
blocking the producer. A viewer on a flaky mobile link is the most extreme version of the case
that policy exists for, and the marker is what keeps the gap honest instead of silent.

`CLI::LiveViews` (`lib/lain/cli/live_views.rb:29`) is where the `--nvim` and `--journal` legs
are assembled, and its comment states the asymmetry a third leg would inherit: "a view leg MAY
simply be gone ... so its ClosedQueueError is swallowed, because a dead viewer must never break
a running tool."

Read-only visibility is, mechanically, one more sink here.

### 2.4 There is already a read-only viewer with the right posture

`CLI::Watch` (`lib/lain/cli/watch.rb`) tails a session journal on one fd, admits only records
whose lineage chains to the named spawn, and renders through an injected sink duck. Its comment:
"Read-only BY CONSTRUCTION: it opens the journal with mode `r` and holds no Store, no provider,
and no Channel, there is nothing here that could write, push, or spend."

That is the posture a remote viewer wants, already stated and already shipped.

### 2.5 There is already a second, non-TTY input source

`CLI::HumanReplies` (`lib/lain/cli/human_replies.rb`) is the `ask_human` reply surface. Every
answer names the set it answers, and it routes by the digest the arrival carried rather than by
"the asker this class happens to hold", because otherwise a child's question becomes
unanswerable while the parent has nothing pending.

`Frontend::Neovim::CommandInbox` (`lib/lain/frontend/neovim/command_inbox.rb`) is the editor's
command rail: `pop`, `attached?`, `review_refused`, `answered`. `#answered` pushes
`[verb, args]` onto an unbounded, never-closed queue that the consumer pops.

A phone reply is a third producer on a rail that already has two. The precedent is shipped, not
hypothetical.

### 2.6 There is a transport contract, and it dials out

`Core::Transport` (`lib/lain/core/transport.rb`) is a two-message contract, `#start -> IO` and
`#stop -> Object`, with `Mock` and `Vsock` implementations. `crates/lain-core/src/main.rs`
already binds either a Unix socket or `AF_VSOCK` from argv, and its header states the point:
"the protocol above the listener is identical either way".

`Core::Client` (`lib/lain/core/client.rb`) runs one reader-loop fiber draining the socket against
an msgid to `Promise` map, so N concurrent callers interleave and the daemon may complete out of
order. `PROTOCOL_VERSION` is pinned exactly, with no negotiation.

Two constraints follow, and both matter in §6.2. Ruby is the **client** everywhere today, and
`crates/lain-core/src/rpc.rs` **refuses msgpack-RPC notifications**: "`[2, method, params]` are
unsupported and answered as invalid requests ... a silent no-reply path would be a second
contract to maintain for nobody."

### 2.7 Nothing in lain accepts a network connection

Every transport today is in-process, a Unix socket, or vsock. This is the one genuinely new
authority boundary the work introduces, and it is worth saying plainly rather than letting it
arrive as a detail of a transport choice.

---

## 3. The finding that reshapes it: there are two autos

Joel's second question was whether "automode" has to work with remote approval. It does, and
the answer is sharper than yes, because `auto` names two unrelated things.

| | what it is | does a remote surface matter? |
|---|---|---|
| posture `auto` (`/mode auto`) | `gate_policy: :approve_all` (`lib/lain/mode/posture.rb:171`) | **No.** Nothing parks. The queue is never consulted and no surface is asked. A phone has nothing to answer. |
| layer `auto_approve` (`/mode +auto_approve`, `--auto-approve`) | wires `Approval::AutoSurface`, an LLM adjudicator on the parked set (`lib/lain/mode/layer.rb:84`) | **Yes.** It is the half that is missing. |

The user-facing consequence: the combination to run when away from the desk is
`accept_edits` (or `manual`) **plus** `auto_approve` **plus** a remote layer. Running
`/mode auto` at the park makes the app inert.

### 3.1 Remote approval completes `auto_approve` rather than competing with it

`AutoSurface`'s doctrine is deny-when-unsure. Only a confident one-word verdict settles a
pending; `#settle` (`auto_surface.rb:64`) approves on `:approve`, denies on `:deny`, and does
nothing at all otherwise. The class comment: a defer, an unparseable answer, or a failed spawn
"leaves the pending for the human surface or the fail-closed timeout".

Away from the desk there is no human surface. So today every defer is 300 seconds of wall clock
followed by a denial. The run pays the latency and gets the refusal, on exactly the calls where
a human's judgement was worth having. A remote surface turns `defer` into a verdict that leads
somewhere.

That reorders the pitch. The app is not a convenience layered on `auto_approve`. It is what
makes `auto_approve` usable unattended.

### 3.2 The race resolves itself, because of the confidence doctrine

`AutoSurface` polls every 50ms (`QueueSurface::DEFAULT_POLL_INTERVAL`) and answers in an LLM
round trip. A phone answers in tens of seconds. Under a naive design the oracle wins every
contested pending, the phone buzzes, and the card is withdrawn under the human's thumb, which
is notification fatigue for decisions they never make.

It does not happen, because `AutoSurface` only settles on confidence. The oracle takes the easy
ones and the phone gets the residue. The sequencing falls out of the doctrine rather than out of
a scheduler, and **`AutoSurface` needs no change**.

### 3.3 A remote surface must not subclass `QueueSurface`

`Approval::QueueSurface`'s whole reason for existing is that `AutoSurface` and `SecretSurface`
**partition** the parked set: `judges?(outstanding)` is `outstanding.none?` at
`auto_surface.rb:58` and `outstanding.any?` at `secret_surface.rb:107`, "complementary by
inspection", with `queue_surface_spec.rb` asserting the exclusive-or over both cases.

A remote human surface races; it does not partition. It belongs beside `Notify` and
`Frontend::ApprovalPolicy`, with its own `watch`/`sweep`. Subclassing `QueueSurface` would break
a claim that currently has a spec.

---

## 4. Two findings worth landing whether or not the app is built

### 4.1 `defer` is unobservable

`AutoSurface#settle` is a no-op on `:defer`. Nothing is journaled, no telemetry record exists,
and the pending simply stays parked.

Two consequences. The bench cannot count how often the auto-approver punted, which is a hole in
a record whose premise is that every decision is evidence; the queue journals `surface`,
`verdict`, `timed_out?` and `latency` for everything that *did* decide. And a remote surface has
no honest trigger for "the oracle has had its say, ask the human now", so it would have to guess
with a timer.

Making abstention a journaled record closes an evidence gap and supplies the dispatch signal.
Small, and independent of everything else here.

### 4.2 The `notify` mode layer is declared with the wrong outcome bit, and has no consumer

`lib/lain/mode/layer.rb:86` declares `notify: new(name: :notify, lighter: "NOTIFY",
alters_outcome: false)`. A grep of `lib/` and `exe/` for `:notify` returns that declaration and
nothing else. `Lain::Notify` was wired by `Notify.for(command:, desktop:)` (`notify.rb:184`)
reading `LAIN_DESKTOP`, not by the layer — and with that surface deleted (2026-09-12) the
declaration names nothing at all, which strengthens the "drop it" half of the ruling below.

So the declaration is currently inert. It is also wrong: dunstify's Approve button is the third
**deciding** surface (`notify.rb:565` and the warning above it). Anyone who later wires
`+notify` to that surface inherits a silently outcome-altering layer, which is the exact bug
`Layer::Declaration` exists to prevent ("A silently-active policy is a bug", `layer.rb:13`).

Either correct the bit or drop the declaration. Do not copy it for a remote layer.

---

## 5. Three tiers of remote capability

They differ enormously in cost, and separating them is what keeps the first slice small.

**Tier A, watch.** Read-only projection of the run: journal tail, status, history. `CLI::Watch`
is the posture and `JournalTee` plus `Channel::DropOldest` is the mechanism. Nearly free once a
wire exists.

**Tier B, answer.** Approvals, and `ask_human` inbox replies. The queue surface of §2.1 plus a
third producer on the rail of §2.5. The inbox is arguably the better fit of the two: its own
doctrine is "a queue they drain on their own schedule, never a modal prompt", which describes a
phone without naming one.

**Tier C, drive.** Remote `you>` lines. This is the step change, and it is the one the
architecture pushes back on.

### 5.1 Why Tier C is different in kind

A `you>` line extends the Timeline rather than observing it. Three things bite.

1. **Two input sources, one conversation.** `Repl` reads `you>` through `CLI::Conductor` and
   runs `Agent#ask` inside a `Sync` block. A remote line arriving mid-ask either queues behind
   the turn or races it. The honest model is that remote chat is an **inbox item that seeds a
   turn**, not a second prompt. Routed that way, Tier C is mostly Tier B with another verb.
2. **The collision hazard is already documented.** `ApprovalSurfaces#watch` takes `terminal:`
   precisely so that a keystroke meant for an `/inbox` question cannot land as the `y/N` on a
   gated `bash` (`approval_surfaces.rb:104`). Two sources of human input at one conversation is
   that hazard, one machine further away.
3. **Loop ownership stays put, and that is the good news.** `Provider` is one round trip and
   lain owns the loop, "because the loop is the object of study". The phone submits intent; the
   desktop process runs every turn. `Context#render` stays pure, the cache prefix is untouched,
   and the bench story is intact.

---

## 6. Where the thinking currently sits

### 6.1 The app is a frontend that also answers

Framing it as an approval remote makes the queue surface the design and the wire an afterthought.
Framing it as a third frontend puts it on a seam `ARCHITECTURE.md` already declares, and the
approval surface becomes one feature inside it.

The practical consequence is §6.2, and it is the reason this document exists before any code.

### 6.2 The wire is the one decision everything hangs on

An approval surface wants request/response. A frontend wants a durable subscription with
backpressure and reconnect. Build the first and you will rebuild it.

What is needed: subscribe to a session's event stream, resume from a digest after a
disconnect, and issue request/response calls for verdicts and replies.

Two placements, and `ARCHITECTURE.md`'s placement rule ("anything async, I/O-bound, or
isolation-relevant lives out of process") rules out `ext/lain` immediately.

**(a) A Ruby listener on the reactor.** `async` provides the endpoint; frames are msgpack; the
socket fiber and the surface fiber are siblings, so `Pending#decide` happens on-reactor with no
thread bridge, which is strictly simpler than `Notify`. Cheapest path to something running. It
puts a network listener inside the Ruby process, which is a posture change the docs would have
to state.

**(b) A `crates/lain-relay` daemon.** Reuses `rpc.rs`'s `Codec` and envelope, `forbid(unsafe_code)`,
and adds a shared `crates/lain-wire` crate of serde types consumed by both the relay and the
Dioxus app, so the pending and verdict schemas cannot drift between the two ends. Ruby stays a
dial-out client, which `Core::Client` already supports with msgid demux and out-of-order
completion, so a long-parked call is a fiber park on existing machinery.

The shared-types argument is what tips it to (b) for me, given the app is Rust. (a) remains a
legitimate spike to prove the UX before paying for a daemon lifecycle.

**Either way the wire contract grows.** Server-push is what a subscription needs, and `rpc.rs`
currently answers a notification frame as an invalid request (§2.6). Extending that is a
deliberate change to a stated contract, not an implementation detail.

Reconnect is the part that is already solved. Durable chat sessions, `--resume`, a response WAL
with resume-time salvage, and `Supervisor::Restart` as replay-from-record all exist. A phone
dropping off LTE and coming back is resume-shaped, and content-addressing means it can name
exactly where it was.

Tailscale itself is not a dependency. The device's Tailscale app owns the tunnel and the app
makes an ordinary TCP connection. **Bind to the tailnet address, never `0.0.0.0`.**

### 6.3 The mode layer, and what the declaration forces

A remote layer answers `alters_outcome?` with **true**: it lets a call be approved that would
otherwise have timed out into a denial. `Layer::Declaration` then *requires* a non-empty lighter
(`layer.rb:58`), so the HUD and
prompt say so whenever a remote authority is armed. That is the design working as intended, and
it is why §4.2 matters.

`LayerSet#|` is a commutative idempotent monoid, so `+auto_approve +remote` composes in any
order by construction.

### 6.4 Disclosure changes shape between the tiers

For approvals it is bounded and per-decision. `Telemetry::ApprovalPending` deliberately omits
`input` and `outstanding` from the Journal because they can carry credential bytes, and its
comment says the hand-maintained field list is the only thing keeping them out. The dunst
surface *does* render `Outstanding#preamble` plus `input.inspect` (`notify.rb:581`), because the
screen was assumed to be this machine's. A phone extends that surface from the desk to the
tailnet. Same fields is defensible; the region bytes stay off the wire exactly as `preamble`
keeps them off the terminal.

For a live journal feed it is unbounded and continuous: tool outputs, file contents, diffs,
reasoning. That is the codebase streaming to a handset. Over a tailnet that is defensible, and
it is a different claim from the approval one, so it wants its own decision and probably its own
tier (status-only versus full transcript).

Two bounds already hold and are worth knowing:

- **Triage sits above the surfaces rung and is now wired.** `Escalation.for` builds
  `[Triage, Rules, Surfaces(queue)]` (`escalation.rb:169-171`) and `Switchboard#build_ladder`
  passes a real `Triage` (`switchboard.rb:299-300`), which was the F63 fix. A protected path
  denies at the triage rung and never reaches any surface. The phone cannot be asked to approve
  `cat ~/.ssh/id_rsa`.
- **Region-carrying pendings can be kept off the phone** with a one-line predicate
  (`outstanding.none?`), leaving secret-releasing reads for the desk or `SecretSurface`. Proposed
  as the default with an explicit opt-out.

Together those bound what a phone can ever release to "ordinary tier-3 calls the auto-approver
was not confident about", which is the right size to hold against §7.2's revocation delay.

### 6.5 `Approval::Risk` is built, dead, and this is its consumer

`lib/lain/approval/risk.rb` (321 lines) computes whether a call is structurally risky, modelled
on Emacs' `risky-local-variable-p`. Nothing in `lib/` or `exe/` constructs it; the only
references are documentation cross-links from `sensitivity.rb` and `credential_patterns.rb`.
ROADMAP item at line 1306 records it as staying dead, as scoped.

"Risky calls are not answerable from the phone, they wait for the desk or they time out" is a
better default than a blanket remote yes, and it is the first real use for an object that has
been sitting unwired.

### 6.6 The status screen owes `/introspect`'s discipline

`CLI::Command::Introspect` (`lib/lain/cli/command/introspect.rb`) exists because of F77: asked
for its own session usage, the agent invented a metrics table while eight `turn_usage` records
carrying the true answer sat in the journal it had just written. Its doctrine, verbatim:

> A CONFIDENT FALSE NEGATIVE is F77 wearing better manners. "review none open" told to a human
> who is annotating one, or a percentage over a denominator nobody vouched for, do the same
> damage as an invented table and are harder to catch, because a plausible number reads as a
> measured one.

So it names the three things it cannot see under `unreported` rather than omitting them,
"because an omission a reader can mistake for an absence is the same lie one step removed".

A phone status screen is where that failure recurs hardest: the human is miles away and cannot
cross-check against the terminal. The remote view should render `/introspect`'s shape including
its `unreported` rows, not a tidier dashboard that quietly drops them.

### 6.7 What stays at the desk

The `Review` subsystem. Diff review wants a keyboard and screen area, and
`planning/human-in-the-loop-review-research-2026-08.md` designed it around nvim buffers,
extmarks and native diff mode. A phone should be able to see **that** a review is open and
blocking, and nothing more.

---

## 7. Decision log

Two rulings so far, both Joel's, recorded in his words.

### 7.1 Scope is a frontend, not an approval remote

> It might be nice for us to longer term give visibility into what is happening when the dev is
> remote such as allowing teh user to "chat remotely" and be able to see the history of things
> or where things are at.

Ruling: the wire is designed for a frontend (subscription, resume, request/response) even though
the first slice implements only approvals. §6.2.

### 7.2 The lost-device risk is handled by tailnet revocation

> On the lost phone: it doesn't happen often, and I could forcibly eject it from my tailscale
> network when it happens.

Ruling: accepted, and it is the right layer to revoke at, since it kills the network path rather
than trusting an app-level token. The residual is that revocation is only as fast as the owner
notices, which is what §6.4's two bounds are sized against rather than an argument for a
different mechanism.

---

## 8. Not verified here

Everything in this list is prior knowledge, unmeasured in this repo, and should be probed before
it is planned against.

- **Dioxus 0.7 mobile on this toolchain.** `../pitchcraft` and `../belle-curves` are Dioxus 0.7
  with `default_platform = "android"`, read on 2026-08-26. Whether `dx build --platform android`
  currently produces a sideloadable APK on this machine was not tested.
- **The wake path is the biggest unknown.** Android will not hold a socket open in the background
  without a foreground service, and Dioxus gives no help there. The cheap alternative is a
  self-hosted ntfy topic for the buzz, with the app connecting over the tailnet only when opened,
  so ntfy's own app pays the foreground-service cost once for every app on the device. Neither
  path was tried.
- **Real buzz-to-verdict latency against the 300s window.** Unlock, tap, connect, read, approve.
  Estimated at 20 to 90 seconds with the phone in hand and unmeasured with it in a pocket. This
  is the number that decides whether `DEFAULT_TIMEOUT` needs a paired-device value.
- **`tailscale whois` round-trip cost** on the LocalAPI, and whether it is cheap enough to run
  per-connection for the journal attribution in §2.1.
- **MagicDNS behaviour** when the phone changes networks mid-session, and how that interacts with
  resume-from-digest.
- **Whether streaming a full journal over a mobile link stays inside `DropOldest`'s bounds**, or
  whether the marker fires often enough to make the feed misleading.

---

## 9. Open questions

1. **Does the timeout get a paired-device value?** The doctrine allows a different constant ("a
   bound, not a hurry"), and unattended runs with many gated calls would otherwise burn 300
   seconds per call when the phone is unreachable. Needs the §8 latency measurement first.
2. **Does reachability change the ladder?** A remote surface that knows no device is connected
   arguably should not extend anything. Where that fact lives, and whether it is a rung or a
   surface property, is unresolved.
3. **Does the relay serve one session or the machine?** Multi-session is where the tmux HUD's
   F75 (two lain processes in one project dir sharing one status feed) would recur over a wire.
4. **What is the feed's redaction path?** `Middleware::RedactSecretReads` treats the model as
   the consumer. Whether a remote sink can subscribe downstream of the same treatment, or needs
   its own, is unexamined.
5. **Protocol versioning across two artifacts.** `Core::Client::PROTOCOL_VERSION` is an exact
   pin with no negotiation, which is right for two things built together. A sideloaded APK is not
   rebuilt when the daemon is, and an exact pin turns that into a dead app rather than a degraded
   one.
6. **Where does the app's own record live?** A verdict made on the phone is journaled by the
   desktop. Whether the phone keeps anything locally, and what that means for the "the Journal is
   the experiment record" claim, has not been thought about.

---

## 10. A first slice, if it is pursued

Ordered so that everything before the last item is testable without a phone.

1. **`crates/lain-wire`**: serde types for a parked approval, a verdict, and a feed event. No
   I/O. Consumed by both ends.
2. **The relay**, per §6.2, speaking the session protocol but implementing only the approval
   verbs. Loopback `:seam` spec: a live fd is explicitly in scope for the tag and it runs by
   default, so no network is involved.
3. **`Approval::RemoteSurface`**, modelled on `Notify`: observe the parked set, dispatch,
   withdraw on sibling settle, decide on the sweep fiber. Default `judges?`-equivalent predicate
   excludes region-carrying pendings (§6.4).
4. **Wiring**: one keyword and one splat in `ApprovalSurfaces#watch`, plus its spec, which pins
   both the size of the returned set and the class of every member.
5. **The mode layer**, `alters_outcome: true` with a lighter (§6.3).
6. **The Dioxus app** against loopback via `adb reverse`, then over the tailnet.
7. **The wake path** last, since everything above it is reachable without solving it.

Tier A (watch) rides the same wire and should ship with Tier B rather than after it, because it
is what makes an approval answerable with context. Approving a `bash` from `input.inspect` alone
is thin.

Two items are independent of all of the above and can land at any time: §4.1 (journal the
abstention) and §4.2 (the `notify` layer declaration).

---

## 11. References

- `ARCHITECTURE.md` § Process topology, § Effects/handlers/Gate/Middleware, § Channel/JournalTee/
  StatusFeed fan-out, § `ext/lain` vs `crates/lain-core`: the placement rule.
- `ROADMAP.md` § Interface & UX, "The human is an actor" and "Approved interface experiments".
- `planning/human-in-the-loop-review-research-2026-08.md`, for the review surface this
  deliberately leaves at the desk (§6.7).
- `planning/interface-integration.md`, for the surface decisions the local frontends were settled
  by.
- `docs/concurrency.md`, for why the posture is fibers and what a non-yielding call costs.
- `../pitchcraft` and `../belle-curves`, the two Dioxus 0.7 Android projects this would copy its
  build from.
