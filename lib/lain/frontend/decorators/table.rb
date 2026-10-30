# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # Its own file so these classes resolve on first use; a constant in decorators.rb fails a reverse-order boot.
      module Table
        BY_TYPE = {
          Telemetry::ToolOutput => ToolOutput,
          Telemetry::ProviderRetry => ProviderRetry,
          ::Lain::Agent::SnapshotSlot::SnapshotDegraded => SnapshotDegraded,
          ::Lain::Agent::SnapshotSlot::SnapshotNarrowed => SnapshotNarrowed,
          TTY::PromptUnclosed => PromptUnclosed,
          Telemetry::FilesWritten => FilesWritten,
          Telemetry::ToolCalled => ToolCalled,
          Telemetry::AssistantText => AssistantText,
          Telemetry::JudgeRuled => JudgeRuled,
          Telemetry::AskSettled => AskSettled,
          Telemetry::EditApplied => EditDiff,
          ::Lain::Provider::Residency::Waiting => ResidencyWaiting
        }.freeze
      end
    end
  end
end
