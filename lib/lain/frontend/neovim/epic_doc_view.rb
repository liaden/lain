# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # A written epic document as the editor's read-only `lain://epic/<slug>/<path>`
      # buffer. The event only names the document; the bytes are read back here
      # through the chat's homes, because the journal record carries a digest and
      # never the text.
      #
      # This runs on the drain thread, so a document that vanished or cannot be
      # read costs the human that one refresh and never the thread.
      class EpicDocView
        # What a frontend wired with no epic homes reads through: it refuses in
        # the one way {#update} already answers.
        module NoHomes
          def self.for(_slug) = raise(Lain::Error, "no epic homes are wired")
        end

        NAME_PREFIX = "lain://epic"

        # @param homes [#for] answers the journaled home of an epic slug
        def initialize(homes: NoHomes)
          @homes = homes
        end

        # @param event [Object] one Channel event
        # @return [Array(String, Array<String>), nil] the buffer name and its
        #   lines, nil for an event that wrote no document or whose file is gone
        def update(event)
          return unless event.is_a?(Lain::Epic::DocWritten)

          ["#{NAME_PREFIX}/#{event.epic_slug}/#{event.path}", read(event).lines(chomp: true)]
        rescue Lain::Error, SystemCallError
          nil
        end

        private

        def read(event)
          home = @homes.for(event.epic_slug)
          id = File.basename(event.path, ".md")
          case event.kind
          when "research" then home.research.read
          when "epic" then home.epic.read
          when "issue" then home.issue(id).read
          else home.plan(id).read
          end
        end
      end
    end
  end
end
