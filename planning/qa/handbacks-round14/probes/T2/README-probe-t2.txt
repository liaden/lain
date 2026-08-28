T2 review probes (untracked scratch; delete when the card lands).

probe_t2_rendered_bytes.rb   A/B: renders an 11-case corpus twice, once with the
                             card's ApprovalView and once with probe_t2_approval_view_AT_HEAD.rb
                             re-opened over it, and compares SHA256 of the lines.
                             Run:  bundle exec ruby probe-t2/probe_t2_rendered_bytes.rb now
                                   bundle exec ruby probe-t2/probe_t2_rendered_bytes.rb head
probe_t2_members.rb          Proves the A/B harness really swaps implementations.
probe_t2_alignment_and_payload.rb  calls-vs-rows alignment, and what the per-row
                             duplication costs in bytes.
probe_t2_cost.rb             The same cost in msgpack wire bytes and in call_of time.
probe_t2_lua_roundtrip.rb    Live headless nvim: what b:lain_approval_calls does when
                             `calls` is nil/short/long/a String, and whether vim.b
                             round-trips multibyte, quotes, newline, tab and NUL.

A bare `bundle exec rubocop` lints this directory. Scope to `lib spec bin`.
