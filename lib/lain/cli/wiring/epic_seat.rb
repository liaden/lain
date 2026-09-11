# frozen_string_literal: true

module Lain
  module CLI
    class Wiring
      # Which epic a chat is seated in, resolved ONCE and read twice: the
      # toolset takes the mount's tools, and an attached editor's lain://status
      # takes its slug. One mount rather than two because {EpicMount} builds the
      # one {Epic::Review} per slug, and a second mount would be a second guard
      # over one journal.
      class EpicSeat
        # @param chronicle [Chronicle] the run's record, which the mount journals into
        # @param options [Hash] the parsed CLI options; `:epic` names the slug
        # @param notify [#question, nil] the desktop notifier a review question is raised through
        # @param root [String] the PROJECT's root, so a chat started in
        #   `services/ingest` mounts the epic its project declares rather than
        #   whichever the working directory happened to name
        # @param replies [#call] a thunk reading the live {HumanReplies}, which
        #   is built after the toolset
        # @option options [String, nil] :epic the epic slug to mount; none mounts no epic
        def initialize(chronicle:, options:, notify:, root:, replies:)
          @chronicle = chronicle
          @options = options
          @notify = notify
          @root = root
          @replies = replies
        end

        # The splat of {ReviewSeams} is what turns the changeset half of
        # `request_review` on. Passing only the notify and bindings keywords left
        # `changesets:` and `surface:` nil, so the implementation stage refused in
        # every real process -- invisible to any spec, because a threaded but
        # never injected seam looks identical to an absent one.
        #
        # @param notice [#call, nil] told why a mount was abandoned; heard by the
        #   FIRST call only, which is the toolset build's
        # @return [EpicMount, EpicMount::NoEpic]
        def mount(notice = nil)
          @mount ||= EpicMount.for(chronicle: @chronicle, options: @options, notice:, notify: @notify, root: @root,
                                   bindings: @replies, **ReviewSeams.for(@replies, root: @root))
        end

        # What lain://status draws. {EpicMount::NoEpic} answers only `tools` --
        # which epic this is has no honest null -- so the CLI's null becomes the
        # frontend's here, once. The fold reads the same root and default state
        # home the mount resolved against, so the buffer folds the epic the mount
        # found.
        #
        # @return [Frontend::Neovim::StatusView::Mounted, Frontend::Neovim::StatusView::Unmounted]
        def status
          return Frontend::Neovim::StatusView::Unmounted if mount.equal?(EpicMount::NoEpic)

          Frontend::Neovim::StatusView::Mounted.new(slug: mount.slug, status: Epic.new(root: @root))
        end
      end
    end
  end
end
