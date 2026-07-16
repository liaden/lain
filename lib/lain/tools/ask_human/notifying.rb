# frozen_string_literal: true

module Lain
  module Tools
    class AskHuman
      # AskHuman that announces each question to an injected callable as it is
      # asked. The frontend's replier parks on whatever the callable feeds
      # (the exe hands an Async::Queue's `enqueue`); the announcement happens
      # inside #ask -- BEFORE perform's await -- so a listener wired after the
      # toolset can still never miss a question. Outbound-only: replying stays
      # AskHuman#reply's business, so the frontend seam is unchanged.
      class Notifying < AskHuman
        def initialize(notify:, **)
          super(**)
          @notify = notify
        end

        def ask(question)
          promise = super
          @notify.call(question)
          promise
        end
      end
    end
  end
end
