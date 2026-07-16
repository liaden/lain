# frozen_string_literal: true

require "json"

module Lain
  module Frontend
    class Neovim
      # The one EDITABLE lain:// view (4-2.3): `lain://request` shows the pending
      # request as pretty JSON a human can edit in place, and `:LainResend` feeds
      # the edited buffer back as a fresh {Telemetry::RequestSent} -- journaled
      # like any other request and diffed by {Buffers} against the original, so
      # "edit it, resend, watch what changed" is a pure, agent-free projection.
      # The re-render/diff reuse is deliberate: a resent request travels the same
      # Channel path an agent request does, so {Buffers}' diff and this buffer's
      # own render handle it with no special case (the shape {Bench::DryReplay}
      # already leans on -- a request is DATA, re-renderable and diffable).
      #
      # Non-destructive by construction. A resend NEVER commits to the Timeline
      # and never reaches into the Agent -- the frontend holds no commit path at
      # all. That is a stronger statement than "speculative fork, not rewrite":
      # `Timeline#fork` is O(1) and returns the same value, and nothing here can
      # move a head, so the original head stays reachable no matter how many
      # resends fire.
      #
      # Threading. {#updates} runs on the frontend's drain thread (turning an
      # agent RequestSent into the editable buffer and remembering it as the
      # resend baseline); {#resend} runs on the resend-worker thread (turning
      # edited lines back into a RequestSent). The baseline is the one piece of
      # state those two threads share, so a Mutex guards exactly it -- and
      # nothing else here is mutable.
      #
      # Known limitation (accepted, T16 panel): a NEW RequestSent arriving while
      # a human is mid-edit replaces the whole buffer -- their unsent keystrokes
      # are clobbered. That is last-writer-wins on a buffer with two writers,
      # and the honest fix (dirty-buffer detection, or a CRDT -- see
      # planning/crdt-exploration.md) is real work this card does not owe. In
      # practice the window is narrow: requests arrive between turns, and a
      # human edits while the agent is idle.
      class RequestBuffer
        REQUEST = "lain://request"

        # @param journal [#<<] where a resent request is recorded -- the very
        #   duck {Agent::Accounting} and {Middleware::JournalRequests} write to,
        #   so a resend journals "like any other". The Null channel by default,
        #   so no caller guards `if journal`.
        def initialize(journal: Channel::Null.instance)
          @journal = journal
          @mutex = Mutex.new
          @baseline = nil
        end

        # Drain-thread projection: an agent (or resent) RequestSent becomes the
        # editable buffer and the new resend baseline. Every other event moves
        # nothing.
        # @param event [Object] one Channel event
        # @return [Hash{String=>Array<String>}] `{REQUEST => lines}` or `{}`
        def updates(event)
          return {} unless event.is_a?(Telemetry::RequestSent)

          @mutex.synchronize { @baseline = event }
          { REQUEST => payload_lines(event.payload) }
        end

        # Resend-worker: edited buffer lines become a fresh {Telemetry::RequestResent}
        # -- a RequestSent for every projection, but journaled under its own
        # discriminator so mining never reads a hand-edit as a failed real
        # dispatch (see RequestResent) -- recorded to the journal and returned
        # for the drain thread to diff and re-render. `nil` when there is
        # nothing to resend yet (no request seen) or the buffer no longer holds
        # valid JSON -- a malformed edit is a silent no-op, never an exception
        # thrown on the worker thread (whose death would strand the resend inbox).
        # @param lines [Array<String>] the current `lain://request` buffer
        # @return [Telemetry::RequestResent, nil]
        def resend(lines)
          resent = build(lines, @mutex.synchronize { @baseline })
          @journal << resent if resent
          resent
        end

        private

        # The edit lives only in the buffer bytes, so a resend rebuilds the whole
        # record from them: the payload is the edited JSON, while `stream` and
        # `extra` (transport, not shown in the buffer) ride along from the
        # baseline. The digest is recomputed over the edited payload -- the same
        # content address {Request#digest} would give it.
        def build(lines, base)
          return nil if base.nil?

          payload = parse(lines)
          payload && Telemetry::RequestResent.new(digest: Canonical.digest(payload), payload:,
                                                  stream: base.stream, extra: base.extra)
        end

        def parse(lines)
          JSON.parse(lines.join("\n"))
        rescue JSON::ParserError
          nil
        end

        def payload_lines(payload)
          JSON.pretty_generate(payload).split("\n")
        end
      end
    end
  end
end
