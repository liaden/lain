# frozen_string_literal: true

require "fileutils"

# Writes `.lain/config.toml` into a throwaway root. Every scenario that reads
# the project config builds its OWN root -- config.toml is a project file,
# never the real cwd's, so no example can read or write a config another spec
# would see. That posture is the same in every one of those files, so the
# writer lives here instead of being copied into each of them.
module LainConfigFile
  def write_config(root, body)
    FileUtils.mkdir_p(File.join(root, ".lain"))
    File.write(config_path(root), body)
  end

  def config_path(root) = File.join(root, ".lain", "config.toml")
end

RSpec.configure { |config| config.include LainConfigFile }
