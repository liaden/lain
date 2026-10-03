# frozen_string_literal: true

# Spec files at or above 5 seconds (THRESHOLD_SECONDS) in tmp/parallel_runtime_rspec.log, measured
# 2026-10-02 after the speed plan, at 16 workers: 29 files, 50% of file-seconds. A bare local
# `rspec` skips them; `LAIN_SLOW=1`, `rake pspec`, the commit hook and CI run them. Regenerate
# after a speedup:
#
#     awk -F: '$2 >= 5 && /_spec.rb/ {print $1}' tmp/parallel_runtime_rspec.log | sort
module SlowFiles
  THRESHOLD_SECONDS = 5

  PATHS = %w[
    spec/e2e/fork_resume_spec.rb
    spec/e2e/upstream_faults_spec.rb
    spec/e2e/wire_contract_spec.rb
    spec/lain/cli/command/ruby_spec.rb
    spec/lain/cli/epic_driver/factory_spec.rb
    spec/lain/cli/human_replies_spec.rb
    spec/lain/cli/repl_spec.rb
    spec/lain/cli/up_spec.rb
    spec/lain/exec/docker_spec.rb
    spec/lain/frontend/line_editor_spec.rb
    spec/lain/frontend/neovim/diff_mode_spec.rb
    spec/lain/frontend/neovim/runtime/51_thread_spec.rb
    spec/lain/frontend/neovim/runtime/65_review_spec.rb
    spec/lain/frontend/stdin_pump_spec.rb
    spec/lain/frontend/tty_spec.rb
    spec/lain/isolation/worker_handoff_spec.rb
    spec/lain/isolation/worktree_handback_spec.rb
    spec/lain/project_dir_spec.rb
    spec/lain/provider/http/stall_protection_spec.rb
    spec/lain/review/deletability_spec.rb
    spec/lain/review/source/github_pr_spec.rb
    spec/lain/seams/input_pane_socket_spec.rb
    spec/lain/seams/plain_chat_prompt_guards_spec.rb
    spec/lain/seams/qa_sandbox_pane_resolution_spec.rb
    spec/lain/seams/stop_ask_spec.rb
    spec/lain/seams/terminal_gone_spec.rb
    spec/lain/seams/typed_during_ask_spec.rb
    spec/lain/suite_load_spec.rb
    spec/lain/tools/bash_spec.rb
    spec/repo_as_fixture_spec.rb
  ].freeze

  def self.enabled? = ENV["LAIN_SLOW"] == "1"

  def self.missing(root:, paths: PATHS) = paths.reject { |path| File.file?(File.join(root, path)) }

  def self.verify!(root:, paths: PATHS)
    gone = missing(root:, paths:)
    raise "SlowFiles::PATHS names files that no longer exist: #{gone.join(", ")}" unless gone.empty?
  end

  # RSpec options whose next argument is a value, not a path; `--tag ~seam` would otherwise expand as a home directory.
  VALUE_OPTIONS = %w[
    -r --require -I -e --example -E --example-matches -t --tag -P --pattern --exclude-pattern -o --out -f --format
    -O --options --default-path -s --seed --order
    --failure-exit-code --error-exit-code --profile -p --drb-port --deprecation-out
  ].to_set.freeze

  # parallel_rspec names every file it hands a worker, so this rule alone keeps pspec's count.
  def self.named(argv, root:)
    candidates(argv).filter_map { |arg| expand(arg, root) }.select { |path| File.file?(path) }
  end

  def self.candidates(argv)
    argv.each_with_index
        .reject { |arg, index| arg.start_with?("-") || (index.positive? && VALUE_OPTIONS.include?(argv[index - 1])) }
        .map(&:first)
  end

  def self.expand(arg, root)
    File.expand_path(arg, root)
  rescue ArgumentError
    nil
  end

  private_class_method :candidates, :expand

  def self.skipped(root:, argv: ARGV)
    asked = named(argv, root:)
    PATHS.reject { |path| asked.include?(File.join(root, path)) }
  end
end
