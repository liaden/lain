# frozen_string_literal: true

# Another process holding a parent checkout's {Lain::Isolation::ParentLock} for
# a block's duration: the shape of a chat handing back while `lain epic land`
# runs, or the reverse. The block is given the holder's pid. Closing the release
# pipe lets it go, and the child leaves through `exit!` in an `ensure`, so a
# failure there never runs this suite's exit hooks in the child.
module HeldParentLock
  def while_held_elsewhere(root)
    ready, held = IO.pipe
    release, go = IO.pipe
    pid = fork { [ready, go].each(&:close) && HeldParentLock.hold_until_told(root, held, release) }
    [held, release].each(&:close)
    raise "the other process never took the lock" unless ready.read(4) == "held"

    yield pid
  ensure
    go&.close
    Process.wait(pid) if pid
  end

  def self.hold_until_told(root, held, release)
    Lain::Isolation::ParentLock.for(repo_root: root).hold { held.write("held") && held.flush && release.read(1) }
  ensure
    exit!(0)
  end
end
