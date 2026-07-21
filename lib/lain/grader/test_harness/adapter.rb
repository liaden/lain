# frozen_string_literal: true

require "json"

module Lain
  module Grader
    class TestHarness
      # How a test framework is DRIVEN and READ, as a duck two methods wide:
      #
      #   command(out_path:) -> argv     # writes the machine-readable result to a FILE
      #   parse(document, exit_status)   # -> {passed:, failed:, errors:} name lists
      #
      # Writing to a file (rspec: `--format json --out`) is the load-bearing
      # choice: a child project's own stdout warnings and deprecations therefore
      # never interleave with the result TestHarness parses. `Rspec` is the first
      # real runtime; `Command` proves the duck with an explicit argv and regexes,
      # needing no second language installed.
      module Adapter
        # Detection could not single out a framework: nothing matched, more than
        # one did, or the one that matched has no adapter written yet. It names
        # every probe it tried so the failure is diagnosable, and it never
        # guesses -- an explicit `adapter:` is the way past it.
        class Undetectable < Lain::Error; end

        # The framework's result file was unreadable as the format the adapter
        # expects (an empty file from a runner that died before writing, a
        # truncated document). Loud, because a silently-zeroed grade would read
        # as "everything failed" and hide the real breakage.
        class Unparseable < Lain::Error; end

        # One framework's fingerprint: what it is, what its presence looks like on
        # disk, the predicate that checks it, and how to build its adapter (nil
        # when the framework is recognized but its adapter is still a follow-up).
        Probe = Data.define(:framework, :looks_for, :match, :build)

        def self.rspec_root?(root)
          File.exist?(File.join(root, "Gemfile")) && Dir.exist?(File.join(root, "spec"))
        end

        def self.jest_root?(root)
          package = File.join(root, "package.json")
          File.exist?(package) && File.read(package).match?(/"jest"/)
        end

        def self.pytest_root?(root)
          File.exist?(File.join(root, "pyproject.toml")) || File.exist?(File.join(root, "pytest.ini"))
        end

        # rspec is the only implemented runtime; jest and pytest are recognized so
        # a match on them fails LOUD ("detected but unimplemented") rather than
        # silently pretending an unwritten adapter exists.
        PROBES = [
          Probe.new(framework: "rspec", looks_for: "a Gemfile beside a spec/ directory",
                    match: method(:rspec_root?), build: ->(_root) { Rspec.new }),
          Probe.new(framework: "jest", looks_for: %(a package.json declaring "jest"),
                    match: method(:jest_root?), build: nil),
          Probe.new(framework: "pytest", looks_for: "a pyproject.toml or a pytest.ini",
                    match: method(:pytest_root?), build: nil)
        ].freeze

        # @param root [String] the project directory to fingerprint
        # @return [#command,#parse] the adapter for the single framework detected
        # @raise [Undetectable] on no match, ambiguity, or an unimplemented match
        def self.detect(root)
          matched = PROBES.select { |probe| probe.match.call(root) }
          choose(root, matched)
        end

        def self.choose(root, matched)
          raise Undetectable, "no test framework detected in #{root} -- probed for #{probed}" if matched.empty?

          if matched.size > 1
            names = matched.map(&:framework).join(", ")
            raise Undetectable, "ambiguous test framework in #{root}: #{names} all matched"
          end

          probe = matched.first
          if probe.build.nil?
            raise Undetectable, "detected #{probe.framework} in #{root}, but its adapter is not implemented yet"
          end

          probe.build.call(root)
        end

        def self.probed
          PROBES.map { |probe| "#{probe.framework} (#{probe.looks_for})" }.join("; ")
        end

        # RSpec via its JSON formatter written to a file. The counts come from the
        # document's own `status` fields; a failing example is named by its
        # `full_description` so `#why` reads.
        class Rspec
          def command(out_path:)
            ["rspec", "--format", "json", "--out", out_path]
          end

          def parse(document, exit_status)
            report = JSON.parse(document)
            examples = report.fetch("examples", [])
            { passed: names(examples, "passed"),
              failed: names(examples, "failed"),
              errors: errors_of(report) }
          rescue JSON::ParserError => e
            raise Unparseable, "rspec produced no parseable JSON result (exit #{exit_status}): #{e.message}"
          end

          private

          def names(examples, status)
            examples.select { |example| example["status"] == status }
                    .map { |example| example.fetch("full_description") }
          end

          # A load crash (SyntaxError, missing require) is counted in the summary
          # AND described in the document's `messages` -- rspec routes it through
          # the formatter, so it lands in the FILE, not on stderr. Surface those
          # messages as the error names (the real diagnostic); fall back to a
          # generic label only if the count is set but the text is absent.
          def errors_of(report)
            count = report.dig("summary", "errors_outside_of_examples_count").to_i
            return [] if count.zero?

            messages = report.fetch("messages", [])
            messages.empty? ? Array.new(count) { |i| "error outside of examples ##{i + 1}" } : messages
          end
        end

        # A runtime-free adapter: an explicit argv built around the out-file path,
        # plus regexes that name the passed/failed/errored cases in that file. Any
        # tool that can be told to write its results to a path fits the duck here,
        # which is how the seam is proven without a second language runtime. A
        # regex's first capture group names the case; absent a group, the whole
        # match names it.
        class Command
          MATCHES_NOTHING = /(?!)/

          def initialize(out_argv:, passed:, failed:, errors: MATCHES_NOTHING)
            @out_argv = out_argv
            @passed = passed
            @failed = failed
            @errors = errors
          end

          def command(out_path:) = @out_argv.call(out_path)

          def parse(document, _exit_status)
            { passed: scan(document, @passed),
              failed: scan(document, @failed),
              errors: scan(document, @errors) }
          end

          private

          def scan(document, pattern)
            document.lines.filter_map { |line| named(line, pattern) }
          end

          def named(line, pattern)
            match = pattern.match(line)
            match && (match[1] || match[0]).strip
          end
        end
      end
    end
  end
end
