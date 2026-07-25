# frozen_string_literal: true

# B1: `/pin [digest]` marks a turn so compaction may not elide it, and
# `/unpin [digest]` takes the mark off. Both are zero-model-turn commands over
# the SAME resolution `/rewind` uses -- hex-only below a full "blake3:" scheme,
# unique or refuse -- resolved against THIS session's live render chain. A
# refusal happens before anything is recorded: a bad target pins nothing.
RSpec.describe Lain::CLI::Command::Pin do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:provider) { Lain::Provider::Mock.new(responses: [text_response("one"), text_response("two")]) }
  let(:session) { Lain::Session.new }

  # Two settled asks: user/assistant/user/assistant, four committed turns.
  let(:agent) do
    Lain::Agent.new(provider:, toolset:, context:, session:).tap do |built|
      built.ask("first")
      built.ask("second")
    end
  end
  let(:env) { instance_double(Lain::CLI::Command::Env, agent:) }

  subject(:command) { described_class.new }

  def hex(digest) = digest.delete_prefix("blake3:")

  def assistant_heads
    agent.timeline.ancestors.select { |turn| turn.role == "assistant" }
  end

  it "is the /pin command and describes itself" do
    expect(command.name).to eq("pin")
    expect(command.usage).to include("/pin")
  end

  # AC7: /pin with no argument pins the last assistant turn.
  describe "bare /pin" do
    it "pins the last assistant turn and names it in the reply" do
      target = assistant_heads.first.digest

      text = command.call("", env)

      expect(session.pinned?(target)).to be(true)
      expect(session.pins).to eq([target])
      expect(text).to include("pinned").and include(hex(target)[0, 8])
    end

    it "refuses on a session with no committed turns, and pins nothing" do
      empty = Lain::Agent.new(provider:, toolset:, context:, session:)

      expect { command.call("", instance_double(Lain::CLI::Command::Env, agent: empty)) }
        .to raise_error(Lain::Error, /no committed turns/)
      expect(session.pins).to eq([])
    end
  end

  # AC8: /pin with a digest prefix pins that turn.
  describe "/pin <prefix>" do
    it "pins the turn matching a bare hex prefix" do
      target = agent.timeline.ancestor_digests.last

      command.call(hex(target)[0, 8], env)

      expect(session.pinned?(target)).to be(true)
    end

    it "accepts a fully-schemed prefix too" do
      target = agent.timeline.head_digest

      command.call(target[0, 15], env)

      expect(session.pinned?(target)).to be(true)
    end

    # /rewind's rule, restated: a partial scheme spelling would otherwise match
    # every digest through the scheme string.
    it "refuses a partial scheme spelling rather than matching every turn" do
      expect { command.call("blak", env) }.to raise_error(Lain::Error, /no turn matching/)
      expect(session.pins).to eq([])
    end
  end

  # Fix 1, the blocker. `/pin 3` reads as /rewind's "three turns back" to any
  # operator, and used to pin whatever turn's digest happened to start with "3"
  # -- reporting SUCCESS. Under B2 that means the wrong turn survives
  # compaction and the intended one is elided. Two halves: a minimum prefix
  # length so no plausible count reaches the matcher, and a refusal that says
  # outright that /pin takes no count.
  describe "a count-shaped argument" do
    # Exhaustive over the digits, on a chain whose four digests between them
    # start with several of them -- the probe found 40/40 such arguments
    # silently pinning a turn.
    it "refuses EVERY single digit, on every chain, and pins nothing" do
      ("0".."9").each do |digit|
        expect { command.call(digit, env) }
          .to raise_error(Lain::Error, /too short/), "#{digit.inspect} was not refused"
      end
      expect(session.pins).to eq([])
    end

    it "refuses two- and three-character arguments -- a turn count never reaches the matcher" do
      %w[1 12 123].each do |argument|
        expect { command.call(argument, env) }.to raise_error(Lain::Error, /too short/)
      end
      expect(session.pins).to eq([])
    end

    it "says explicitly that /pin takes no turn count, so the operator learns the grammar" do
      expect { command.call("3", env) }.to raise_error(Lain::Error, /names a turn, not a count/)
    end

    # The length guard cannot catch a four-digit argument that is also a real
    # prefix, so the MESSAGE has to teach on the unmatched path too.
    it "names the no-count grammar on an unmatched longer numeric argument as well" do
      expect { command.call("999999999", env) }
        .to raise_error(Lain::Error, /names a turn, not a count/)
    end

    it "still accepts a legitimate four-character prefix -- the guard is a floor, not a ban" do
      target = agent.timeline.head_digest

      command.call(hex(target)[0, 4], env)

      expect(session.pinned?(target)).to be(true)
    end
  end

  # AC9: an unmatched prefix refuses loudly and pins nothing. The Repl's
  # boundary renderer turns the raised Lain::Error into the reply, exactly as
  # it does for /rewind's refusals.
  describe "an unmatched or ambiguous prefix" do
    it "refuses loudly and records nothing" do
      expect { command.call("deadbeef", env) }
        .to raise_error(Lain::Error, /no turn matching "deadbeef"/)
      expect(session.pins).to eq([])
    end

    it "refuses an ambiguous prefix by naming the candidates" do
      expect { command.call("", env) }.not_to raise_error
      session.record_unpin(agent.timeline.head_digest)

      expect { command.call("blake3:", env) }.to raise_error(Lain::Error, /ambiguous/)
    end
  end
end

RSpec.describe Lain::CLI::Command::Unpin do
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "be terse") }
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:provider) { Lain::Provider::Mock.new(responses: [text_response("one")]) }
  let(:session) { Lain::Session.new }
  let(:agent) { Lain::Agent.new(provider:, toolset:, context:, session:).tap { |built| built.ask("first") } }
  let(:env) { instance_double(Lain::CLI::Command::Env, agent:) }

  subject(:command) { described_class.new }

  it "is the /unpin command and describes itself" do
    expect(command.name).to eq("unpin")
    expect(command.usage).to include("/unpin")
  end

  it "takes the pin off the turn a prefix names, through the SAME resolution /pin uses" do
    target = agent.timeline.head_digest
    session.record_pin(target)

    text = command.call(target.delete_prefix("blake3:")[0, 8], env)

    expect(session.pinned?(target)).to be(false)
    expect(text).to include("unpinned")
  end

  it "unpins the last assistant turn on a bare /unpin" do
    target = agent.timeline.ancestors.find { |turn| turn.role == "assistant" }.digest
    session.record_pin(target)

    command.call("", env)

    expect(session.pins).to eq([])
  end

  it "refuses an unmatched prefix rather than silently unpinning nothing" do
    expect { command.call("deadbeef", env) }.to raise_error(Lain::Error, /no turn matching/)
  end

  # Fix 4: this command's own comment says an operator must not read silence as
  # success for a mistyped digest. A CORRECTLY typed digest that was never
  # pinned got exactly that -- "unpinned ... compaction may elide this turn
  # again", over a session with no pins at all.
  describe "a resolvable turn that was never pinned" do
    it "says it was not pinned instead of claiming a release" do
      text = command.call("", env)

      expect(text).to include("was not pinned")
      expect(text).not_to include("unpinned")
    end

    it "journals nothing for the no-op, so the replay log stays free of empty retractions" do
      journal_io = StringIO.new
      journaled = Lain::Session::Journaled.new(session:, journal: Lain::Journal.new(io: journal_io))
      wired = instance_double(Lain::CLI::Command::Env,
                              agent: instance_double(Lain::Agent, timeline: agent.timeline, session: journaled))

      command.call("", wired)

      expect(journal_io.string).to be_empty
    end
  end

  it "still refuses a count-shaped argument, through the same shared resolver" do
    expect { command.call("2", env) }.to raise_error(Lain::Error, /names a turn, not a count/)
  end
end
