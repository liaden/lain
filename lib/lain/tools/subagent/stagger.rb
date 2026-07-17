# frozen_string_literal: true

require "async"

module Lain
  module Tools
    class Subagent < Tool
      # CE-5's stagger scheduling policy: release sibling 1 alone, await its
      # `stream_started` signal (the earliest point its cache WRITE becomes
      # probe-able -- {Provider::StreamStartedSignal}), then release siblings
      # 2..N together. Lain owns the loop (CLAUDE.md), so this scheduling is
      # ours to make: fan N cache-sibling children out simultaneously and all
      # N pay full prefill, because none of their writes is probe-able yet;
      # staggering by one first-token wait is what turns N-1 of them into
      # reads instead of cold prefills (`cache-economics.md` CE-5).
      #
      # `tasks` are dispatch units, not {Tools::Subagent} instances -- the
      # policy is deliberately generic over anything answering
      # `#call(on_stream_started:)`, the same duck CE-5 already gave
      # `Provider#complete` (see {Provider::StreamStartedSignal}). Threading
      # an actual sibling-template fan-out through it is the spawn seam's
      # job, not this policy's: {Subagent}/{Agent} do not plumb
      # `on_stream_started` through today, so this class owns exactly the
      # scheduling, and nothing about how a "child" runs.
      #
      # == Fiber-parked, not reactor-blocked
      #
      # {Promise#await} parks the calling FIBER, so waiting for sibling 1's
      # first token never blocks the reactor thread -- other work proceeds on
      # the SAME thread while this one fiber waits. `Sync` is the same "join
      # a reactor if there is one, spin one up otherwise" idiom
      # {Agent::ToolRunner#gather} already uses, so a direct caller outside a
      # reactor still works.
      #
      # == A DOCUMENTED gap: #call still hangs if sibling 1 stalls AFTER
      # streaming starts
      #
      # "Never hangs" (see {#call}'s degrade path) covers only the PRE-signal
      # case: a provider that never calls `on_stream_started` at all. A
      # provider that fires it and then never completes and never raises --
      # a stalled stream, first token arrived, then silence -- still wedges
      # the whole fan-out: `gate` opens (siblings 2..N dispatch normally),
      # but `[first, *rest].map(&:wait)` waits on sibling 1's own task
      # forever, because nothing bounds HOW LONG a dispatch unit itself may
      # run. Reproduced in review (tmp/c3-probes/probe_c_hang_after_stream_
      # started.rb). Bounding sibling 1's own completion -- a timeout or
      # explicit cancellation on the dispatch unit itself, independent of
      # this policy's release gate -- is a later card's job: {Stagger} owns
      # WHEN to release, not how long any one dispatch may take.
      class Stagger
        # One line per dispatch, in ACTUAL start order -- {#call} returns
        # results in `tasks`' own order, so this is the only place dispatch
        # order (as opposed to completion order) is recoverable from the
        # record. `index` is the task's position in the fan-out (0 is
        # sibling 1, the one dispatched alone).
        Dispatched = Data.define(:index) do
          include Telemetry::Journalable

          def initialize(index:)
            super(index: Integer(index))
          end
        end

        # Valid {Released#reason}s. A named, top-level constant -- not
        # defined inside the `Data.define ... do` block below, which is
        # lexically scoped to `Stagger` (the {Request::SYSTEM_PREFIX} trap
        # CLAUDE.md documents) but which RuboCop also flags for constant
        # DEFINITIONS specifically (`Lint/ConstantDefinitionInBlock`).
        RELEASE_REASONS = %i[stream_started degraded].freeze

        # The moment siblings 2..N are released, and why: `:stream_started`
        # is CE-5's natural release; `:degraded` is the safety valve for a
        # task that never signals (see {#call}) -- journaled so a fan-out
        # that quietly never staggered is visible in the record rather than
        # reading identically to a real cache win.
        Released = Data.define(:reason) do
          include Telemetry::Journalable

          def initialize(reason:)
            unless RELEASE_REASONS.include?(reason)
              raise ArgumentError, "reason must be one of #{RELEASE_REASONS.inspect}, got #{reason.inspect}"
            end

            super
          end
        end

        def initialize(journal: Channel::Null.instance)
          @journal = journal
        end

        # `tasks`: an ordered Array of dispatch units, each answering
        # `#call(on_stream_started:)`. Task 0 dispatches alone; every other
        # task dispatches only once task 0's `on_stream_started` fires, or --
        # the degrade path -- once task 0's own call returns (or raises)
        # having never fired one. A non-streaming provider has no earlier
        # point to signal at, so "task 0 is done" is the honest fallback
        # release rather than a hang.
        #
        # Returns results in `tasks`' own order regardless of finish order --
        # the same "gather, don't just await" contract
        # {Agent::ToolRunner#gather} keeps for gate 2.
        #
        # @param tasks [Array<#call>]
        # @return [Array] one result per task, in `tasks`' order. `[]` for an
        #   empty fan-out -- there is no sibling 1 to release anything from.
        def call(tasks)
          return [] if tasks.empty?

          Sync do |root|
            gate = Promise.new
            first = root.async(finished: false) { dispatch_first(tasks.first, gate) }
            @journal << Released.new(reason: gate.await)
            [first, *release_rest(root, tasks.drop(1))].map(&:wait)
          end
        end

        private

        # `finished: false` on BOTH this and sibling 1's own spawn (see
        # {#call}) is not cosmetic: a task whose block raises before its own
        # first yield is, from the async gem's point of view, an "unhandled
        # exception" the instant it happens, and it logs one straight to
        # STDERR -- regardless of whether `.wait` later re-raises and a
        # caller handles it perfectly. A degraded/raising sibling 1 is an
        # ANTICIPATED path here (see `dispatch_first`'s `ensure`), not a bug,
        # so that warning is a false alarm -- but a false alarm on STDERR is
        # exactly the catastrophe CLAUDE.md's output discipline exists to
        # prevent: the Journal is NDJSON, and one stray interleaved line
        # breaks `JSON.parse` on it. `finished: false` suppresses the async
        # gem's own warning without touching exception propagation (verified
        # against `Async::Task#initialize`, which only toggles
        # `@promise.suppress_warnings!`).
        def release_rest(root, tasks)
          tasks.each_with_index.map do |task, offset|
            root.async(finished: false) { dispatch(task, index: offset + 1) }
          end
        end

        # Sibling 1's own dispatch. `gate` opens the instant `on_stream_started`
        # fires (the natural release). The `ensure` is what makes the degrade
        # path safe under EITHER a clean return (a non-streaming provider
        # completed having never signalled) or a raise (sibling 1's dispatch
        # failed before ever streaming) -- both leave `gate` unopened without
        # it, and an unopened gate is a fan-out that hangs forever. #open_once
        # makes "exactly one opening reason wins" structural rather than
        # relying on {Promise}'s own raise on a double #resolve.
        def dispatch_first(task, gate)
          @journal << Dispatched.new(index: 0)
          task.call(on_stream_started: ->(_digest) { open_once(gate, :stream_started) })
        ensure
          open_once(gate, :degraded)
        end

        def dispatch(task, index:)
          @journal << Dispatched.new(index:)
          task.call(on_stream_started: ->(_digest) {})
        end

        def open_once(gate, reason)
          gate.resolve(reason) unless gate.resolved?
        end
      end
    end
  end
end
