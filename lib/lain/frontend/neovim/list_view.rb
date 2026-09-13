# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # What a list view has handed the editor, and which of it the editor can
      # still be holding. lain://inbox and lain://approval both draw rows a
      # keypress answers, and a keypress can only carry a LINE, so both need the
      # same rule; this is the one place it is stated.
      #
      # THE STAMP IS THE WHOLE OF THE IDENTITY. These buffers' positions are not
      # stable -- a retired item takes its row out and every row below it moves
      # up while the render that removes it is still queued for nvim -- so a
      # line alone names a POSITION, and a position read against the wrong
      # rendering answers the NEIGHBOURING row, with both values legal and
      # nothing downstream able to notice. A height cannot separate two
      # renderings either: the empty-state placeholder and a one-item list are
      # both one line.
      #
      # A LATE RENDER CANNOT STEAL AN OLDER GESTURE'S ANSWER. {#at} matches by
      # stamp EQUALITY, never by recency, so two renders racing leave two
      # entries and each gesture is answered by the rendering it was actually
      # made on. That holds only while a stamp names one rendering forever,
      # which is why they are minted here rather than accepted, strictly
      # increasing, and never reused -- {#forget} drops a rendering without
      # rewinding the counter for exactly that reason. What ages one out is the
      # ring filling, a memory bound rather than a correctness one: a rendering
      # still held resolves exactly, one gone is refused BY NAME.
      #
      # THE STAMP STORED AND THE STAMP SENT ARE ONE VALUE for the caller that
      # posts. {#remember} mints and returns in one call, so {ApprovalView}
      # sends the number it was handed rather than a candidate read off the
      # counter beforehand. The two shapes differ only when a render lands
      # BETWEEN the read and the store -- both then take the same unchanged
      # counter and go out carrying one number for two renderings -- so that is
      # what pins it, at the surface rather than here: `approval_view_spec.rb`
      # forces the interleave and holds the two posts to two distinct stamps.
      # WHICH rendering the editor ends up showing is settled by the render
      # queue on the RPC thread, so that half is only visible across threads.
      #
      # IT IS NOT A PROPERTY OF EVERY CALLER, and saying so would overstate what
      # this object provides. {InboxView} does not post -- it hands lines up to
      # {Surfaces}, which reads the stamp back through {Buffers#generation_of}
      # in a SECOND `@slot` acquisition. That is the same value today only
      # because the render and the post are one drain thread's consecutive work
      # with no render in between: an ordering that holds, not a guarantee
      # {#remember} can make for it.
      #
      # IT CARRIES NO PAYLOAD BUT `owners`. lain://approval also ships `calls`
      # and a `call_index` to the editor, but both are consumed by the post that
      # sends them and neither is read back out, so they stay on that view's own
      # render value: a ring that knew what a tool call was would not be a ring.
      #
      # LOCK-FREE, WHICH IS A LICENSE ITS HOLDERS GRANT AND NOT A PROPERTY OF
      # THIS FILE. Nothing here is atomic, so every holder owes its own
      # serialization. {InboxView} pays it with `@slot`, held across every
      # public method. {ApprovalView} pays it for TWO of its three callers --
      # `#sweep` and `#decide` are fibers of one reactor thread with no yield
      # point between reading its state and writing it.
      #
      # THE THIRD IS NOT COVERED, and it is named here rather than left for the
      # next reader to discover. {ApprovalView#prime} reaches {#remember} from
      # the DRAIN thread (`Neovim#run` spawns it, `#drain` primes the surfaces),
      # and nothing orders that against the first sweep on the reactor: the
      # construction order {ApprovalView#prime} argues is not an execution
      # guarantee, because nothing waits for the primer. The gap predates this
      # object and has its own card. What matters HERE is that a view joining
      # this ring must check its own callers rather than inherit that sentence
      # -- the argument is per-holder, and one of them is already short.
      class ListView
        # The STAMP a buffer carries and what OWNS each of its lines.
        #
        # ONE ENTRY PER LINE, NEVER ONE PER ITEM. Addressing the listed items as
        # `owners[line - 1]` is the same answer only while every item is exactly
        # one line; the moment an item wraps under its summary that arithmetic
        # names the NEIGHBOURING item.
        Held = Data.define(:generation, :owners) do
          def stamped?(named) = generation == named

          # The 1-based/0-based seam, guarded here rather than at each caller:
          # line 0 would index -1, which is the LAST line -- a cursor nvim
          # never reports would silently answer the newest row. `Integer` is
          # ARMOR and not a parsing feature: nvim sends a cursor line as a
          # number, and what this buys is that something else crossing msgpack
          # owns nothing rather than raising on the consumer's fiber, which has
          # no caller left to report to.
          def at(line)
            index = Integer(line, exception: false)
            index&.positive? ? owners[index - 1] : nil
          end
        end
        private_constant :Held

        # What a line and a stamp name, or which of the two ways they name
        # nothing. It carries a NAME and not prose: the sentence is the view's,
        # because each names its own buffer and lain://inbox has three further
        # refusals ("not pending", "already answered", "cannot be read") that
        # are about its listing rather than about its rendering.
        # `:unowned` -- held rendering, no row on that line (line 0, past the
        # end, the trailer, the placeholder) -- gets no predicate of its own:
        # both callers reach it by finding `#owned?` false, so one would have
        # had no caller but its own spec.
        Resolution = Data.define(:owner, :outcome) do
          # The rendering is one this view still holds and the line is a row.
          def owned? = outcome == :owned

          # The buffer the human is looking at is not a rendering this view
          # still holds -- it re-rendered, or was never stamped at all.
          def unshown? = outcome == :unshown
        end

        UNSHOWN = Resolution.new(owner: nil, outcome: :unshown)
        private_constant :UNSHOWN

        UNOWNED = Resolution.new(owner: nil, outcome: :unowned)
        private_constant :UNOWNED

        # @param held [Integer] how many renderings stay resolvable. A MEMORY
        #   bound, not a rule about correctness, which is the difference the
        #   stamp makes -- so it is the caller's number rather than one here:
        #   lain://inbox holds 16 and lain://approval 8, and nothing known
        #   reconciles the two.
        def initialize(held:)
          @limit = held
          @held = [].freeze
          @generation = 0
        end

        # The stamp the NEWEST rendering carries: what the buffer holding it is
        # stamped with, and therefore what a gesture from that buffer sends
        # back.
        # @return [Integer]
        attr_reader :generation

        # Newest first, bounded, and stamped with a number that never repeats.
        #
        # COPIED BEFORE IT IS FROZEN. A query that froze its argument in place
        # would reach back into the caller -- {ApprovalView} passes
        # `rendering.owners`, so a `Rendering`'s own field would silently become
        # immutable by being looked at. One Array copy per render is the price
        # of this object owning what it keeps.
        #
        # @param owners [Array<Object, nil>] what owns each LINE of the
        #   rendering, in line order; shorter than the rendering itself where
        #   the lines below the list belong to nothing
        # @return [Integer] the stamp minted for it, which is the value to send
        #   to the editor alongside the lines
        def remember(owners:)
          @generation += 1
          @held = [Held.new(generation: @generation, owners: owners.dup.freeze), *@held].first(@limit).freeze
          @generation
        end

        # A rendering the editor refused: drop it. A stamp nothing ever wrote
        # onto a buffer is one no gesture can cite, so keeping it would only let
        # a burst of refusals push out every rendering a human IS looking at.
        # The counter is deliberately not rewound -- a reused stamp would name
        # two different renderings, the defect the stamp exists to close.
        # @return [nil] so a caller can answer "nothing was posted" with it
        def forget(generation)
          @held = @held.reject { |rendering| rendering.stamped?(generation) }.freeze
          nil
        end

        # What the named rendering put on that line.
        #
        # @param line [Integer] 1-based, as nvim's cursor reports it
        # @param generation [Integer] the stamp on the buffer the human is
        #   looking at (b:lain_view_generation, written by `45_views.lua`'s
        #   `set_view` and by the approval rail)
        # @return [Resolution]
        def at(line, generation:)
          rendering = @held.find { |held| held.stamped?(generation) }
          return UNSHOWN if rendering.nil?

          owner = rendering.at(line)
          owner.nil? ? UNOWNED : Resolution.new(owner:, outcome: :owned)
        end
      end
    end
  end
end
