# frozen_string_literal: true

# Child processes booted ahead of the example that takes them. A fresh Ruby that
# loads `lain` costs over a second, and an example that boots one waits for it
# before it can begin; a child booted while the PREVIOUS example runs makes that
# wait overlap work the file was doing anyway.
#
# One pool per spec file, built in `before(:context)` and drained in
# `after(:context)` by {Group#warm_pool}, so nothing is shared between files and
# nothing outlives its file. A spare is only booted while more children are
# expected than have been taken, so a one-example run boots no spare.
#
# A child must be able to reap itself (`#reap`): kill, wait, close its pipes and
# remove its directory. Whatever the child cannot be told after it boots, such as
# the TERM Reline reads at load, is the `key`.
module WarmPool
  # How a booted child learns what the example decides. It waits for the file
  # named by WARM_GO to appear, which {.release} writes whole, and takes its
  # ARGV from it. It exits if its parent (WARM_PPID) goes first, so a worker
  # killed mid-file leaves no Ruby polling for a file that will never appear.
  PARK = <<~RUBY
    go = ENV.fetch("WARM_GO")
    worker = ENV.fetch("WARM_PPID").to_i
    until File.exist?(go)
      exit! unless Process.ppid == worker
      sleep(0.01)
    end
    ARGV.replace(File.read(go).split("\\n"))
  RUBY

  def self.parked(script) = "require \"lain\"\n#{PARK}#{script}"

  def self.go_path(dir) = File.join(dir, "go")

  def self.park_env(dir) = { "WARM_GO" => go_path(dir), "WARM_PPID" => Process.pid.to_s }

  # Written beside `go` and renamed, so the child never reads half a line.
  def self.release(dir, argv)
    File.write("#{go_path(dir)}.tmp", argv.join("\n"))
    File.rename("#{go_path(dir)}.tmp", go_path(dir))
  end

  class Pool
    ALL = Object.new.freeze

    # @param expected [Integer, Hash] how many children the file will take, or
    #   how many it will take of each key
    # @yieldparam key [Object] what the child cannot be told after it boots
    # @yieldreturn [#reap]
    def initialize(expected:, &boot)
      @boot = boot
      @left = expected.is_a?(Hash) ? expected.dup : { ALL => expected }
      @ready = {}
      @taken = Hash.new(0)
    end

    # Too high an `expected:` is harmless, drain reaps the spare; only too low raises.
    def take(key = nil)
      count = counter_for(key)
      raise_unexpected(key, count) unless @left[count].positive?

      @taken[count] += 1
      child = @ready.delete(key) || @boot.call(key)
      @ready[key] = @boot.call(key) if (@left[count] -= 1).positive?
      child
    end

    def drain
      @ready.each_value(&:reap)
      @ready.clear
    end

    private

    def raise_unexpected(key, count)
      subject = count.equal?(ALL) ? "a child" : key.inspect
      raise ArgumentError, "#{subject} was expected #{@taken[count]} times and this is take #{@taken[count] + 1}: " \
                           "raise `expected:`"
    end

    def counter_for(key)
      return key if @left.key?(key)

      @left.key?(ALL) ? ALL : raise(KeyError, "no children expected for #{key.inspect}; expected #{@left.keys.inspect}")
    end
  end

  module Group
    # Declares `name` as the file's pool; the block boots one child for a key.
    # `expected` says how many of each key the examples take, when the file does
    # not take one child per example.
    def warm_pool(name, expected: nil, &boot)
      before(:context) do
        (@warm_pools ||= {})[name] = Pool.new(expected: expected || self.class.descendant_filtered_examples.size, &boot)
      end

      after(:context) { @warm_pools.each_value(&:drain) }

      define_method(name) { @warm_pools.fetch(name) }
    end
  end
end

RSpec.configure { |config| config.extend WarmPool::Group }
