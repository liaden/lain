# frozen_string_literal: true

require "tmpdir"

# `runtime/47_diff.lua` -- the review's stamp, and the tabpage it is checked
# against. The group below carries the rule and what `unstamp` means.
#
# `diff_mode_spec.rb` covers the same module's OTHER entry point -- drawing one
# changed file into the layout's two diff slots -- and drives the injected chunk
# directly. This one needs the whole frontend, because what broke was a review
# surviving the gestures that leave it.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-diff-spec") { example.run } }

  # `gf` out of a review buffer silently ended the review. The new side is
  # DELIBERATELY a real, editable, file-backed buffer -- that is what makes the
  # language server and treesitter attach (`47_diff.lua`'s header) -- so the
  # gestures that leave it are the ordinary ones, and `47_diff.unstamp` had
  # already withdrawn the previous row's stamp when the next one opened. Coming
  # back left the human in the file they were reviewing with none of the review's
  # keys on it.
  #
  # THE RULE IS THE TABPAGE, AND IT IS CHECKED ON EVERY ENTRY, not once. Inside
  # the review's tabpage a file THIS round opened re-acquires its stamp; outside
  # it, a buffer that carries one gives it back. A boundary tested on the first
  # transition only is not a boundary -- it would let a human annotate the review
  # from a tabpage the review is not in, which is authority and not decoration.
  # `review_notes.stamp` is still the single membership test, and `unstamp` still
  # means what it meant: withdrawal is what makes the record, so nothing here
  # takes a stamp `unstamp` left or keeps one it took.
  #
  # THE ROUND ENDS WHEN LAIN SAYS SO. Nothing in the editor can see a settle --
  # the tabpage, the panes and the buffers all survive it -- so
  # `Review::Surface::Neovim#settle` tells the runtime, and `__lain.review_settled`
  # tears the round down. Without it every buffer the round opened would go on
  # re-acquiring against a review nobody is holding.
  #
  # A SURVEY rather than a changeset for most of these, because that is the round
  # the defect was measured in and the harder one: one side, so the row's buffer IS the
  # file on disk and there is no `nofile` old side to fall back into.
  describe "a review that survives the tabpage" do
    # `47_diff.lua` freezes the project root at attach and resolves every
    # repository-relative path against it; `vim.g.lain_review_root` is the
    # documented override for an editor started somewhere else, which this
    # harness's nvim always is.
    def survey(dir, sides = ["new"])
      inspector.exec_lua("vim.g.lain_review_root = ...", [dir])
      inspector.exec_lua("_G.__lain.set_review({ 'a.rb', 'b.rb' }, 1, ...)", [sides])
    end

    # `a.rb` names `stray.rb` on its second line, which is what makes a REAL `gf`
    # drivable below: nvim's default 'path' begins with `.`, the directory of the
    # file the cursor is in, so the gesture resolves without configuring anything.
    def write_round(dir)
      File.write(File.join(dir, "a.rb"), "alpha\nstray.rb\n")
      File.write(File.join(dir, "b.rb"), "gamma\ndelta\n")
      File.write(File.join(dir, "stray.rb"), "no row names this one\n")
    end

    # A survey's own pair: {Review::Source::Corpus::BASE_REF}-shaped, and the one
    # a re-acquired stamp has to still be naming.
    def revisions = { "old" => "base0ff", "new" => "head1ff" }

    def open_row(path, old_lines = [])
      inspector.exec_lua("_G.__lain.open_changeset(...)", [path, old_lines, 1, revisions])
    end

    # What `Review::Surface::Neovim#settle` posts when a verdict lands. Driven at
    # the runtime here because that is this file's subject; that the surface
    # actually posts it is `spec/lain/review/surface/neovim_spec.rb`'s to pin.
    def settle_round = inspector.exec_lua("_G.__lain.review_settled()", [])

    # The reported gesture itself: out of the REVIEW BUFFER, which is the file
    # pane and not the navigator. `open_changeset` lands the human in the sidebar
    # (`review_diff.landing`), so an `:edit` run wherever focus happens to be
    # measures re-entry into the navigator instead -- a different window, and not
    # the one the defect was reported from. So the file pane is focused first, and
    # `:edit` is `gf` reduced to its effect: a real buffer switch in a real
    # window, firing nvim's own `BufEnter` rather than a synthetic one.
    def gesture(dir, name)
      inspector.exec_lua(<<~LUA, [File.join(dir, name)])
        local wanted = ...
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.w[win].lain_review_slot == "new" then vim.api.nvim_set_current_win(win) end
        end
        vim.cmd("edit " .. vim.fn.fnameescape(wanted))
      LUA
    end

    # The same switch WITHOUT hunting for the review's file pane -- for the
    # tabpage that has no such window, where "wherever the human is" is the whole
    # point of the example.
    def enter_here(dir, name)
      inspector.exec_lua("vim.cmd('edit ' .. vim.fn.fnameescape(...))", [File.join(dir, name)])
    end

    # nvim's own `gf`, pressed rather than approximated, and then nvim's own way
    # back. Both go through `nvim_replace_termcodes` because `<C-o>` in a lua
    # string is not an escape sequence, it is six characters.
    def followed_the_filename
      inspector.exec_lua(<<~LUA, [])
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.w[win].lain_review_slot == "new" then vim.api.nvim_set_current_win(win) end
        end
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        vim.cmd("normal! gf")
        return vim.api.nvim_buf_get_name(0)
      LUA
    end

    def went_back
      inspector.exec_lua(<<~LUA, [])
        vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<C-o>", true, false, true))
        return vim.api.nvim_buf_get_name(0)
      LUA
    end

    # The note keys as nvim answers for them in the current buffer. `maparg` per
    # lhs rather than pressing anything: a press that finds no map is not a no-op
    # in normal mode, so an absence asserted by pressing fails somewhere else
    # entirely (`annotate_spec.rb`'s reason). The prefix crosses as an ARGUMENT
    # because `\L` is not a lua escape.
    def note_keys
      inspector.exec_lua(<<~LUA, ["\\L"])
        local prefix = ...
        local found = {}
        for _, suffix in ipairs({ "n", "q", "b" }) do
          found[suffix] = vim.fn.maparg(prefix .. suffix, "n")
        end
        return found
      LUA
    end

    # The stamp on one buffer, found by the name the editor resolved. `stamped`
    # is always present so the answer is a dictionary either way -- an all-nil
    # table would cross msgpack as an empty ARRAY and read as a different shape.
    def stamp_of(dir, name)
      inspector.exec_lua(<<~LUA, [File.join(dir, name)])
        local wanted = ...
        local buf = vim.fn.bufnr(wanted)
        if buf == -1 then return { stamped = false } end
        return { stamped = vim.b[buf].lain_review_side ~= nil, side = vim.b[buf].lain_review_side,
                 revision = vim.b[buf].lain_review_revision, path = vim.b[buf].lain_review_path }
      LUA
    end

    # Every buffer in the editor that currently CLAIMS to be the review, as the
    # three facts a rail reads off one. A census rather than a count, because
    # "how many" is not the question `unstamp`'s rule is about.
    def claiming_the_review
      inspector.exec_lua(<<~LUA, [])
        local claiming = vim.tbl_filter(function(b) return vim.b[b].lain_review_side ~= nil end,
          vim.api.nvim_list_bufs())
        local claims = vim.tbl_map(function(b)
          return vim.b[b].lain_review_side .. "@" .. vim.b[b].lain_review_revision .. ":" .. vim.b[b].lain_review_path
        end, claiming)
        table.sort(claims)
        return claims
      LUA
    end

    # Every buffer still REMEMBERING a round -- `b:lain_review_round`, which
    # `withdraw` writes and `reacquire` reads. A claim and a memory of one are
    # different facts, so a settle has to end both.
    def remembering_the_round
      inspector.exec_lua(<<~LUA, [])
        local held = vim.tbl_filter(function(b) return type(vim.b[b].lain_review_round) == "table" end,
          vim.api.nvim_list_bufs())
        return vim.tbl_map(function(b) return vim.b[b].lain_review_round.path end, held)
      LUA
    end

    def markers
      inspector.exec_lua(<<~LUA, [])
        local buf = vim.api.nvim_get_current_buf()
        local ns = vim.api.nvim_create_namespace("lain_review_notes")
        local found = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
          found[#found + 1] = { row = mark[2] + 1, text = mark[4].virt_text[1][1] }
        end
        return found
      LUA
    end

    def messages = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])

    def noted(line, text)
      inspector.exec_lua(<<~LUA, [line, text])
        local row, sentence = ...
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        local ok, err = pcall(vim.cmd, "LainNote note " .. sentence)
        return { ok, tostring(err) }
      LUA
    end

    # The keys come back, and the command they name works -- asserted
    # together, because a key that is bound and refuses is the failure this whole
    # autocmd exists to prevent.
    it "binds the note keys again on a row this round already opened" do
      Dir.mktmpdir("lain-review-tab") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")
          open_row("b.rb")

          gesture(dir, "a.rb")

          expect(note_keys).to include(
            "n" => a_string_including("LainNote note"),
            "q" => a_string_including("LainNote question"),
            "b" => a_string_including("LainNote blocker")
          )
          expect(noted(2, "hello")).to eq([true, ""])
          expect(markers).to eq([{ "row" => 2, "text" => "● note" }])
        end
      end
    end

    # The deferred half, stated as a refusal rather than as a guess: a
    # buffer no row has opened needs a revision, a side and a repository-relative
    # path that only Ruby holds, and deriving one from the buffer's name is the
    # second silent spelling of `OLD_PREFIX` that `47_diff.stamp` refuses.
    it "leaves a file no row has opened out of the review, and says how to get back" do
      Dir.mktmpdir("lain-review-tab") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")

          gesture(dir, "stray.rb")

          expect(note_keys.values).to all(eq(""))
          expect(noted(1, "hello")).to eq([true, ""])
          expect(messages).to include("lain: :LainNote needs a buffer lain has open for review -- <C-o> goes back")
          expect(markers).to be_empty
        end
      end
    end

    # The other half of the example above, and the one a sentence cannot be
    # trusted without: the remedy has to work FROM WHERE THE HUMAN IS. `gf`
    # replaces the buffer in the window it was pressed in, so a refusal naming
    # the sidebar names a surface this very gesture can have taken off the
    # screen. `<C-o>` is nvim's own way back from a jump, it needs no window the
    # human can still see, and landing is what re-acquires the stamp -- so the
    # sentence and the fix are one gesture.
    it "names a way back that works from the buffer the human landed in" do
      Dir.mktmpdir("lain-review-tab") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")

          expect(followed_the_filename).to eq(File.join(dir, "stray.rb"))
          expect(note_keys.values).to all(eq(""))

          expect(went_back).to eq(File.join(dir, "a.rb"))
          expect(note_keys["n"]).to include("LainNote note")
        end
      end
    end

    # Renamed for what it pins: a file the round has MOVED PAST. The old
    # title said "a reviewed file", which is also true of one the human has just
    # revisited -- and that one is the example below, whose answer is the
    # opposite until the stamp is given back at the boundary.
    it "does not stamp a file the round has moved past in another tabpage" do
      Dir.mktmpdir("lain-review-tab") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")
          open_row("b.rb")

          inspector.exec_lua("vim.cmd('tabnew')", [])
          enter_here(dir, "a.rb")

          expect(note_keys.values).to all(eq(""))
          expect(stamp_of(dir, "a.rb")).to include("stamped" => false)
        end
      end
    end

    # THE BOUNDARY ON EVERY ENTRY, which is what makes it a boundary at all. A
    # buffer that has just re-acquired its stamp inside the review tabpage holds
    # a BUFFER variable, and a buffer variable follows the buffer anywhere it is
    # shown -- so without a withdrawal on the way out the human could annotate
    # the review from a tabpage the review is not in. Coming back is the other
    # half: the withdrawal is what records the round, so the stamp returns.
    #
    # THE RETURN IS A BARE `tabprevious`, deliberately: the review's pane and the
    # other tabpage's window hold the SAME buffer here, so nvim reports no buffer
    # entry in either direction and a `BufEnter`-only rule would leave the human
    # in the file they are reviewing with the keys the far tabpage took. Crossing
    # a tabpage is a window entry, which is why the runtime watches both.
    it "gives the stamp back when the buffer leaves the review tabpage, and again when it returns" do
      Dir.mktmpdir("lain-review-tab") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")
          open_row("b.rb")
          gesture(dir, "a.rb")
          expect(stamp_of(dir, "a.rb")).to include("stamped" => true)

          inspector.exec_lua("vim.cmd('tabnew')", [])
          enter_here(dir, "a.rb")

          expect(note_keys.values).to all(eq(""))
          expect(stamp_of(dir, "a.rb")).to include("stamped" => false)

          inspector.exec_lua("vim.cmd('tabprevious')", [])

          expect(stamp_of(dir, "a.rb")).to include("stamped" => true, "path" => "a.rb")
          expect(note_keys["n"]).to include("LainNote note")
        end
      end
    end

    # DISMISSING IS NOT SETTLING, and what tells them apart is that one of them
    # is a tabpage. Closing the review's tabpage is the human's dismiss gesture
    # and the review stays open -- 41_layout's own ruling, and `51_thread`
    # rebuilds the whole layout for a render that arrives afterwards, finding the
    # pair by these very stamps (`side_buf`). So a buffer entered while the
    # review has NO tabpage keeps its claim: there is no boundary to be outside
    # of, and only a settle ends a round.
    it "keeps the claim while the review's tabpage is closed" do
      Dir.mktmpdir("lain-review-tab") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")

          inspector.exec_lua("vim.cmd('tabclose')", [])
          enter_here(dir, "a.rb")

          expect(stamp_of(dir, "a.rb")).to include("stamped" => true, "path" => "a.rb")
        end
      end
    end

    # A LATER ROUND DOES NOT INHERIT THE ONE BEFORE IT, which is what forgetting
    # at settle buys beyond tidiness. Round two opens `b.rb` alone, so `a.rb` is a
    # file only the PREVIOUS round ever drew -- and `open_changeset` in THIS round
    # is the whole scope of what may re-acquire. While the teardown left the
    # record behind, a matching revision pair was enough to hand a claim to a file
    # this round never opened, and the sidebar's own row list would not have
    # agreed that it was under review.
    it "does not hand a later round a file the round before it opened" do
      Dir.mktmpdir("lain-review-tab") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")
          open_row("b.rb")
          settle_round

          survey(dir)
          open_row("b.rb")
          gesture(dir, "a.rb")

          expect(stamp_of(dir, "a.rb")).to include("stamped" => false)
          expect(claiming_the_review).to eq(["new@head1ff:b.rb"])
        end
      end
    end

    # The one that matters: the INTERLEAVING, not the endpoints. A
    # stamp that was never withdrawn would pass an endpoint assertion and prove
    # nothing about `unstamp`; a stamp re-acquired from anywhere but the round's
    # own memory could come back naming the wrong file or the wrong revision.
    it "hands back the stamp this round gave it, after the next row withdrew it" do
      Dir.mktmpdir("lain-review-tab") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)

          open_row("a.rb")
          expect(stamp_of(dir, "a.rb")).to include("stamped" => true, "path" => "a.rb")

          open_row("b.rb")
          expect(stamp_of(dir, "a.rb")).to include("stamped" => false)

          gesture(dir, "a.rb")

          expect(stamp_of(dir, "a.rb")).to eq(
            "stamped" => true, "side" => "new", "revision" => "head1ff", "path" => "a.rb"
          )
          expect(stamp_of(dir, "b.rb")).to include("stamped" => true, "path" => "b.rb")
        end
      end
    end

    # THE CENSUS, because `unstamp`'s own comment used to say only the two under
    # review are ever stamped and that is no longer the rule the tree keeps. A
    # revisited row is a THIRD claim, and it is a correct one: the human is
    # reading a file this round opened, inside the round's tabpage. What the rule
    # protects is unchanged -- every claim here names this round's revisions and
    # its own path, so no reader can be handed a file nobody is reviewing.
    it "lets a revisited row claim the review beside the pair being drawn" do
      Dir.mktmpdir("lain-review-tab") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir, %w[old new])
          open_row("a.rb", ["alpha"])
          open_row("b.rb", ["gamma"])

          gesture(dir, "a.rb")

          expect(claiming_the_review).to eq(
            ["new@head1ff:a.rb", "new@head1ff:b.rb", "old@base0ff:b.rb"]
          )
        end
      end
    end

    # THE ROUND IS OVER, and the editor has to be told: nothing about a settle is
    # visible here -- the tabpage, its panes and every buffer survive it. Left
    # untold, the tabpage goes on vouching for the round and every file it opened
    # re-acquires on entry, so a note lands in a review nobody is holding. That is
    # a wrong answer rather than a missing one, and it is the whole reason
    # `#settle` posts anything at all.
    #
    # THE MEMORY GOES WITH THE CLAIM, asserted beside it because the teardown's
    # own mechanism is what would leave it: `withdraw` is the writer of the round
    # record, so a sweep that only withdrew would retire every claim and re-arm
    # every one of them in the same pass. Settling is as permanent for a round as
    # `:saveas` is for one buffer.
    it "stops handing stamps back once the round has settled" do
      Dir.mktmpdir("lain-review-tab") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")
          open_row("b.rb")

          settle_round

          expect(claiming_the_review).to be_empty
          expect(remembering_the_round).to be_empty
          gesture(dir, "a.rb")

          expect(stamp_of(dir, "a.rb")).to include("stamped" => false)
          expect(note_keys.values).to all(eq(""))
          expect(noted(1, "hello")).to eq([true, ""])
          expect(markers).to be_empty
        end
      end
    end
  end
end
