# frozen_string_literal: true

require "ipaddr"
require "uri"

module Lain
  class Config
    # The tables of one `.lain/config.rb`, each already through its own `.from`.
    #
    # `tests` is nil when the file declares no such table, and {#test_layout}
    # is the reader: absence must stay distinguishable from a declared table so
    # the detected-framework fallback survives, without every caller comparing
    # against {TestLayout::None}.
    Built = Data.define(:epics, :approval, :isolation, :sensitivity, :shell, :search, :tests, :middleware,
                        :env_pass, :approval_timeout, :approval_silence, :judge_timeout, :judge_memo, :keys, :todos,
                        :theme, :attention, :think, :review, :budget, :remote_relay, :remote_ntfy, :github) do
      # @param framework [String, nil] a detected test framework
      # @return [TestLayout] the declared layout, else what the framework implies
      def test_layout(framework: nil) = tests || TestLayout.from(nil, path: nil, framework:)
    end

    # The evaluation context for `.lain/config.rb`: one verb per table, each
    # handing the same `.from` the TOML reader used a string-keyed hash, so
    # every semantic refusal survives the change of syntax. instance_eval'd
    # with no sandbox, like `.lain/services.rb`.
    #
    # A refusal names the line of the verb that caused it, because the user
    # wrote Ruby and a backtrace into this file points nowhere they can edit.
    class Builder
      VERBS = %i[epics approval isolation sensitivity shell search tests middleware env todos think review
                 budget github].freeze

      ENV_TABLE = "`env`"
      THINK_TABLE = "`think`"
      BUDGET_TABLE = "`budget`"
      REMOTE_TABLE = "`remote`"
      RELAY_ADDRESS = /\A(?<host>\[[^\]]+\]|[^:\[\]]+):(?<port>\d{1,5})\z/
      BAD_RELAY = "relay must be an IP address and a port, such as \"100.64.0.1:7820\", got %s"
      EVERYWHERE = "relay listens only on loopback or this host's tailscale0 address, never on every address, " \
                   "got %s"
      BAD_NTFY = "ntfy must be an http or https URL naming a topic, got %s"
      UNNAMED_LEVEL = "think takes a level name such as \"low\", got %s"

      SECRET_PASS = "pass names %<names>s, which match the secret shape #{Exec::ChildEnv::SECRET.source}; " \
                    "remove them from env pass".freeze
      SCRUBBED_PASS = "pass names %<names>s, which every child has deleted whatever the pass list says; " \
                      "remove them from env pass"
      MALFORMED_PASS = "pass names %<names>s, each not a variable name; " \
                       "a name is letters, digits and underscores, not starting with a digit"
      VARIABLE_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

      # The user's config.rb runs in every project, so the tables that rule
      # one project stay in that project's file.
      USER_VERBS = %i[middleware keys theme attention github remote].freeze

      # Records the calls a block makes, so the verb that owns the block can
      # validate them at the line each was written on.
      class Collector
        Call = Data.define(:verb, :args, :kwargs, :block, :line)

        attr_reader :calls

        def initialize(path, verbs)
          @path = path
          @verbs = verbs
          @calls = []
        end

        # @param name [Symbol] the verb
        # @param args [Array] its positional arguments
        # @param kwargs [Hash{Symbol => Object}] its keyword arguments, kept as written
        # @param block [Proc, nil] the block the call carried, kept for the verb that wants it
        # @option kwargs [Object] :field one field of an entry, as written
        def method_missing(name, *args, **kwargs, &block)
          line = Builder.line_in(@path)
          raise Builder.unknown_verb(name, @verbs, path: @path, line:) unless @verbs.include?(name)

          @calls << Call.new(verb: name, args:, kwargs:, block:, line:)
        end

        def respond_to_missing?(name, include_private = false) = @verbs.include?(name) || super
      end
      private_constant :Collector

      # @param source [String] the text of a `.lain/config.rb`
      # @param path [String] what backtraces and refusals name
      # @param verbs [Array<Symbol>] the tables this file may declare
      # @param skills [Array<String>, nil] the skill names a `budget` row may name; nil reads the project's catalog
      # @param user_config [String, nil] the user's config.rb, named by a refusal of a verb that belongs there
      # @return [Built]
      # @raise [Refusal] naming the path and line of what the file got wrong,
      #   whether that is a refused value or Ruby itself failing
      def self.evaluate(source, path:, verbs: VERBS, skills: nil, user_config: nil)
        builder = new(path, verbs, skills, user_config)
        # A String read under LC_ALL=C is US-ASCII, and `load` would assume UTF-8 here.
        builder.instance_eval(source.dup.force_encoding(Encoding::UTF_8), path, 1)
        builder.built
      rescue Refusal
        raise
      rescue ScriptError, StandardError => e
        raise translated(DslCatalog.refusal_message(e, path, source), path)
      end

      def self.translated(message, path)
        location = message[/\A#{Regexp.escape(path)}(:\d+)?/]
        Refusal.new(message.delete_prefix("#{location}: "), path: location)
      end
      private_class_method :translated

      # @return [Integer, nil] the line in `path` the current call came from
      def self.line_in(path) = caller_locations.find { |frame| frame.path == path }&.lineno

      def self.located(path, line) = line ? "#{path}:#{line}" : path

      def self.unknown_verb(name, known, path:, line:)
        Refusal.new("has no verb #{name.inspect}; known verbs: #{known.join(", ")}",
                    path: located(path, line), key: name.to_s)
      end

      # @param path [String] what backtraces and refusals name
      # @param verbs [Array<Symbol>] the tables this file may declare
      # @param skills [Array<String>, nil] the skill names a `budget` row may name; the catalog is read
      #   only when a row names something else
      # @param user_config [String, nil] the user's config.rb, named by a refusal of a verb that belongs there
      def initialize(path, verbs = VERBS, skills = nil, user_config = nil)
        @path = path
        @verbs = verbs
        @skills = skills
        @user_config = user_config
        @tables = {}
        @approval_timeout = Config::DEFAULT_APPROVAL_TIMEOUT
        @approval_silence = Config::DEFAULT_APPROVAL_SILENCE
        @judge_timeout = Config::DEFAULT_JUDGE_TIMEOUT
        @judge_memo = Config::DEFAULT_JUDGE_MEMO
        @remote = {}
      end

      # @return [Built] every table not declared at its default
      def built
        Built.new(epics: @tables.fetch(:epics) { Epics.from(nil, path: @path) },
                  approval: @tables.fetch(:approval, Answers.empty),
                  isolation: @tables.fetch(:isolation, Isolation.empty),
                  sensitivity: @tables.fetch(:sensitivity, Sensitivity::Rules.empty),
                  shell: @tables.fetch(:shell, Shell::Exclusions.empty),
                  search: @tables.fetch(:search, SearchRules.empty),
                  tests: @tables[:tests],
                  middleware: @tables.fetch(:middleware, Middleware.empty),
                  env_pass: @tables.fetch(:env, []),
                  approval_timeout: @approval_timeout, approval_silence: @approval_silence,
                  judge_timeout: @judge_timeout, judge_memo: @judge_memo,
                  think: @tables[:think], remote_relay: @remote[:relay], remote_ntfy: @remote[:ntfy],
                  **small_tables)
      end

      def epics(**table, &block)
        declare(:epics, Epics::TABLE, table) do |at|
          gates = gates_from(collect(block, %i[gate]), table, at)
          Epics.from(shaped(table, "gates" => gates), path: at)
        end
      end

      def approval(timeout: nil, judge_timeout: nil, silence: nil, judge_memo: nil, &block)
        declare(:approval, Answers::TABLE) do |at|
          @approval_timeout = timeout_from(timeout, at)
          @approval_silence = silence_from(silence, at)
          @judge_timeout = timeout_from(judge_timeout, at, key: "judge_timeout", current: @judge_timeout)
          @judge_memo = memo_from(judge_memo, at)
          calls = collect(block, %i[allow deny deny_tool])
          calls.each { |call| Answers.from({ call.verb.to_s => [entry(call)] }, path: located_at(call.line)) }
          Answers.from(calls.group_by(&:verb).to_h { |verb, group| [verb.to_s, group.map { |call| entry(call) }] },
                       path: at)
        end
      end

      def isolation(**table)
        declare(:isolation, Isolation::TABLE, table) { |at| Isolation.from(shaped(table), path: at) }
      end

      def sensitivity(**table)
        declare(:sensitivity, Sensitivity::Rules::TABLE, table) { |at| Sensitivity::Rules.from(shaped(table), path: at) }
      end

      def shell(**table)
        declare(:shell, Shell::Exclusions::TABLE, table) { |at| Shell::Exclusions.from(shaped(table), path: at) }
      end

      def search(**table)
        declare(:search, SearchRules::TABLE, table) { |at| SearchRules.from(shaped(table), path: at) }
      end

      def middleware(&block)
        declare(:middleware, Middleware::TABLE) { Middleware.from(collect(block, Middleware::AREAS), path: @path) }
      end

      def todos(**table) = declare(:todos, Todos::TABLE, table) { |at| Todos.from(shaped(table), path: at) }

      def review(**table) = declare(:review, Review::TABLE, table) { |at| Review.from(shaped(table), path: at) }

      # `budget iterations: { "plan-epic" => 80 }` replaces the default row of that name.
      def budget(**table)
        declare(:budget, BUDGET_TABLE, table) { |at| budget_from(shaped(table), at) }
      end

      # `remote relay: "100.64.0.1:7820"` turns the phone's approval surface on:
      # the address is where the relay listens for the phone, and the chat
      # dials the relay's own socket beside it. `ntfy:` is the topic a waiting
      # item is announced on.
      def remote(relay: nil, ntfy: nil)
        declare(:remote, REMOTE_TABLE) do |at|
          @remote = { relay: relay_from(relay, at), ntfy: ntfy_from(ntfy, at) }.compact.freeze
        end
      end

      def github(**table) = declare(:github, Github::TABLE, table) { |at| Github.from(shaped(table), path: at) }

      def keys(**table) = declare(:keys, Keys::TABLE, table) { |at| Keys.from(shaped(table), path: at) }

      def theme(**table) = declare(:theme, Theme::TABLE, table) { |at| Theme.from(shaped(table), path: at) }

      def attention(**table)
        declare(:attention, Attention::TABLE, table) { |at| Attention.from(shaped(table), path: at) }
      end

      # `env pass: %w[DATABASE_URL RAILS_ENV]` hands those variables, from the
      # environment lain started under, to every command the bash tool runs.
      #
      # The check reads the NAME, never the value: a secret-shaped name
      # ({Exec::ChildEnv::SECRET}) is refused, while `DATABASE_URL` passes and
      # can carry a password inside its value. Passing a name is the project's
      # decision about what that value holds.
      #
      # What the bash output mask does with a passed value is {Sensitivity::Literals}' to say.
      def env(**table) = declare(:env, ENV_TABLE, table) { |at| env_pass_from(shaped(table), at) }

      # `think "low"` names the reasoning level a chat asks for. Whether the
      # model accepts it is the server's to say, so only the shape is checked here.
      def think(level = nil)
        declare(:think, THINK_TABLE) do |at|
          unless named?(level)
            raise Refusal.new(UNNAMED_LEVEL % level.inspect, path: at, table: THINK_TABLE,
                                                             key: "think")
          end

          -level.strip
        end
      end

      def tests(**table) = declare(:tests, TestLayout::TABLE, table) { |at| TestLayout.from(shaped(table), path: at) }

      # Kernel#test answers the likeliest typo of `tests` with an unrelated TypeError.
      def test(*, **)
        raise self.class.unknown_verb(:test, @verbs, path: @path, line: self.class.line_in(@path))
      end

      def method_missing(name, *, **)
        raise self.class.unknown_verb(name, @verbs, path: @path, line: self.class.line_in(@path))
      end

      def respond_to_missing?(*) = super

      private

      def small_tables
        { keys: @tables.fetch(:keys) { Keys.empty }, todos: @tables.fetch(:todos) { Todos.empty },
          theme: @tables.fetch(:theme) { Theme.empty }, attention: @tables.fetch(:attention) { Attention.empty },
          review: @tables.fetch(:review) { Review.empty }, github: @tables.fetch(:github) { Github.empty },
          budget: @tables.fetch(:budget) { Lain::Budget::Table.new } }
      end

      def declare(table, label, keywords = {})
        at = located_at(self.class.line_in(@path))
        refuse_project_only(table, at) unless @verbs.include?(table)
        raise Refusal.new("declares #{table} twice", path: at, table: label, key: table.to_s) if @tables.key?(table)

        refuse_repeated_keys(keywords, at, label)
        @tables[table] = yield(at)
      end

      def refuse_project_only(table, at)
        owner = USER_VERBS.include?(table) ? user_file : "a project's #{ProjectDir.config}"
        raise Refusal.new("#{table} belongs in #{owner}", path: at, key: table.to_s)
      end

      def user_file = ["the user's config.rb", @user_config].compact.join(", ")

      def refuse_repeated_keys(keywords, at, label)
        twice = keywords.keys.map(&:to_s).tally.select { |_, count| count > 1 }.keys
        raise Refusal.new("gives #{twice.join(", ")} twice", path: at, table: label, key: twice) if twice.any?
      end

      def named?(level) = level.is_a?(String) && !level.strip.empty?

      def budget_from(table, at)
        unknown = table.keys - %w[iterations]
        raise Refusal.unknown_keys(unknown, known: %w[iterations], path: at, table: BUDGET_TABLE) if unknown.any?

        rows = table.fetch("iterations", {})
        refuse_unknown_rows(rows.keys.map(&:to_s), at)
        Lain::Budget::Table.new(rows:)
      rescue ArgumentError => e
        raise Refusal.new(e.message, path: at, table: BUDGET_TABLE, key: "iterations")
      end

      def refuse_unknown_rows(names, at)
        unknown = names - known_rows
        unknown -= skill_names if unknown.any?
        return if unknown.empty?

        detail = "iterations names #{unknown.map(&:inspect).join(", ")}, which is no skill, role or default; " \
                 "known: #{(known_rows + skill_names).uniq.join(", ")}"
        raise Refusal.new(detail, path: at, table: BUDGET_TABLE, key: "iterations")
      end

      def known_rows = [*Lain::Budget::Table::ROWS.keys, *Lain::Role::Catalog.names.map(&:to_s)].uniq

      def skill_names
        @skill_names ||= @skills || Lain::Skill::Catalog.load(root: File.expand_path("../..", @path)).names.map(&:to_s)
      end

      def env_pass_from(table, at)
        unknown = table.keys - %w[pass]
        raise Refusal.unknown_keys(unknown, known: %w[pass], path: at, table: ENV_TABLE) if unknown.any?

        names = table.fetch("pass", [])
        refuse_env("pass must be a list of variable names, got #{names.inspect}", at) unless names_list?(names)
        refuse_names(names.grep(Exec::ChildEnv::SCRUB), SCRUBBED_PASS, at)
        refuse_names(names.grep_v(VARIABLE_NAME), MALFORMED_PASS, at)
        refuse_names(names.grep(Exec::ChildEnv::SECRET), SECRET_PASS, at)
        names.map(&:-@).uniq.freeze
      end

      def refuse_names(names, message, at)
        refuse_env(format(message, names: names.map(&:inspect).join(", ")), at) if names.any?
      end

      def names_list?(names) = names.is_a?(Array) && names.all?(String)

      def refuse_env(detail, at) = raise(Refusal.new(detail, path: at, table: ENV_TABLE, key: "pass"))

      def timeout_from(timeout, at, key: "timeout", current: @approval_timeout)
        return current if timeout.nil?
        return timeout if timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?

        detail = "#{key} must be above 0 seconds, got #{timeout.inspect}"
        raise Refusal.new(detail, path: at, table: Answers::TABLE, key:)
      end

      def silence_from(silence, at)
        return @approval_silence if silence.nil?
        return silence if Approval::Silence.named?(silence)

        raise Refusal.new("silence must be :hold or :deny, got #{silence.inspect}", path: at, table: Answers::TABLE,
                                                                                    key: "silence")
      end

      def memo_from(memo, at)
        return @judge_memo if memo.nil?
        return memo if [true, false].include?(memo)

        detail = "judge_memo must be true or false, got #{memo.inspect}"
        raise Refusal.new(detail, path: at, table: Answers::TABLE, key: "judge_memo")
      end

      def relay_from(relay, at)
        return if relay.nil?

        address = RELAY_ADDRESS.match(relay.to_s)
        host = address && ip(address[:host].delete("[]"))
        unless host && address[:port].to_i.between?(1, 65_535)
          raise Refusal.new(format(BAD_RELAY, relay.inspect), path: at, table: REMOTE_TABLE, key: "relay")
        end
        return -relay unless host.to_i.zero?

        raise Refusal.new(format(EVERYWHERE, relay.inspect), path: at, table: REMOTE_TABLE, key: "relay")
      end

      def ip(host)
        IPAddr.new(host)
      rescue IPAddr::Error
        nil
      end

      def ntfy_from(ntfy, at)
        return if ntfy.nil?
        return -ntfy if topic_url?(ntfy)

        raise Refusal.new(format(BAD_NTFY, ntfy.inspect), path: at, table: REMOTE_TABLE, key: "ntfy")
      end

      def topic_url?(ntfy)
        uri = URI.parse(ntfy.to_s)
        %w[http https].include?(uri.scheme) && !uri.host.to_s.empty? && uri.path.length > 1
      rescue URI::InvalidURIError
        false
      end

      def located_at(line) = self.class.located(@path, line)

      def refuse(detail, line:, table:, key:) = raise(refusal(detail, line:, table:, key:))

      def refusal(detail, line:, table:, key:) = Refusal.new(detail, path: located_at(line), table:, key:)

      def collect(block, verbs)
        collector = Collector.new(@path, verbs)
        collector.instance_eval(&block) if block
        collector.calls
      end

      def gates_from(calls, table, at)
        both = calls.any? && table.key?(:gates)
        if both
          raise Refusal.new("gives gates both as a keyword and as a block", path: at, table: Epics::TABLE,
                                                                            key: "gates")
        end

        gates = {}
        refusals = calls.flat_map { |call| refusals_of(call, gates) }
        raise_all(refusals)
        gates.empty? ? nil : gates
      end

      def refusals_of(call, seen)
        stage, policy = gate_pair(call)
        repeated = seen.key?(stage)
        seen[stage] = policy
        [bad_policy(call, stage, policy), (twice(call, stage) if repeated)].compact
      rescue Refusal => e
        [e]
      end

      def bad_policy(call, stage, policy)
        Epics::Gates.from(shaped({ stage => policy }), path: located_at(call.line))
        nil
      rescue Refusal => e
        e
      end

      def twice(call, stage)
        refusal("declares gate #{stage.inspect} twice", line: call.line, table: Epics::Gates::TABLE, key: stage.to_s)
      end

      # One bad line re-raises as it was, so its file:line prefix is unchanged; several are
      # one refusal because the first alone sends the user round the loop once per typo.
      def raise_all(refusals)
        raise refusals.first if refusals.one?
        return if refusals.empty?

        raise Refusal.new(refusals.map(&:message).join("\n"), key: refusals.flat_map { |r| Array(r.key) })
      end

      def gate_pair(call)
        return call.args if call.args.size == 2 && call.kwargs.empty?

        refuse("gate takes a stage and a policy, got #{call.args.size} arguments",
               line: call.line, table: Epics::Gates::TABLE, key: "gate")
      end

      def entry(call)
        unless call.args.size == 1
          refuse("#{call.verb} takes one tool name, got #{call.args.size} arguments",
                 line: call.line, table: Answers::TABLE, key: call.verb.to_s)
        end

        { "tool" => call.args.first }.merge(input_of(call))
      end

      # `allow "x"` with no fields is an empty input; `deny_tool` refuses a
      # whole tool, so a field beside it is refused here, as the file wrote it.
      def input_of(call)
        return { "input" => shaped(call.kwargs) } unless call.verb == :deny_tool
        return {} if call.kwargs.empty?

        fields = call.kwargs.map { |field, value| "#{field}: #{value.inspect}" }.join(", ")
        refuse("takes a tool name and no fields, got #{fields}", line: call.line,
                                                                 table: "`deny_tool`", key: "deny_tool")
      end

      # TOML's own shape: string keys, and a symbol is a string.
      def shaped(value, extra = {})
        case value
        when Hash then value.merge(extra.compact).to_h { |key, member| [key.to_s, shaped(member)] }
        when Array then value.map { |member| shaped(member) }
        when Symbol then value.to_s
        else value
        end
      end
    end
  end
end
