# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      class InboxView
        # What this view has handed out, and which of it the editor can still be
        # holding. Separate from {InboxView} because reconciling "what I drew"
        # with "what you are looking at" is its own rule, and the gesture is only
        # safe while that rule is stated in one place.
        #
        # LOCK-FREE ON PURPOSE, and it is safe only because of who calls it:
        # every caller is an {InboxView} method holding that view's `@slot`
        # ({#render}, {#placeholder}, {#digest_at}, {#open}, {#open_next}), so
        # this object's mutation and every read of it are already serialized.
        # Nothing outside {InboxView} may hold one.
        class Renderings
          # One rendering, as a gesture has to read it back: the STAMP the
          # editor's buffer carries for it (T16), and which set OWNS each of its
          # lines. The stamp is what the editor sends back with the gesture,
          # and it is the whole of the identity -- the empty-state placeholder
          # and a one-item list are both ONE line high, so the height could
          # never separate them and the stamp always does.
          #
          # ONE ENTRY PER LINE, NEVER ONE PER SET (T12), and that is what this
          # object had wrong rather than incomplete: `digests` used to be the
          # listed sets in order, addressed as `digests[line - 1]`, which is the
          # same answer only while every item is exactly one line. The moment a
          # question folded under its summary, that arithmetic named the
          # NEIGHBOURING set -- which is why {InboxView#line_for} was pinned to
          # one line at all. `owners` is the map the drawing pass builds beside
          # the lines it draws, so a set owns every line of its own item and the
          # keys below the list own nothing.
          Rendering = Data.define(:generation, :owners) do
            def stamped?(named) = generation == named

            # The 1-based/0-based seam, guarded here rather than at each caller:
            # line 0 would index -1, which is the LAST line -- a cursor nvim never
            # reports would silently open the newest set.
            def at(line) = line.positive? ? owners[line - 1] : nil
          end
          private_constant :Rendering

          # How many stay resolvable, and it is a MEMORY bound now rather than a
          # rule about correctness -- which is the whole difference the stamp
          # makes. The previous bound was 2, justified by "the render queue
          # drains everything in one tick, so the screen is the newest rendering
          # or the one before it". That justification was FALSE: {RenderQueue}
          # drains once per RPC tick, so a burst posts arbitrarily many
          # renderings between drains and the screen can be k of them behind.
          # Under the height key, a rendering that aged out did not fail --
          # it ALIASED onto a later one of the same height and opened the wrong
          # document, reported as a success. Under the stamp both sides are
          # safe: a rendering still held resolves exactly, and one forgotten is
          # refused BY NAME ({UNSHOWN}). So this number only says how far
          # behind the screen may be before a keypress must be pressed again,
          # and each rendering costs one frozen array of digests -- one entry
          # per LINE since T12, which is a rendering's height rather than its
          # item count and still nothing worth bounding more tightly.
          HELD = 16

          def initialize
            @held = [].freeze
            @generation = 0
          end

          # The stamp the NEWEST rendering carries: what the buffer holding it
          # is stamped with, and therefore what a gesture from that buffer
          # sends back.
          # @return [Integer]
          attr_reader :generation

          # Newest first, bounded, and stamped with a generation that never
          # repeats -- a stamp that repeated would name two different sets on
          # one line, which is the defect it exists to close. The retired digest
          # on an older rendering stays reachable until the render that removes
          # its row has landed, which is how a keypress on it is answered with
          # {RETIRED} rather than with its neighbour.
          #
          # @param owners [Array<String, nil>] the set owning each LINE of the
          #   rendering, in line order; shorter than the rendering itself where
          #   the lines below the list belong to no set
          def remember(owners:)
            @generation += 1
            @held = [Rendering.new(generation: @generation, owners:), *@held].first(HELD).freeze
          end

          # Whether the rendering the editor names is one this view can still
          # identify. Separate from {#digest_at} because the two answers differ:
          # "I do not know which buffer you are holding" and "that line names no
          # set" are different facts and get different sentences.
          def holds?(generation) = !shown(generation).nil?

          # Which set the named rendering put on that line, or nil when the line
          # names none (line 0, past the end, the placeholder) or when the
          # rendering itself is forgotten.
          def digest_at(line, generation) = shown(generation)&.at(line)

          private

          def shown(generation) = @held.find { |rendering| rendering.stamped?(generation) }
        end
      end
    end
  end
end
