# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tmpdir"

# tmux has no environment variable that skips the operator's config, and that config may run a
# plugin manager at every server start. A `tmux` ahead of the real one on PATH is the one seam
# that also covers lib's servers, specs' hand-run ones and the `tmux` a pane's own child runs.
# tmux loads every `-f` in order and /dev/null adds nothing, so a caller's own `-f` still loads.
module IsolatedTmux
  REAL = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "tmux") }
            .find { |path| File.executable?(path) }

  if REAL
    DIR = Dir.mktmpdir("lain-spec-tmux-")
    File.write(File.join(DIR, "tmux"), "#!/bin/sh\nexec #{REAL.shellescape} -f /dev/null \"$@\"\n", perm: 0o755)
    ENV["PATH"] = [DIR, ENV.fetch("PATH")].join(File::PATH_SEPARATOR)
    at_exit { FileUtils.remove_entry(DIR, true) }
  end
end
