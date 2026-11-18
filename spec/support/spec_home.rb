# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A Paths built from a Hash with no HOME and no XDG_CONFIG_HOME falls back to
# Dir.home, the developer's real home, where their config.rb runs or is refused
# as untrusted. The suite's XDG_CONFIG_HOME cannot help: the Hash replaces ENV.
# Dir.home itself stays real, because child processes and leak guards read it.
module SpecHome
  DIR = Dir.mktmpdir("lain-spec-home-")
  at_exit { FileUtils.remove_entry(DIR, true) }

  def self.env(env) = env.key?("HOME") || env.key?("XDG_CONFIG_HOME") ? env : { "HOME" => DIR }.merge(env)
end
