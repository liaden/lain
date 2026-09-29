# frozen_string_literal: true

require "async"

module Lain
  module Tools
    class Subagent < Tool
      # Records a spawn's causal lineage as events in the shared Store:
      # {Subagent} runs the child, this writes the record. Both events are
      # causal-only, so neither enters any render chain -- `meet`, the
      # first-parent walk and gate 2 are untouched.
      class Lineage
        # Every event this writer puts into the shared Store is also appended
        # to `log` in EMISSION ORDER, so a mailbox {Event::Projection} can fold
        # it. The one-shot path injects {Log::Null}, whose appends vanish.
        #
        # `observer` is the outward slot on the same funnel. A further observer
        # must COMPOSE with the @log append, as this constructor does, never
        # SUBSTITUTE for it -- or @log's mailbox fold silently stops.
        # `lane` names the spawn lane an actor is launched in; empty for the
        # run's own. See {#spawn}.
        def initialize(policy:, log: Log::Null, observer: Event::ChainWriter::Null.new, lane: "")
          @policy = policy
          @log = log
          @lane = lane
          @adoptions = Hash.new(0)
          @chain_writer = Event::ChainWriter.new(observer: lambda { |event|
            @log << event
            observer.call(event)
          })
        end

        # The causal record the fresh root omits: its edge to H is what keeps
        # lineage reconstructable when the child's render chain shares nothing
        # with the parent's. Put into the SHARED Store, where H already lives,
        # so referential integrity holds.
        #
        # This event's digest is an ADDRESS: an actor's `tell` names it, and so
        # do the window `--windows` opens and `lain watch` for a one-shot too.
        # Two calls in one assistant turn spawn from one head, so without the
        # work in the body the fleet, the journal and a watch read the pair as
        # one. `task` is the DIGEST of the prompt, not its text: the prompt is
        # already the child's first turn, and the record should not grow by it.
        # Content-derived, so identity survives a resumed run and a role spawn's
        # per-call writer. Identical twins keep sharing one address because the
        # same work from one head IS the same spawn -- a ruling, not a
        # dependency: the session record dedupes a child's turns on their own
        # digests, which never cite the spawn.
        #
        # `lifecycle`, `adoption` and `unattended` are written CONDITIONALLY.
        # `unattended` is in the record because without it a recorded spawn no
        # longer determines the child's toolset, the one property a bench reader
        # replays a spawn to check.
        #
        # `adoption` separates what `task` cannot: two launches of one arm on
        # the same work from one head, which as live actors must not share an
        # address. A COUNTER, not a nonce, and that is the binding constraint: a
        # nonce would not break replay (a record rebuilds from its own recorded
        # body) but would break CROSS-RUN reproducibility, and two runs of one
        # bench arm could then not be joined on a spawn digest.
        #
        # Its scope is this WRITER; {#next_adoption} says what that leaves open.
        # A named `lane` closes the part of it two issues' actors meet: each
        # issue's writer counts from 1 over the chat's one head, and the lane
        # is what their spawns then differ by. The run's own lane writes none.
        def spawn(parent, prompt:, lifecycle: nil)
          head = parent.head_digest
          body = { "prefix" => @policy.prefix.label, "posture" => @policy.posture.label,
                   "only" => @policy.only, "spawned_from" => head, "task" => Canonical.digest(prompt) }
          body["unattended"] = true if @policy.unattended
          body.merge!(adopted(head, lifecycle, body, parent.store)) unless lifecycle.nil?
          put(parent, kind: :spawn, from: correlation_of(parent), to: nil,
                      causal_parents: [head].compact, body:)
        end

        # The return as a first-class event -- the schema has no `:result`
        # kind, and a result IS a message. It names the :spawn and the child's
        # final turn F, so a provenance walk reaches both intent and answer.
        #
        # The JOIN to the parent is at CORRELATION grain -- the parent chain's
        # root digest, NOT the parent's rendered tool_result turn, which keeps
        # `causal_parents` empty so ToolRunner and Timeline#commit stay out of
        # this seam. A walk therefore enters at the correlation, finds this
        # :message, and descends to the :spawn and F. Edge-grain linkage is
        # deliberately not built here.
        #
        # The completion is a TRANSITION, so it carries the same discriminator
        # every other transition does -- STOPPED, because a one-shot child is
        # done for good, exactly as an actor's farewell is. Written
        # UNCONDITIONALLY: future completions hash differently from the ones
        # on disk, which is safe because a recorded journal re-derives its
        # digest from its own recorded body. This closes the vocabulary's
        # TERMINAL end only -- a one-shot's :spawn still writes no "launched"
        # (see {#spawn}), so "did this spawn start" is still `kind == :spawn`.
        # A child that never answered ends in {#ended} instead.
        def message(parent, spawn, child, response)
          final = child.head_digest
          body = { "result" => response.text, "final" => final,
                   "lifecycle" => StatusFeed::SpawnLifecycle::STOPPED }
          put(parent, kind: :message, from: correlation_of(child), to: correlation_of(parent),
                      causal_parents: [spawn.digest, final].compact, body:)
        end

        # A one-shot whose child did not answer: it raised, and `error` names
        # the class, or its task was stopped. No `"result"`, which is what keeps
        # it out of every reader of finished work; `"final"` only when the child
        # has a head to name.
        def ended(parent, spawn, child, lifecycle:, error: nil)
          final = child.head_digest
          body = { "lifecycle" => lifecycle, "error" => error, "final" => final }.compact
          put(parent, kind: :message, from: correlation_of(child), to: correlation_of(parent),
                      causal_parents: [spawn.digest, final].compact, body:)
        end

        # A plain message between two chain identities, carrying the renderable
        # `text` {Context::Mailbox} folds. The actor's inbound and outbound both
        # go through here.
        #
        # `lifecycle` is the body-level discriminator a reader keys on WITHOUT
        # parsing prose. Its ABSENCE is meaningful: a tell is conversation, not
        # a transition.
        def note(parent, from:, to:, text:, causal_parents:, lifecycle: nil)
          body = { "text" => text }
          body["lifecycle"] = lifecycle unless lifecycle.nil?
          put(parent, kind: :message, from:, to:, causal_parents:, body:)
        end

        # The parent chain's root digest, the same identity {#put} stamps on
        # every event. Public so an {Actor} can address the parent without
        # reaching into `identity`.
        def correlation_of(timeline) = Event::ChainWriter.correlation_of(timeline)

        # A write that ends a one-shot and could not land: `record` names which
        # -- the `completion` or the `questions_consumed` -- and `error` the
        # class of what refused it, never its message. It speaks the completion
        # duck the fleet readers retire on, a `:message` citing the spawn and
        # carrying the lifecycle mark, because a spawn whose completion was lost
        # has still ended, and a fleet that waited for the lost record would
        # count it running for the rest of the session.
        EndingNotRecorded = Data.define(:spawn, :record, :lifecycle, :error) do
          include Telemetry::Journalable

          def initialize(spawn:, record:, lifecycle:, error:)
            super(spawn: -spawn.to_s, record: -record.to_s, lifecycle: -lifecycle.to_s, error: -error.to_s)
          end

          def kind = :message
          def to = nil
          def causal_parents = [spawn].freeze
          def payload = { "lifecycle" => lifecycle }.freeze
        end

        private

        # Keyed by the head, the scope a collision lives in: two adoptions from
        # ONE head. Different heads already differ in `spawned_from`, and a
        # per-head sequence is what makes an identical second run replay the
        # same numbers in the same order.
        #
        # Scoped to THIS writer: a second writer over the same head starts at 1
        # again. {#adopted} is what keeps it from colliding, by skipping every
        # ordinal the shared Store already holds a record for, so a relaunch
        # or a resumed run over that Store takes the next free address and its
        # digest depends on what the Store holds. Two writers over DIFFERENT
        # Stores still count independently.
        #
        # Unsynchronized, and safe only because nothing between the read, the
        # Store check in {#adopted} and the write suspends the fiber; behind an
        # await two writers could pick one ordinal, or one writer issue
        # duplicates, with nothing raised.
        #
        # One entry per head ever actor-spawned from, never evicted: O(actor
        # launches), a session-sized Hash rather than a leak.
        def next_adoption(head)
          @adoptions[head] += 1
        end

        # The marks only an actor's spawn carries, its lane among them when it
        # has one. The count skips every ordinal whose record the shared Store
        # already holds, because a relaunch of failed work builds a second
        # writer over the same head and would otherwise take the first
        # attempt's address, which the fleet has already retired for good.
        def adopted(head, lifecycle, body, store)
          Enumerator.produce { marks_for(head, lifecycle) }.find { |marks| !recorded?(store, body.merge(marks)) }
        end

        def marks_for(head, lifecycle)
          marks = { "adoption" => next_adoption(head), "lifecycle" => lifecycle }
          @lane.empty? ? marks : marks.merge("lane" => @lane)
        end

        def recorded?(store, body) = store.key?(Event::Payload.new(kind: :spawn, body:).digest)

        # The payload-then-envelope write, delegated so @chain_writer is its
        # one home.
        def put(parent, kind:, from:, to:, causal_parents:, body:)
          @chain_writer.put(parent, kind:, from:, to:, causal_parents:, body:)
        end

        # One one-shot dispatch's record, from its :spawn to whichever
        # completion ends it. One per dispatch and never shared, so a fan-out
        # sibling resuming mid-flight cannot make a completion name the wrong
        # spawn or child.
        class OneShot
          # A spawn whose child was never built -- its context would not render,
          # its stack would not close -- has no head and asked nothing.
          module Unbuilt
            def self.settled = Timeline.empty
            def self.asked = []
          end

          attr_reader :parent

          # @param lineage [Lineage] the writer
          # @param parent [Timeline] the head the spawn is made from
          # @param consumed [#<<] the journal the live inbox surfaces fold, where
          #   a question the child left parked is named consumed
          # @param journal [#<<] the session record, where a loss is noted when
          #   `consumed` refuses it too
          def initialize(lineage, parent, consumed:, journal:)
            @lineage = lineage
            @parent = parent
            @consumed = consumed
            @journal = journal
            @spawn = nil
            @child = Unbuilt
            @open = true
          end

          # Runs one dispatch, and ends the record however it exits: a raise
          # writes `failed`, and any exit that is not a StandardError -- a
          # cancel raises `Async::Stop` -- writes `stopped`.
          def recording
            yield self
          rescue StandardError => e
            ended(StatusFeed::SpawnLifecycle::FAILED, error: e.class.name)
            raise
          ensure
            ended(StatusFeed::SpawnLifecycle::STOPPED)
          end

          def spawned(prompt) = @spawn = @lineage.spawn(@parent, prompt:)

          # @param child [#settled, #asked] the child this spawn built
          # @return the child, so a build reads as one expression
          def built(child) = @child = child

          # @return [Response] what the parent is given
          def finished(timeline, response)
            @open = false
            @lineage.message(@parent, @spawn, timeline, response)
            response
          end

          private

          # Nothing ends a spawn that never happened -- a refused lease writes
          # no :spawn. Shielded from a further stop, because this runs while
          # the task is already unwinding and a write is a suspension point:
          # `defer_stop` holds off one more cancel, the one a reactor teardown or
          # an ancestor task lands on a run already stopping.
          def ended(lifecycle, error: nil)
            return unless @open && @spawn

            @open = false
            shielded do
              completed(lifecycle, error)
              retired(lifecycle)
            end
          end

          def shielded(&block)
            task = Async::Task.current?
            task ? task.defer_stop(&block) : yield
          end

          # Each write catches its own failure, so a lost completion never costs
          # the question its retirement, and neither replaces the exception
          # already climbing.
          def completed(lifecycle, error)
            @lineage.ended(@parent, @spawn, @child.settled, lifecycle:, error:)
          rescue StandardError => e
            lost("completion", lifecycle, e)
          end

          # A question is listed until something in the record names it
          # consumed, and the child's turn that would have done so never comes.
          def retired(lifecycle)
            digests = @child.asked
            @consumed << Telemetry::QuestionsConsumed.new(turn: nil, digests:) unless digests.empty?
          rescue StandardError => e
            lost("questions_consumed", lifecycle, e)
          end

          # The live-view journal first, which in a chat is also the session
          # file; the session record alone when that is what refused.
          def lost(record, lifecycle, error)
            loss = EndingNotRecorded.new(spawn: @spawn.digest, record:, lifecycle:, error: error.class.name)
            [@consumed, @journal].find { |sink| noted?(sink, loss) }
          end

          def noted?(sink, loss)
            sink << loss
            true
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
