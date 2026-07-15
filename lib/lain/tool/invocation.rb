# frozen_string_literal: true

module Lain
  class Tool
    # What a tool actually receives as its second argument, in place of the
    # bare context {Effect::Handler::Live} used to hand it straight through. Built once
    # per dispatch from the {Effect::ToolCall} plus the handler's injected
    # channel, so a tool can attribute its own output (Tools::Bash's
    # live_stdout) to the exact `tool_use_id` that asked for it, without every
    # tool threading that id through by hand.
    #
    # `channel` defaults to a Null Object rather than `nil` so a tool that
    # emits nothing (ReadFile, ListFiles) can push to it unconditionally --
    # no `if channel` guard needed anywhere, matching {Sink::Null}'s role
    # for IO-shaped writers.
    Invocation = Data.define(:tool_use_id, :context, :channel) do
      # @param tool_use_id [String, nil] the `tool_use` block this call answers
      # @param context [Object, nil] whatever the caller threads through (the
      #   Agent, a read-set, nil in a bare spec)
      # @param channel [Lain::Channel] where attributed output goes
      def initialize(tool_use_id: nil, context: nil, channel: Channel::Null.instance)
        super
      end
    end
  end
end
