# frozen_string_literal: true

require "pathname"

module TestMap
  # Names the spec file the process is working on, while RSpec loads it and while its top-level group runs.
  module Attribution
    # Process-wide rather than per thread, so a thread lib code starts is attributed too. Only RSpec's own
    # thread writes it.
    class Tracker
      # The interval between loading the last spec file and running the first group, where before(:suite)
      # hooks build what many files later share.
      SUITE = :suite

      # @return [String, nil] the repo-relative path of the spec file being loaded or run
      attr_reader :current

      # @param root [Pathname] the directory paths are named relative to
      def initialize(root)
        @root = root
        @current = nil
        @open_interval_file = nil
        @boundaries = []
      end

      # @yieldparam leaving [String, Symbol, nil] the interval that closed: a spec file, SUITE, or nil for boot
      # @yieldparam entering [String, Symbol, nil] the interval that opens: a spec file, SUITE, or nil when the
      #   run has ended
      # @return [nil]
      def on_boundary(&block)
        @boundaries << block
        nil
      end

      # A group run inside an example (a sandboxed RSpec) stays with the example's file.
      #
      # @param path [String] a spec file, absolute or `./`-relative
      # @return [Object] the block's value
      def within(path)
        return yield if @current

        open_interval(normalise(path))
        begin
          yield
        ensure
          @current = nil
        end
      end

      # @return [void]
      def enter_suite = open_interval(SUITE, current: nil)

      # @return [void]
      def finish = open_interval(nil, current: nil)

      private

      # Gaps between files stay with the file before them, so a boundary costs 1 snapshot per file per
      # phase rather than 1 on each side of every gap.
      def open_interval(interval, current: interval)
        @current = current
        return if interval == @open_interval_file

        leaving = @open_interval_file
        @open_interval_file = interval
        @boundaries.each { |boundary| boundary.call(leaving, interval) }
      end

      def normalise(path)
        absolute = Pathname(File.expand_path(path, @root))
        relative = absolute.relative_path_from(@root).to_s
        relative.start_with?("../") ? absolute.to_s : relative
      end
    end

    TRACKER = Tracker.new(Pathname(File.expand_path("../../..", __dir__)))

    # @return [String, nil] the repo-relative path of the spec file being loaded or run
    def self.current = TRACKER.current

    # @yieldparam leaving [String, Symbol, nil] the interval that closed: a spec file, Tracker::SUITE, or nil
    #   for boot
    # @yieldparam entering [String, Symbol, nil] the interval that opens: a spec file, Tracker::SUITE, or nil
    #   when the run has ended
    # @return [nil]
    def self.on_boundary(&block) = TRACKER.on_boundary(&block)

    # Spec files arrive as `:load`; `--require spec_helper` arrives as `:require` and is not a spec file.
    module FileLoad
      # @return [Object] RSpec's own return value
      def load_file_handling_errors(method, file)
        return super unless method == :load

        TRACKER.within(file) { super }
      end
    end

    # Names the file for a group's before(:context), after(:context) and every example.
    module GroupRun
      # @return [Boolean] RSpec's own return value
      def run(...)
        TRACKER.within(metadata[:rerun_file_path]) { super }
      end
    end
  end
end

if TestMap::RECORD_DIR
  RSpec::Core::Configuration.prepend(TestMap::Attribution::FileLoad)
  RSpec::Core::ExampleGroup.singleton_class.prepend(TestMap::Attribution::GroupRun)
  RSpec.configure do |config|
    config.prepend_before(:suite) { TestMap::Attribution::TRACKER.enter_suite }
    config.append_after(:suite) { TestMap::Attribution::TRACKER.finish }
  end
end
