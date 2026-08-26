# frozen_string_literal: true

module Lain
  module CLI
    # What an `implementation` review needs from the process around it: where
    # its diff comes from, where it is drawn for a human, and the rendering a
    # gesture's row number resolves through. One object because the three are
    # one decision -- they arrive together, and two come off the same editor.
    #
    # == Why two of them are thunks and one is not
    #
    # The repository is a fact about the process before anything starts. The
    # surface and the view belong to a {Frontend::Neovim} that {Repl#run} builds
    # STRICTLY AFTER the toolset, so a value read here would be the editor that
    # does not exist yet -- hence a thunk, read at call time by
    # {Tools::RequestReview}.
    #
    # nil is what an unattached editor answers, and it stays nil: coalescing to
    # {Review::Surface::Null} is {Tools::RequestReview::Implementation::Seams}'
    # job, which is the one place that decision is made.
    module ReviewSeams
      # No editor to draw a changeset in, and so no rail to answer its writes
      # on. {HumanReplies::NoEditor}'s fourth sibling, for the same reason the
      # third is one: a headless chat, a `--nvim` chat before its frontend
      # exists, and a chat whose editor died are all this, and none of them is
      # "no review is open". It lives here because it is the null of exactly
      # the duck this module reads. Both readers answer nil rather than a null
      # surface, per the class doc.
      module Unattached
        def self.review_surface = nil
        def self.review_view = nil
        def self.bind_changeset_review(_review) = nil
      end

      module_function

      # @param editor [#call] a thunk reading whatever holds the run's review
      #   editor -- {HumanReplies} in production, which answers `review_surface`
      #   and `review_view` off the frontend {Repl#run} bound into it
      # @param root [String] the repository an `implementation` diff is read from
      # @return [Hash] the seams, as {EpicMount.for}'s keywords
      def for(editor, root: Dir.pwd)
        { changesets: Lain::Review::Source::Repository.new(repo_root: root),
          surface: -> { editor.call&.review_surface }, view: -> { editor.call&.review_view } }
      end
    end
  end
end
