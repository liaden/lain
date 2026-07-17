# Frozen prefix-digest chain corpus — format 1 (pre-rolling-chain)

Byte-for-byte copies of the variance session fixtures as recorded **before**
`Request#prefix_digests` became a rolling chain (`PREFIX_CHAIN_VERSION = 2`).
Their `request_sent` records carry unversioned format-1 chains (a full
stripped-prefix digest per marker, no `prefix_chain_version` key) — the exact
shape of every journal recorded before the migration.

These files exist so `Bench::Rewrites`' dual-read coverage runs against real
old-format bytes, proving old recorded journals stay loadable and still
localize divergence. **Never regenerate them**: `bin/regenerate-session-fixtures`
writes format-2 chains and must only touch `spec/fixtures/sessions/variance/`,
whose job is writer byte-reproducibility, not format archaeology.
