# frozen_string_literal: true

module Lain
  module CLI
    # `lain trust [PATH]`: shows a project's `.lain/*.rb` and, on a yes, records
    # {Project::Trust}'s mark for those exact bytes.
    #
    # What is shown is what is granted: the listing and the mark both come from
    # one {Project::Trust}, which read the bytes once. `yes:` is the headless
    # door, for a CI job whose operator has already read the files.
    #
    # A decline is a refusal, so `lain trust && lain chat` stops there.
    class Trust
      # Anything but a y or yes, end of input included, records nothing.
      AFFIRMATIVE = /\Ay(es)?\z/i

      NOTHING = "%<root>s has no .lain/*.rb, so there is nothing to trust"
      ALREADY = "already trusted: %<files>s"
      QUESTION = "Trust covers these %<count>d file(s) only, not what they require or load.\n" \
                 "Run them as Ruby whenever lain loads this project? [y/N] "
      USER_QUESTION = "Trust covers this file only, not what it requires or loads.\n" \
                      "Run it as Ruby in every project lain loads? [y/N] "
      GRANTED = "trusted: %<files>s"
      NO_USER_CONFIG = "the user config does not exist (%<path>s), so there is nothing to trust"
      DECLINED = "not trusted; nothing recorded"

      # The human said no, or nothing.
      class Declined < Error; end

      # @param root [String, nil] the project root whose `.lain/*.rb` is judged; unused with `user:`
      # @param input [#gets] where the human's answer is read
      # @param output [#write] where the files and the question are shown
      # @param paths [Paths] supplies the state home the mark is kept under
      # @param yes [Boolean] grant without asking
      # @param user [Boolean] judge the user's config.rb instead of the project's
      def initialize(input:, output:, root: nil, paths: Paths.new, yes: false, user: false)
        @root = root
        @input = input
        @output = output
        @yes = yes
        @user = user
        @empty = user ? format(NO_USER_CONFIG, path: paths.user_config) : format(NOTHING, root:)
        @trust = if user
                   Project::Trust.for_user(paths:)
                 else
                   Project::Trust.for(project_dir: ProjectDir.new(root:, paths:), paths:)
                 end
      end

      # @return [String] the outcome, for the caller to print
      def call
        return legible(@empty) if @trust.files.empty?
        return legible(format(ALREADY, files: listed)) if @trust.trusted?

        show
        raise Declined, DECLINED unless confirmed?

        @trust.grant!
        legible(format(GRANTED, files: listed))
      end

      private

      def listed = @trust.files.join(", ")

      def show
        @trust.sources.each { |path, bytes| @output.write(legible("==> #{path} <==\n#{bytes}\n")) }
      end

      def question = @user ? USER_QUESTION : format(QUESTION, count: @trust.files.length)

      def confirmed?
        return true if @yes

        @output.write(question)
        AFFIRMATIVE.match?(@input.gets.to_s.strip)
      end

      # A name or a body must not be able to redraw the terminal and hide a line
      # from the human consenting to it.
      def legible(text) = Project::Trust.legible(text)
    end
  end
end
