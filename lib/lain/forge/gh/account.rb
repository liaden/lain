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

        ABSENT = "gh was not found, so there is no token for the GitHub account %<account>s; " \
                 "install gh and run `gh auth login`, or change `github account:` in the lain config"

        UNRUNNABLE = "gh could not be run (%<reason>s), so there is no token for the GitHub account %<account>s; " \
                     "fix gh, or change `github account:` in the lain config"

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
        # @param notes [#puts]
        # @param shell_out_factory [#call]
        # @return [Account, None]
        def self.configured(root:, notes:, shell_out_factory: Shell::Out.public_method(:new))
          self.for(Config.github(root:), shell_out_factory:, notes:)
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

        # The `GH_TOKEN` a child should carry. A child that inherits the process's environment
        # already holds an exported one, but a bash child is handed only what is lent to it.
        #
        # @return [Hash{String=>String}] `GH_TOKEN` set to the exported token when one is
        #   exported, else to the account's; resolved once and then memoised
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
          told(exported) if exported
          { "GH_TOKEN" => exported ? @env[exported] : token }.freeze
        end

        def told(variable) = @notes.puts(format(EXPORTED_WINS, variable:, account: @name))

        def token
          shell = asked
          token = shell.stdout.to_s.strip
          raise Refused, format(UNKNOWN, account: @name) unless Shell::Out.ok?(shell) && !token.empty?

          token
        end

        def asked
          @shell_out_factory.call("gh", "auth", "token", "--user", @name).run_command
        rescue Errno::ENOENT
          raise Refused, format(ABSENT, account: @name)
        rescue SystemCallError => e
          raise Refused, format(UNRUNNABLE, reason: e.message, account: @name)
        end
      end
    end
  end
end
