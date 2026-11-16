# frozen_string_literal: true

module Lain
  module Forge
    class Gh
      # The GitHub account every gh child acts as, lent as `GH_TOKEN` so a box logged in to several
      # accounts posts as the one the config names rather than whichever gh last switched to.
      #
      # The token is asked of gh on first use, never at construction: an account gh does not know
      # must fail the call that needs it, not the chat that merely could. A token the human
      # exported already wins, because they chose it on purpose; the chat is told once.
      class Account
        # gh knows no token for the account, or no gh answered. A {Lain::Error}, so the chat
        # renders it and stays up.
        class Refused < Error; end

        # What a chat with no account configured lends: nothing, so every gh child gets the
        # parent's environment unchanged.
        class None
          # @return [Hash{String=>String}] always empty
          def environment = {}
        end

        # The variables gh reads a token from, in its own order of precedence.
        EXPORTED = %w[GH_TOKEN GITHUB_TOKEN].freeze

        UNKNOWN = "gh has no token for the GitHub account %<account>s; " \
                  "run `gh auth login` for it, or change `github account:` in the lain config"

        EXPORTED_WINS = "%<variable>s is exported, so gh runs as that token rather than " \
                        "the configured GitHub account %<account>s"

        # @param github_config [Config::Github] the resolved `github` table
        # @param env [#[]] the process environment, read for an exported token
        # @param shell_out_factory [#call] builds the `gh auth token` runner
        # @param notes [#puts] where the exported-token warning goes
        # @return [Account, None] None when no account is configured
        def self.for(github_config, shell_out_factory:, notes:, env: ENV)
          return None.new if github_config.account.nil?

          new(github_config.account, env:, shell_out_factory:, notes:)
        end

        # The account the config names for a project, or for no project with a nil root.
        #
        # @param root [String, nil] the project whose `.lain/config.rb` is read
        # @param paths [Paths] finds the user's config
        # @param notes [#puts]
        # @param shell_out_factory [#call]
        # @return [Account, None]
        def self.configured(root:, paths:, notes:, shell_out_factory: Shell::Out.public_method(:new))
          self.for(Config.github(root:, paths:), shell_out_factory:, notes:)
        end

        # @param name [String] the account gh is asked for a token of
        # @param env [#[]] the process environment
        # @param shell_out_factory [#call]
        # @param notes [#puts]
        def initialize(name, env:, shell_out_factory:, notes:)
          @name = name
          @env = env
          @shell_out_factory = shell_out_factory
          @notes = notes
          @guard = Mutex.new
          @environment = nil
        end

        # @return [Hash{String=>String}] `GH_TOKEN` set to the account's token, or empty when a
        #   token is exported; resolved once and then memoised
        # @raise [Refused] naming the account and the fix; a refusal is not memoised, so a login
        #   made since is picked up on the next call
        def environment = @guard.synchronize { @environment ||= resolved }

        # The memoised token stays out of every inspect, a Gh's or a failure message's included.
        #
        # @return [String] the class and the account name
        def inspect = "#<#{self.class.name} #{@name}>"

        private

        def resolved
          exported = EXPORTED.find { |variable| !@env[variable].to_s.empty? }
          return told(exported) if exported

          { "GH_TOKEN" => token }.freeze
        end

        def told(variable)
          @notes.puts(format(EXPORTED_WINS, variable:, account: @name))
          {}.freeze
        end

        def token
          shell = @shell_out_factory.call("gh", "auth", "token", "--user", @name).run_command
          token = shell.stdout.to_s.strip
          raise Refused, format(UNKNOWN, account: @name) unless Shell::Out.ok?(shell) && !token.empty?

          token
        end
      end
    end
  end
end
