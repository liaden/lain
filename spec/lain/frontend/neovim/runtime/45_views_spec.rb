# frozen_string_literal: true

# `runtime/45_views.lua` -- the projections with a lua-side home, and the rail
# table every surface now renders through.
#
# The rail table's gate is here rather than in `rpc_thread_spec.rb` because a
# dispatch that COMPILES but names a lua function wrongly fails nowhere else:
# every rail rides an `nvim_exec_lua` NOTIFY and nvim discards a notify's error,
# so a misnamed entry point is a whole surface that silently never draws.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-views-spec") { example.run } }

  describe "workspace view has a lua-side home" do
    it "renders lain://workspace through set_view as a first-class lain buffer, not an orphan" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        # Session::Null has no reminders, so priming renders the empty state.
        # Before the fix, named_buf("lain://workspace") looked up a name the
        # runtime's tables never held: `vim.bo[buf].filetype = nil` silently
        # left the filetype "", so the buffer rendered but lived OUTSIDE the
        # lain contract -- no syntax, no view marker. That is the orphan.
        wait_until_editor { buffer_lines("lain://workspace") == ["(no reminders)"] }

        state = inspector.exec_lua(<<~LUA, [])
          local buf = vim.fn.bufnr("lain://workspace")
          return {
            filetype = vim.bo[buf].filetype,
            buftype = vim.bo[buf].buftype,
            modifiable = vim.bo[buf].modifiable,
            lain_view = vim.b[buf].lain_view,
          }
        LUA

        expect(state["filetype"]).to eq("lain")
        expect(state["buftype"]).to eq("nofile")
        expect(state["modifiable"]).to be(false)
        expect(state["lain_view"]).to eq("lain://workspace")
      end
    end
  end

  # Markdown rather than the shared "lain" filetype, because the buffer carries
  # a ```mermaid fence and markdown is what an image plugin (snacks.image)
  # renders one in. Read-only and claimed like every other projection.
  describe "status view has a lua-side home" do
    it "renders lain://status as a read-only markdown buffer" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://status").any? }

        state = inspector.exec_lua(<<~LUA, [])
          local buf = vim.fn.bufnr("lain://status")
          return {
            filetype = vim.bo[buf].filetype,
            buftype = vim.bo[buf].buftype,
            modifiable = vim.bo[buf].modifiable,
            lain_view = vim.b[buf].lain_view,
          }
        LUA

        expect(state).to eq("filetype" => "markdown", "buftype" => "nofile", "modifiable" => false,
                            "lain_view" => "lain://status")
      end
    end
  end

  # THE RAIL TABLE'S ONE GATE, and it is here rather than in
  # `rpc_thread_spec.rb` because a dispatch that COMPILES but names a lua
  # function wrongly fails nowhere else: every rail rides an `nvim_exec_lua`
  # NOTIFY, nvim discards a notify's error, and a misnamed entry point is a
  # whole surface that silently never draws.
  #
  # The unit side pins the table against the runtime's SOURCE -- that the
  # declarations exist, spelled as {RenderQueue::RAILS} says. This pins it
  # against a runtime that has actually been INJECTED AND RUN, which is the
  # difference between a name in a file and a name on `_G.__lain`: a module that
  # loads and then errors publishes nothing, and the source would still read
  # fine. The rest of the proof is that every other example in this file renders
  # at all: they all reach their views through this one chunk now.
  describe "the rail table's one lua dispatch" do
    def rails = Lain::Frontend::Neovim::RenderQueue::RAILS

    def arity_of(rail) = rail.params.empty? ? 0 : rail.params.split(",").size

    # Every entry point the table names, stood aside for a recorder, so a rail
    # is observed by the NAME it dispatches on rather than by whatever that
    # entry point would have drawn -- several of them open windows.
    #
    # IT REPLACES, WHICH MEANS IT CAN ALSO CREATE, and an earlier draft did
    # exactly that: `_G.__lain[name] = function() ... end` for every row made
    # every row reachable, so a table naming `set_thread_NOPE` passed. So the
    # names are CHECKED before they are stood aside, and the ones that were not
    # already live functions come back to be named in the failure -- which is
    # the whole of what this example can see that the source read cannot.
    #
    # @return [Array<String>] table rows naming nothing this runtime published
    def install_rail_recorder
      inspector.exec_lua(<<~LUA, [rails.each_value.map(&:lua)])
        _G.__rails = {}
        local absent = {}
        for _, name in ipairs(...) do
          if type(_G.__lain[name]) ~= "function" then
            table.insert(absent, name)
          else
            _G.__lain[name] = function(...) _G.__rails[name] = select("#", ...) end
          end
        end
        return absent
      LUA
    end

    it "reaches every rail's lua entry point, with the arity its row declares" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { buffer_lines("lain://workspace") == ["(no reminders)"] }
        absent = install_rail_recorder

        expect(absent).to be_empty, "rail rows naming no live _G.__lain function: #{absent.inspect}. " \
                                    "A module that loads and then errors publishes nothing, and its " \
                                    "source still reads fine -- which is why this is checked here."

        rails.each_value do |rail|
          inspector.exec_lua(Lain::Frontend::Neovim::RenderQueue::DISPATCH,
                             [rail.lua, Array.new(arity_of(rail)) { |index| index }])
        end

        expect(inspector.exec_lua("return _G.__rails", []))
          .to eq(rails.each_value.to_h { |rail| [rail.lua, arity_of(rail)] })
      end
    end
  end
end
