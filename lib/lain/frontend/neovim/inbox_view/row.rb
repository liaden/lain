# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      class InboxView
        # One listed set, drawn. Separate from {InboxView} because "what a
        # pending question looks like on screen" is a rule of its own -- and
        # because that class was over `Metrics/ClassLength` carrying it, the
        # same cop that named {Renderings} and {CommandInbox} before it.
        #
        # It draws and nothing else: no clock (the age arrives resolved, so this
        # object cannot race one), no store, no lock. Every constant it reads --
        # {InboxView::WIDTH}, {INDENT}, {ELISION}, {BODY} -- is the enclosing
        # view's, because they are the buffer's conventions rather than one
        # row's, and the runtime is pinned against that one spelling of them.
        class Row
          # @param item [InboxView::Item] the listed set
          # @param age [String] how long it has sat here, already rendered
          def initialize(item, age:)
            @item = item
            @age = age
          end

          # ONE LINE EXACTLY WHEN THAT LINE IS THE WHOLE ITEM. Anything else --
          # a question the announcement already cut, a set whose further
          # questions the summary only COUNTS, a row wider than {WIDTH} -- draws
          # the summary with its cut marked and the whole row underneath it,
          # indented, folded away at rest.
          #
          # NOTHING BOUNDS THE FOLD, and a reader deciding whether to bound it
          # should start here (carried as a follow-up, not fixed in the card that
          # found it -- a bound is a design decision about what a human is allowed
          # to be shown, not a repair). {#whole} is built on EVERY render just to
          # decide this height, and it is the whole set: a 60KB question draws ~655
          # indented lines, and {Question::Set::MAX_SET} permits roughly 2800. The
          # cost is real but it is not the reason to look -- {ApprovalView}'s
          # precedent does not cover it, because a command's `input.inspect` is
          # incidentally short while {Tools::AskHuman}'s own docstring INVITES
          # tables and fenced diffs into a question body. Three ways out, none
          # free: clamp the body (loses the verbatim guarantee {#whole} rests on),
          # clamp only what is DRAWN while the document keeps everything (two
          # truths on one screen), or leave it unbounded and let the fold hide it
          # (today, and it is only tolerable because the fold is closed at rest).
          # @return [Array<String>]
          def lines
            return [summary] if summary == whole && summary.length <= WIDTH

            [elided] + body
          end

          private

          # Sender and age lead, mirroring the TTY drain's listing: a glance
          # answers "who is stuck, and for how long" before the question reads.
          #
          # A summary must never OPEN with {INDENT}, which is why the `lstrip`
          # is here and is not tidying ({ApprovalView#summary_for}'s invariant,
          # for its reason): that prefix is the runtime's whole test for a
          # continuation line, so a record naming NOBODY would draw a row the
          # fold surface reads as part of the item above it -- and the `<CR>`
          # walk would then answer that item's set.
          def summary = @summary ||= drawn(@item.question)

          # THE WHOLE ITEM, as one line before it is wrapped: the same sender
          # and age columns the summary shows, and every question the set asks
          # VERBATIM, rather than the announcement's one-line summary of them.
          #
          # THE INVARIANT, STATED AS NARROWLY AS IT IS TRUE: nothing the summary
          # elided is missing from the ITEM, because this line carries the whole
          # of it and {#lines} always draws this line when {#summary} is not it.
          # That is the safety property, and it is the only one worth relying on.
          #
          # It is NOT the stronger claim an earlier draft of this comment made,
          # that the summary is a cut PREFIX of the body. That relation holds for
          # the common row -- one question, its headline the body's own first line
          # -- and a review found the two shapes where it does not hold. First,
          # any set of more than one question: the summary ends in
          # {Announcement}'s `(+N more)`, which is arithmetic and appears nowhere
          # in the body. Second, a body whose headline is not where the collapsed
          # body starts -- and the obvious guess for that one is WRONG, which is
          # why it is spelled out: a FENCED body does not do it, because the fence
          # is the first line and so heads both renderings. What does it is the
          # gap between two definitions of "nothing" -- {Blankness} counts U+200B
          # blank, so {Announcement#headline} skips a line of it, while Ruby's
          # `String#strip` removes only ASCII whitespace, so {#prose} keeps it.
          # The summary then names the second line while the body still opens with
          # the first. Both shapes are pinned in inbox_view_spec, asserting the
          # safety property AND asserting the prefix relation is absent -- so the
          # narrower claim is a thing a reader can check rather than believe.
          #
          # THE SENDER AND AGE ARE REPEATED UNDER THE SUMMARY DELIBERATELY, and
          # they are the reason the cut is checkable at all: the body is the same
          # row drawn the same way, so a reader comparing the two lines is
          # comparing like with like. Drawing the body from the question alone
          # would save one repetition and cost that.
          def whole = @whole ||= drawn(questions)

          # EVERY FIELD THE RECORD SUPPLIES GOES THROUGH {#prose}, sender included.
          # The sender is here because a rendered newline is a known-shape defect in
          # this repo rather than a hypothesis (T17/F17: nvim refuses a line holding
          # one, the render rides as a NOTIFY, and the buffer silently stops taking
          # writes) -- and because scrubbing it makes the EDITOR more dependable, not
          # less: `RECORD_START[INBOX]` and 70_inbox.lua's `inbox_row` both find a row
          # by the two-space-padded `from  age  question` shape, and a `from` that
          # could carry a newline is exactly what makes that shape unreliable.
          #
          # Scrubbed BEFORE the {SENDER} clamp, so the clamp measures what is drawn.
          # The age needs no rule and gets none: it is this view's own arithmetic over
          # two Times, never a record's bytes.
          def drawn(text) = "#{prose(@item.from)[0, SENDER]}  #{@age}  #{prose(text)}".lstrip

          # Every question of the set the record carries, in the order it asks
          # them. {Tools::AskHuman} merges {Question::Set#to_body} into the
          # event body beside the one-line `"question"` summary, so the full
          # prose is already here and no announcement has to widen for this view
          # to show it. A body that is no set at all -- a bare
          # `{"question" => ...}` from before sets existed, or one whose
          # questions are malformed -- falls back to that summary.
          #
          # PERMISSIVE WHERE {Gestures#rebuilt} IS STRICT, and the difference is
          # deliberate rather than an oversight: a malformed set that cannot be
          # OPENED must say so ({Question::Set.from_body} raising, reported as
          # UNREADABLE), while a malformed set that cannot be fully DRAWN must
          # still list -- a row that vanished would hide a human's own pending
          # question. That is two readers of one wire shape, which is a real
          # smell; merging them is a bigger change than the card that split them.
          def questions
            listed = asked.filter_map { |question| question["body"] if question.is_a?(Hash) }
            joined = listed.map { |body| prose(body) }.join(" ")
            Blankness.blank?(joined) ? @item.question : joined
          end

          def asked
            listed = @item.body["questions"]
            listed.is_a?(Array) ? listed : []
          end

          # A rendered LINE may not carry a newline: `nvim_buf_set_lines`
          # refuses one and the render rides as a notify, so a view that emits
          # one loses every later write to its buffer in silence (T17/F17). The
          # wrap {BODY} does is this object's own; a record's newlines are
          # collapsed before it.
          #
          # THE STRIP IS LOAD-BEARING, and it is {Tools::AskHuman::Announcement
          # #headline}'s own -- that method strips each line, so the summary this
          # view is handed already has, while {Question} keeps the body's bytes
          # verbatim ({Rules.prose}). Without the same strip here a question
          # ending in a newline made {#whole} differ from {#summary} by one
          # trailing space -- manufacturing a two-line item, and a keys line for
          # the whole list, out of whitespace no human can see. The review that
          # found it was right that the specs which stayed green were a fixture
          # accident until this line existed.
          def prose(text) = text.to_s.gsub(NEWLINES, " ").strip

          def elided = summary.length <= WIDTH ? summary : summary[0, WIDTH - ELISION.length] + ELISION

          def body = whole.scan(BODY).map { |part| INDENT + part }
        end
      end
    end
  end
end
