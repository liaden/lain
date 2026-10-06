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

      # The most of the budget one human turn may take whole: its line is
      # offered whole only while it is at most this fraction of the question.
      # At the conservative window that is 964 bytes, which holds a typed
      # paragraph, measured at about 800 bytes, while a pasted log is cut to
      # its line and leaves the rest of the budget to the work. The
      # share scales with the window, so a larger one keeps longer turns whole.
      WHOLE_SHARE = 8

      # The key that marks a message in the earlier slot as a held
      # replacement. A replacement is a user text turn, the same shape as the
      # human's own words, and only this tells the question which is which.
      SUMMARY = "summary"

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
                   held: "Earlier in this conversation, oldest first:",
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
      # What every slot leaves then makes whole lines out of cut ones: the
      # span's first, since it is the work in progress, then the earlier
      # slot's, where an opening request would otherwise stay cut.
      #
      # @param document [String, nil] the state the last handoff wrote, if any,
      #   exactly as its cut recorded it
      # @param held [Array<Hash>] the history before the newest cut, oldest
      #   first: each held replacement, and each turn no cut covered in its place
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
        taken[:held] = left.widen(taken.fetch(:held))
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

      # A user turn of nothing but text, unless it is marked {SUMMARY}.
      #
      # @param message [Hash] a canonical-normalized projection
      # @return [Boolean]
      def human?(message)
        message.fetch("role") == "user" && !message[SUMMARY] && blocks(message).all? { |block| block["type"] == "text" }
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
      # Within a slot the human's own turns are bought first, then the rest,
      # and within each the NEWEST survive. The human's words are what the work
      # is for, and a directive lost to forty tool stubs is the one thing the
      # handoff cannot recover; among turns of a kind, a budget spent
      # oldest-first would hand back the opening and drop the part being worked
      # on. What survives is rendered oldest first even so, because that is
      # how a conversation reads.
      class Budget
        # One slot as {Budget#take} afforded it: lines, messages and their
        # source positions in the order the budget bought them, and the notice
        # already paid for.
        Section = Data.define(:heading, :notice, :lines, :messages, :positions) do
          # The heading, then the lines oldest first under the notice; "" when
          # nothing fits or there was nothing to say, because a heading over
          # nothing is worse than silence.
          #
          # @return [String]
          def to_s
            return "" if lines.empty?

            "#{heading}\n\n#{[notice, *in_source_order].compact.join("\n")}\n"
          end

          private

          def in_source_order = lines.zip(positions).sort_by(&:last).map(&:first)
        end

        ELIDED = "[%<count>d turn(s) elided: they did not fit this question]"

        def initialize(bytes)
          @left = bytes
          @whole_at_most = bytes / WHOLE_SHARE
        end

        # @param messages [Array<Hash>] canonical-normalized projections
        # @param heading [String] what this section is called
        # @return [Section] the lines that fit, in the order they were
        #   bought, with the notice for those that did not
        def take(messages, heading:)
          order = priority(messages)
          afforded = affordable(order.map { |position| forms(messages.fetch(position)) }, heading)
          return Section.new(heading:, notice: nil, lines: [], messages: [], positions: []) if afforded.empty?

          charge(afforded.last.last + heading.bytesize + 2)
          bought(heading, messages, order, afforded)
        end

        # The turns of a section, in the order {#take} bought them, made whole
        # out of what every slot left AFTER it was afforded at cut length. A
        # second pass and never part of {#take}, so it cannot spend room
        # another slot or the elided notice was owed.
        #
        # @param section [Section]
        # @return [Section]
        def widen(section)
          section.with(lines: section.lines.zip(section.messages)
                                     .map { |short, message| upgraded(short, Handoff.whole(message)) })
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

        def bought(heading, messages, order, afforded)
          kept = order.first(afforded.size)
          Section.new(heading:, notice: notice(order.size - afforded.size), lines: afforded.map(&:first),
                      messages: messages.values_at(*kept), positions: kept)
        end

        def priority(messages)
          messages.each_index.sort_by { |position| [Handoff.human?(messages.fetch(position)) ? 0 : 1, -position] }
        end

        # Per line rather than a prefix, so one newer line too large to make
        # whole does not keep an older one that fits from being made whole.
        def upgraded(short, whole)
          cost = whole.bytesize - short.bytesize
          return short if cost > @left

          charge(cost)
          whole
        end

        # The heading and its blank line are reserved with the notice, for the
        # notice's reason: a section's own furniture is part of what the budget
        # bounds, or the bound is only about the lines inside it.
        def affordable(choices, heading)
          room = @left - reserve(choices.size) - heading.bytesize - 2
          priced(choices, room).take_while(&:first)
        end

        # Whole before cut, so a directive stays whole while it fits rather
        # than only if room is left over once every tool stub was bought. Past
        # {WHOLE_SHARE} it is offered cut only: a pasted log is a human turn too.
        def forms(message)
          short = Handoff.line(message)
          whole = Handoff.whole(message)
          Handoff.human?(message) && whole.bytesize <= @whole_at_most ? [whole, short] : [short]
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

        # Each turn's first form that fits beside every turn before it, with
        # the running cost; nil where none fits, so the cut is a `take_while`
        # rather than a fold with a flag in it.
        def priced(choices, room)
          choices.inject([]) do |bought, forms|
            spent = bought.last&.last || 0
            line = forms.find { |form| spent + form.bytesize + 1 <= room }
            bought + [[line, spent + (line ? line.bytesize + 1 : 0)]]
          end
        end
      end
    end
  end
end
