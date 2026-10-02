# frozen_string_literal: true

require "open3"
require "rbconfig"

# A new ruby that has required lain and nothing else, for asserting what a boot does and does not load.
module FreshRuby
  LIB = File.expand_path("../../lib", __dir__)

  def self.run(script, stdin: "")
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-r", "lain", "-e", script, stdin_data: stdin)
    raise "subprocess failed: #{stderr}" unless status.success?

    stdout
  end
end
