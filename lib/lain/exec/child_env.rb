# frozen_string_literal: true

module Lain
  module Exec
    # The environment a child of this process is handed, decided once for every
    # backend so the transport a command took cannot change what it sees.
    #
    # An ALLOWLIST over what the child would otherwise INHERIT, for the reason
    # {Docker::CROSSES} gives: a denylist over an unbounded set missed
    # `ANTHROPIC_API_KEY`, which a child read straight back out of its own
    # environ. What the caller LENDS is a different question. A name it added,
    # or whose value it changed, passes whatever its shape, because lending it
    # was the decision; a name it merely copied from the process is held to the
    # allowlist like any inherited one, which is what keeps
    # {WorkerEnv.default}, a full snapshot of ENV, from lending every secret.
    #
    # The four scrubs on {Exec} hold over both: a framework, shell, loader or
    # function variable is deleted whether inherited, lent or passed.
    class ChildEnv
      # The human named a secret-shaped variable to pass to every child.
      class Refused < Lain::Error; end

      # Names the child always gets from the process, each a toolchain fact a
      # command needs to find its tools, its home or its git config. The
      # DOCKER_ and CONTAINER_ names are how a client reaches a remote or
      # rootless daemon; {Docker}'s own client runs through {Local} and needs
      # them, and {Docker::CROSSES} keeps them out of the container.
      KEEP = /\A(?:PATH|HOME|USER|LOGNAME|SHELL|PWD|TMPDIR|LANG|LC_[A-Z]+|TZ|TERM|COLORTERM|NO_COLOR|CI|
                 GIT_CONFIG_(?:GLOBAL|NOSYSTEM)|LD_LIBRARY_PATH|GEM_[A-Z_]+|MISE_[A-Z_]+|CARGO_HOME|RUSTUP_HOME|
                 XDG_[A-Z_]+|SSL_CERT_(?:FILE|DIR)|LAIN_[A-Z_]+|
                 DOCKER_(?:HOST|CONTEXT|CONFIG|CERT_PATH|TLS_VERIFY)|CONTAINER_(?:HOST|CONNECTION))\z/x

      # Withheld from the process's environment even where {KEEP} or the pass
      # list names it; only a caller lending one on purpose gets it through.
      # A shape, not a meaning, so it fails closed: TOKENIZERS_PARALLELISM is
      # refused too, and the refusal names it.
      SECRET = /KEY|TOKEN|SECRET|PASSW|CREDENTIAL|AUTH_SOCK/i

      SCRUB = Regexp.union(FRAMEWORK_ENV, SHELL_ENV, LOADER_ENV, FUNCTION_ENV)

      PASS_VARIABLE = "LAIN_ENV_PASS"

      REFUSAL = "#{PASS_VARIABLE} names secret-shaped variables (%<names>s), which would reach every command " \
                "lain runs; remove them from #{PASS_VARIABLE}".freeze

      # @param env [#[], #to_h] the process environment the child would inherit
      # @param pass [Array<String>] the names a project's `env pass:` lists
      # @return [ChildEnv] passing those and the names {PASS_VARIABLE} lists
      # @raise [Refused] when one of them is secret-shaped
      def self.from(env, pass: []) = new(pass: pass + listed(env), env:)

      def self.listed(env) = env.fetch(PASS_VARIABLE, "").split(",").map(&:strip).reject(&:empty?)
      private_class_method :listed

      # @param pass [Array<String>] names to keep from the process beyond {KEEP}
      # @param env [#[], #to_h] the process environment the child would
      #   inherit, read on every call so a later change is seen
      # @raise [Refused] when a passed name is secret-shaped
      def initialize(pass: [], env: ENV)
        refused = pass.grep(SECRET)
        raise Refused, format(REFUSAL, names: refused.join(", ")) if refused.any?

        @pass = pass.to_set.freeze
        @env = env
        freeze
      end

      # What {Exec.child_env} asks. Built at boot, so a secret-shaped name in
      # {PASS_VARIABLE} refuses the launch rather than the first command.
      DEFAULT = from(ENV)

      # A kept name the caller omitted is left to inheritance, so a backend
      # that inherits nothing, {Docker}, crosses only what the caller named.
      #
      # @param lent [Hash] the caller's environment ({WorkerEnv#env})
      # @return [Hash] lent values for names the caller added or changed or that
      #   are kept, and nil for every other inherited or scrubbed name
      def call(lent)
        inherited = @env.to_h
        passed = lent.select { |name, value| inherited[name] != value || keep?(name) }
        withheld = inherited.keys.reject { |name| passed.key?(name) || keep?(name) }
        passed.merge(removed(withheld)).merge(removed((lent.keys + inherited.keys).grep(SCRUB)))
      end

      # @return [Hash] the parent environment as it is now
      def environment = @env.to_h

      # @param name [String] a variable name
      # @return [Boolean] whether the pass list names it
      def passes?(name) = @pass.include?(name)

      private

      def keep?(name) = (KEEP.match?(name) && !SECRET.match?(name)) || passes?(name)

      def removed(names) = names.to_h { |name| [name, nil] }
    end
  end
end
