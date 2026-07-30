# Firecracker / microVM isolation for Lain ⚠️ LLM-generated

**Not an external source** — Claude-written synthesis (2026-07-28) from the Firecracker upstream
docs, the Lima docs/issues, the Clawk README, and a read of Lain's own `Isolation`, `WorkerEnv`,
`Core::Client`, and `Tools::CoreExec`. External claims are linked at the bottom; the
Lain-mapping section is inference from this repo's code and should be read as a proposal, not a
finding.

---

## The one-line answer

A microVM is a **good fit for Lain's exec boundary and a bad fit for Lain's `Isolation`
backend seam** — and the reason is already written down in `lib/lain/worker_env.rb`: a
`WorkerEnv` is "override, not confinement." Confinement was always going to live at the
out-of-process exec boundary, and Lain already *has* that boundary: `lain-core`, msgpack-RPC,
Unix socket. Firecracker's vsock is a Unix socket with a four-word handshake in front of it.
That is a much smaller change than "add a VM backend."

The hardware is the harder half. **Neither machine can run Firecracker today**: this desktop
has no `/dev/kvm`, and macOS cannot run Firecracker at all.

---

## 1. Hardware reality check

### The Linux desktop (Ryzen 7 3700X, Ubuntu, kernel 6.8.0-136)

| Check | Result |
|---|---|
| `/dev/kvm` | **absent** |
| `kvm`/`kvm_amd` in `lsmod`, `/sys/module` | **not loaded** |
| `modinfo kvm_amd` | present at `/lib/modules/6.8.0-136-generic/kernel/arch/x86/kvm/kvm-amd.ko.zst` |
| CPU `svm` flag | present (Zen 2 — `svm`, `npt`, `sev`, `vgif`, `v_vmsave_vmload`) |
| `systemd-detect-virt` | `none` (bare metal, not itself a guest) |
| RAM | 15 GiB total, **~7 GiB available** |
| Installed VMMs | none — no `firecracker`, no `qemu-system-x86_64`; Docker 29.4.2 on `runc` |

The module exists and the silicon supports SVM, so this is almost certainly **SVM/AMD-V
disabled in the BIOS** (on AMD the `svm` cpuid flag is still advertised when firmware has it
switched off, so the flag is not proof). Diagnosis is one command, but it needs your password:

```bash
sudo modprobe kvm_amd     # expect: "kvm_amd: SVM disabled (by BIOS) in CPU 0" if it's firmware
```

If that is the message, it is a reboot into BIOS → *SVM Mode: Enabled* (on most Ryzen boards
under CPU Configuration / Advanced). If it loads clean, you also need `usermod -aG kvm joel` —
`joel` is currently in `docker` and `lxd` but **not** `kvm`.

**RAM is the real ceiling, not the CPU.** ~7 GiB available means roughly **4–6 concurrent
microVMs at 512 MiB–1 GiB each**, before the host agent, the editor, and Docker. That is enough
for a bench arm; it is not enough to make every worker in a fan-out a VM. Plan the backend so
VM-ness is per-arm, not global.

### The work MacBook Pro

**Firecracker does not run on macOS.** It is a KVM-only VMM — upstream's supported hosts are
x86_64 (Cascade Lake … Granite Rapids, Milan, Genoa) and Graviton 2/3/4 on Linux, and the build
instructions say "any Unix/Linux system that has Docker running." There is a 2025-era proof of
concept (issue #5017) booting an aarch64 guest on Apple silicon through
Virtualization.framework by disabling most KVM-specific paths; it is explicitly not
production-ready and has not landed.

So the Mac has three real options, and only one of them is actually Firecracker — see §3.

---

## 2. What Firecracker gives you, concretely

- **Boot**: ~125 ms to user code from cold; **snapshot-restore in 5–30 ms**. Up to ~150 microVMs
  per host per second. Snapshot restore uses a `MAP_PRIVATE` mapping of the memory file with
  on-demand paging and CoW for writes — which is why resume is cheap and why a pre-warmed base
  image (runtimes, package cache, a hydrated `bundle`) is the intended pattern.
- **Footprint**: guest kernel stripped to 5–10 MB, rootfs ≤ ~50 MB.
- **Security posture**: the `jailer` binary applies cgroup + namespace isolation and drops
  privileges before exec'ing Firecracker; the VMM itself runs under thread-specific seccomp
  filters (~24 syscalls) inside a chroot. An escape from the hardware virtualization boundary
  lands in that jail, not on your host.
- **Devices — and the constraint that matters most**: virtio-net, virtio-block (rw/ro),
  **virtio-vsock**, virtio-entropy, virtio-pmem, virtio-PCI with hotplug. **No virtio-fs.**
  There is no shared-directory device.

That last point is the one that reshapes the design. On macOS/VZ you can live-mount a git
worktree into the guest and the file the agent edits is the file in your editor. On Firecracker
you cannot. You get a block device, so the choices are: bake the workspace into the rootfs at
create time, attach a CoW block clone (`FICLONE` on XFS/Btrfs, reflinks on ext4 only with
`reflink=1`, which Ubuntu does not default to), or ship files over vsock. Clawk — the project
in `references/hn-agent-landscape-2026-07.md` §5 — hits exactly this and says so: macOS is
live-mounted via virtio-fs, "Linux currently bakes it in at create."

**This directly collides with `Isolation::Worktree`.** That backend's whole premise is a real
`git worktree add` on the host filesystem that the worker's `cwd` points at. Under Firecracker
the checkout is on the far side of a block device. `Worktree` and a microVM backend are not
composable the way `DbIndex` and `Compose` decorate `Null`/`Worktree` today — the VM one
*replaces* the filesystem story rather than enriching it.

---

## 3. The Mac, and the Lima question

**Yes, Firecracker-inside-Lima works — on M3 or newer, macOS 15+, and only via nested
virtualization.** The chain is:

```
macOS 15+ on M3/M4  →  Virtualization.framework exposes nested virt (Hypervisor.framework, 15.0+)
                    →  Lima `vmType: vz` + `nestedVirtualization: true`  (PR lima-vm/lima#2530)
                    →  /dev/kvm appears inside the Lima Linux guest
                    →  Firecracker runs there, against nested KVM
```

Validation is literally `limactl shell <vm>` then check `/dev/kvm` exists.

Caveats worth knowing before you commit to it:

- **M3 is a hard floor.** M1/M2 have no nested virtualization at any macOS version. If the work
  MacBook is M1/M2 Pro/Max, this path is closed, full stop — that is the first thing to check.
- It is **not on by default**; Lima issue #2824 is a still-open request to auto-enable it when
  the conditions hold, and there are reports (M3 / macOS 15.2) of people not getting it working.
  Treat it as "supported, fiddly," not "turnkey."
- Nested virt costs performance, and you are now maintaining two guest images (Lima's Ubuntu,
  plus the Firecracker rootfs) and two kernels.
- `lima-vm/lima#4498` reports nested virt failing for QEMU-in-guest on M4, so the feature is not
  uniformly solid across chips yet.

**The honest read:** Lima-nested-Firecracker is the right answer if your goal is *parity* — one
Firecracker code path exercised identically on both machines, so the bench arm you measure on
Linux is the arm you measure on the Mac. It is the wrong answer if your goal is *isolation on
the Mac*, because you are stacking two hypervisors to reach a VMM that macOS has a native
equivalent for.

The alternatives, if parity is not the goal:

| Option | Mechanism | Verdict for Lain |
|---|---|---|
| **Lima + nested Firecracker** | vz → nested KVM → Firecracker | Only path with a *literally identical* Firecracker arm on both hosts. M3+/macOS 15+. Fiddly. |
| **libkrun / krunvm** | Library embedding a Rust VMM; KVM on Linux, **Hypervisor.framework on macOS/arm64**, bundles its own kernel via libkrunfw | The strongest cross-platform story. One C API, no nesting, no kernel image to manage, runs on **both** your machines including M1/M2. Not Firecracker, but the same shape. |
| **Virtualization.framework directly** | Apple's own VMM, virtio-fs live mounts | What Clawk does on macOS. Best Mac ergonomics (live-mounted worktree), zero Linux reuse. |
| **Apple `container` / mvm** | VZ-backed, sub-second start; `mvmctl` auto-detects `/dev/kvm`, Apple Virtualization, or Docker | Interesting mainly as prior art for *backend auto-detection*, which is the ergonomic problem you'd otherwise hand-roll. |

If I had to pick one: **libkrun is the better bet than Firecracker for Lain specifically**,
precisely because Lain is a study bench that has to produce comparable numbers on two very
different machines. Firecracker's advantage is operational maturity at fleet scale, which is
not a property this bench measures.

---

## 4. Where it actually plugs into Lain

### 4a. Not here: `Isolation#acquire`

`Isolation#acquire(worker_id) -> Lease` hands back a `WorkerEnv`, which is `(cwd, env)` — host
paths, host environment. `worker_env.rb` already states the limit in its own words: mixlib
applies `environment:` per-key onto the ENV the forked child *already inherited*, so an omitted
var still leaks; "true confinement belongs to the out-of-process exec boundary (M5/M6), never
to this hash." `Tools::CoreExec`'s class doc says the same thing about the transport: "A
TRANSPORT BOUNDARY IS NOT A SANDBOX … crossing a Unix socket adds no seccomp, landlock,
namespace, or chroot confinement."

Both comments are pointing at the same missing piece, and a microVM is that piece. But a VM
backend cannot express itself as a `(cwd, env)` pair, because the cwd it wants to name does not
exist in the host namespace. Forcing it through `Lease` would mean inventing a fake host path,
which is exactly the kind of lie the `WorkerEnv` doc was written to prevent.

### 4b. Here: the `lain-core` transport

This is the good news, and it is a genuinely small change.

`Core::Child#start` spawns the daemon and returns **a connected `UNIXSocket`, ownership passed
to the caller**. `Core::Client` then owns bytes only — one reader-loop fiber, msgid demux,
msgpack-RPC frames. The client does not care where the socket came from.

Firecracker's host→guest vsock is:

1. `connect(AF_UNIX, uds_path)` — the `uds_path` from the vsock device config
2. write `"CONNECT <port>\n"`
3. read `"OK <hostside_port>\n"`
4. …the socket is now a plain bidirectional stream to the guest listener

Which means: **run `lain-core` inside the guest listening on AF_VSOCK, and the only thing that
changes on the Ruby side is how a connected socket is obtained.** No RPC protocol change, no
`exec.rs` change, no `CoreExec` change. The `exec` method's params — `argv`, `cwd`, `env`,
`timeout_ms` — are already the right shape for a guest, and `cwd` finally means something
confined instead of something advisory.

The one blocker in current code: `Client.start(paths:, binary:, ...)` constructs
`Child.new(paths:, binary:)` internally, so the transport is hard-wired to spawn-a-local-child.
Extracting a transport duck (`#start -> socket`, `#stop`, `#socket_path`) with `Child` as the
default implementation is the enabling refactor, and it is the same injection idiom
`shell_out_factory` already uses in `Isolation::Worktree`, `Tools::Bash`, and
`CLI::IsolationBackend`.

That refactor is worth doing **even if the microVM work never happens** — it is the seam that
makes the transport testable without a real daemon.

### 4c. Why this is bench-shaped, not infra-shaped

`Tools::CoreExec` is already documented as "the exec boundary's comparison arm: NOT in
exe/lain's base_tools and never wired into a shipped toolset; a bench constructs it explicitly
next to `Bash` to measure the transport." There is already a differential spec pinning `Bash`
and `CoreExec` byte-identical on process output, with spawn-failure and timeout as *posture*
parity rather than byte parity.

A microVM arm is the **third** member of that family, and the existing differential spec is the
acceptance test that already exists for it. The asymmetries the doc lists (boot-time ENV
snapshot vs call-time fork; no streaming over RPC) get *larger*, not different in kind. And the
thing the bench would measure is the thing the ROADMAP §M5 entry already asks for: "microVM /
container / bwrap as a *compared* knob (not just an exec seam)."

The measurable axes fall out for free: cold-boot vs snapshot-restore latency per tool call,
tokens-to-task-completion under confinement vs not, and the rate at which a confined agent
*fails* at tasks the unconfined one completes — which is the number nobody publishes and the
one a study bench exists to produce.

### 4d. The 90% nobody budgets for

The Clawk comment thread's lesson, recorded in `hn-agent-landscape-2026-07.md`, is worth
repeating because it survives contact with this analysis: **the sandbox is the easy 10%; the
policy engine and credential brokering are the hard 90%.**

For Lain that decomposes into:

- **Egress.** Clawk's approach — gvproxy fork, userspace TCP/IP stack terminating guest
  TCP/UDP/ICMP and re-dialing as host sockets, allow-list consulted per connection and per DNS
  query — is strictly better than iptables because guest-root cannot bypass it and it needs no
  `sudo`. For Lain the payoff is that **every allowed/denied connection becomes an attributed
  Journal event**, which makes egress an observable `Effect` rather than a silent side channel.
  That is the piece that answers the DN42 runaway-cost story in ROADMAP §M5: `Agent::Budget`
  counts tokens, and the $6,500 there was *egress*.
- **Credentials.** `ANTHROPIC_API_KEY` must never enter the guest. The provider round trip stays
  host-side — which Lain's architecture already wants, since `Provider` is host-side and only
  *tool* execution needs confining. This is the one place the microVM design and "Workspace is
  sent, not stored" reinforce each other: brokered, never injected, so digests stay
  credential-free.
- **Workspace round-tripping.** Without virtio-fs, "what did the agent change?" needs an answer.
  The interesting one, and it is already sketched in the HN reference: hash the guest's disk
  state into a turn's `meta` so `diverge_at` reproduces *conversation and filesystem together*.
  That is a real research contribution and not merely plumbing — but it is a chunk, not a card.

---

## 5. Suggested staging

Ordered so each step is independently useful and none is wasted if the next is abandoned.

1. **Unblock the hardware, and find out if the Mac is even eligible.** `sudo modprobe kvm_amd`
   here (BIOS SVM + `usermod -aG kvm joel` if needed); `sysctl -n machdep.cpu.brand_string` and
   the macOS version on the Mac. If the MacBook is M1/M2, the Lima path is dead and the
   cross-platform question collapses to libkrun-or-nothing. **Do this before anything else** —
   it decides the shape of everything downstream.
2. **Extract the `Core::Client` transport seam.** Pure refactor, no VM, immediately useful,
   TDD-able against a `Transport::Mock` in the same spirit as `Provider::Mock`. This is the card
   that makes the rest cheap.
3. **Prove the vsock path with the smallest possible guest.** A stock kernel + minimal rootfs,
   `lain-core` cross-compiled and running on AF_VSOCK, and the *existing* differential spec run
   against it. Success criterion: the `Bash` / `CoreExec` differential passes with the daemon
   inside a VM. That single green spec is the whole feasibility question answered.
4. **Only then** decide Firecracker-vs-libkrun, on measurements rather than on the reading
   above. Step 3's spec is backend-agnostic, so it grades both.
5. **Egress-as-Effect**, which is separable from all of the above and arguably higher-value —
   an allow-list enforced below the guest, every decision a Journal event.

Workspace-state-in-`meta` (§4d) is deliberately last and deliberately its own chunk.

---

## 6. De-risked by spike (2026-07-28)

Two of the load-bearing claims above are no longer inference. Both were provable without a
hypervisor, and both passed.

### `spike/vsock_relay_poc.rb` — the transport claim, 6/6

A Ruby relay impersonates Firecracker's host-side vsock UDS exactly as `docs/vsock.md` specifies
(`CONNECT <port>\n` → `OK <hostside_port>\n`, then a dumb byte splice) in front of a real
`lain-core`. An **unmodified `Core::Client`** then runs against it:

```
handshake: sent 'CONNECT 5252', got 'OK 1073741824'
  ok   ping / version gate -> 0.1.0
  ok   exec echo -> "hello from the guest" status=0
  ok   cwd is honored across the boundary
  ok   explicit-nil scrubs a var (the one removal lever) -> [scrubbed]
  ok   server-side timeout still fires through the relay -> timed_out=true
  ok   concurrent calls interleave (msgid demux over the splice) -> 0,1,2,3,4,5,6,7
```

Three things this settles:

- **`Client.new(child:, socket:, version:)` is already public and takes an arbitrary socket** —
  only `.start` hard-wires `Child.new`. §4b's "enabling refactor" is smaller than described:
  the injection point exists, and `.start` is merely the convenience door. A VM transport needs
  to supply a `child` duck answering `#pid`/`#stop` and a connected socket. That is all.
- **msgid demux survives a splice.** Out-of-order completion, the timeout, and the explicit-nil
  env scrub all work through an opaque relay, so the RPC really is transport-agnostic.
- **Teardown is the part that bites, not the protocol.** The first run deadlocked: joining both
  splice pumps parks forever, because the idle direction only EOFs when the client closes, and
  the client only closes when it sees EOF. Firecracker collapses both halves of a vsock
  connection together, and any transport we write must too. Cheap to learn here; expensive to
  learn against a live VM.

### Static `lain-core` for a microVM rootfs — trivial

```
cargo build --release --target x86_64-unknown-linux-musl -p lain-core
→ 1.7 MB, static-pie, "statically linked"; 1.2 MB stripped
```

No `musl-gcc` needed (Rust's self-contained linking covers it), and every dependency is pure
Rust — tokio, tokio-util, futures-util, rmpv, bytes, tracing, thiserror, nix. Against
Firecracker's ≤50 MB rootfs guidance the daemon costs ~2.5% of the budget. **The rootfs is not
a risk.** Cross-compiling to `aarch64-unknown-linux-musl` for the Mac path is untested but has
no obvious obstacle.

### `spike/vsock_loopback_poc.rb` — real AF_VSOCK, 7/7, and **no sudo needed**

The relay above faked vsock with a Unix socket. This one removes the fake: genuine `AF_VSOCK`
sockets over the kernel's `vsock_loopback` transport, no hypervisor.

**The module autoloads.** `sudo modprobe` turned out to be unnecessary — the first
`socket(AF_VSOCK, SOCK_STREAM, 0)` in any process pulls in `vsock` and `vsock_loopback`
unprivileged. So this whole test is available to any user on this machine right now.

Ruby 4.0.5 exposes `Socket::AF_VSOCK == 40` but has **no `sockaddr_vm` helper**, so the 16-byte
struct is hand-packed (`[AF_VSOCK, 0, port, cid, 0,0,0,0].pack("SSLLCCCC")`); binding
`VMADDR_CID_ANY` and dialing `VMADDR_CID_LOCAL(1)` works first try.

```
connected over AF_VSOCK to CID_LOCAL(1):5252 — no hypervisor, no sudo
  ok   ping / version gate over vsock -> 0.1.0
  ok   exec echo -> "hello over vsock" status=0
  ok   large payload survives the transport (1 MiB stdout) -> 1048576 bytes intact
  ok   binary-clean stdout (msgpack bin, not str) -> [0, 1, 254, 255]
  ok   explicit-nil scrubs a var -> [scrubbed]
  ok   server-side timeout fires -> timed_out=true
  ok   concurrent calls interleave (msgid demux) -> 0,1,2,3,4,5,6,7
```

**Transport latency is in the noise — do not model it.** Median `ping` round trip over three
runs: vsock+splice 119 / 90 / 140 µs against unix-direct 90 / 61 / 157 µs. The third run has
vsock *faster*. At ~60–160 µs the cost is the Ruby + Async round trip, not the socket family,
and any per-call transport penalty is below measurement. The first run alone would have
suggested a ~30 µs vsock tax; it does not exist.

### The finding worth keeping: the child duck carries a *liveness obligation*

`Core::Client#stop` is `@child.stop; @reader.wait; @socket.close` — it waits for the reader
fiber **before** closing the socket. `Child` earns that by TERMing the daemon, which drops the
connection and EOFs the reader. A handle whose `#stop` does nothing parks `#stop` **forever**;
the spike deadlocked on exactly this.

So the transport seam is not merely the shape `#pid` / `#stop` / `#status`. **A transport's
`#stop` must cause the wire to EOF** — TERM the guest daemon, tear the VM down, or at minimum
`shutdown(2)` the socket. That contract is undocumented today and is precisely the kind of thing
a `Transport::Mock` should pin when the seam is extracted.

Two other traps this cost time on, both mine rather than the boundary's, both worth not
repeating: joining *both* splice pumps deadlocks (either direction closing must collapse the
pair), and `sh` here is dash, whose `printf` implements POSIX `\ooo` but **not** bash's `\xNN` —
with hex it emits the escape text verbatim, which reads exactly like a transport corrupting
bytes. It is not one.

### Residual — ✅ CLOSED 2026-07-28

The one piece still faked was `lain-core` binding `AF_VSOCK` natively; the guest-side listener
here was a Ruby splice standing in for it. That was a listener swap in `main.rs`, against
[`tokio-vsock`](https://crates.io/crates/tokio-vsock) 0.7.2 — Apache-2.0, ~7.1M downloads,
maintained under the `rust-vsock` org. Mature crate, known shape, no research risk.

**Shipped** by `planning/specs/chunk-vsock-exec-transport.md` (`048f935`, `c338bf3`, `1c8734e`,
`0e07a5f`, `8fa9058`, `f844d6c`). `lain-core vsock:<port?> <tracing_path>` binds `AF_VSOCK` on
`VMADDR_CID_ANY` and publishes its bound port; `Lain::Core::Transport::Vsock` dials it; and the
**same `Tools::Bash`-vs-`Tools::CoreExec` differential that pins the Unix path now passes over the
vsock boundary** — byte identity including NUL and high bytes, posture parity, and boundary death
as a tool error rather than a raise. The crate estimate held exactly: no tokio bump, no feature
change.

> ⚠️ **The conclusion immediately above this section was overturned in execution.** "A transport's
> `#stop` must cause the wire to EOF" is **not** the contract that shipped. The panel's reading was
> that this promoted an accident of statement ordering in `Client#stop` into an obligation, and
> that it is implementable only by a transport that owns a process — which would have excluded the
> attaching AF_VSOCK transport this whole document argues for. `Client#stop` now collapses its
> **own** read side before waiting, so the reader EOFs because the client shut its half, and
> `lib/lain/core/transport.rb` states the opposite of the sentence above: a transport that merely
> attaches **owns nothing at `#stop`, releases nothing, and only reports**. The spike's deadlock
> was real; the obligation it seemed to imply was not.

Two further corrections this document's §6 measurements need, both found by re-measuring during
execution. **Dialing `VMADDR_CID_HOST` from the host is fine** — the "connects then `ENOTCONN`"
behaviour was measured against a port with *nothing listening*, so it belonged to the dead port,
not the CID; against a live `CID_ANY` listener, `CID_LOCAL` and `CID_HOST` are behaviourally
indistinguishable and only the diagnostic string tells them apart. And **`connect(2)` to a dead
vsock port usually SUCCEEDS** on `vsock_loopback` (4 runs in 5), so nothing can detect "nothing is
listening" at connect time and `ECONNREFUSED` never fires — the failure surfaces at the handshake
instead.

**The spike scripts themselves are gone.** `spike/vsock_relay_poc.rb` and
`spike/vsock_loopback_poc.rb` are in no commit, on no branch, in no dangling object, and in no
stash — searched exhaustively. Untracked files deleted before a commit leave no trace, which is
consistent with their having run. Their results survive only as the prose above, so **treat this
section as testimony rather than as a reproducible artifact**; the reproducible proof is now the
`:vsock`-tagged suite (`bundle exec rspec --tag vsock`).

## 7. Answers to §4/§5's open questions (researched 2026-07-28)

### Services: one VM, two VMs, or neither (the `Compose`/`DbIndex` problem)

The §4a worry — that the decorator stack cannot cross the boundary — has **three** resolutions,
and the best one is the one that keeps the decorators untouched.

**(A) One VM, DB inside it.** The VM *is* the namespace, so `DbIndex`'s whole reason for
existing (`createdb lain_worker_<hash>`, Redis index pool) evaporates: every worker gets
`postgres://localhost/app`, identical string, isolated by the boundary rather than by naming.
Costs: rootfs grows from ~50 MB to a few hundred, and Postgres wants ~256 MB RAM, which on this
desktop's ~7 GiB collapses the concurrent worker count. **But it pairs with snapshots
beautifully** — snapshot *after* boot + migrate, and every worker restores a warm, migrated
database in 5–30 ms. That is a better story than `createdb` per worker, not merely an equal one.

**(B) Two coordinated VMs.** Architecturally this fits: a `SiblingVm` decorator provisions the
second VM, discovers its address, and injects the URL — which is *exactly* the existing
`Provisioned(service_name, env_var, url, release)` shape, and `Lease`'s `on_release` already
composes. The cost is operational, not structural: Firecracker networking is TAP-based, every
TAP device needs `sudo ip tuntap add` (root or `CAP_NET_ADMIN`), inter-VM traffic needs a bridge
or namespaced NAT, and you are now paying 2× RAM per worker. On the Mac path all of that sits
inside Lima, nested. Viable, and the general mechanism, but the wrong default.

**(C) vsock-forward to a host service — the one to build.** Firecracker's *guest-initiated*
vsock needs no handshake: the guest connects to CID 2 on port N, and the host receives it on a
Unix socket at `<uds_path>_<port>`. So put a forwarder there pointing at the per-worker Postgres
that `DbIndex` **already provisions on the host today**, run a shim in the guest listening on
`127.0.0.1:5432`, and `DATABASE_URL=postgres://localhost:5432/...` works unmodified.

This is the same splice `spike/vsock_relay_poc.rb` already proved, run in the other direction.
No TAP, no root, no bridge, no second VM, no rootfs growth — and **`DbIndex` and `Compose` keep
working exactly as written**, because they still provision on the host. It also makes credential
brokering concrete and nearly free: the host-side forwarder holds the real DSN, and the guest
gets an unauthenticated localhost socket it cannot read a password out of.

The trade is a deliberate hole in the boundary — the guest can reach a host service. But it is
an *enumerated* hole, one vsock port per declared service, which is the "tools are capabilities,
not permissions" posture rather than a violation of it.

**Recommendation:** C as the default, A when the experiment demands true confinement (and for
the snapshot-a-migrated-DB trick), B only if something genuinely needs two kernels.

### Q3 — snapshots and live vsock: connections die, listeners survive

Firecracker sends `VIRTIO_VSOCK_EVENT_TRANSPORT_RESET` at snapshot time, and on resume "the
vsock driver closes all existing connections." Critically: **"Existing listen sockets still
remain active and can accept new connections after resume."** Network is weaker still — "guest
network connectivity is not guaranteed to be preserved after resume," and packet loss "can be
expected" when resuming in a different Firecracker process.

For Lain this is a **good** result. The daemon must not be respawned, only reconnected: after
restore, the host redoes `CONNECT <port>\n` and `lain-core`'s still-live AF_VSOCK listener
accepts. The cost of a snapshot-fork is therefore one reconnect plus the bounded `ping` version
gate — a transport concern, not a protocol change, and `Client` already models wire death
(`Died`, `Stopped`) and a bounded handshake.

**The sharp edge is multi-resume.** Restoring one snapshot into N clones duplicates "identifiers,
random numbers and random number seeds, the guest OS entropy pool, as well as cryptographic
tokens." For a *production* fleet that is a security defect. For a **study bench it is a
double-edged gift**: duplicated entropy across speculative forks is precisely the determinism
that makes reruns comparable — and simultaneously a trap for any task touching UUIDs, TLS, or
anything that assumes fresh randomness. This tension should be *measured*, not assumed away; it
is the sharpest concrete instance of §5's reproducibility argument.

### Q4 — gvproxy: buys the network stack, not the allow-list

gvproxy (`containers/gvisor-tap-vsock`) is a pure-Go userspace stack over gVisor's netstack,
with a virtual gateway at 192.168.127.1 doing DHCP + DNS, port-forwarding over an HTTP API, and
transports for **vsock, QEMU, BESS, and vfkit — Firecracker is not among them**, and outbound
filtering / allow-lists are **not documented at all**. That is consistent with Clawk shipping a
*fork*: the allow-list is the part you write.

So gvproxy gives away the genuinely hard 80% (a working userspace TCP/IP stack, no root, no
iptables) and none of the policy. Adopting it for Firecracker means adding a transport *and*
the filtering layer.

### Q5 — libkrun, and the finding that may reorder the whole plan

libkrun is a C API (`krun_create_ctx`, `krun_set_vm_config`, `krun_set_root`,
`krun_start_enter`, `krun_add_virtiofs*`, `krun_add_net_unixstream`) over KVM on Linux and
**HVF on macOS/ARM64**, with a `krun-sys` Rust crate. No snapshot support documented — it
loses to Firecracker there. But two things cut the other way, hard:

1. **`krun_add_virtiofs*` exists.** Firecracker has no virtio-fs at all (§2), which is what
   forced the whole "bake the workspace in at create" problem and broke `Isolation::Worktree`'s
   premise. libkrun can live-mount a host worktree into the guest — so `Worktree` survives the
   boundary intact, on **both** machines.
2. **TSI — Transparent Socket Impersonation** — gives the guest network connectivity over
   virtio-vsock with *no virtual interface at all*: guest socket calls are impersonated on the
   host. That means the egress choke point is inherent to the design, needing no TAP, no root,
   and no bridge. Enforcing an allow-list there is (inference, not documented) far closer to
   free than forking gvproxy and bolting it onto Firecracker's TAP model.

Between them, libkrun answers §4a's `Worktree` problem *and* §4d's egress problem with
mechanisms it already has, on both target machines, without nested virtualization. It pays for
that with no snapshots — which costs the 5–30 ms fork and the snapshot-a-migrated-DB trick from
(A) above. **That is the real trade to decide, and it is not the trade this document opened
with.**

### Q2 — streaming: a prerequisite for the *measurement*, not the mechanism

`CoreExec` buffers until reply; `Bash` attributes live bytes to the channel. The spike shows a
VM arm works fine buffered, so streaming is not a mechanism prerequisite.

It is a **bench** prerequisite, for a reason specific to what this repo is: if the unconfined
arm streams and the confined arm goes silent for three minutes of `rspec`, the isolation
variable is confounded with an observability variable, and the arms are no longer comparable.
Unequal observability between arms is a study-design defect, not a UX one.

The extension is additive: msgpack-RPC's Notification frame (type 2) is already in the wire
vocabulary and unused by this protocol (`REQUEST = 0`, `RESPONSE = 1`), and `Client`'s single
reader loop is the natural dispatch point. Sequence it after the AF_VSOCK proof and before any
measurement.

## Sources

- [Firecracker README — devices, supported hosts](https://github.com/firecracker-microvm/firecracker) · [snapshot support](https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md) · [vsock protocol](https://github.com/firecracker-microvm/firecracker/blob/main/docs/vsock.md) · [prod host setup](https://github.com/firecracker-microvm/firecracker/blob/main/docs/prod-host-setup.md) · [jailer](https://lib.rs/gh/firecracker-microvm/firecracker/jailer)
- [Firecracker on Apple Silicon PoC — issue #5017](https://github.com/firecracker-microvm/firecracker/issues/5017) · [discussion #5019](https://github.com/firecracker-microvm/firecracker/discussions/5019)
- [Lima VZ docs](https://lima-vm.io/docs/config/vmtype/vz/) · [nested virt PR #2530](https://github.com/lima-vm/lima/pull/2530) · [M3 nested virt issue #2824](https://github.com/lima-vm/lima/issues/2824) · [M4 nested virt issue #4498](https://github.com/lima-vm/lima/issues/4498) · [firecracker-lima-vm](https://github.com/yashdiq/firecracker-lima-vm)
- [Clawk](https://github.com/clawkwork/clawk) — VZ/Firecracker, vsock agent, gvproxy egress allow-list, CoW clones
- [libkrun backends comparison](https://docs.celesto.ai/smolvm/concepts/backends) · [container-to-VM runtimes compared](https://rywalker.com/research/container-vm-runtimes)
- [How to sandbox AI agents in 2026](https://manveerc.substack.com/p/ai-agent-sandboxing-guide) · [28 ms boots via Firecracker snapshots](https://dev.to/adwitiya/how-i-built-sandboxes-that-boot-in-28ms-using-firecracker-snapshots-i0k) · [AWS Lambda MicroVMs](https://aws.amazon.com/blogs/aws/run-isolated-sandboxes-with-full-lifecycle-control-aws-lambda-introduces-microvms/)
- [Firecracker network setup](https://github.com/firecracker-microvm/firecracker/blob/main/docs/network-setup.md) (TAP, bridge, sudo) · [gvproxy / gvisor-tap-vsock](https://github.com/containers/gvisor-tap-vsock) · [libkrun](https://github.com/containers/libkrun) (C API, HVF, virtio-fs, TSI)
- Internal: `spike/vsock_relay_poc.rb` (§6); `references/hn-agent-landscape-2026-07.md` §5 (Clawk, DN42 cost runaway); `lib/lain/worker_env.rb`, `lib/lain/isolation.rb`, `lib/lain/core/{child,client}.rb`, `lib/lain/tools/core_exec.rb`, `crates/lain-core/src/{main,exec}.rs`; `ROADMAP.md` §M5.
