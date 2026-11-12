# frozen_string_literal: true

module Lain
  module Chores
    # The question a headless chat is started with for one chore.
    module Brief
      RESEARCH = "research"

      CHORE = <<~TEXT
        Do this one chore in this checkout, then commit it with a short message that says what changed:

        %<text>s

        Change only what the chore asks for, and run the specs that cover what you touched before you
        commit. Nobody will answer a question, so decide for yourself. Stop once the commit is made.
      TEXT

      REPORT = <<~TEXT
        /research %<text>s

        Commit the report in this checkout once it is written, so the drain can land it.
      TEXT

      # @param item [Item] the claimed chore
      # @return [String] the chat's --prompt
      def self.for(item)
        format(item.tag == RESEARCH ? REPORT : CHORE, text: item.text)
      end
    end
  end
end
