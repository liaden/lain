# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "delegate"

module Lain
  module Middleware
    # Withholds the output of a `bash` call nobody looked at when it holds a
    # credential-shaped region, and bars that command from automatic approval
    # for the rest of the session.
    #
    # The path boundary judges what a command NAMES, which is not what it
    # prints: `cat notes.txt` over a pasted key is an ordinary path, and a rule
    # or `auto` approval runs it with no human in the loop. So the output is
    # scanned on the way OUT, and only when the approval was automatic -- a
    # human who approved the command saw what it would do and gets its bytes.
    #
    # It withholds rather than masks. A mask needs a release key a human can
    # answer, and a command's output has no path to key one on; the move it
    # names instead is a retry, which the bar sends to a human.
    #
    # == What it is not
    #
    # It catches an ACCIDENTAL print of credential-shaped output, and nothing
    # more. The detector matches shapes as printed, so a command written to
    # reshape its output -- `fold`, `sed`, `xxd`, any encoding -- passes it.
    # This layer checks shape, not safety, in {Tool::Input}'s sense: under
    # `ask` it is the approval predicates that keep such a command in front of
    # a human, and they must not be loosened on the strength of this layer.
    #
    # Nor does it cover the live display. `bash` streams its output to the
    # human's own pane as it runs, before the result reaches this layer; the
    # human is the authority here, and what is withheld is the model's copy
    # and the record's.
    #
    # == How it learns who approved the call
    #
    # The gate sits after this layer and answers only a result, so the
    # authority rides the context: the call goes downstream over a {Carried}
    # context, the ladder hands its settled ruling to it, and this layer reads
    # it back once the call returns. A context no ladder ruled on stays
    # automatic, which is the reading safe to be wrong about.
    class WithholdAutomaticOutput < Base
      # Exact membership, {RedactSecretReads::GUARDED_TOOLS}' rule.
      GUARDED_TOOLS = Set["bash"].freeze
      COMMAND = "command"

      # Mode-neutral: under `auto` nobody is asked, so it names what the
      # command needs rather than who will answer.
      WITHHELD = "%<name>s output withheld: it held %<count>s, and the command was approved automatically, " \
                 "so it now needs a human's approval."

      # Counts, never bytes: a record that quoted the output would write the
      # credential into the journal this layer keeps it out of.
      AutomaticOutputWithheld = Data.define(:tool_use_id, :regions) do
        include Telemetry::Journalable

        def initialize(tool_use_id:, regions:) = super(tool_use_id: -tool_use_id.to_s, regions: Integer(regions))
      end

      # The commands a session no longer approves automatically. One per board,
      # so a command a child printed a key with is barred for its parent too.
      # Keyed on the exact command string: a respelling is a different command,
      # whose output is scanned again.
      #
      # Deliberately mutable and unlocked, {Approval::Queue}'s posture: `add`
      # and `include?` are straight-line with no yield point between them.
      class Bar
        def initialize
          @commands = Set.new
        end

        def add(command)
          @commands << -command.to_s
          self
        end

        def include?(command) = @commands.include?(command)
      end

      # The context a guarded call runs under: the caller's own, answering
      # every message it answers, plus the two the ladder duck-types on --
      # whether this command is barred, and the ruling it settled on.
      #
      # Mutable for exactly one write, and built per call, so parallel calls
      # never share one.
      class Carried < SimpleDelegator
        def initialize(context, barred:)
          super(context)
          @barred = barred
          @authority = :automatic
        end

        def automatic_approval_barred? = @barred

        def ruled(ruling)
          @authority = ruling.authority
          self
        end

        def human? = @authority == :human
      end

      attr_reader :bar

      # @param bar [Bar] the session's one bar
      # @param journal [#<<] where {AutomaticOutputWithheld} lands
      def initialize(bar:, journal: Channel::Null.instance)
        @bar = bar
        @journal = journal
        super()
        freeze
      end

      def call(env, &app)
        effect = env.fetch(:effect)
        return downstream(env, &app) unless guarded?(effect)

        carried = Carried.new(env[:context] || Session::Null.instance, barred: @bar.include?(command(effect)))
        ran = downstream(env.merge(context: carried), &app).merge(context: env[:context])
        carried.human? ? ran : scanned(ran, effect)
      end

      private

      def called(effect) = effect.approval? ? effect.effect : effect

      def guarded?(effect) = called(effect).tool_call? && GUARDED_TOOLS.include?(called(effect).name)

      def command(effect) = called(effect).input[COMMAND]

      def scanned(env, effect)
        count = RedactSecretReads::Scan.new(env.fetch(:result).content).regions.size
        count.zero? ? env : withhold(env, called(effect), count)
      end

      def withhold(env, effect, count)
        @bar.add(effect.input[COMMAND])
        record(AutomaticOutputWithheld.new(tool_use_id: effect.tool_use_id, regions: count))
        env.merge(result: Tool::Result.error(format(WITHHELD, name: effect.name,
                                                              count: "#{count} credential-shaped " \
                                                                     "#{"region".pluralize(count)}")))
      end

      # Swallowed, {RedactSecretReads#record}'s way: the tool has already run,
      # and a raise here would leave its `tool_use` with no answer.
      def record(entry)
        @journal << entry
      rescue StandardError
        nil
      end
    end
  end
end
