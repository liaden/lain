# frozen_string_literal: true

module Lain
  module Oracle
    # The last-resort question: "write the one document that stands in for this
    # whole conversation". {Compaction::Source} fires it once, after a prompt
    # has already been refused for not fitting the window and no cut could make
    # room, and records the answer as the replacement a `handoff` cut holds.
    #
    # It is NOT a summarizer. {Summarize} compresses one tool result back into
    # prose a later turn can act on; this writes the state a fresh reader needs
    # to CONTINUE -- which is why the schema is five named fields rather than
    # one free paragraph. A model handed "summarize this" writes a narrative of
    # what happened, and the next turn then asks where the file it was editing
    # went.
    #
    # The document it produces is a compaction replacement and nothing else. It
    # is never written to project memory: memory is durable fact a human or
    # `lain consolidate` chose to keep, and this is a derived, rebuildable view
    # of one chat's own history.
    #
    # The three slots are the whole of what the question is shown, and the
    # split is the reason the input fits at all: the held replacements are
    # already compressed, the uncollapsed span arrives with every tool result
    # reduced to a stub, and the pins are named rather than quoted because the
    # render keeps them verbatim anyway.
    module Handoff
      SCHEMA = Class.new(Tool::Input) do
        field :goal, :string, required: true,
                              description: "what the human asked for, in their terms, across the whole conversation"
        field :progress, :string, required: true,
                                  description: "what has been done so far and what was learned doing it"
        field :files_and_decisions, :string, required: true,
                                             description: "which files were read or changed, and every decision " \
                                                          "a later turn must not re-litigate"
        field :open_todos, :string, required: true,
                                    description: "what remains, including anything started and left unfinished"
        field :next_step, :string, required: true,
                                   description: "the single next action, concretely enough to act on with no " \
                                                "other context"
      end

      # At most this much of any ONE block. Two hundred characters is about a
      # line, which is what a reader skimming forty turns of history can use:
      # past that a block is restating itself, and the bytes it costs are bytes
      # the newest turns do not get.
      LINE_CHARS = 200

      # The lowest bytes-per-token ever measured on a real request here: a
      # digit-heavy line, where such a tokenizer spends a token per digit,
      # against 3.26 for ordinary source and 3.33 for prose
      # ({Tool::Bounds::CEILINGS}' own figures). A Rational and not a Float,
      # because this multiplies a window into a byte count and a repeating
      # binary fraction has no place in a bound.
      BYTES_PER_TOKEN = Rational(131, 100)

      # What comes off the window before the slots get any of it: the rendered
      # template and its JSON schema, measured at 1,447 bytes together, which
      # is ~1,105 tokens at the density above and is reserved at 1,280; plus
      # the answer's own ceiling, {Model::DEFAULT_MAX_TOKENS}.
      #
      # A tier given a larger `--summarizer-max-tokens` than that default is
      # the one case this reserve is short, and it is short by exactly what the
      # flag added.
      RESERVED_TOKENS = 1_280 + Model::DEFAULT_MAX_TOKENS

      # What the whole question may cost, in bytes of slot text, against the
      # window the summarizer tier will ACTUALLY be asked in -- not a fixed
      # assumption about which local model is running. A run whose book cannot
      # identify the model is asked in {ContextWindow::CONSERVATIVE_FALLBACK}'s
      # 8,192, and sizing the input to 32,768 there would fail on the very
      # prompt a handoff exists to answer.
      #
      # What is left after {RESERVED_TOKENS} is spent at {BYTES_PER_TOKEN}, so
      # the budget is the bytes that CANNOT overflow rather than the bytes that
      # usually would not: 7,713 at 8,192 and 39,907 at the 32,768 a local
      # runner usually serves, where ordinary prose at 3.33 costs a third of
      # either. A window smaller than the reserve buys nothing, which is a
      # budget of zero rather than a negative one.
      #
      # @param window_tokens [Integer] the summarizer tier's resolved window
      # @return [Integer] bytes
      def self.budget_for(window_tokens)
        [((window_tokens - RESERVED_TOKENS) * BYTES_PER_TOKEN).to_i, 0].max
      end

      # What each slot is called in the question. Folded into the SLOT rather
      # than written into the template, so a slot the budget left empty -- or
      # one a chain simply has nothing for, a session with no pins -- prints no
      # heading over nothing.
      SECTIONS = { document: "The previous state document, whole:",
                   held: "Earlier summaries of this conversation, oldest first:",
                   span: "The conversation since, one line per turn:",
                   pins: "Turns the human pinned, which stay verbatim and need no restating:" }.freeze

      # What each answered field is called in the document. Ordered, because
      # the order IS the document's structure -- a reader meets the goal before
      # the progress toward it.
      HEADINGS = { "goal" => "Goal", "progress" => "Progress",
                   "files_and_decisions" => "Files and decisions",
                   "open_todos" => "Open todos", "next_step" => "Next step" }.freeze

      # The document's first line, and it is not decoration: a model handed
      # five headings with no frame reads them as a note it wrote to itself and
      # goes on to ask about turns that no longer exist.
      PREAMBLE = "The conversation before this point no longer fit the context window and was replaced by " \
                 "this state document. The turns it covers are gone; work from what follows."

      # THE LAST LINE IS NOT DECORATION, for {Summarize::TEMPLATE}'s reason: a
      # provider that ignores the structured-output format constraint answers a
      # template asking only "write the state" with prose, which
      # {Model::JsonDecoder} cannot decode. Asking in words too costs nothing
      # on a provider the constraint already binds.
      TEMPLATE = <<~ERB
        A long conversation no longer fits its context window. Everything below will be
        REPLACED by your answer, and the work continues from it alone.

        <%= render("document") %>
        <%= render("held") %>
        <%= render("span") %>
        <%= render("pins") %>
        Write the state a reader needs to carry this work on. State facts, not a
        narrative of what happened. Do not editorialize and do not offer to help.

        Reply with a JSON object and nothing else, in exactly this shape:
        {"goal": "...", "progress": "...", "files_and_decisions": "...", "open_todos": "...", "next_step": "..."}
      ERB

      module_function

      # @param tier [Symbol] folded into the digest, so a model answer and a
      #   heuristic answer to this same question sit at two addresses (see
      #   {PruneScoring.definition}).
      # @return [Oracle::Definition]
      def definition(tier: :model) = Definition.new(template: TEMPLATE, schema: SCHEMA, tier:)

      # The answer as the one message a `handoff` cut records.
      #
      # @param answer [Tool::Input] a validated answer to {.definition}
      # @return [String]
      def document(answer) = Document.from_answer(answer.to_h).to_s

      # The slots, cut to ONE byte budget in the order they can best afford
      # it: the previous state document first and never cut, because it is the
      # one account of everything before it and a line of it would be a guess
      # at the rest; the held replacements next, because they are already
      # compressed and are the only account of history nothing else carries;
      # then the uncollapsed span; then the pins, which the render keeps
      # verbatim anyway, so naming them is a courtesy rather than the content.
      #
      # @param document [String, nil] the state the last handoff wrote, if any,
      #   exactly as its cut recorded it
      # @param held [Array<Hash>] the replacements the cuts that hold rendered
      # @param span [Array<Hash>] the turns no held cut has collapsed
      # @param pins [Array<Hash>] the pinned turns, which stay verbatim
      # @param budget [Integer] bytes of slot text, from {.budget_for} against
      #   the window the summarizer tier answers in. The conservative window's
      #   by default, which is the one a caller that cannot resolve the tier's
      #   model would be asked in anyway.
      # @return [Hash{Symbol=>String}] the slots {TEMPLATE} names
      def question(held:, span:, pins:, document: nil, budget: budget_for(ContextWindow::CONSERVATIVE_FALLBACK))
        left = Budget.new(budget)
        whole = left.keep(document, heading: SECTIONS.fetch(:document))
        taken = SECTIONS.except(:document).zip([held, span, pins])
                        .to_h { |(slot, heading), messages| [slot, left.take(messages, heading:)] }
        taken[:span] = left.widen(taken.fetch(:span))
        { document: whole }.merge(taken.transform_values(&:to_s))
      end

      # One line for one message: the role, then every block reduced to at most
      # {LINE_CHARS} of it. EVERY block kind, not just a tool result -- a
      # handoff fires because a prompt did not fit, and the bulk is as likely
      # to be assistant prose or a pasted blob as a tool observation.
      #
      # @param message [Hash] a canonical-normalized projection
      # @return [String]
      def line(message)
        "#{message.fetch("role")}: #{blocks(message).map { |block| cut(stub(block)) }.join(" ")}"
      end

      # The same line with no block cut: what a turn costs when the budget can
      # afford all of it. Tool results are still stubs, as in {.line}.
      #
      # @param message [Hash] a canonical-normalized projection
      # @return [String]
      def whole(message)
        "#{message.fetch("role")}: #{blocks(message).map { |block| flatten(stub(block)) }.join(" ")}"
      end

      # {Context::Conversation#blocks}' reading and its reasoning: a bare String
      # content is a shape the Messages API accepts, so it carries one text
      # block rather than raising inside the render path.
      def blocks(message)
        content = message.fetch("content")
        content.is_a?(Array) ? content.grep(Hash) : [{ "type" => "text", "text" => content.to_s }]
      end
      private_class_method :blocks

      # An `else` on purpose: the block vocabulary is the provider's and grows
      # without notice, so an unknown type is named rather than dropped.
      def stub(block)
        case block["type"]
        when "text" then block["text"].to_s
        when "tool_use" then "[calls #{block["name"]}]"
        when "tool_result" then "[result for #{block["tool_use_id"]}, #{Canonical.dump(block["content"]).bytesize} " \
                                "bytes, elided]"
        else "[#{block["type"]}]"
        end
      end
      private_class_method :stub

      def flatten(text) = text.gsub(/\s+/, " ")
      private_class_method :flatten

      # One line, and the cut says what it cost -- a bound that silently
      # shortened a block would leave the model reading a truncated sentence as
      # a whole one.
      def cut(text)
        flat = flatten(text)
        return flat if flat.length <= LINE_CHARS

        "#{flat[0, LINE_CHARS]}... [#{text.bytesize} bytes in full]"
      end
      private_class_method :cut

      # One byte budget spent across the question's slots, in the order they
      # are asked for. Its own object because "how much is left" is state that
      # outlives one slot, and three module functions sharing it would be three
      # functions sharing a global.
      #
      # Within a slot the NEWEST turns are the ones that survive: what a reader
      # needs to carry the work on is what just happened, and a budget spent
      # oldest-first would hand back the opening of a conversation and drop the
      # part being worked on. What survives is rendered oldest first even so,
      # because that is how a conversation reads.
      class Budget
        # One slot as {Budget#take} afforded it: lines and messages are newest
        # first, and the notice is already paid for.
        Section = Data.define(:heading, :notice, :lines, :messages) do
          # The heading, then the lines oldest first under the notice; "" when
          # nothing fits or there was nothing to say, because a heading over
          # nothing is worse than silence.
          #
          # @return [String]
          def to_s
            return "" if lines.empty?

            "#{heading}\n\n#{[notice, *lines.reverse].compact.join("\n")}\n"
          end
        end

        ELIDED = "[%<count>d earlier turn(s) elided: they did not fit this question]"

        def initialize(bytes)
          @left = bytes
        end

        # @param messages [Array<Hash>] canonical-normalized projections
        # @param heading [String] what this section is called
        # @return [Section] the lines that fit, newest first, with the notice
        #   for those that did not
        def take(messages, heading:)
          newest = messages.reverse
          lines = newest.map { |message| Handoff.line(message) }
          afforded = affordable(lines, heading)
          return Section.new(heading:, notice: nil, lines: [], messages: []) if afforded.empty?

          charge(afforded.last.last + heading.bytesize + 2)
          Section.new(heading:, notice: notice(lines.size - afforded.size), lines: afforded.map(&:first),
                      messages: newest.first(afforded.size))
        end

        # The turns of a section, newest first, bought back whole out of what
        # every slot left AFTER it was afforded at cut length. A second pass
        # and never part of {#take}, so it cannot spend room another slot or
        # the elided notice was owed.
        #
        # @param section [Section]
        # @return [Section]
        def widen(section)
          wholes = section.messages.map { |message| Handoff.whole(message) }
          extra = upgrade_costs(section.lines, wholes)
          count = extra.take_while { |sum| sum <= @left }.size
          charge(extra.fetch(count - 1)) if count.positive?
          section.with(lines: wholes.first(count) + section.lines.drop(count))
        end

        # A section that is never cut, for the one thing the question must not
        # summarize. It is charged even when it overruns, so what follows sees
        # no room rather than a budget the document already spent.
        #
        # @param text [#to_s, nil] nil is no section at all
        # @param heading [String]
        # @return [String]
        def keep(text, heading:)
          return "" if text.nil?

          "#{heading}\n\n#{text}\n".tap { |section| charge(section.bytesize) }
        end

        private

        # Cumulative, like {#running}, for the same `take_while`.
        def upgrade_costs(shorts, wholes)
          shorts.zip(wholes).map { |short, whole| whole.bytesize - short.bytesize }
                .inject([]) { |sums, cost| sums + [(sums.last || 0) + cost] }
        end

        # The heading and its blank line are reserved with the notice, for the
        # notice's reason: a section's own furniture is part of what the budget
        # bounds, or the bound is only about the lines inside it.
        def affordable(lines, heading)
          room = @left - reserve(lines.size) - heading.bytesize - 2
          lines.zip(running(lines)).take_while { |_, total| total <= room }
        end

        # What could not be said, said once -- and charged, when there is room
        # for the sentence itself.
        def notice(count)
          return unless count.positive? && @left >= reserve(count)

          charge(reserve(count))
          format(ELIDED, count:)
        end

        def charge(bytes) = @left -= bytes

        # The notice costs bytes too, and reserving them BEFORE the lines are
        # taken is what makes the budget a BOUND rather than a target: charged
        # afterwards it can only be charged once the overrun has happened. It
        # is reserved on the widest count the slot could report, so the reserve
        # can never be short, and given back unspent when nothing was elided.
        #
        # A slot with no room even for its own notice is therefore EMPTY rather
        # than over budget. That is not a silent loss: an earlier slot has
        # already said the history did not fit, which is the same sentence this
        # one would have written.
        def reserve(count) = count.zero? ? 0 : format(ELIDED, count:).bytesize + 1

        # The cumulative cost of taking each line AND every line before it, so
        # the cut is a `take_while` over a plain comparison rather than a fold
        # with a flag in it.
        def running(lines)
          lines.inject([]) { |totals, line| totals + [(totals.last || 0) + line.bytesize + 1] }
        end
      end
    end
  end
end
