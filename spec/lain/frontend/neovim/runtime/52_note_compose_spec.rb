# frozen_string_literal: true

require "tmpdir"

# `runtime/52_note_compose.lua` -- a note too long for a prompt, grown in a pane of
# its own and settled back onto the row it belongs to.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-note-compose-spec") { example.run } }

  describe "a long note grown in a pane" do
    # The same survey `a review that survives the tabpage` drives, and for its
    # reasons: one side, so the row's buffer IS the file on disk. Its helpers are
    # its own; this block asks different questions of the same round.
    def survey(dir)
      inspector.exec_lua("vim.g.lain_review_root = ...", [dir])
      inspector.exec_lua("_G.__lain.set_review({ 'a.rb' }, 1, ...)", [["new"]])
    end

    def write_round(dir)
      File.write(File.join(dir, "a.rb"), "#{(1..30).map { |i| "line #{i}" }.join("\n")}\n")
    end

    def revisions = { "old" => "base0ff", "new" => "head1ff" }

    def open_row(path) = inspector.exec_lua("_G.__lain.open_changeset(...)", [path, [], 1, revisions])

    # `open_changeset` lands the human in the sidebar, so every gesture below
    # starts by putting them back in the file pane -- the window a note is placed
    # from.
    def in_file_pane(body)
      inspector.exec_lua(<<~LUA, [])
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.w[win].lain_review_slot == "new" then vim.api.nvim_set_current_win(win) end
        end
        #{body}
      LUA
    end

    # The cmdline note, as a human types it.
    def noted(line, text)
      in_file_pane(<<~LUA)
        vim.api.nvim_win_set_cursor(0, { #{line}, 0 })
        vim.cmd("LainNote note #{text}")
      LUA
    end

    # The pane gesture: cursor onto a line in the file pane, then the command the
    # `c` key pre-fills. The reservation is taken HERE. The raise is RETURNED
    # rather than swallowed -- a regression that raises must fail as a raise and
    # not as a missing message three assertions later.
    def compose(line, arguments = "note")
      in_file_pane(<<~LUA)
        vim.api.nvim_win_set_cursor(0, { #{line}, 0 })
        local ok, err = pcall(vim.cmd, "LainNoteCompose #{arguments}")
        return { ok = ok, err = tostring(err) }
      LUA
    end

    # The panes, by the prefix their names carry, in name order.
    def pane_names
      inspector.exec_lua(<<~LUA, [])
        local found = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          local name = vim.api.nvim_buf_get_name(b)
          if name:match("^lain://note/") then found[#found + 1] = name end
        end
        table.sort(found)
        return found
      LUA
    end

    def pane_buf(name = nil)
      found = pane_names
      wanted = name || found.first
      raise "no compose pane among #{found.inspect}" if wanted.nil?

      inspector.exec_lua(<<~LUA, [wanted])
        local wanted = ...
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_get_name(b) == wanted then return b end
        end
      LUA
    end

    def typed_into_pane(lines, name = nil)
      inspector.exec_lua("vim.api.nvim_buf_set_lines(select(1, ...), 0, -1, false, select(2, ...))",
                         [pane_buf(name), lines])
    end

    # `:w` on the pane, with the write's own outcome ANSWERED. A `pcall` whose
    # error is discarded turns a future raise into "expected messages to
    # include...", which names the wrong thing entirely.
    def write_pane(name = nil)
      inspector.exec_lua(<<~LUA, [pane_buf(name)])
        local b = ...
        local ok, err
        vim.api.nvim_buf_call(b, function() ok, err = pcall(vim.cmd, "write") end)
        return { ok = ok, err = tostring(err), modified = vim.bo[b].modified }
      LUA
    end

    # `:LainNoteDone` with `vim.rpcrequest` swapped for a capture -- `annotate_spec.rb`'s
    # idiom, needed here too: `review_notes` is an ANSWERED verb, so the batch never
    # reaches `command_inbox` and the only place to read it is the wire.
    def settled
      inspector.exec_lua(<<~LUA, [])
        local seen
        local original = vim.rpcrequest
        vim.rpcrequest = function(_, _, _, args) seen = args end
        local ok, err = pcall(vim.cmd, "LainNoteDone")
        vim.rpcrequest = original
        return { ok = ok, err = tostring(err), sent = seen }
      LUA
    end

    # The batch as it crossed the wire. BOTH ways of sending nothing are refused
    # by name: `ok` false is the command raising, a nil `sent` is `:LainNoteDone`
    # deciding there was nothing to hand over and never reaching the wire.
    def handed_back
      answer = settled
      raise "LainNoteDone raised: #{answer["err"]}" unless answer["ok"]
      raise "LainNoteDone sent nothing: #{answer.inspect}" if answer["sent"].nil?

      answer.fetch("sent").fetch(0)
    end

    def markers
      in_file_pane(<<~LUA)
        local ns = vim.api.nvim_create_namespace("lain_review_notes")
        local found = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
          found[#found + 1] = { row = mark[2] + 1, text = mark[4].virt_text[1][1] }
        end
        return found
      LUA
    end

    def note_keys
      inspector.exec_lua(<<~LUA, ["\\L"])
        local prefix = ...
        local found = {}
        for _, suffix in ipairs({ "n", "q", "b", "c", "N", "t" }) do
          found[suffix] = vim.fn.maparg(prefix .. suffix, "n")
        end
        return found
      LUA
    end

    def messages = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])

    # The rail's lines, anchored. A matcher that looks anywhere in one blob
    # cannot see a doubled `lain: ` prefix, which is how one once reached a human
    # for a whole card (`annotate_spec.rb`'s reason).
    def echoed = messages.lines.map(&:chomp).grep(/\Alain: /)

    def displayed_width(line) = inspector.exec_lua("return vim.fn.strdisplaywidth(...)", [line])

    # The whole round trip of the long path: opened from a line, typed into,
    # written -- and the note lands on THAT line with THOSE words.
    it "places the note the pane was written with, on the line the pane was opened from" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")

          expect(compose(7)).to include("ok" => true)
          typed_into_pane(["the first paragraph of a long note", "", "and its second"])
          expect(write_pane).to include("ok" => true, "modified" => false)

          expect(markers).to eq([{ "row" => 7, "text" => "● note" }])
          expect(handed_back).to contain_exactly(
            hash_including("line" => 7, "kind" => "note", "side" => "new", "path" => "a.rb",
                           "text" => "the first paragraph of a long note\n\nand its second")
          )
        end
      end
    end

    # THE WHOLE POINT OF THE CARD: the INTERLEAVING. The pane is opened first
    # and written LAST, so a sequence assigned at commit time would hand these
    # back in the wrong order -- and every assertion about the notes' content
    # would still pass. Only the order can catch it.
    it "hands a pane note back ahead of a cmdline note placed after the pane opened" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")

          compose(10)
          noted(20, "the quick one")
          typed_into_pane(["the slow one"])
          write_pane

          expect(handed_back.map { |note| note["line"] }).to eq([10, 20])
        end
      end
    end

    # Whitespace under nothing is not a note -- and the refusal is the
    # thread pane's shape exactly: on the rail, no traceback, and 'modified' left
    # standing, because clearing it would be the one write that says "saved" over
    # text lain never took.
    it "refuses an empty pane in words and leaves the buffer modified" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")

          compose(7)
          typed_into_pane(["   ", ""])
          expect(write_pane).to include("modified" => true)

          expect(echoed).to include("lain: this pane has no note in it yet -- write one, then :w again")
          expect(messages).not_to include("stack traceback")
          expect(markers).to be_empty
        end
      end
    end

    # THE SECOND `:w`: `BufWriteCmd` fires on an acwrite buffer whether or not it
    # is modified, so a human who saves twice out of habit would file the
    # identical note twice, under two sequence numbers, on one line. The pane
    # stays CLEAN on this leg -- its note really was taken, so a write that
    # reported failure would be the lie in the other direction.
    it "places nothing on a second write of a pane whose note is already placed" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")

          compose(7)
          typed_into_pane(["said once"])
          write_pane
          expect(write_pane).to include("ok" => true, "modified" => false)

          expect(echoed.last).to start_with("lain: this pane's note is already placed;")
          expect(messages).not_to include("stack traceback")
          expect(markers).to eq([{ "row" => 7, "text" => "● note" }])
          expect(handed_back.size).to eq(1)
        end
      end
    end

    # The short path is untouched: `<leader>Ln` still PRE-FILLS the cmdline
    # with the same characters, byte for byte, and the pane's own key sits beside
    # it rather than in place of it.
    it "leaves the cmdline note keys exactly as they were, and adds the pane's beside them" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")
          in_file_pane("return true")

          expect(note_keys).to include(
            "n" => ":LainNote note ",
            "q" => ":LainNote question ",
            "b" => ":LainNote blocker ",
            "c" => ":LainNoteCompose "
          )
        end
      end
    end

    # THE CARD'S SIBLING CONSTRAINT, pinned rather than argued: the pane must not
    # become a third writer of the stamp state. Entering it INSIDE the review's
    # tabpage is the case that matters -- that is where `review_diff.entered`
    # re-acquires -- so the entry is driven for real and both halves are read: the
    # pane acquires no stamp and no round memory and binds no note key, and the
    # buffer the human came from still holds both.
    it "acquires no stamp and binds no note key when it is entered inside the review tabpage" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")
          compose(10)

          state = inspector.exec_lua(<<~LUA, [pane_buf, "\\L"])
            local pane, prefix = ...
            vim.api.nvim_set_current_buf(pane)
            vim.api.nvim_exec_autocmds("BufEnter", { buffer = pane })
            vim.api.nvim_exec_autocmds("WinEnter", {})
            local keys = {}
            for _, suffix in ipairs({ "n", "q", "b", "c", "N", "t" }) do
              keys[#keys + 1] = vim.fn.maparg(prefix .. suffix, "n")
            end
            return { side = tostring(vim.b[pane].lain_review_side),
                     revision = tostring(vim.b[pane].lain_review_revision),
                     path = tostring(vim.b[pane].lain_review_path),
                     round = tostring(vim.b[pane].lain_review_round),
                     keys = keys,
                     in_review_tab = vim.t[0].lain_review_revisions ~= nil }
          LUA

          expect(state).to include("in_review_tab" => true, "side" => "nil", "revision" => "nil",
                                   "path" => "nil", "round" => "nil")
          expect(state["keys"]).to all(eq(""))
          expect(in_file_pane("return tostring(vim.b[0].lain_review_side)")).to eq("new")
          expect(note_keys["n"]).to eq(":LainNote note ")
        end
      end
    end

    # THE RESTART, WHICH IS THE DESIGNED LIFECYCLE AND NOT AN EDGE. The runtime is
    # injected once per attach, so the reservation counter starts again at one --
    # while nvim outlives the Ruby process (ARCHITECTURE: `lain up` reattaches to
    # a tmux session) and a hidden pane keeps its NAME. Naming a fresh buffer over
    # a surviving one is E95, which escapes a `define`d callback wearing nvim's
    # traceback and, with a UI attached, a hit-enter prompt -- and leaves an
    # orphaned unnamed scratch buffer behind on every attempt, because the buffer
    # is created before it is named.
    it "opens a pane on a second attach while the first attach's pane is still there" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)

        described_class.new(channel:, socket_path: @socket).run do
          survey(dir)
          open_row("a.rb")
          compose(7)
          typed_into_pane(["begun before the restart"])
        end
        expect(pane_names.size).to eq(1)

        @inspector = nil
        described_class.new(channel:, socket_path: @socket).run do
          survey(dir)
          open_row("a.rb")

          expect(compose(9)).to include("ok" => true)
          expect(messages).not_to include("stack traceback")
          expect(pane_names.size).to eq(2)
          expect(pane_names.uniq.size).to eq(2)
          expect(inspector.exec_lua(<<~LUA, [])).to eq(0)
            local orphans = 0
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_get_name(b) == "" and vim.bo[b].buftype == "acwrite" then
                orphans = orphans + 1
              end
            end
            return orphans
          LUA
        end
      end
    end

    # THE SETTLE THAT WOULD INVERT THE INTERLEAVING THROUGH A DOOR THAT EXAMPLE
    # DOES NOT WATCH. A pane holding a reservation it has not spent is a note
    # whose place in line is taken and whose words have not arrived; settling
    # around it hands back the LATER note first and files the earlier one in a
    # later batch, which is the one thing this card exists to prevent.
    # `assert_saved` refuses an unsaved reviewed buffer for the neighbouring
    # reason; this is the same obligation.
    it "refuses to settle while a pane still holds a reservation, and names it" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")

          compose(10)
          typed_into_pane(["a long note still being typed"])
          noted(20, "the quick one")

          answer = settled
          expect(answer).to include("ok" => true)
          expect(answer["sent"]).to be_nil
          expect(echoed.last).to eq("lain: a note pane is unwritten -- :w it, or :bwipeout lain://note/1")
          expect(messages).not_to include("stack traceback")

          write_pane
          expect(handed_back.map { |note| note["line"] }).to eq([10, 20])
        end
      end
    end

    # A PANE THE HUMAN RENAMES HAS LEFT LAIN, AND ITS PLACE IN LINE GOES WITH IT.
    # `:file`/`:saveas` renames a buffer IN PLACE and fires no unload, so nothing
    # released the claim: `assert_placed` then refused every settle -- for the
    # life of the attach -- naming a buffer that no longer holds the draft, and
    # the next pane could take the stranded name and overwrite the orphan, so the
    # refusal went on to name a DIFFERENT human's draft. A refusal whose remedy
    # does not reach the thing it names is the one way that guard can trap
    # somebody, which is worse than the inversion it exists to prevent.
    # `47_diff` carries a whole `BufFilePost` handler for this same gesture on a
    # buffer that cannot even be written, so it is not exotic.
    #
    # THE OLD NAME SURVIVES THE RENAME, which is nvim's doing and not lain's:
    # `:file` sets the ALTERNATE file to the buffer's old name, so an unloaded
    # husk is left holding `lain://note/1`. That is why the next pane is
    # `lain://note/2` -- `free_name` asks the editor, and the editor still has
    # that name spoken for.
    it "gives back the place in line when the pane is renamed out from under lain" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")

          compose(10)
          typed_into_pane(["taken out of lain's hands"])
          renamed = inspector.exec_lua(<<~LUA, [File.join(dir, "renamed.md"), pane_buf])
            local wanted, pane = ...
            vim.api.nvim_buf_call(pane, function()
              vim.cmd("file " .. vim.fn.fnameescape(wanted))
            end)
            return vim.api.nvim_buf_get_name(pane)
          LUA
          expect(renamed).to eq(File.join(dir, "renamed.md"))

          noted(20, "the quick one")
          expect(handed_back.map { |note| note["line"] }).to eq([20])
          expect(echoed).not_to include(a_string_starting_with("lain: a note pane is unwritten"))

          # ...and the next pane is a pane of its own, holding a place in line
          # the renamed one is not standing in front of. It is `note/2` because
          # the alternate husk still holds `note/1` -- so both are named here, and
          # the new one is addressed BY NAME rather than taken as "the first",
          # which the husk would have answered.
          compose(11)
          expect(pane_names).to eq(["lain://note/1", "lain://note/2"])
          typed_into_pane(["a second draft, after the rename"], "lain://note/2")
          expect(write_pane("lain://note/2")).to include("ok" => true, "modified" => false)
          expect(handed_back.map { |note| note["line"] }).to eq([11])
        end
      end
    end

    # THE ARGUMENT SHAPE, AND IT IS THE ONE `<leader>Lc` INVITES. The key
    # pre-fills exactly as `<leader>Ln` does, whose contract is "the kind, then
    # your words" -- so a human who keeps typing must not have the whole line
    # echoed back at them as a mistyped kind. `nargs = "+"` splits and `fargs[1]`
    # is one whitespace-free token, so the refusal stays inside the budget; the
    # words that followed seed the pane rather than being dropped.
    it "takes the kind as the first word alone, and seeds the pane with what follows it" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")

          compose(7, "note the beginning of a thought")
          expect(inspector.exec_lua("return vim.api.nvim_buf_get_lines(select(1, ...), 0, -1, false)",
                                    [pane_buf])).to eq(["the beginning of a thought"])

          compose(8, "notee and some words after it")
          refusal = echoed.last
          expect(refusal).to eq("lain: :LainNoteCompose takes a kind: blocker, note, question -- got notee")
          expect(displayed_width(refusal)).to be <= 80
        end
      end
    end

    # A `:bdelete`d PANE, whose draft nvim has already thrown away: the name
    # survives, so `:w` on the reloaded husk still reaches this rail -- and the
    # husk comes back `buftype = ""` and UNMODIFIED, which is the one leg where
    # "reaching here means they typed something" does not hold. So this leg sets
    # 'modified' itself: a write that placed nothing must not report success.
    it "fails the write and places nothing when the pane has been deleted under it" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")
          compose(10)
          name = pane_names.first
          inspector.exec_lua("vim.cmd('bdelete! ' .. vim.fn.bufnr(select(1, ...)))", [name])

          revived = inspector.exec_lua(<<~LUA, [name])
            local name = ...
            vim.cmd("tabnew")
            vim.cmd("edit " .. vim.fn.fnameescape(name))
            local b = vim.api.nvim_get_current_buf()
            local ok, err
            vim.api.nvim_buf_call(b, function() ok, err = pcall(vim.cmd, "write") end)
            return { ok = ok, err = tostring(err), modified = vim.bo[b].modified }
          LUA

          expect(revived).to include("modified" => true)
          expect(echoed.last).to start_with("lain: nothing is pending in this pane;")
          expect(messages).not_to include("stack traceback")
          expect(markers).to be_empty
        end
      end
    end

    # THE DRAFT HAS AN ADDRESS, and the echo is where the human is told it. A
    # pane backed out of with `:q` is hidden and UNLISTED, so `:ls` does not show
    # it and no later gesture reaches it -- the one moment lain can name it is the
    # moment it opens. The path goes LAST, `assert_saved`'s rule for an unbounded
    # field, so a shortened echo truncates the file and not the way back.
    it "names the buffer the draft lives in, and the line it is against" do
      Dir.mktmpdir("lain-note-pane") do |dir|
        write_round(dir)
        frontend = described_class.new(channel:, socket_path: @socket)

        frontend.run do
          survey(dir)
          open_row("a.rb")
          compose(10)

          expect(echoed.last).to eq("lain: :w places this note; :b lain://note/1 comes back -- a.rb:10")
          expect(displayed_width(echoed.last)).to be <= 80

          typed_into_pane(["a draft backed out of"])
          inspector.exec_lua("vim.cmd('quit')", [])
          expect(inspector.exec_lua("return vim.fn.win_findbuf(select(1, ...))", [pane_buf])).to be_empty

          # ...and the address in that sentence is one that actually works.
          expect(inspector.exec_lua(<<~LUA, [])).to eq(["a draft backed out of"])
            vim.cmd("buffer lain://note/1")
            return vim.api.nvim_buf_get_lines(0, 0, -1, false)
          LUA
        end
      end
    end
  end
end
