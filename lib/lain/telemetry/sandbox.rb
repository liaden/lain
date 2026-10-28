# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `created_sealed` and `kept_tmpdir` are absent from the record written before the call.
      class Sandbox < Declarative::Carrier
        attribute :tool_use_id
        attribute :profile
        attribute :trace
        attribute :refused
        attribute :created_sealed, default: -> { [] }
        attribute :kept_tmpdir
        attribute :granted, default: -> { [] }
      end
    end

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
    #
    # `granted` names the programs a parsed command was handed as grants that the
    # profile lets run, on the record written before the call.
    Sandbox = Data.define(:tool_use_id, :profile, :trace, :refused, :created_sealed, :kept_tmpdir, :granted) do
      include Journalable

      def initialize(tool_use_id:, profile:, trace:, refused:, created_sealed: [], kept_tmpdir: nil, granted: [])
        super(**Carriers::Sandbox.settle!(tool_use_id:, profile:, trace:, refused:, created_sealed:, kept_tmpdir:,
                                          granted:))
      end
    end
  end
end
