# frozen_string_literal: true

require "json"
require "pathname"

module Lain
  module Grader
    class TestHarness
      module Adapter
        # `cargo test` on stable: libtest prints text lines and cargo prints JSON
        # compiler messages, both on stdout, so one pass over the lines reads each.
        # A path picks its package through `cargo metadata`, because no TOML gem
        # is in the bundle to read the manifests.
        class Cargo
          FLAGS = %w[--no-fail-fast --message-format=json].freeze
          TEST_LINE = /\Atest (?<name>.+?) \.\.\. (?<outcome>ok|FAILED)\s*\z/
          CRATE_ROOTS = %w[lib main].freeze
          CRATE_ROOT_FILES = %w[lib.rs main.rs].freeze
          NOT_MODULES = %w[lib main mod].freeze
          # A test calling what the subject has not defined yet fails to resolve; any other code is a mistake.
          MISSING_ITEM = /\A(?:E0425|E0432|E0433|E0412|E0599) (?<file>\S+): /

          # One path's place in its package: the package, plus the narrowing
          # that path asks for (a module filter, a test target, or neither).
          Selection = Data.define(:package, :filter, :target)

          # @param root [String] the workspace directory cargo runs in
          # @param metadata [#call] returns `cargo metadata --no-deps` JSON; injected
          #   so a spec needs no cargo
          def initialize(root, metadata: -> { read_metadata(root) })
            @root = root.to_s
            @metadata = metadata
          end

          def stdout? = true

          def lockfile = "Cargo.lock"

          def build_dir = "target/"

          # Any missing-item error in the target is accepted when the target is the subject: an inline
          # test sits in the subject file, so a typo in a test-local name reads as the item the subject
          # lacks. A split layout (tests/x.rs importing a missing item) is never awaiting, since its
          # primary span is in the test file.
          def awaiting_subject?(errors, subject:, **)
            errors.any? && errors.all? { |text| MISSING_ITEM.match(text)&.[](:file) == subject }
          end

          # A new file is not compiled until its parent module declares it, so the filtered run would
          # print "running 0 tests"; the harness appends this line, never the test_engineer child.
          # @return [Array<Registration>]
          # @raise [Error] when the parent module file does not exist
          def registration(subject:, root:)
            return [] unless new_module?(subject)

            name = File.basename(subject, ".rs")
            parent = parent_file(File.dirname(subject), root)
            return [] if declared?(File.read(File.join(root, parent)), name)

            [Registration.new(path: parent, line: "pub mod #{name};")]
          end

          def command(paths: [], **)
            return ["cargo", "test", "--workspace", *FLAGS] if paths.empty?

            selections = paths.map { |path| selection_for(path) }
            ["cargo", "test", *package_args(selections), *target_args(selections), *FLAGS, *filter_args(selections)]
          end

          def parse(document, exit_status)
            raise Unparseable, "cargo printed no output to read (exit #{exit_status})" if document.strip.empty?

            lines = document.lines
            tests = lines.filter_map { |line| TEST_LINE.match(line) }
            { passed: named(tests, "ok"), failed: named(tests, "FAILED"), errors: errors_of(lines) }
          end

          private

          def new_module?(subject)
            subject.end_with?(".rs") && !NOT_MODULES.include?(File.basename(subject, ".rs")) &&
              File.dirname(subject).split("/").include?("src")
          end

          def parent_file(dir, root)
            if bin?(dir)
              raise Error,
                    "a src/bin target is not supported by the red step: cargo discovers it with no mod line"
            end

            candidates = parent_candidates(dir)
            candidates.find { |path| File.file?(File.join(root, path)) } ||
              raise(Error, "no parent module file to declare the new file in: expected #{candidates.join(" or ")}")
          end

          def bin?(dir) = File.basename(dir) == "bin" && File.basename(File.dirname(dir)) == "src"

          def parent_candidates(dir)
            return ["#{dir}/mod.rs", "#{dir}.rs"] unless File.basename(dir) == "src"

            CRATE_ROOT_FILES.map { |file| "#{dir}/#{file}" }
          end

          def declared?(source, name) = source.match?(/^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+#{Regexp.escape(name)}\s*;/)

          def named(tests, outcome) = tests.select { |m| m[:outcome] == outcome }.map { |m| m[:name] }

          # The lib build and its test build report the same error, so it is deduplicated.
          def errors_of(lines) = lines.filter_map { |line| compile_error(line) }.uniq

          # A failure-note and the closing "aborting" line carry no code, so the code is what marks a real error.
          def compile_error(line)
            message = line.start_with?("{") && JSON.parse(line)["message"]
            return unless message.is_a?(Hash) && message["level"] == "error" && message["code"]

            file = message["spans"].to_a.find { |span| span["is_primary"] }&.fetch("file_name")
            "#{message.dig("code", "code")} #{file}: #{message["message"]}"
          rescue JSON::ParserError
            nil
          end

          def package_args(selections) = selections.map(&:package).uniq.flat_map { |name| ["-p", name] }

          def target_args(selections) = selections.filter_map(&:target).uniq.flat_map { |name| ["--test", name] }

          # Cargo applies one filter to every selected package, so a selection
          # that runs a whole package leaves nothing to filter.
          def filter_args(selections)
            return [] if selections.any? { |s| s.filter.nil? && s.target.nil? }

            selections.filter_map(&:filter).uniq.first(1)
          end

          def selection_for(path)
            absolute = File.expand_path(path, @root)
            name, dir = owner(absolute)
            raise Error, "#{path} is in no package of the workspace at #{@root}" unless name

            place(name, Pathname.new(absolute).relative_path_from(dir).to_s)
          end

          def place(package, inside)
            case inside.delete_suffix(".rs").split("/")
            in ["tests", target] then Selection.new(package:, filter: nil, target:)
            in ["src", *modules] then module_selection(package, modules)
            else Selection.new(package:, filter: nil, target: nil)
            end
          end

          def module_selection(package, modules)
            modules = modules.take(modules.size - 1) if modules.last == "mod"
            return Selection.new(package:, filter: nil, target: nil) if modules.empty? || crate_root?(modules)

            Selection.new(package:, filter: "#{modules.join("::")}::", target: nil)
          end

          def crate_root?(modules) = modules.one? && CRATE_ROOTS.include?(modules.first)

          # The deepest package directory holding the path, so a nested crate wins over its parent.
          def owner(absolute)
            packages.select { |_, dir| absolute == dir.to_s || absolute.start_with?("#{dir}/") }
                    .max_by { |_, dir| dir.to_s.size }
          end

          def packages
            @packages ||= JSON.parse(@metadata.call).fetch("packages").to_h do |package|
              [package.fetch("name"), Pathname.new(File.dirname(package.fetch("manifest_path")))]
            end
          end

          def read_metadata(root)
            shell = Shell::Out.new("cargo", "metadata", "--no-deps", "--format-version", "1", cwd: root)
            shell.run_command
            raise Error, "cargo metadata failed in #{root}: #{shell.stderr}" unless Shell::Out.ok?(shell)

            shell.stdout
          end
        end
      end
    end
  end
end
