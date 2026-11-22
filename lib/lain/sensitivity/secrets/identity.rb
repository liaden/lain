# frozen_string_literal: true

require "open3"
require "socket"

module Lain
  class Sensitivity
    module Secrets
      Identity = Data.define(:pairs, :aliasing, :restoring) do
        # @param env [#[]] where HOME and USER are read
        # @param git [#call] answers a `git config` key with its value or nil
        # @param hostname [String]
        # @return [Identity]
        def self.current(env: ENV, git: method(:git_config), hostname: Socket.gethostname)
          git_keys = { "user.name" => "<lain:git-author>", "user.email" => "<lain:git-email>" }
          known = [[env["HOME"], "/home/<lain:user>"], [env["USER"], "<lain:user>"], [hostname, "<lain:host>"]]
          known += git_keys.map { |key, placeholder| [asked(git, key), placeholder] }
          new(pairs: ordered(known.map { |real, placeholder| [real.to_s.strip, placeholder] }))
        end

        # The process's own identity, read on first use and kept: the home,
        # account, host and git author do not change under a running process,
        # and every request body and tool call asks for it.
        #
        # @return [Identity]
        def self.session = Identity::SESSION.compute_if_absent(:current) { current }

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

        # Both patterns are compiled here, once: building one per string cost
        # 13 ms on a 228 KB request body.
        def initialize(pairs:, **)
          shared = Ractor.make_shareable(pairs.map { |pair| pair.map(&:-@) })
          super(pairs: shared, aliasing: Identity::Swap.over(shared.to_h, boundary: true),
                restoring: Identity::Swap.over(shared.to_h(&:reverse), boundary: false))
        end

        # @param text [String]
        # @return [String] real values as placeholders, whole words only
        def alias(text) = aliasing.call(text)

        # @param text [String]
        # @return [String] placeholders as the real values
        def restore(text) = restoring.call(text)
      end

      # The values that name the person and the box, each paired with a
      # placeholder. Longest value first, so the home path is replaced before
      # the account name inside it. The placeholders are namespaced because
      # ordinary text holds bare `<host>` and `<user>`, which a restore would
      # otherwise turn into the box's values.
      #
      # Reopened to hold the compiled swap and the session memo; YARD keeps
      # only this docstring.
      #
      # @!attribute [r] pairs
      #   @return [Array<Array(String, String)>] real value, placeholder
      # @!attribute [r] aliasing
      #   @return [Identity::Swap] real values to placeholders, whole words only
      # @!attribute [r] restoring
      #   @return [Identity::Swap] placeholders to real values
      class Identity
        SESSION = Concurrent::Map.new

        # A word boundary, or a literal escape sequence such as `\n` written
        # out inside a string leaf holding JSON or source text, whose letter
        # would otherwise read as part of the word that follows.
        BEFORE = '(?:(?<!\w)|(?<=\\\\[ntrbf"\\\\/]))'

        # One table and its pattern, applied in one pass, so a placeholder a
        # value spells part of is never rescanned.
        #
        # @!attribute [r] pattern
        #   @return [Regexp, nil] nil when there is nothing to swap
        # @!attribute [r] table
        #   @return [Hash{String=>String}]
        Swap = Data.define(:pattern, :table) do
          # @param table [Hash{String=>String}]
          # @param boundary [Boolean] whether a match must be a whole word
          # @return [Swap]
          def self.over(table, boundary:)
            return new(pattern: nil, table: Ractor.make_shareable(table)) if table.empty?

            names = table.keys.sort_by { -_1.length }.map { Regexp.escape(_1) }.join("|")
            pattern = boundary ? /#{Identity::BEFORE}(?:#{names})(?!\w)/ : /#{names}/
            new(pattern: Ractor.make_shareable(pattern), table: Ractor.make_shareable(table))
          end

          # Most strings hold none of the values, and a substring search per
          # value rejects them about 3 times faster than the pattern or a bare
          # alternation of the values does.
          #
          # @param text [String]
          # @return [String]
          def call(text) = pattern && table.each_key.any? { text.include?(_1) } ? text.gsub(pattern, table) : text
        end
      end
    end
  end
end
