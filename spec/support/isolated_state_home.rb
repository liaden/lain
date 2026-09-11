# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Every suite process gets its own XDG state home, so no example can write
# into the real ~/.local/state: shadow stores, gc stamps, worktree roots and
# journals all resolve under it. Two such leaks were found only by accident.
# A spec that needs a specific state home still sets its own.
module IsolatedStateHome
  DIR = Dir.mktmpdir("lain-state-home-")
  ENV["XDG_STATE_HOME"] = DIR
  at_exit { FileUtils.remove_entry(DIR, true) }
end
