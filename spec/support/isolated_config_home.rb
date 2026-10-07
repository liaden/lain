# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Every suite process gets its own XDG config home, so no example reads the
# developer's ~/.config/lain: the user's config.rb there runs in every project,
# and a suite that read it would pass or fail on what that file says. A spec
# that needs a specific config home still sets its own.
module IsolatedConfigHome
  DIR = Dir.mktmpdir("lain-config-home-")
  ENV["XDG_CONFIG_HOME"] = DIR
  at_exit { FileUtils.remove_entry(DIR, true) }
end
