# frozen_string_literal: true

require "fileutils"
require "json"

# Counts every git command lib/ spawns by shape and the innermost lib/ frames that asked for it, so a repeated
# read can be pinned on a call site. Inert unless the spawns lens set SUITE_PROFILE_LENS.
if ENV["SUITE_PROFILE_LENS"] == "spawns"
  module SuiteProfile
    SPAWN_TALLY = Hash.new(0)

    module GitCallers
      module_function

      def shape(words)
        words.drop_while { |word| File.basename(word) != "git" }.drop(1)
             .reject { |word| word.start_with?("/") }
             .map { |word| word.gsub(/[0-9a-f]{40}/, "SHA") }.first(5).join(" ")
      end

      def site(frames)
        frames.map(&:to_s).grep(%r{/lib/lain/}).reject { |frame| frame.include?("/shell/") }.first(3)
              .map { |frame| frame.sub(%r{.*/lib/lain/}, "").sub(/:in .*/, "") }.join(" < ")
      end

      def spawn(*args, **)
        words = args.flatten.grep(String)
        SPAWN_TALLY[[GitCallers.shape(words), GitCallers.site(caller_locations)]] += 1 if words.any? do |word|
          File.basename(word) == "git"
        end
        super
      end
    end
  end

  Process.singleton_class.prepend(SuiteProfile::GitCallers)
  spawn_dir = File.join(ENV.fetch("SUITE_PROFILE_DIR"), "spawns")
  FileUtils.mkdir_p(spawn_dir)
  at_exit do
    rows = SuiteProfile::SPAWN_TALLY.map { |(shape, site), n| { shape:, site:, n: }.to_json }
    File.write(File.join(spawn_dir, "w#{ENV.fetch("TEST_ENV_NUMBER", "")}x#{Process.pid}.ndjson"), rows.join("\n"))
  end
end
