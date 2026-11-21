# frozen_string_literal: true

require "open3"
require "socket"

module Lain
  class Sensitivity
    module Secrets
      # The values that name the person and the box, each paired with a
      # placeholder. Longest value first, so the home path is replaced before
      # the account name inside it.
      #
      # @!attribute [r] pairs
      #   @return [Array<Array(String, String)>] real value, placeholder
      Identity = Data.define(:pairs) do
        # @param env [#[]] where HOME and USER are read
        # @param git [#call] answers a `git config` key with its value or nil
        # @param hostname [String]
        # @return [Identity]
        def self.current(env: ENV, git: method(:git_config), hostname: Socket.gethostname)
          git_keys = { "user.name" => "<git-author>", "user.email" => "<git-email>" }
          known = [[env["HOME"], "/home/<user>"], [env["USER"], "<user>"], [hostname, "<host>"]]
          known += git_keys.map { |key, placeholder| [asked(git, key), placeholder] }
          new(pairs: ordered(known.map { |real, placeholder| [real.to_s.strip, placeholder] }))
        end

        # A box without git has no author to hide, and must still start.
        def self.asked(git, key)
          git.call(key)
        rescue SystemCallError
          nil
        end

        def self.git_config(key)
          out, status = Open3.capture2(Isolation::Worktree::GIT_SPAWN_ENV, "git", "config", "--get", key, err: File::NULL)
          out if status.success?
        end

        def self.ordered(known)
          known.reject { _1.first.empty? }.each_with_index.sort_by { |(real, _), index| [-real.length, index] }
               .map(&:first).uniq(&:first)
        end

        private_class_method :asked, :git_config, :ordered

        def initialize(pairs:)
          super(pairs: Ractor.make_shareable(pairs.map { |pair| pair.map(&:-@) }))
        end

        # @param text [String]
        # @return [String] real values as placeholders, whole words only
        def alias(text) = swap(text, pairs.to_h, boundary: true)

        # @param text [String]
        # @return [String] placeholders as the real values
        def restore(text) = swap(text, pairs.to_h { |real, placeholder| [placeholder, real] }, boundary: false)

        private

        # One pass, so a placeholder a value spells part of is never rescanned.
        def swap(text, table, boundary:)
          return text if table.empty?

          names = table.keys.sort_by { -_1.length }.map { Regexp.escape(_1) }.join("|")
          pattern = boundary ? /(?<!\w)(?:#{names})(?!\w)/ : /#{names}/
          text.gsub(pattern, table)
        end
      end
    end
  end
end
