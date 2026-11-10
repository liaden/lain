# frozen_string_literal: true

# Lists the spec files that run real git without a :seam or :e2e tag, so the inner loop (`--tag '~seam'`)
# can be checked to run none. Report only: it never changes an example's result.
if ENV["LAIN_SEAM_REPORT"] == "1"
  module SeamReport
    COUNTS = Hash.new(0)
    LOCK = Mutex.new

    module_function

    def git?(args)
      words = args.flatten.grep(String)
      words = words.first.split if words.size == 1 && words.first.include?(" ")
      File.basename(words.first.to_s) == "git"
    end

    def untagged_example
      example = RSpec.current_example
      example unless example.nil? || example.metadata[:seam] || example.metadata[:e2e]
    end

    def record
      example = untagged_example
      LOCK.synchronize { COUNTS[example.metadata[:rerun_file_path].to_s.delete_prefix("./")] += 1 } if example
    end

    # Open3, Kernel#system and backticks spawn through Kernel, which Process.spawn does not cover.
    module Spawn
      def spawn(*args, **)
        SeamReport.record if SeamReport.git?(args)
        super
      end

      def system(*args, **)
        SeamReport.record if SeamReport.git?(args)
        super
      end

      def `(command)
        SeamReport.record if SeamReport.git?([command])
        super
      end
    end

    module Popen
      def popen(*args, **, &block)
        SeamReport.record if SeamReport.git?(args)
        super
      end
    end

    # A clone keeps Kernel's instance methods private, which the shared module would make public.
    PRIVATE_SPAWN = Spawn.clone.tap { _1.send(:private, :spawn, :system, :`) }
  end

  Process.singleton_class.prepend(SeamReport::Spawn)
  Kernel.singleton_class.prepend(SeamReport::Spawn)
  Kernel.prepend(SeamReport::PRIVATE_SPAWN)
  IO.singleton_class.prepend(SeamReport::Popen)

  RSpec.configure do |config|
    config.after(:suite) do
      SeamReport::COUNTS.sort.each { |file, count| warn("seam-report: #{file} #{count}") }
    end
  end
end
