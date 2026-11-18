# lain-wire

The messages the phone and lain exchange through the relay. Structs encode as msgpack maps and
enums as one-key maps, so Ruby's msgpack gem reads and writes the same bytes. `crates/lain-daemon`
and `apps/lain-remote` both depend on it, and `lib/lain/remote/wire.rb` is the Ruby side.

## Build

It is a library, `lain-wire`, built with the workspace:

```bash
cargo build -p lain-wire
```

## Tests

```bash
cargo test -p lain-wire
```

`tests/fixtures/` holds `.msgpack` files, such as `agenda_page.msgpack`, that pin the bytes.

## Layout

`src/lib.rs` holds everything: the message types plus `encode`, `decode` and `WIRE_VERSION`.

## Constraints

- Never build a msgpack map by hand. Payloads go through `lain_wire::encode` and `decode`.
- The phone app is sideloaded and is not rebuilt when lain is. Its `Hello` carries `WIRE_VERSION`
  and the relay refuses a mismatch.
- An offer's request and row cross the daemon as values it never reads.

Related: [`../lain-daemon`](../lain-daemon), [`../../apps/lain-remote`](../../apps/lain-remote),
[phone approvals](../../docs/users/remote.md).
