# frozen_string_literal: true

module Lain
  module Telemetry
    # The profile a bash call ran under: `profile` is its name, `trace` whether
    # its execs were traced, and `refused` the resolved programs it was not
    # started for because the profile may not run them, the granted path a
    # mask would have hidden, or the TMPDIR a workspace call could not make
    # its own dir beneath. A call with a refusal ran nothing.
    #
    # `created_sealed` names the sealed paths a workspace call found absent and
    # left existing, and `kept_tmpdir` the call's own TMPDIR when it could not be
    # removed. The record written before the call holds neither; a second one for
    # the same call, written after it, holds them, and only when there is either.
    Sandbox = Data.define(:tool_use_id, :profile, :trace, :refused, :created_sealed, :kept_tmpdir) do
      include Journalable

      def initialize(tool_use_id:, profile:, trace:, refused:, created_sealed: [], kept_tmpdir: nil)
        super(tool_use_id: tool_use_id.dup.freeze, profile:, trace:, refused: Ractor.make_shareable(refused.dup),
              created_sealed: Ractor.make_shareable(created_sealed.dup), kept_tmpdir: kept_tmpdir&.dup&.freeze)
      end
    end
  end
end
