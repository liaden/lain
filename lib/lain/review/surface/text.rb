# frozen_string_literal: true

module Lain
  module Review
    module Surface
      # The CLI's review surface: renders a changeset, an annotation, a mark or a
      # refusal as plain text into an injected {Lain::Sink} -- never `$stdout`
      # (CLAUDE.md's Output discipline). This is what model specs drive so a
      # review never spawns nvim; {Surface::Neovim} is the interactive twin.
      #
      # Tri-state markers, not a boolean: a hunk's own mark is binary
      # (`Review::MARK_STATES`), but the coarser indicator this renders is
      # `Review::FILE_STATES`, and {STATE_MARKERS} gives each of the three its own
      # glyph. Keyed by the CANONICAL STRING spelling `FILE_STATES` declares, not
      # by a second, independent Symbol vocabulary: a fix-round panel caught the
      # first cut doing exactly that, which meant `present` raised `KeyError` on
      # the very spelling every journaled record actually stores.
      #
      # See {Surface}'s class doc for the single place `present`'s `changeset`
      # duck is stated for every adapter.
      class Text
        # One glyph per canonical file state, DERIVED from `Review::FILE_STATES`
        # rather than an independent Hash literal -- the trap this class already
        # fell into once (see the class doc). Deriving the KEYS means a state
        # `FILE_STATES` gains with no glyph decided for it raises at load time
        # rather than rendering silently blank. {glyph_for} is a
        # `private_class_method` rather than inlined so a spec can drive that
        # claim directly, instead of pinning `STATE_MARKERS.keys == FILE_STATES`,
        # which is tautological.
        def self.glyph_for(state)
          case state
          when "reviewed" then "[x]"
          when "partial" then "[~]"
          when "unreviewed" then "[ ]"
          else raise "no glyph declared for file state #{state.inspect} -- add one here"
          end
        end
        private_class_method :glyph_for

        STATE_MARKERS = Review::FILE_STATES.to_h { |state| [state, glyph_for(state)] }.freeze

        # `scope:` dispatch, keyed by the NAME of each {Review::Partition}
        # strategy so a value nothing declares fails loudly via `Hash#fetch`
        # rather than a bare `==` that silently treats anything-not-`:commits` as
        # `:cumulative`.
        #
        # A LITERAL rather than derived from {Review::Partition::STRATEGIES},
        # because what a strategy renders AS is this surface's decision and not
        # the strategy's: only {Review::Partition::Whole} is flat. The spec pins
        # completeness in the direction that matters -- every registered strategy
        # resolves here -- so a strategy shipped with no rendering declared is a
        # red spec rather than a `KeyError` the first time somebody asks.
        SCOPE_RENDERER = { cumulative: :file_table, commits: :partition_table,
                           by_directory: :partition_table }.freeze

        # What `#file_table`/`#partition_table` render when there is nothing to
        # show. A bare `""` would write a lone `"\n"` to the sink -- a
        # near-invisible line that reads as a rendering glitch, not as "this
        # changeset touches nothing".
        NOTHING_CHANGED = "(nothing changed)"

        # @param sink [Lain::Sink] where every rendering goes; never `$stdout`
        def initialize(sink:)
          @sink = sink
        end

        # @param changeset [#files, #partitions] see {Surface}'s class doc
        #   ("What `present`'s `changeset` argument answers") for the one
        #   place this duck is stated, and why neither `Changeset` nor
        #   `Marks` alone can answer it.
        # @param scope [Symbol] the name of a {Review::Partition} strategy, as
        #   a Symbol (`:cumulative`/`:commits`/`:by_directory`); anything else
        #   raises via {SCOPE_RENDERER}'s `fetch`, naming what was asked for.
        # @return [Integer] {#write}'s byte count -- never a String, which is
        #   what this port reserves for "the surface could not deliver this"
        def present(changeset, scope:)
          renderer = SCOPE_RENDERER.fetch(scope)
          write("#{send(renderer, changeset)}\n")
        end

        # @return [Integer] see {#present}
        def annotate(anchor, text, kind:)
          write("annotation [#{kind}] at #{describe(anchor)}: #{text}\n")
        end

        # `hunk_key` is truncated through {Surface.preview} -- the SAME call
        # {Surface::Neovim#mark} makes, not a second copy of its length -- so a
        # mark names the same unit and state on both surfaces. This surface has no
        # pane-width constraint of its own to force it, and a shared operation at
        # the port is what makes disagreement unconstructible rather than merely
        # untested.
        # @return [Integer] see {#present}
        def mark(hunk_key, state)
          write("marked #{Surface.preview(hunk_key)} #{state}\n")
        end

        # Announces that the position now has focus. Nothing here can print a
        # PRIOR conversation: the surface holds no annotation state of its own
        # (the port's own doc, and CLAUDE.md's Null Object rule), so this is
        # the honest text-mode reading of "open" -- name where a reply now
        # lands, rather than replay a history this object never kept.
        # @return [Integer] see {#present}
        def thread(anchor)
          write("-- thread at #{describe(anchor)} --\n")
        end

        # A batch/model-driven run has nobody at a keyboard to answer this
        # QUERY synchronously. {Surface::Null#verdict}'s own comment records
        # the same tension -- a query returning `nil` reintroduces the very
        # `if surface` guard the Null Object exists to delete -- and this
        # adapter makes it concrete rather than resolves it -- the verdict's
        # real shape is still to be settled.
        # @return [nil]
        def verdict = nil

        # A text transcript has no window to raise and nobody sitting at it, so
        # this is the port's shape and nothing else. Not a no-op by oversight:
        # {Surface::Null}'s method says the same thing for a different reason,
        # and only one of the four adapters can actually move anybody.
        # @return [nil]
        def focus = nil

        # The COMMAND beside that query: a verdict the session admitted and
        # journaled, said out loud. A batch run has nobody at a keyboard to
        # answer `#verdict`, but it still has a transcript, and a round that
        # closed with no line saying so is a transcript that ends mid-sentence.
        # @return [Integer] see {#present}
        def settle(verdict)
          write("settled: #{verdict}\n")
        end

        # @return [Integer] see {#present}
        def refuse(message)
          write("refused: #{message}\n")
        end

        private

        # Answers what `Sink#write` answers, which is the byte count `IO#write`
        # would -- NOT nil, as the five commands above claimed until somebody
        # measured it. The port reserves String for a refusal, and a count is not
        # one.
        def write(bytes) = @sink.write(bytes)

        def file_table(changeset)
          rows = changeset.files.map { |file| row(file) }
          rows.empty? ? NOTHING_CHANGED : rows.join("\n")
        end

        def partition_table(changeset)
          sections = changeset.partitions.map { |partition| partition_section(partition) }
          sections.empty? ? NOTHING_CHANGED : sections.join("\n\n")
        end

        def partition_section(partition)
          ([legible(partition.label)] + partition.files.map { |file| "  #{row(file)}" }).join("\n")
        end

        def row(file) = "#{STATE_MARKERS.fetch(file.state.to_s)} #{legible(file.path).sub(%r{\A(?:\.\./)+}, "")}"

        # git (and a commit subject) yields BYTES, not characters -- the house
        # precedent is `Isolation::Worktree::Handback#unmerged` (`force_encoding`,
        # never a transcode). Forced UNCONDITIONALLY, not only on paths that look
        # suspect: two rows built from DIFFERENT valid encodings still raise
        # `Encoding::CompatibilityError` inside `#join` the moment either carries
        # a non-ASCII byte, so only a UNIFORM encoding is safe to join.
        #
        # `Encoding::BINARY` was the first cut, and a fix-round panel caught what
        # it broke: bytes reaching a REAL `Sink::IOAdapter` come out
        # ASCII-8BIT-tagged, and `Canonical.utf8` then raises
        # `Canonical::UnsupportedType` on a plain UTF-8 path that dumped fine
        # before -- while `JSON.generate` separately warns "UTF-8 string passed as
        # BINARY", which json 3.0 turns into a raise.
        #
        # `force_encoding(UTF_8)` is a RE-TAG like the BINARY cut, but `#scrub`
        # then replaces exactly the byte sequences that are not valid UTF-8, so
        # the result is always validly UTF-8 and legible content is untouched.
        # Lossy `?` is right HERE: this is a rendering surface, not the diff bytes.
        def legible(string) = string.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")

        # `Surface.candidate_name`'s idiom for the identical reason: a raw
        # `#inspect` on a generic double prints a memory address that names
        # nothing a transcript's reader can act on.
        def describe(anchor)
          return "#{anchor.path}:#{anchor.line}" if anchor.respond_to?(:path) && anchor.respond_to?(:line)

          anchor.class.name || "an anonymous class"
        end
      end
    end
  end
end
