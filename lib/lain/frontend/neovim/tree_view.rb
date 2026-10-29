# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # lain://tree: every turn the view has seen, drawn as a tree whose trunk is the chain the
      # session stands on. {TimelineView}'s shape (`initial` / `update(event)`, plain lines, never nvim).
      #
      # The Store holds no children, so the parent-to-children index is folded here from the chains
      # each {Telemetry::TurnUsage} names. A rewind moves only the head; a turn is abandoned exactly
      # when it is not an ancestor of the head, so nothing is stored about it.
      #
      # Markers and labels are SUFFIXES, as {TimelineView::PIN_MARKER} is, so a line keeps its role
      # first. Only a branch's leading indent is a prefix.
      class TreeView
        NAME = "lain://tree"
        EMPTY = ["(no turns yet)"].freeze
        ABANDONED = "  [abandoned]"
        HEAD = "  [head]"
        LABEL = "  # "
        INDENT = "  "
        FORK = "fork or resume: "
        MISSING = "(turn not in store)"
        ABANDONED_REFUSAL = "that turn is on an abandoned branch; the head cannot move there"
        STALE = "the tree changed since it was drawn; look again and retry"
        NO_TURN = "no turn on lain://tree line %<line>d"
        LABELED = "labeled %<digest>s"
        NOTHING_TO_SAY = ""
        NEWLINES = Buffers::TimelineView::NEWLINES

        Node = Data.define(:parent, :text)

        # What a refresh redrew: `lines` is nil when nothing moved.
        Refreshed = Data.define(:lines, :generation)

        # What <CR> may do with a line: `digest` is nil exactly when the line is refused.
        Pick = Data.define(:digest, :report) do
          def rewindable? = !digest.nil?
        end

        # `lines` and `generation` are the redraw the label made, nil for a refusal.
        Labeled = Data.define(:digest, :report, :lines, :generation) do
          def labeled? = !digest.nil?
        end

        # @param store [Ext::Store] where the turns are read
        # @param session [Session] holds the labels
        # @param forks [#call] answers `{digest => [child file name]}`; read when the buffer is first drawn
        #   and on {#refresh}, never per event, because it scans a directory
        def initialize(store:, session:, forks:)
          @store = store
          @session = session
          @forks = forks
          @fork_files = {}.freeze
          @nodes = {}
          @children = Hash.new { |hash, key| hash[key] = [] }
          @head = nil
          @live = Set.new
          @line_digests = [].freeze
          @shown = EMPTY
          @shown_labels = {}.freeze
          @generation = 0
          @slot = Mutex.new
        end

        # The stamp of the rendering a gesture must name: a line is a position in the buffer the human is
        # looking at, and positions move under a drain thread that repaints on its own clock. Read on the
        # drain thread straight after {#update}, as {InboxView#generation} is.
        # @return [Integer]
        def generation = @slot.synchronize { @generation }

        # @return [Array<String>]
        def initial
          @fork_files = @forks.call
          @shown = EMPTY.dup
        end

        # @return [Refreshed]
        def refresh = @slot.synchronize { redraw_forks }

        # @param event [Object] one Channel event
        # @return [Array<String>, nil] the whole buffer, or nil when it did not move
        def update(event) = @slot.synchronize { updated(event) }

        # @param line [Integer] 1-based, as nvim's cursor reports it
        # @return [String, nil] nil when the line names no turn
        def digest_at(line) = @slot.synchronize { named_at(line) }

        # @return [Pick]
        def pick(line, generation:) = @slot.synchronize { picked(line, generation) }

        # @return [Labeled]
        def label(line, text, generation:) = @slot.synchronize { labelled_at(line, text, generation) }

        private

        def redraw_forks
          @fork_files = @forks.call
          drawn = redraw
          Refreshed.new(lines: drawn, generation: @generation)
        end

        def updated(event)
          moved = absorb(event)
          return nil unless moved || @session.labels != @shown_labels

          redraw
        end

        def picked(line, generation)
          digest = named_at(line)
          return Pick.new(digest: nil, report: STALE) unless generation == @generation
          return Pick.new(digest: nil, report: format(NO_TURN, line:)) if digest.nil?
          return Pick.new(digest: nil, report: ABANDONED_REFUSAL) unless @live.include?(digest)

          Pick.new(digest:, report: NOTHING_TO_SAY)
        end

        def labelled_at(line, text, generation)
          digest = named_at(line)
          return refused(STALE) unless generation == @generation
          return refused(format(NO_TURN, line:)) if digest.nil?

          @session.record_label(digest, text.to_s.strip)
          Labeled.new(digest:, report: format(LABELED, digest:), lines: redraw, generation: @generation)
        end

        def named_at(line) = (@line_digests[line - 1] if line.positive?)

        def refused(report) = Labeled.new(digest: nil, report:, lines: nil, generation: nil)

        # The generation moves exactly when the drawn turns do, which is what makes a held line stale; a
        # label changes text and never position. nil when nothing moved.
        def redraw
          @shown_labels = @session.labels
          drawn = lines
          return nil if drawn == @shown

          @shown = drawn
        end

        def absorb(event)
          case event
          when Telemetry::TurnUsage then arrive(event.digest)
          when Hash then event["type"] == "rewound" && retreat(event["to"])
          else false
          end
        end

        def arrive(digest)
          @head = digest
          @store.key?(digest) ? fold(Dag::Factory.timeline(head_digest: digest, store: @store).to_a) : missing(digest)
          self
        end

        def missing(digest)
          @nodes[digest] ||= Node.new(parent: nil, text: MISSING).tap { @children[nil] << digest }
        end

        def retreat(digest)
          @head = digest
          self
        end

        def fold(turns)
          turns.each_with_index do |turn, index|
            parent = (turns[index - 1].digest if index.positive?)
            register(turn, parent) unless @nodes.key?(turn.digest)
          end
        end

        def register(turn, parent)
          @nodes[turn.digest] = Node.new(parent:, text: "#{turn.role}: #{preview(turn.content)}")
          @children[parent] << turn.digest
        end

        def preview(content)
          text = Array(content).select { |block| block["type"] == "text" }.map { |block| block["text"] }.join(" ")
          return text.gsub(NEWLINES, " ") unless text.empty?

          kinds = Array(content).filter_map { |block| block["type"] }.uniq
          kinds.empty? ? "(empty)" : "(#{kinds.join(", ")})"
        end

        def lines
          @live = Enumerator.produce(@head) { |digest| @nodes[digest]&.parent }.take_while(&:itself).to_set
          rows = walk
          drawn = rows.flat_map { |digest, depth| [[digest, line(digest, depth)], *fork_rows(digest, depth)] }
          digests = drawn.map(&:first).freeze
          @generation += 1 unless digests == @line_digests
          @line_digests = digests
          drawn.empty? ? EMPTY.dup : drawn.map(&:last)
        end

        def fork_rows(digest, depth)
          Array(@fork_files[digest]).map { |file| [nil, "#{INDENT * (depth + 1)}#{FORK}#{file}"] }
        end

        # Preorder without recursion: a long chain is thousands deep. Off-trunk children come first and
        # indented; the trunk child continues at its parent's depth, after them.
        def walk
          rows = []
          pending = @children[nil].reverse.map { |root| [root, 0] }
          until pending.empty?
            digest, depth = pending.pop
            rows << [digest, depth]
            pending.concat(continuations(digest, depth))
          end
          rows
        end

        def continuations(digest, depth)
          kids = @children[digest].partition { |kid| !@live.include?(kid) }.flatten
          return [] if kids.empty?

          (kids[0...-1].map { |kid| [kid, depth + 1] } + [[kids.last, depth]]).reverse
        end

        def line(digest, depth)
          "#{INDENT * depth}#{@nodes.fetch(digest).text}#{abandoned(digest)}#{head(digest)}#{labelled(digest)}"
        end

        def abandoned(digest) = @live.include?(digest) ? "" : ABANDONED
        def head(digest) = digest == @head ? HEAD : ""

        def labelled(digest)
          text = @shown_labels[digest]
          text ? "#{LABEL}#{text}" : ""
        end
      end
    end
  end
end
