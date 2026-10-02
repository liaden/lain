# frozen_string_literal: true

# Spec files at or above 5 seconds (THRESHOLD_SECONDS) in tmp/parallel_runtime_rspec.log, measured
# 2026-10-02: 62 files, 76% of file-seconds. A bare local `rspec` skips them; `LAIN_SLOW=1`,
# `rake pspec`, the commit hook and CI run them. Regenerate after a speedup:
#
#     awk -F: '$2 >= 5 && /_spec.rb/ {print $1}' tmp/parallel_runtime_rspec.log | sort
module SlowFiles
  THRESHOLD_SECONDS = 5

  PATHS = %w[
    spec/lain/cli/command/review_spec.rb
    spec/lain/cli/command/undo_spec.rb
    spec/lain/cli/epic_driver/factory_spec.rb
    spec/lain/cli/epic_driver/issue_actor_spec.rb
    spec/lain/cli/epic_driver/issue_tests_spec.rb
    spec/lain/cli/human_replies_spec.rb
    spec/lain/cli/repl_spec.rb
    spec/lain/cli_spec.rb
    spec/lain/cli/up_spec.rb
    spec/lain/cli/wiring_spec.rb
    spec/lain/exec/docker_spec.rb
    spec/lain/exec/local_spec.rb
    spec/lain/forge/local_landing_spec.rb
    spec/lain/forge/promotion_spec.rb
    spec/lain/frontend/neovim/annotate_spec.rb
    spec/lain/frontend/neovim/approval_view_spec.rb
    spec/lain/frontend/neovim/buffers_spec.rb
    spec/lain/frontend/neovim/changeset_diff_spec.rb
    spec/lain/frontend/neovim/layout_spec.rb
    spec/lain/frontend/neovim/runtime/46_sidebar_spec.rb
    spec/lain/frontend/neovim/runtime/47_diff_spec.rb
    spec/lain/frontend/neovim/runtime/51_thread_spec.rb
    spec/lain/frontend/neovim/runtime/52_note_compose_spec.rb
    spec/lain/frontend/neovim/runtime/65_review_spec.rb
    spec/lain/frontend/stdin_pump_spec.rb
    spec/lain/frontend/tty_spec.rb
    spec/lain/grader/test_harness_spec.rb
    spec/lain/isolation/gc_spec.rb
    spec/lain/isolation/landing_queue_spec.rb
    spec/lain/isolation/self_sync_spec.rb
    spec/lain/isolation/worker_handoff_spec.rb
    spec/lain/isolation/working_branch_spec.rb
    spec/lain/isolation/worktree_handback_spec.rb
    spec/lain/project/root_defaults_spec.rb
    spec/lain/provider/anthropic_streaming_spec.rb
    spec/lain/provider/http/stall_protection_spec.rb
    spec/lain/provider/ollama_streaming_spec.rb
    spec/lain/review/changeset_spec.rb
    spec/lain/review/deletability_spec.rb
    spec/lain/review/source/github_pr_spec.rb
    spec/lain/review/source/local_branch_spec.rb
    spec/lain/seams/child_worktree_approval_spec.rb
    spec/lain/seams/crash_mid_tool_spec.rb
    spec/lain/seams/critique_over_held_review_spec.rb
    spec/lain/seams/hangup_spec.rb
    spec/lain/seams/input_pane_socket_spec.rb
    spec/lain/seams/one_shot_handback_spec.rb
    spec/lain/seams/plain_chat_prompt_guards_spec.rb
    spec/lain/seams/qa_sandbox_pane_resolution_spec.rb
    spec/lain/seams/recorded_run_spec.rb
    spec/lain/seams/stop_ask_spec.rb
    spec/lain/seams/survey_subdirectory_spec.rb
    spec/lain/seams/terminal_gone_spec.rb
    spec/lain/seams/typed_during_ask_spec.rb
    spec/lain/shell/pipeline_spec.rb
    spec/lain/status_feed_spec.rb
    spec/lain/suite_load_spec.rb
    spec/lain/test_layout/guard_spec.rb
    spec/lain/tools/bash_spec.rb
    spec/lain/workspace/snapshot/scope/shadow_git_spec.rb
    spec/repo_as_fixture_spec.rb
    spec/support_headless_editor_spec.rb
  ].freeze

  def self.enabled? = ENV["LAIN_SLOW"] == "1"

  def self.missing(root:, paths: PATHS) = paths.reject { |path| File.file?(File.join(root, path)) }

  def self.verify!(root:, paths: PATHS)
    gone = missing(root:, paths:)
    raise "SlowFiles::PATHS names files that no longer exist: #{gone.join(", ")}" unless gone.empty?
  end

  # parallel_rspec names every file it hands a worker, so this rule alone keeps pspec's count.
  def self.named(argv, root:)
    argv.reject { |arg| arg.start_with?("-") }
        .map { |arg| File.expand_path(arg, root) }
        .select { |path| File.file?(path) }
  end

  def self.skipped(root:, argv: ARGV)
    asked = named(argv, root:)
    PATHS.reject { |path| asked.include?(File.join(root, path)) }
  end
end
