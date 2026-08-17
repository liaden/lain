# frozen_string_literal: true

module Lain
  module Review
    module Surface
      # The CLI's review surface: renders a changeset, an annotation, a mark or
      # a refusal as plain text into an injected {Lain::Sink} -- never
      # `$stdout` (CLAUDE.md's Output discipline; `spec/output_discipline_spec.rb`
      # enforces it mechanically). This is what model specs drive so a review
      # never spawns nvim; {Surface::Neovim} (T19) is the interactive twin.
      #
      # Tri-state markers, not a boolean: a hunk's own mark is binary
      # (`Review::MARK_STATES`), but the coarser indicator this renders is
      # `Review::FILE_STATES` -- `reviewed` only when every hunk is, `partial`
      # when some are, `unreviewed` otherwise -- and {STATE_MARKERS} gives
      # each of the three its own glyph so a reader can tell them apart at a
      # glance. Keyed by the CANONICAL STRING spelling `FILE_STATES` declares,
      # not by a second, independent Symbol vocabulary: a fix-round panel
      # caught the first cut doing exactly that, which meant `present` raised
      # `KeyError` on the very spelling every journaled record actually
      # stores. `#row` accepts a Symbol as readily as a String (`.to_s` at the
      # lookup), matching `HunkMarked`'s own tolerance for the same pair.
      #
      # `Lain::Review::Changeset` (T7) and `Lain::Review::Marks` (T8) are
      # siblings that had not landed when this was written, so `#present`
      # states the narrowest duck it needs directly on itself -- see that
      # method's doc, and {Surface}'s own class doc for the single place that
      # duck is now stated for every adapter, not just this one.
      class Text
        # One glyph per canonical file state, DERIVED from `Review::FILE_STATES`
        # rather than an independent Hash literal -- the trap this class
        # already fell into once (see the class doc). Deriving the KEYS
        # means a state `FILE_STATES` gains with no glyph decided for it
        # raises immediately, at load time, rather than rendering silently
        # blank the first time a real changeset carries it -- {glyph_for} is
        # a `private_class_method` rather than inlined into the block below
        # so a spec can drive that claim directly (`send(:glyph_for,
        # "bogus")`) instead of pinning `STATE_MARKERS.keys == FILE_STATES`,
        # which is tautological: the keys ARE `FILE_STATES`, by construction,
        # for any glyph mapping at all.
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
        # strategy so a value nothing declares (or a typo of one that does)
        # fails loudly via `Hash#fetch` -- the same loud-failure choice
        # {STATE_MARKERS} makes, rather than a bare `==` that silently treats
        # anything-not-`:commits` as `:cumulative`.
        #
        # A LITERAL rather than derived from {Review::Partition::STRATEGIES},
        # because what a strategy renders AS is this surface's decision and not
        # the strategy's: only {Review::Partition::Whole} is flat, and every
        # grouping gets the same table whatever it grouped by. The spec pins
        # completeness in the direction that matters -- every registered
        # strategy resolves here -- so a strategy shipped with no rendering
        # declared for it is a red spec rather than a `KeyError` the first time
        # somebody asks for that scope.
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
        #   place this duck is stated, and why neither `Changeset` (T7) nor
        #   `Marks` (T8) alone can answer it.
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

        # `hunk_key` is truncated through {Surface.preview} -- the SAME
        # call {Surface::Neovim#mark} makes, not a second copy of its
        # length -- so a mark names "the same unit and state" on both
        # surfaces rather than one staying long. This surface has no
        # pane-width constraint of its own to force it, but T6 asks for
        # the two to stay consistent, and a shared operation at the port
        # is what makes disagreement unconstructible rather than merely
        # untested (see {Surface.preview}'s own doc).
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
        # adapter makes it concrete rather than resolves it: T13 owns the
        # verdict's real shape.
        # @return [nil]
        def verdict = nil

        # @return [Integer] see {#present}
        def refuse(message)
          write("refused: #{message}\n")
        end

        private

        # Answers what `Sink#write` answers, which is the byte count `IO#write`
        # would -- NOT nil, as the five commands above claimed until T19 measured
        # it. Harmless and now stated: the port reserves String for a refusal
        # (see `spec/support/shared_examples/review_surface.rb`, law #5), and a
        # count is not one.
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

        def row(file) = "#{STATE_MARKERS.fetch(file.state.to_s)} #{legible(file.path)}"

        # git (and a commit subject) yields BYTES, not characters -- the house
        # precedent is `Isolation::Worktree::Handback#unmerged`
        # (`force_encoding`, never a transcode). Forced UNCONDITIONALLY, on
        # every path/subject alike, not only ones that look suspect: two rows
        # built from DIFFERENT valid encodings (a clean UTF-8 path beside one
        # merely re-tagged) still raise `Encoding::CompatibilityError` inside
        # `#join` the moment either carries a non-ASCII byte -- only a
        # UNIFORM encoding across every contributor is safe to join.
        #
        # `Encoding::BINARY` was the first cut, and a fix-round panel caught
        # what it broke: bytes reaching a REAL `Sink::IOAdapter` come out
        # ASCII-8BIT-tagged, and `Canonical.dump` (`Canonical.utf8`, which
        # only skips its `#encode` call when the String is ALREADY tagged
        # UTF-8) then raises `Canonical::UnsupportedType` on a plain UTF-8
        # path that dumped fine before -- and `JSON.generate` separately
        # warns "UTF-8 string passed as BINARY", a warning CLAUDE.md's Output
        # discipline section says would corrupt the NDJSON Journal if it ever
        # reached the wrong stream, and one json 3.0 turns into a raise.
        #
        # `force_encoding(UTF_8)` is a RE-TAG, same as the BINARY cut -- it
        # does not transcode -- but `#scrub` then walks the result and
        # replaces exactly the byte sequences that are not valid UTF-8 with
        # `"?"`, one per invalid byte, so the String it returns is always
        # validly UTF-8-encoded: `Canonical.utf8`'s `valid_encoding?` check
        # passes, `JSON.generate` never sees BINARY, and legible content
        # (a clean UTF-8 path, a `café.rb`) is untouched -- `#scrub` only
        # touches what was already unreadable. Lossy `?` is the right answer
        # HERE: this is a rendering surface, not the diff bytes themselves.
        def legible(string) = string.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")

        # `anchor.class.name || "an anonymous class"` mirrors
        # `Surface.candidate_name`'s own idiom for the identical reason: a raw
        # `#inspect` on a generic double prints `#<Object:0x...>`, a memory
        # address that names nothing a transcript's reader can act on.
        def describe(anchor)
          return "#{anchor.path}:#{anchor.line}" if anchor.respond_to?(:path) && anchor.respond_to?(:line)

          anchor.class.name || "an anonymous class"
        end
      end
    end
  end
end
