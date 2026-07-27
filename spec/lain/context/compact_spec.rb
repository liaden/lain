# frozen_string_literal: true

RSpec.describe Lain::Context::Compact do
  def text(body) = [{ "type" => "text", "text" => body }]

  def message(role, body)
    { "role" => role, "content" => text(body) }
  end

  let(:messages) do
    [
      message("user", "a" * 200),
      message("assistant", "b" * 200),
      message("user", "c" * 200),
      message("assistant", "d" * 200)
    ]
  end

  let(:summarizer) { ->(dropped) { "summary of #{dropped.size} turns" } }

  it "is a no-op under threshold" do
    compact = described_class.new(threshold: 1_000_000, keep_last: 1, summarizer:)
    expect(compact.call(messages)).to eq(messages)
  end

  it "replaces the dropped head with one summary turn, keeping the tail intact" do
    compact = described_class.new(threshold: 10, keep_last: 1, summarizer:)
    result = compact.call(messages)

    expect(result.size).to eq(2)
    expect(result.first["content"].first["text"]).to eq("summary of 3 turns")
    expect(result.last).to eq(messages.last)
  end

  it "calls the summarizer with exactly the dropped messages" do
    seen = nil
    compact = described_class.new(threshold: 10, keep_last: 1, summarizer: lambda { |dropped|
      seen = dropped
      "s"
    })
    compact.call(messages)
    expect(seen).to eq(messages[0..-2])
  end

  it "is pure: identical input yields identical output (the summarizer must be too)" do
    compact = described_class.new(threshold: 10, keep_last: 1, summarizer:)
    expect(compact.call(messages)).to eq(compact.call(messages))
  end

  # #requires is an enforcement contract, not a comparison label. Compact
  # summarizes entirely client-side via the injected summarizer, so it needs
  # nothing from the provider -- and declaring :server_compaction would make
  # Capability::Policy wrongly raise (:strict) or journal a false degradation
  # (:degrade) on exactly the providers lacking native compaction, which is
  # when you reach for client-side Compact.
  it "requires nothing from the provider -- it is a client-side summarizer" do
    compact = described_class.new(threshold: 10, keep_last: 1, summarizer:)
    expect(compact.requires).to eq([])
  end

  it "composes with other combinators via >>" do
    require "lain/context/base"
    composed = described_class.new(threshold: 10, keep_last: 1, summarizer:) >> Lain::Context::Identity
    expect(composed.call(messages).size).to eq(2)
  end

  # T4. What this combinator renders has to be a conversation the Messages API
  # accepts. Grounding F1 measured the shipped one ASSISTANT-first at every
  # keep_last, and non-alternating at every even one; F2 measured it splitting
  # tool pairs. {Lain::Context::Conversation} is the assertion here and nowhere
  # else -- it is deliberately not wired into the render path, because a
  # repairing or raising validator would hide the producer bug rather than name
  # it (T1's ruling). The producer is what got fixed.
  describe "the rendered conversation" do
    def alternating(count)
      (1..count).map { |index| message(index.odd? ? "user" : "assistant", "turn #{index}") }
    end

    # An assistant tool_use turn answered by a user tool_result turn, which is
    # the only shape {Agent#perform_tools} commits (Correctness gate 2).
    def tool_heavy(rounds)
      [message("user", "start")] + (1..rounds).flat_map do |round|
        [{ "role" => "assistant",
           "content" => [{ "type" => "tool_use", "id" => "toolu_#{round}", "name" => "grep", "input" => {} }] },
         { "role" => "user",
           "content" => [{ "type" => "tool_result", "tool_use_id" => "toolu_#{round}", "content" => "ok" }] }]
      end
    end

    def timeline_of(history)
      history.inject(Lain::Timeline.empty(store: Lain::Store.new)) do |timeline, entry|
        timeline.commit(role: entry["role"], content: entry["content"])
      end
    end

    def violations(rendered) = Lain::Context::Conversation.new(rendered).violations

    # The composed production pipeline, in {Compaction::Scheduler::COMPOSE}'s
    # order -- Compact ahead of Reminder and CacheBreakpoints -- rendered
    # through the real {Context#render} rather than by calling the combinator,
    # because that composition is what F1 measured invalid.
    def rendered_through(compact, history)
      Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024,
                        pipeline: ->(workspace) { compact >> Lain::Context.pipeline(workspace) })
                   .render(timeline: timeline_of(history), toolset: Lain::Toolset.new).messages
    end

    def compacting(keep_last, pins = Lain::Context::ProtectedPatterns::NONE)
      described_class.new(threshold: 1, keep_last:, summarizer:, protected_patterns: pins)
    end

    # Scenario: a compacted render is a valid conversation at the shipped default
    it "is valid at the shipped default keep_last of 20" do
      rendered = rendered_through(compacting(20), alternating(41))

      expect(violations(rendered)).to be_empty
      expect(rendered.size).to be < 41
    end

    # Scenario: validity holds across every keep_last, odd and even
    it "is valid at every keep_last, odd and even" do
      history = alternating(41)

      (1..history.size).each do |keep_last|
        expect(violations(rendered_through(compacting(keep_last), history)))
          .to be_empty, "keep_last=#{keep_last}"
      end
    end

    # Scenario: a compacted tool-heavy render leaves no orphaned tool blocks
    it "leaves no unanswered tool_use and no orphaned tool_result, at every keep_last" do
      history = tool_heavy(12)

      (1..history.size).each do |keep_last|
        found = violations(rendered_through(compacting(keep_last), history)).map(&:rule)

        expect(found).to be_empty, "keep_last=#{keep_last} #{found.inspect}"
      end
    end

    # The Open decisions ruling, pinned: one role, decided once, never computed
    # from history parity. An assistant summary is what made messages[0] invalid
    # at EVERY keep_last (F1), so the role cannot be a function of anything.
    it "emits its summary as a user message whatever the history's parity" do
      (1..8).each do |keep_last|
        rendered = compacting(keep_last).call(alternating(9))

        expect(rendered.first["role"]).to eq("user"), "keep_last=#{keep_last}"
      end
    end

    # Scenario: a pinned message keeps its neighbours (F3). The hoist put a pin
    # from the middle of the span at index 0, ahead of the summary of everything
    # that PRECEDED it -- reading order inverted, and its predecessor gone.
    it "leaves a pinned message after the summary of what preceded it, not ahead of it" do
      history = alternating(9)
      pinned = history[4]
      pins = Lain::Context::PinnedMessages.new([pinned])
      rendered = compacting(3, pins).call(history)

      expect(rendered.first["content"].first["text"]).to start_with("summary of")
      expect(rendered[1]).to eq(pinned)
      expect(rendered.drop(2)).to eq(history.drop(history.index(pinned) + 1).last(rendered.size - 2))
    end

    # Scenario: pinning everything droppable declines rather than emitting an
    # empty summary. {Compaction::Source} already declines a turn whose head is
    # empty, but Compact is reachable from the bench arm directly -- and a
    # summary of NOTHING costs a full cache break to add bytes.
    it "declines byte-identically when every droppable message is pinned" do
      history = alternating(9)
      pins = Lain::Context::PinnedMessages.new(history.take(6))
      compact = compacting(3, pins)

      expect(Lain::Canonical.dump(compact.call(history))).to eq(Lain::Canonical.dump(history))
      expect(compact.call(history)).to eq(history)
    end

    # A boundary that DECLINES (the only legal cut is 0) is not an ordinary
    # empty span, and it must not become one here: the render is byte-identical
    # rather than a summary of nothing followed by a tail sliced off index 0.
    it "declines byte-identically when the boundary declines" do
      history = [{ "role" => "assistant",
                   "content" => [{ "type" => "tool_use", "id" => "t0", "name" => "read", "input" => {} }] },
                 { "role" => "user",
                   "content" => [{ "type" => "tool_result", "tool_use_id" => "t0", "content" => "ok" }] },
                 message("assistant", "fin")]
      rendered = compacting(2).call(history)

      expect(Lain::Compaction::Boundary.new(messages: history, keep_last: 2)).to be_declined
      expect(Lain::Canonical.dump(rendered)).to eq(Lain::Canonical.dump(history))
    end

    # CHARACTERIZATION OF A KNOWN DEFECT, not a desired behaviour. Every other
    # example in this block runs with pins OFF, and that is the honest scope of
    # the validity claim: {Compaction::Boundary} protects the CUT, but a pin
    # punches a hole in the MIDDLE of the span and nothing looks at that hole.
    # Pin a `tool_use` turn and it survives while the `tool_result` answering it
    # is summarized away -- F1 and F2 reconstituted, on the pinned path only.
    # Measured through the real {Compaction::Source} at the shipped
    # `keep_last: 20`; swept at this level, 780 introduced `unanswered_tool_use`
    # and 780 `orphaned_tool_result` across 20,060 cells.
    #
    # It is pinned rather than fixed because the fix is a decision about what a
    # PIN MEANS -- a pin that would strand its counterpart either drags the
    # counterpart along or is dropped with it -- and that decision is not T4's.
    # This is the repo's own idiom for a property that cannot yet be made
    # structural (`chunk-compaction-tiers-pins-isolation.md`'s A5). It is not a
    # regression: the rule this replaced never covered the pinned path either.
    #
    # WHEN THE PIN SEMANTICS ARE DECIDED, this example must go red and be
    # deleted -- a characterization spec that keeps passing after its defect is
    # fixed has become a spec FOR the defect.
    it "still strands a tool_result whose pinned tool_use survives -- a known defect, characterized" do
      history = [message("user", "ask"),
                 { "role" => "assistant",
                   "content" => [{ "type" => "tool_use", "id" => "toolu_1", "name" => "grep", "input" => {} }] },
                 { "role" => "user",
                   "content" => [{ "type" => "tool_result", "tool_use_id" => "toolu_1", "content" => "ok" }] },
                 message("assistant", "reply"), message("user", "next"), message("assistant", "fin")]
      pins = Lain::Context::PinnedMessages.new([history[1]])
      found = violations(compacting(2, pins).call(history)).map(&:rule)

      expect(found).to include(:unanswered_tool_use)
      expect(violations(compacting(2).call(history))).to be_empty
    end

    # Scenario: Head and Compact still agree on what is droppable -- the other
    # half of the sweep in `spec/lain/compaction/head_spec.rb`, asserted here
    # over the alternating shapes the boundary actually snaps.
    it "removes exactly the messages the Head names, at every keep_last" do
      history = alternating(12)

      (1..history.size).each do |keep_last|
        head = Lain::Compaction::Head.new(messages: history, keep_last:)
        seen = :summarizer_never_called
        described_class.new(threshold: 1, keep_last:,
                            summarizer: ->(dropped) { (seen = dropped) && "s" }).call(history)
        expected = head.empty? ? :summarizer_never_called : head.messages

        expect(seen).to eq(expected), "keep_last=#{keep_last}"
      end
    end
  end
end
