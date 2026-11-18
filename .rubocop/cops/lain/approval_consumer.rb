# frozen_string_literal: true

module RuboCop
  module Cop
    module Lain
      # The approval arrival queue hands each parked call to exactly ONE `#dequeue`
      # caller: a second consumer does not observe a pending, it TAKES it. Only the
      # surface that can ask a person may drain it; every other surface observes the
      # parked set through `Queue#each`. A desktop notifier once broke this and left
      # a `--no-nvim` session with no approval surface, unseen by any behavioural spec.
      #
      # The syntax tree cannot say WHICH queue a receiver names, so every `#dequeue`
      # site in `lib/` is ruled on by file and receiver in AllowedReceivers. A matcher
      # that guessed the queue would pass while wrong, the failure this guards.
      #
      # @example
      #   loop { notify(parked.dequeue) }          # bad
      #   queue.each { |pending| notify(pending) } # good
      class ApprovalConsumer < Base
        MSG = "`%<receiver>s.dequeue` drains a queue nobody has ruled on. If it drains an approval " \
              "queue it must not exist: observe the parked set through Queue#each, as " \
              "Approval::Parked::QueueSurface and Neovim::ApprovalView do. If it drains some other " \
              "queue, add the receiver under this file in .rubocop.yml's Lain/ApprovalConsumer " \
              "AllowedReceivers, with its reason."
        UNREADABLE = "(unreadable receiver)"

        RESTRICT_ON_SEND = %i[dequeue].freeze

        def on_send(node)
          receiver = receiver_name(node.receiver)
          return if node.receiver.nil? || allowed.include?(receiver)

          add_offense(node.receiver.source_range.join(node.loc.selector), message: format(MSG, receiver:))
        end
        alias on_csend on_send

        private

        # An unnameable receiver is reported, because nobody can rule on it.
        def receiver_name(node)
          case node&.type
          when :ivar, :lvar then node.children.first.to_s
          when :const then node.namespace ? UNREADABLE : node.short_name.to_s
          when :send then node.receiver || node.arguments? ? UNREADABLE : node.method_name.to_s
          else UNREADABLE
          end
        end

        def allowed
          cop_config.fetch("AllowedReceivers", {})
                    .fetch(config.path_relative_to_config(processed_source.file_path), [])
        end
      end
    end
  end
end
