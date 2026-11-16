# frozen_string_literal: true

module Lain
  module Forge
    class Gh
      # The two read-only gh calls a pull request review makes, run as the configured account.
      #
      # Apart from {Gh} on purpose: Gh is a closed set of landing verbs written in three mirrors,
      # and a read has no landing to fold into. This runs the subprocess and hands it back
      # unjudged; each caller keeps its own reading of a refusal.
      class Reads
        # The `--json` fields the review reads, and nothing else.
        PR_FIELDS = %w[baseRefName baseRefOid headRefOid].freeze

        # @param cwd [String] where gh runs, which is how it resolves WHICH repository it asks about
        # @param account [Account, Account::None] whose token every gh child runs with
        # @param timeout [Numeric] seconds one gh call may take
        # @param shell_out_factory [#call] builds the subprocess runner
        def initialize(cwd:, account:, timeout: DEFAULT_TIMEOUT, shell_out_factory: Shell::Out.public_method(:new))
          @cwd = cwd.to_s
          @account = account
          @timeout = timeout
          @shell_out_factory = shell_out_factory
          freeze
        end

        # @param ref [String] a number, URL or branch, as the human wrote it
        # @return [#stdout, #stderr, #exitstatus] the finished `gh pr view`
        # @raise [Account::Refused] when gh has no token for the configured account
        # @raise [Shell::Out::Timeout, Errno::ENOENT]
        def pr_refs(ref:) = run("pr", "view", ref, "--json", PR_FIELDS.join(","))

        # @param ref [String] as for {#pr_refs}
        # @return [#stdout, #stderr, #exitstatus] the finished `gh pr diff`
        def pr_diff(ref:) = run("pr", "diff", ref)

        # The token stays out of every inspect: the account's own inspect names no token.
        def inspect = "#<#{self.class.name} #{@account.inspect}>"

        private

        def run(*argv)
          shell = @shell_out_factory.call("gh", *argv, cwd: @cwd, timeout: @timeout,
                                                       environment: @account.environment)
          shell.run_command
          shell
        end
      end
    end
  end
end
