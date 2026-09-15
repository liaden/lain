# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Middleware::WithholdAutomaticOutput do
  subject(:guard) { described_class.new(bar:, journal:) }

  let(:bar) { described_class::Bar.new }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:key) do
    "-----BEGIN OPENSSH PRIVATE KEY-----\n" \
      "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n" \
      "QyNTUxOQAAACBkSFTHQQ+dpqPdxkFGgYj9bzDbArQV711eUcx0p2x/BAAAAJiFPjsMhT47\n" \
      "-----END OPENSSH PRIVATE KEY-----\n"
  end
  let(:printed) { Lain::Tool::Result.ok("exit status: 0\n--- stdout ---\n#{key}--- stderr ---\n") }

  def call_of(command, name: "bash", id: "tu_1")
    Lain::Effect::ToolCall.new(tool_use_id: id, name:, input: { "command" => command })
  end

  def ruling(authority) = Lain::Approval::Escalation::Ruling.allow(rung: "spec", because: "spec", authority:)

  # The block stands where the gate and the interpreter stand: it may rule on
  # the context it was handed, and it answers the result.
  def run(effect, result: printed, authority: nil, context: :the_session)
    seen = []
    env = guard.call({ effect:, context:, tool: Lain::Tools::Bash.new }) do |inner|
      seen << inner.fetch(:context)
      inner.fetch(:context).ruled(ruling(authority)) if authority
      inner.merge(result:)
    end
    [env, seen.first]
  end

  def withheld = Lain::Journal.records(journal_io.string.lines, type: "automatic_output_withheld").to_a

  describe "an automatically approved command that printed a credential" do
    it "answers a refusal naming the region count, never the bytes" do
      env, = run(call_of("cat notes.txt"), authority: :automatic)

      expect(env.fetch(:result)).to have_attributes(is_error: true)
      expect(env.fetch(:result).content).to include("1 credential-shaped region")
      expect(env.fetch(:result).content).not_to include("PRIVATE KEY")
    end

    # Under `auto` nobody is asked, so the refusal must not promise a human:
    # it says what the command now needs, whichever approval level is in force.
    it "says the command now needs a human's approval, promising no human" do
      env, = run(call_of("cat notes.txt"), authority: :automatic)

      expect(env.fetch(:result).content).to include("now needs a human's approval")
      expect(env.fetch(:result).content).not_to include("will be asked")
    end

    it "bars the command string from automatic approval" do
      run(call_of("cat notes.txt"), authority: :automatic)

      expect(bar.include?("cat notes.txt")).to be(true)
    end

    it "records the call and the count, with no bytes" do
      run(call_of("cat notes.txt", id: "tu_9"), authority: :automatic)

      expect(withheld).to contain_exactly(include("tool_use_id" => "tu_9", "regions" => 1))
      expect(withheld.first.keys).to contain_exactly("ts", "type", "tool_use_id", "regions")
    end

    it "journals a record that stays Ractor-shareable over an unfrozen id" do
      record = described_class::AutomaticOutputWithheld.new(tool_use_id: +"tu_9", regions: 1)

      expect(Ractor.shareable?(record)).to be(true)
    end

    it "counts every region the output held" do
      env, = run(call_of("cat notes.txt"), authority: :automatic,
                                           result: Lain::Tool::Result.ok("#{key}\nfiller line\n\n#{key}"))

      expect(env.fetch(:result).content).to include("2 credential-shaped regions")
    end

    it "treats a call no ladder ruled on as automatic" do
      env, = run(call_of("cat notes.txt"))

      expect(env.fetch(:result).content).to include("withheld")
    end

    it "still answers the call when the journal refuses the record" do
      closed = Class.new { def <<(_entry) = raise(IOError, "closed") }.new

      unjournaled = described_class.new(bar:, journal: closed)

      env = unjournaled.call({ effect: call_of("cat notes.txt"), context: nil }) { _1.merge(result: printed) }

      expect(env.fetch(:result).content).to include("withheld")
    end
  end

  describe "a call that passes untouched" do
    it "returns a human-approved command's bytes unchanged, and bars nothing" do
      env, = run(call_of("cat notes.txt"), authority: :human)

      expect(env.fetch(:result)).to be(printed)
      expect(bar.include?("cat notes.txt")).to be(false)
      expect(withheld).to be_empty
    end

    it "returns ordinary output approved automatically unchanged" do
      listing = Lain::Tool::Result.ok("exit status: 0\n--- stdout ---\nnotes.txt\n--- stderr ---\n")

      env, = run(call_of("ls"), result: listing, authority: :automatic)

      expect(env.fetch(:result)).to be(listing)
      expect(bar.include?("ls")).to be(false)
    end

    it "leaves a tool it does not guard, and its context, alone" do
      read = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file", input: { "path" => "notes.txt" })

      env, seen = run(read)

      expect(env.fetch(:result)).to be(printed)
      expect(seen).to be(:the_session)
    end
  end

  describe "the context a guarded call runs under" do
    it "answers every message the caller's context answers" do
      _, seen = run(call_of("ls"), context: "the session")

      expect(seen.upcase).to eq("THE SESSION")
    end

    it "says a command is barred once its output was withheld" do
      run(call_of("cat notes.txt"), authority: :automatic)

      _, seen = run(call_of("cat notes.txt"), authority: :human)

      expect(seen.automatic_approval_barred?).to be(true)
    end

    it "says nothing is barred for a command that never printed a credential" do
      _, seen = run(call_of("ls"))

      expect(seen.automatic_approval_barred?).to be(false)
    end

    # A bare caller threads no session, and a tool below reads one: the null
    # session stands in, where a delegator over nil would answer nothing.
    it "stands the null session in for a caller that threads none" do
      _, seen = run(call_of("ls"), context: nil)

      expect(seen.__getobj__).to be(Lain::Session::Null.instance)
    end

    it "hands the caller's own context back up the stack" do
      env, = run(call_of("ls"))

      expect(env.fetch(:context)).to be(:the_session)
    end
  end
end
