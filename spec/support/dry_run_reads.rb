# frozen_string_literal: true

# How many files a spec file reads while it merely LOADS, counted in a fresh ruby
# that dry-runs it. A read at load is time no example's timing is charged for.
module DryRunReads
  ROOT = File.expand_path("../..", __dir__)

  # @param spec_path [String] relative to the repository root
  # @return [Integer]
  def self.count(spec_path)
    FreshRuby.run(script(File.join(ROOT, spec_path))).to_i
  end

  def self.script(path)
    <<~RUBY
      require "pathname"
      require "stringio"
      $reads = 0
      Pathname.prepend(Module.new do
        def read(*) = ($reads += 1; super)
        def readlines(*) = ($reads += 1; super)
      end)
      require "rspec/core"
      Dir.chdir(#{ROOT.inspect})
      RSpec::Core::Runner.run(["--dry-run", #{path.inspect}], StringIO.new, StringIO.new)
      puts $reads
    RUBY
  end
end
