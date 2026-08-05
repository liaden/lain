# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Temporary directories for the specs that mint UNIX SOCKETS inside them -- the
# editor and cockpit harnesses, which spawn a real `nvim --listen` and hand the
# path to `Socket.unix`. Two constraints that `Dir.mktmpdir` alone fails, both of
# them only on macOS, and both of them silent:
#
#   * `sun_path` is 104 bytes on darwin (108 on Linux), and macOS's per-user
#     `$TMPDIR` (`/var/folders/<2>/<24>/T`, 49 bytes) spends half the budget
#     before the fixture's own name. A socket under it overflows -- `ArgumentError`
#     from Ruby, and NOTHING from nvim, whose `serverstart` is wrapped in `pcall`
#     by design (init.lua's documented degrade mode: serve no socket). So the
#     interesting failure is not the raise, it is the example that sees an empty
#     `serverlist()` and cannot say why. `/tmp` is 4 bytes and leaves ~100.
#   * `/tmp` and `/var` are both SYMLINKS into `/private` on macOS. nvim's
#     `getcwd()` and `fnamemodify(..., ":p")` return kernel-resolved paths, as
#     does `Paths#project_hash` (`sha256(realpath)`), so an unresolved fixture
#     root makes a spec compare `/var/...` against the editor's `/private/var/...`
#     and disagree about a path that is the same file.
#
# Resolving here rather than at each call site is what keeps the two sides
# expressed once: a fixture root from this helper is already the path the editor
# will name back.
module SocketTmpdir
  # Short enough for `sun_path` on every platform we run, and NOT the per-user
  # `$TMPDIR`: the point is the byte budget. World-readable, so nothing secret
  # belongs in a fixture built here -- which is already true of every caller.
  BASE = "/tmp"

  # `Dir.mktmpdir` with the two corrections above. Same signature and same
  # block/return contract, so it substitutes directly.
  def socket_tmpdir(prefix = nil)
    return File.realpath(Dir.mktmpdir(prefix, BASE)) unless block_given?

    Dir.mktmpdir(prefix, BASE) { |dir| yield File.realpath(dir) }
  end

  # The `PROJECT = ...` constant shape, for a fixture built once per process and
  # torn down at exit. `module_function`-reachable because those constants are
  # assigned in a plain `module` body, outside any RSpec example group.
  def self.persistent(prefix)
    File.realpath(Dir.mktmpdir(prefix, BASE)).tap do |dir|
      at_exit { FileUtils.remove_entry(dir) if File.directory?(dir) }
    end
  end
end

RSpec.configure { |config| config.include SocketTmpdir }
