# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The human inbox as a projection (I6): lain://inbox IS
      # {Event::Projection#pending}("human") rendered -- {Buffers}' fourth
      # view, PULL-shaped like its siblings, fed the two record shapes the
      # telemetry tee actually carries:
      #
      # * a {Telemetry::Message} addressed to the human lists (sender, age,
      #   question), and
      # * a {Telemetry::TurnUsage} retires whatever the named head's chain has
      #   cited among its turns' causal_parents -- the delivery commit's edge
      #   ({Agent#perform_tools}), which is the ONLY consumption the pending
      #   projection counts. A REPLY :message alone never retires an item;
      #   that pinned rule is what keeps this view and {StatusFeed}'s
      #   inbox_count in agreement (the parity spec holds them to it).
      #
      # Consumption is a standing digest Set, {StatusFeed}'s own shape, so a
      # replayed log that delivers the consuming turn before the question
      # never lists a retired item. Like {Buffers}, this never touches nvim:
      # it turns records into plain lines; {RpcThread} does the rendering.
      class InboxView
        NAME = "lain://inbox"
        EMPTY = ["(no questions pending)"].freeze

        # {Tools::AskHuman::HUMAN}, named rather than imported for the same
        # reason {StatusFeed::INBOX_RECIPIENT} is: this view depends on the
        # record stream, not on the Tools tree. Both spellings are spec-pinned.
        RECIPIENT = "human"

        # One listed question: who asked, what, and when this view first saw
        # it. `asked_at` is OBSERVATION time by necessity -- events are
        # content-addressed and carry no wall clock -- which is exactly what
        # an inbox's "age" means: how long the item has sat here unanswered.
        Item = Data.define(:from, :question, :asked_at)
        private_constant :Item

        # @param store [Lain::Store] resolves a TurnUsage's head so the chain's
        #   causal edges are readable; the {Buffers::DetachedStore} default
        #   renders consumption as simply never observed, same honesty as the
        #   timeline view's unavailable state
        # @param clock [#call] wall time for ages, injectable so a spec never
        #   races a real clock
        def initialize(store: Buffers::DetachedStore.instance, clock: -> { Time.now })
          @store = store
          @clock = clock
          @pending = {}
          @consumed = Set.new
        end

        # The at-rest projection (see {Neovim#prime_views}): the inbox exists
        # from attach, saying it is empty rather than reading as broken.
        # @return [Hash{String=>Array<String>}]
        def initial
          { NAME => EMPTY.dup }
        end

        # @param event [Object] one Channel event
        # @return [Array<String>, nil] full replacement lines when the pending
        #   set moved, nil otherwise (ages alone never force a rewrite --
        #   {Buffers#workspace_update}'s change-guard idiom)
        def update(event)
          moved = question?(event) ? arrive(event) : consume(event)
          moved ? render : nil
        end

        private

        def question?(event)
          event.respond_to?(:kind) && event.kind == :message && event.to == RECIPIENT
        end

        # @return [Item, nil] the newly listed item, nil when the question is
        #   already listed or already consumed
        def arrive(event)
          return nil if @consumed.include?(event.digest) || @pending.key?(event.digest)

          @pending[event.digest] = Item.new(from: event.from, question: question_text(event),
                                            asked_at: @clock.call)
        end

        # The consuming edges ride committed turns, and what the tee carries
        # for a commit is a {Telemetry::TurnUsage} naming the head -- so the
        # cited digests are read off the head's chain in the shared Store,
        # {Buffers#timeline_update}'s idiom, including its never-raise rule: a
        # head this store cannot resolve is a miss, not a drain-thread death.
        def consume(event)
          return false unless event.respond_to?(:usage) && event.respond_to?(:digest)

          cited_by_chain(event.digest).inject(false) do |moved, digest|
            @consumed << digest
            !@pending.delete(digest).nil? || moved
          end
        end

        def cited_by_chain(head_digest)
          Timeline.new(head_digest:, store: @store).to_a.flat_map(&:causal_parents)
        rescue Store::MissingObject
          []
        end

        def question_text(event)
          body = event.respond_to?(:payload) ? event.payload : event.body
          body.is_a?(Hash) ? body.fetch("question", "(no question text)") : "(no question text)"
        end

        def render
          return EMPTY.dup if @pending.empty?

          @pending.values.map { |item| line_for(item) }
        end

        # Sender and age lead, mirroring the TTY drain's listing: a glance
        # answers "who is stuck, and for how long" before the question reads.
        def line_for(item)
          "#{item.from.to_s[0, 19]}  #{age_of(item.asked_at)}  #{item.question}"
        end

        def age_of(asked_at)
          seconds = (@clock.call - asked_at).to_i
          return "#{seconds}s" if seconds < 60
          return "#{seconds / 60}m" if seconds < 3600

          "#{seconds / 3600}h"
        end
      end
    end
  end
end
