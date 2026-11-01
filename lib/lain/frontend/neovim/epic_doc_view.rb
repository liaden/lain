# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # A written epic document as the editor's read-only `lain://epic/<slug>/<path>`
      # buffer. The event only names the document; the bytes are read back here
      # through the chat's homes, because the journal record carries a digest and
      # never the text. An issue is shown as its {Lain::Epic::IssueView}, the
      # graph's links included, rather than as the authored half on disk.
      #
      # This runs on the drain thread, so a document that vanished or cannot be
      # read costs the human that one refresh and never the thread. That one
      # thread is also why the set of shown issues needs no lock.
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
          @shown = Hash.new { |shown, slug| shown[slug] = Set.new }
        end

        # An issue's view renders its Links from epic.md, so an epic write also
        # re-renders every issue this view has shown for that epic. Each document
        # is read on its own: one that vanished costs only its own refresh.
        #
        # @param event [Object] one Channel event
        # @return [Array<Array(String, Array<String>)>] each buffer name and its
        #   lines, empty for an event that wrote no document
        def update(event)
          return [] unless event.is_a?(Lain::Epic::DocWritten)

          slug = event.epic_slug
          [document(slug, event.kind, event.path), *reshown(slug, event.kind)].compact
        end

        private

        def document(slug, kind, path)
          lines = read(@homes.for(slug), kind, path).lines(chomp: true)
          @shown[slug] << path if kind == "issue"
          ["#{NAME_PREFIX}/#{slug}/#{path}", lines]
        rescue Lain::Error, SystemCallError
          nil
        end

        def reshown(slug, kind)
          kind == "epic" ? @shown[slug].map { |path| document(slug, "issue", path) } : []
        end

        def read(home, kind, path)
          id = File.basename(path, ".md")
          case kind
          when "research" then home.research.read
          when "epic" then home.epic.read
          when "issue" then Lain::Epic::IssueView.read(home, id).to_markdown
          else home.plan(id).read
          end
        end
      end
    end
  end
end
