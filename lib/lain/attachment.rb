# frozen_string_literal: true

module Lain
  # Bytes a turn refers to but must not carry: a screenshot, a rendered page, a
  # binary a tool produced. They live on disk at their content address, and only
  # the address rides the Timeline.
  #
  # The measurement that forced the split: base64 of a single 219 KB screenshot
  # clears the compaction threshold on its own, and an inline block is
  # re-serialized into EVERY later `request_sent` -- 86x the journal over ten
  # exchanges, against +1.2 KB for the reference. The wire payload is identical
  # either way, because the bytes are put back on the way out. The cost was never
  # CPU; it was bytes at rest, multiplying the growth `Telemetry::RequestSent`
  # already accepts.
  #
  # {Store} is the whole of the subsystem today, and it is deliberately NOT
  # {Lain::Store}: that one is an in-memory Hash of DAG nodes that dies with the
  # process, and these bytes have to outlive it and be found again by a resumed
  # chat, a fork or a child agent. So this is a directory, keyed by the PROJECT
  # under {Paths#container} beside `sessions/`, addressing bytes rather than
  # objects. `Store::KIND` names that directory and `Store::TAG` the keyspace its
  # digests belong to; both are read from outside.
  #
  # What is NOT here, and is load-bearing: nothing substitutes an address back
  # for its bytes. That has to happen downstream of the Request, in the
  # provider's encoding stage -- base64 is valid UTF-8, so an encoded payload
  # reaching {Canonical.normalize} would be interned silently and without bound,
  # and doing the substitution in {Context#render} would cost that AND the purity
  # the prompt cache rests on.
  module Attachment
  end
end
