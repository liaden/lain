# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# `commit`, `merge`, `fetch` and `receive-pack` each fork a detached `git maintenance run --auto`
# that outlives the example and writes under a repo its tmpdir teardown is deleting.
# NOSYSTEM: a distro /etc/gitconfig would otherwise still reach fixtures.
module IsolatedGitConfig
  CONTENT = "[gc]\n\tauto = 0\n[maintenance]\n\tauto = false\n"
  DIR = Dir.mktmpdir("lain-git-config-")
  FILE = File.join(DIR, "gitconfig")
  File.write(FILE, CONTENT)
  ENV["GIT_CONFIG_GLOBAL"] = FILE
  ENV["GIT_CONFIG_NOSYSTEM"] = "1"
  at_exit { FileUtils.remove_entry(DIR, true) }
end
