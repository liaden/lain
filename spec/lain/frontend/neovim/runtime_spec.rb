# frozen_string_literal: true

require "timeout"

# `runtime.lua` -- the chunk itself rather than any module it loads: the digest it
# reports back, and the one-lain-per-editor rule its chunk-local channel imposes.
#
# The two belong together because both are properties of INJECTION. The digest is
# what the editor answers about the source it was given; `chan` is the local at
# the head of that same chunk, which a second attach repoints at the newcomer --
# and every :Lain* verb closes over it.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  include NeovimRuntime

  around { |example| headless_editor("lain-nvim-runtime-spec") { example.run } }

  describe "the runtime digest" do
    # A GENUINELY STALE RUNTIME: a real lain, whose real `_G.__lain` and real
    # commands are still installed, injected under a token that is not this gem's,
    # whose process has since gone away.
    #
    # A bare `vim.g.lain_rpc_version` write is NOT this, and the distinction is
    # the whole of what the gate is for -- a guard that fires on a leftover
    # variable with no runtime behind it is refusing an editor that has nothing
    # wrong with it. Every example below that means "stale" uses this.
    #
    # `:LainGhost` is the residue the refusal exists to warn about: a command this
    # runtime defines and ours does not, so re-injection cannot take it away.
    def install_stale_runtime(token: "OLD-RUNTIME-TOKEN")
      described_class.new(channel: Lain::Channel.new, socket_path: @socket, protocol: token).run do
        wait_until_editor { live_protocol == token }
        inspector.exec_lua("vim.api.nvim_create_user_command('LainGhost', function() end, {}); return true", [])
      end
      token
    end

    # What the RUNTIME says is loaded here, published only once every module has
    # executed -- as against `g:lain_rpc_version`, which the chunk head stamps
    # before a single module runs and which therefore says only what was injected.
    def live_protocol
      inspector.exec_lua("return type(_G.__lain) == 'table' and _G.__lain.protocol or nil", [])
    end

    # Through lua, not `get_var`: the gem's `get_var` raises "Key not found" for an
    # absent global rather than answering nil, and an editor no lain has touched is
    # the starting state of half these examples.
    def injected_stamp = inspector.exec_lua("return vim.g.lain_rpc_version", [])

    def ghost? = inspector.exec_lua("return vim.fn.exists(':LainGhost')", []) == 2

    # The token is DERIVED from the bytes injected, so "the two halves agree" is
    # not a thing anybody maintains -- it is the same expression twice.
    it "attaches to an editor holding no runtime, stamping it with the digest of what it injected" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until_editor { live_protocol == described_class.protocol }
        expect(described_class.protocol).to eq(Lain::Ext.blake3_hex(runtime_source))
        expect(injected_stamp).to eq(described_class.protocol)
      end
    end

    # The lua half cannot hold a literal copy of a digest of itself, so what it
    # compares against is what the runtime IN THIS EDITOR published about itself --
    # which exists only if a runtime really loaded here.
    it "refuses an editor whose live runtime was injected from a different source" do
      stale = install_stale_runtime

      expect { described_class.new(channel:, socket_path: @socket).run { nil } }
        .to raise_error(Lain::Frontend::Neovim::RuntimeStale, /#{stale[0, 12]}/)
    end

    # The refusal names the socket, for {SocketOwned}'s reason: the human who has
    # to act on it is at the terminal that just tried to attach, and a sentence
    # about "the editor" names nothing they can point at when two are open.
    it "names the socket and the runtime this gem would have injected" do
      install_stale_runtime

      expect { described_class.new(channel:, socket_path: @socket).run { nil } }
        .to raise_error(Lain::Frontend::Neovim::RuntimeStale,
                        /#{Regexp.escape(@socket)}.*#{described_class.protocol[0, 12]}/m)
    end

    # THE GATE. `g:lain_rpc_version` outlives the runtime that set it -- a `:source`
    # of somebody's config, a plugin, an editor that was attached and had its
    # `_G.__lain` cleared -- and a leftover variable is not a stale runtime. Refusing
    # on one costs a human their editor over litter.
    it "does not refuse on a leftover stamp with no runtime behind it" do
      inspector.exec_lua("vim.g.lain_rpc_version = ('0'):rep(64); return true", [])

      frontend = described_class.new(channel:, socket_path: @socket)
      frontend.run do |handle|
        inspector.command("LainReply over the litter")
        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["reply", ["over the litter"]])
      end
    end

    # PROPORTIONALITY, and it is the whole of why refusing is affordable. The digest
    # moves on every edit to any runtime module, so a guard that latched would cost
    # a developer their editor each time they touched a line of lua. It announces
    # ONCE and the re-run is the consent.
    #
    # And it clears a PRIVATE flag to do it, never `g:lain_rpc_version`: that
    # variable is published surface, and the shipped plugin reads it to decide
    # whether an editor is attached at all (`plugin/nvim/lua/lain/init.lua`). An
    # earlier draft cleared it and left :LainStart telling an attached human their
    # editor was not attached.
    it "announces once, leaves the published stamp alone, and attaches on the re-run" do
      stale = install_stale_runtime

      expect { described_class.new(channel: Lain::Channel.new, socket_path: @socket).run { nil } }
        .to raise_error(Lain::Frontend::Neovim::RuntimeStale)
      expect(injected_stamp).to eq(stale)

      frontend = described_class.new(channel:, socket_path: @socket)
      frontend.run do |handle|
        inspector.command("LainReply reclaimed")
        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["reply", ["reclaimed"]])
      end
      expect(live_protocol).to eq(described_class.protocol)
    end

    # WHAT THE ANNOUNCEMENT IS AND IS NOT, said out loud so nobody reads more into
    # it later. Re-injection replaces everything the new chunk defines and every
    # augroup in it is `clear = true`, so what survives is exactly what the newer
    # runtime no longer has -- and it survives the consented re-attach too. This is
    # a WARNING that an editor is carrying another lain's leavings, not a repair of
    # them; the repair is quitting nvim, which is what the sentence says.
    it "does not pretend the consented re-attach removes the older runtime's leavings" do
      install_stale_runtime
      expect(ghost?).to be(true)

      expect { described_class.new(channel: Lain::Channel.new, socket_path: @socket).run { nil } }
        .to raise_error(Lain::Frontend::Neovim::RuntimeStale)
      described_class.new(channel:, socket_path: @socket).run { wait_until_editor { owner_channel } }

      expect(ghost?).to be(true)
    end

    # The half a one-shot gets wrong if it records its consent against the EDITOR
    # rather than against the runtime it consented to replace: a guard that fires
    # once and is then permanently satisfied is not a guard at all past its first
    # use. The flag is cleared when a runtime installs, so the NEXT difference
    # announces itself too.
    it "announces again the next time the runtime differs, rather than staying satisfied" do
      install_stale_runtime

      expect { described_class.new(channel: Lain::Channel.new, socket_path: @socket).run { nil } }
        .to raise_error(Lain::Frontend::Neovim::RuntimeStale)
      described_class.new(channel: Lain::Channel.new, socket_path: @socket).run { wait_until_editor { owner_channel } }

      expect { described_class.new(channel:, socket_path: @socket, protocol: "A-THIRD-RUNTIME").run { nil } }
        .to raise_error(Lain::Frontend::Neovim::RuntimeStale, /#{described_class.protocol[0, 12]}/)
    end

    # The ordinary case -- the human quits lain and starts another one in the same
    # editor -- and it must cost nothing at all.
    it "attaches over a runtime injected from the SAME source, saying nothing" do
      described_class.new(channel: Lain::Channel.new, socket_path: @socket).run { wait_until_editor { owner_channel } }

      frontend = described_class.new(channel:, socket_path: @socket)
      frontend.run do |handle|
        inspector.command("LainReply same source")
        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["reply", ["same source"]])
      end
    end

    # Ownership is settled BEFORE the digest, and the order is the contract: a live
    # lain's editor must be left exactly as it was found, and the stale check writes
    # a flag, which is still a write.
    it "refuses a live owner by channel, whatever the runtimes say" do
      first = described_class.new(channel:, socket_path: @socket)

      first.run do
        wait_until_editor { owner_channel }

        expect { described_class.new(channel: Lain::Channel.new, socket_path: @socket, protocol: "OTHER").run { nil } }
          .to raise_error(Lain::Frontend::Neovim::SocketOwned)
        expect(live_protocol).to eq(described_class.protocol)
      end
    end
  end

  # ONE LAIN PER EDITOR. The runtime is injected into a process-wide
  # `_G.__lain`, and every :Lain* command closes over `chan`, the chunk-local at
  # the head of runtime.lua -- so a second attach re-injects the whole chunk and
  # repoints every verb at the newcomer's channel. Measured twice before this
  # guard existed: the first lain's :LainReply raised `Invalid channel: N`
  # forever once the second exited, the newcomer's empty prime replaced the
  # first's rendered views, and the only evidence anywhere was a traceback in
  # :messages that reached nobody.
  #
  # Every example here drives TWO real frontends against one real editor,
  # because the defect lives strictly between two attaches and nothing smaller
  # can see it.
  describe "one lain per editor" do
    it "refuses a second attach by name, and the first lain's replies keep arriving" do
      first = described_class.new(channel:, socket_path: @socket)

      first.run do |handle|
        wait_until_editor { owner_channel }

        expect { second_frontend.run { nil } }
          .to raise_error(Lain::Frontend::Neovim::SocketOwned, /#{Regexp.escape(@socket)}/)

        inspector.command("LainReply still mine")
        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["reply", ["still mine"]])
      end
    end

    # The refusal has to be TOTAL, and this is the half a "refuse, then carry
    # on injecting anyway" implementation passes the example above with: the
    # marker still names the first lain, so nothing repointed, and the chunk
    # never reached the module that would have.
    it "leaves the owner's marker and its rendered views exactly as they were" do
      first = described_class.new(channel:, socket_path: @socket)

      first.run do
        owner = wait_until_editor { owner_channel }
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t0", stream: :stdout, bytes: "the first lain"))
        wait_until_editor { buffer_lines("lain://journal").any? { |line| line.include?("the first lain") } }

        expect { second_frontend.run { nil } }.to raise_error(Lain::Frontend::Neovim::SocketOwned)

        expect(owner_channel).to eq(owner)
        expect(buffer_lines("lain://journal")).to include(a_string_including("the first lain"))
      end
    end

    # An implementation that detects PRESENCE rather than LIVENESS refuses this
    # one too, and that is worse than the defect: a lain that crashed leaves its
    # `_G.__lain` behind, and the human's editor would then be unusable until
    # they restarted nvim. The marker is a channel id precisely so the editor
    # can be ASKED whether that lain is still there.
    it "attaches over a marker left by a lain that has gone away" do
      inspector.exec_lua("_G.__lain = { channel = 9999 }; return true", [])

      frontend = described_class.new(channel:, socket_path: @socket)
      frontend.run do |handle|
        inspector.command("LainReply reclaimed")
        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["reply", ["reclaimed"]])
      end
    end

    # The same rule for a runtime injected BEFORE the marker existed (any
    # protocol below 11): a table with no channel on it names no owner, so it
    # cannot answer for one, and refusing on it would strand every editor a
    # older gem had ever touched.
    it "attaches over a runtime that predates the ownership marker" do
      inspector.exec_lua("_G.__lain = { render = function() end }; return true", [])

      frontend = described_class.new(channel:, socket_path: @socket)
      frontend.run { wait_until_editor { owner_channel } }
    end

    # The real re-attach, end to end and with no marker planted by hand: the
    # human quits lain and starts another one in the same editor. The first
    # lain's channel dies with its socket, so the second is not a second at all.
    it "attaches again once the lain that owned the editor has exited" do
      described_class.new(channel: Lain::Channel.new, socket_path: @socket).run { wait_until_editor { owner_channel } }

      frontend = described_class.new(channel:, socket_path: @socket)
      frontend.run do |handle|
        inspector.command("LainReply after the first quit")
        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["reply", ["after the first quit"]])
      end
    end

    # A guard that fires once is a guard that fails the second time somebody
    # does the thing -- and the second time is the likelier one, since a human
    # who has just been refused tends to try again.
    it "refuses every further attach, not merely the first one after the owner" do
      first = described_class.new(channel:, socket_path: @socket)

      first.run do
        wait_until_editor { owner_channel }

        2.times do
          expect { second_frontend.run { nil } }.to raise_error(Lain::Frontend::Neovim::SocketOwned)
        end
      end
    end
  end

  # The RPC channel the runtime records as this editor's owner, or nil when no
  # lain has ever attached. Read through a THIRD connection (the inspector), so
  # the reading never disturbs the two frontends the examples below are about.
  def owner_channel
    inspector.exec_lua("return type(_G.__lain) == 'table' and _G.__lain.channel or nil", [])
  end

  # A second frontend on the SAME socket, with its own Channel: `Neovim#run`'s
  # teardown closes the Channel it was built over, so sharing the `channel` let
  # would have the refused attach's teardown close the surviving lain's drain --
  # a second collision, inside the example testing the first.
  def second_frontend = described_class.new(channel: Lain::Channel.new, socket_path: @socket)

  # The chunk nvim is actually sent. Read through the loader, never off runtime.lua,
  # which is only the chunk's HEAD and defines nothing.
  def runtime_source
    Lain::Frontend::Neovim::RuntimeLoader.new.source
  end
end
