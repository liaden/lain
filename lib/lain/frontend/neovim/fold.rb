# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The one hard-wrap value {ApprovalView} and {InboxView} both render by,
      # and the reason it is its own file rather than a constant read off
      # either of them: `neovim.rb`'s manifest loads views in the order they
      # are required, and a sibling loaded first cannot reference a constant on
      # a sibling loaded after it. A LEAF loaded before both is the fix -- see
      # `neovim.rb`'s require block, which places this file ahead of
      # `inbox_view` and `approval_view`.
      #
      # `INDENT` is the runtime's own boundary test: `05_records.lua`'s
      # `CONTINUATION` pattern is this string anchored, so "does this line
      # start a record" is answerable on the editor side without parsing the
      # record's own text. Ruby is authoritative -- the Lua pattern is written
      # to match this constant, never the other way -- and `fold_spec.rb`
      # pins the two together by reading the Lua source.
      module Fold
        # The cockpit nvim pane measures 110 columns; this leaves room for
        # `10_folds.lua`'s "  (+N lines)" marker so a closed item still sits on
        # one screen line.
        WIDTH = 96

        # See the module doc: the Lua side's `CONTINUATION` pattern is this
        # string anchored, so changing it here changes what the editor reads
        # as a record's boundary.
        INDENT = "  "

        # ASCII, so a font with no ellipsis glyph shows a cut rather than a
        # replacement box.
        ELISION = "..."

        # A hard wrap, NEVER at a word boundary: what is folded here is bytes
        # that must survive intact (a command, a question's verbatim prose),
        # and a word-boundary break would still be legibility-only while
        # costing the property that the wrapped body is byte-for-byte the
        # input. `/m` carries a newline into a chunk rather than dropping it.
        BODY = /.{1,#{WIDTH - INDENT.length}}/m

        module_function

        # The whole of a fold: unchanged when it already fits, or a cut first
        # line plus its indented remainder when it does not. This is the
        # shape both {ApprovalView#lines_for} and {InboxView::Row#lines} draw
        # from a single string; a view folding two different strings (a
        # summary cut, a separately-wrapped whole) calls {.cut} and {.wrap}
        # directly instead of this.
        # @return [Array<String>]
        def lines(text) = text.length <= WIDTH ? [text] : [cut(text)] + wrap(text)

        # The first line alone: the text verbatim if short enough, otherwise
        # cut to leave room for {ELISION} at the end.
        def cut(text) = text.length <= WIDTH ? text : text[0, WIDTH - ELISION.length] + ELISION

        # The text, hard-wrapped at {WIDTH} and marked with {INDENT} so the
        # runtime's `CONTINUATION` test finds every line of it.
        # @return [Array<String>]
        def wrap(text) = text.scan(BODY).map { |part| INDENT + part }
      end
    end
  end
end
