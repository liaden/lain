# frozen_string_literal: true

module Lain
  module Isolation
    module MergeCoordinator
      # Names the parts of a landed change that run or steer something later:
      # CI config, hooks, agent config, build inputs and symlinks. It only
      # names them; the landing has already been judged by the verifier.
      class LandedFlags
        # What a batch asks when nothing is wired to look.
        NONE = Object.new.tap { |none| none.define_singleton_method(:for) { |_report| [] } }.freeze

        CI_CONFIG = %r{\A(?:\.github/|\.gitlab-ci\.yml\z|\.pre-commit-config\.yaml\z)}
        HOOKS = %r{\A\.(?:husky|githooks)/}
        AGENT_CONFIG = %r{\A(?:\.lain/|\.envrc\z|CLAUDE\.md\z)}
        BUILD_INPUT = Shell::Executable::RunFiles::BUILD_FILES.values.flatten.uniq.freeze
        SYMLINK_MODE = "120000"

        # @param git [Checkout] the repository the landed commits are in
        def initialize(git:)
          @git = git
        end

        # @param report [WorkerHandoff::Report]
        # @return [Array<String>] "<class> <path>", sorted; empty for a report that landed onto no base
        def for(report)
          return [] if report.base.nil? || report.sha.nil?

          paths = changed(report)
          hooks = hooks_path
          named = paths.filter_map { |path| (label = kind(path, hooks)) && "#{label} #{path}" }
          (named + symlinks(report.sha, paths).map { |path| "symlink #{path}" }).sort
        end

        private

        def changed(report) = @git.run("diff", "--name-only", "-z", report.base, report.sha).stdout.split("\0")

        def kind(path, hooks)
          case path
          when CI_CONFIG then "ci_config"
          when HOOKS then "hooks"
          when AGENT_CONFIG then "agent_config"
          else
            return "hooks" if under?(path, hooks)

            "build_input" if BUILD_INPUT.include?(File.basename(path))
          end
        end

        def hooks_path
          configured = @git.run("config", "--get", "core.hooksPath")
          Shell::Out.ok?(configured) ? configured.stdout.strip.delete_prefix("./").chomp("/") : ""
        end

        def under?(path, directory) = !directory.empty? && path.start_with?("#{directory}/")

        def symlinks(sha, paths)
          return [] if paths.empty?

          @git.run("ls-tree", "-z", sha, "--", *paths).stdout.split("\0").filter_map do |entry|
            meta, path = entry.split("\t", 2)
            path if meta.start_with?("#{SYMLINK_MODE} ")
          end
        end
      end
    end
  end
end
