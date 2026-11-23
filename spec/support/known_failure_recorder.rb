# frozen_string_literal: true

require "English"
require "json"
require "rspec/core"
require "rspec/core/formatters/base_formatter"

# Writes 1 worker's outcome as JSON for bin/known-failures to compare against its ledger.
class KnownFailureRecorder < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register self, :start, :message, :example_passed, :example_failed, :dump_summary

  OUTSIDE_EXAMPLES = /An error occurred[^\n]*/

  # @param output [IO] the worker's summary file
  def initialize(output)
    super
    @failed = []
    @passed = []
    @errors = []
  end

  # @param notification [RSpec::Core::Notifications::StartNotification]
  # @return [void]
  def start(notification)
    super
    @expected = notification.count
  end

  # @param notification [RSpec::Core::Notifications::MessageNotification]
  # @return [void]
  def message(notification)
    @errors.concat(notification.message.gsub(/\e\[[\d;]*m/, "").scan(OUTSIDE_EXAMPLES))
  end

  # @param notification [RSpec::Core::Notifications::ExampleNotification]
  # @return [void]
  def example_passed(notification) = @passed << key(notification.example)

  # @param notification [RSpec::Core::Notifications::ExampleNotification]
  # @return [void]
  def example_failed(notification) = @failed << key(notification.example)

  # @param summary [RSpec::Core::Notifications::SummaryNotification]
  # @return [void]
  def dump_summary(summary)
    output.write(JSON.generate(expected: @expected, examples: summary.examples.size,
                               seed: RSpec.configuration.seed, failed: @failed, passed: @passed,
                               errors: outside_errors(summary.errors_outside_of_examples_count)))
    output.flush
  end

  private

  # RSpec's count is the authority: the text only names what it counted.
  def outside_errors(count)
    @errors.first(count) + (["unnamed error"] * [count - @errors.size, 0].max)
  end

  def key(example)
    description = example.full_description.dup.force_encoding(Encoding::UTF_8).scrub
    "#{example.metadata[:rerun_file_path]} #{description.gsub(/0x\h+/, "0x0").gsub(/\s+/, " ").strip}"
  end
end

# Deleted on read because specs spawn their own rspec, which would overwrite this worker's file.
known_failures_out = ENV.delete("LAIN_KNOWN_FAILURES_OUT")
if known_failures_out
  worker = ENV.fetch("TEST_ENV_NUMBER", "").then { _1.empty? ? "1" : _1 }
  summary_path = File.join(known_failures_out, "worker-#{worker}.json")
  RSpec.configure { |config| config.add_formatter(KnownFailureRecorder, summary_path) }
  owner = Process.pid
  exit_was_clean = false
  # RSpec itself exits 0 or 1, so any other status means a handler took over the exit.
  at_exit do
    exit_was_clean = $ERROR_INFO.nil? || ($ERROR_INFO.is_a?(SystemExit) && [0, 1].include?($ERROR_INFO.status))
  end
  # A finalizer runs after every at_exit handler, so a hard crash in any of them leaves no marker.
  # A forked child inherits it, and its clean exit says nothing about the worker's.
  ObjectSpace.define_finalizer(KnownFailureRecorder, proc do
    File.write(summary_path.sub(/\.json\z/, ".exit"), "") if Process.pid == owner && exit_was_clean
  end)
end
