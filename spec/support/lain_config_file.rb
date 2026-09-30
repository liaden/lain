# frozen_string_literal: true

require "fileutils"

# Writes `.lain/config.rb` into a throwaway root and trusts its bytes, the way
# `lain trust` would. Every scenario that reads the project config builds its
# OWN root -- config.rb is a project file, never the real cwd's, so no example
# can read or write a config another spec would see.
#
# Trust is granted last, over every `.lain/*.rb` then present, so a spec that
# plants a sibling Ruby file first gets both trusted by this one call.
module LainConfigFile
  # The committed fixture projects are this repository's own files, trusted
  # once per process as a developer running `lain trust` on a checkout would.
  # Trust is keyed on content, so every copy a spec makes of one is trusted by
  # the same mark; a spec that sets its own state home grants its own.
  COMMITTED = Dir.glob(File.expand_path("../fixtures/**/.lain", __dir__), File::FNM_DOTMATCH)
                 .map { |dir| File.dirname(dir) }.freeze

  def self.trust_committed(paths: Lain::Paths.new)
    COMMITTED.each do |root|
      Lain::Project::Trust.for(project_dir: Lain::ProjectDir.new(root:, paths:), paths:).grant!
    end
  end

  def write_config(root, body, paths: Lain::Paths.new)
    FileUtils.mkdir_p(File.join(root, ".lain"))
    File.write(config_path(root), body)
    trust_project(root, paths:)
  end

  def config_path(root) = File.join(root, ".lain", "config.rb")
end

RSpec.configure do |config|
  config.include LainConfigFile
  config.before(:suite) { LainConfigFile.trust_committed }
end
