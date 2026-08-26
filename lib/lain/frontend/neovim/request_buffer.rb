# frozen_string_literal: true

require "json"

module Lain
  module Frontend
    class Neovim
      # The one EDITABLE lain:// view: `lain://request` shows the pending
      # request as pretty JSON a human can edit in place, and `:LainResend` feeds
      # the edited buffer back as a fresh record -- journaled like any other
      # request and diffed by {Buffers} against the original. A resent request
      # travels the same Channel path an agent request does, so the diff and this
      # buffer's own render handle it with no special case.
      #
      # NON-DESTRUCTIVE BY CONSTRUCTION: it never commits to the Timeline and
      # never reaches into the Agent -- the frontend holds no commit path at all,
      # so nothing here can move a head however many resends fire. Whether the
      # resent request also DISPATCHES is the injected bridge's business, one
      # level up, and that dispatch commits onto a rewound head whose dropped
      # turn stays reachable in the Store: a speculative fork, never a rewrite.
      #
      # Threading. {#updates} runs on the frontend's drain thread; {#resend} runs
      # on the resend-worker thread. The baseline is the one piece of state those
      # two share, so a Mutex guards exactly it, and nothing else here is mutable.
      #
      # KNOWN LIMITATION: a new RequestSent arriving while a human is mid-edit
      # replaces the whole buffer and clobbers their unsent keystrokes --
      # last-writer-wins on a buffer with two writers. The honest fix
      # (dirty-buffer detection, or a CRDT) is work this class does not owe, and
      # the window is narrow: requests arrive between turns.
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

        # The at-rest projection, posted once at attach (see {Buffers#initial}).
        # Deliberately NOT empty JSON: with no baseline yet {#resend} is already
        # a no-op, and a plausible-looking empty request would invite editing a
        # request that does not exist.
        # @return [Hash{String=>Array<String>}]
        def initial
          { REQUEST => ["(no request yet)"] }
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

        # {#build}'s inverse, for the resend bridge's dispatch offer: the payload
        # keys are exactly Request.new's content keywords, with the
        # digest-excluded transport fields carried alongside. It lives HERE
        # because the record's shape is this class's knowledge, and it RAISES on
        # a payload that parses as JSON but is not request-shaped -- the caller
        # decides what a raise means.
        # @param resent [Telemetry::RequestResent]
        # @return [Lain::Request]
        def rebuild(resent)
          Request.new(stream: resent.stream, extra: resent.extra,
                      **resent.payload.transform_keys(&:to_sym))
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
