# frozen_string_literal: true

RSpec.describe Lain::Tool::RoundBudget do
  let(:read_file) { Lain::Tools::ReadFile.new }
  # Any tool that keeps the default stands in for subagent here: what keeps a
  # result from being withheld is that the tool cannot be asked again cheaply.
  let(:subagent) do
    Class.new(Lain::Tool) do
      def name = "subagent"
      def description = "test double: a tool whose call cannot be repeated"
    end.new
  end

  def result(id, content, is_error: false)
    { "type" => "tool_result", "tool_use_id" => id, "content" => content, "is_error" => is_error }
  end

  def room(window:, usage: Lain::Usage.zero, ceiling: 16_384) = Lain::Tool::Room.new(window:, usage:, ceiling:)

  def call(id, tool = read_file) = described_class::Call.new(id:, tool:)

  def round26
    described_class.window.for(head: "blake3:asked") do
      room(window: 32_768, usage: Lain::Usage.new(input_tokens: 7_492))
    end
  end

  def bounded(budget, blocks, calls)
    records = []
    delivered = budget.call(blocks, calls) { |record| records << record }
    [delivered, records]
  end

  describe "results masked to the same placeholder" do
    def answered_pair(content)
      delivered, = bounded(round26, [result("tu_1", content), result("tu_2", content)], [call("tu_1"), call("tu_2")])
      delivered.map { |block| block["content"] }
    end

    it "delivers both, since the same mask can hide different secrets" do
      expect(answered_pair("<redacted:1>")).to eq(["<redacted:1>", "<redacted:1>"])
    end

    it "delivers both when the placeholder sits inside other text" do
      content = "TOKEN=<redacted:1>\n"

      expect(answered_pair(content)).to eq([content, content])
    end

    it "delivers both when the content is an array of blocks holding a placeholder" do
      content = [{ "type" => "text", "text" => "<redacted:1>" }]

      expect(answered_pair(content)).to eq([content, content])
    end

    it "still deduplicates identical results holding no placeholder" do
      expect(answered_pair("plain")).to eq(["plain", "same result as call tu_1"])
    end
  end

  describe "the round 26 shape under the window budget" do
    let(:files) { (1..5).map { |n| "file #{n} ".ljust(8_000, n.to_s) } }
    let(:ids) { (1..15).map { |n| "tu_#{n}" } }
    let(:blocks) { ids.each_with_index.map { |id, index| result(id, files[index % 5]) } }
    let(:outcome) { bounded(round26, blocks, ids.map { |id| call(id) }) }

    it "delivers each file's first result while the budget lasts, in call order" do
      delivered, = outcome

      expect(delivered.first(3).map { |block| block["content"] }).to eq(files.first(3))
      expect(delivered.map { |block| block["tool_use_id"] }).to eq(ids)
    end

    it "answers a later result with identical bytes by naming the call that carried them" do
      delivered, = outcome

      expect(delivered.values_at(5, 6, 7, 10, 11, 12).map { |block| block["content"] })
        .to eq(["same result as call tu_1", "same result as call tu_2", "same result as call tu_3"] * 2)
      expect(delivered.values_at(5, 10).map { |block| block["is_error"] }).to eq([false, false])
    end

    it "withholds a result past the budget as an error that says how to get it" do
      delivered, = outcome

      withheld = delivered.values_at(3, 4, 8, 9, 13, 14)
      expect(withheld.map { |block| block["is_error"] }).to all(be(true))
      expect(withheld.map { |block| block["content"] }.uniq)
        .to eq(["not delivered: this round reached its 27745-byte budget (window 32768 tokens); " \
                "re-request it in a later round, or narrower with offset and limit"])
    end

    it "journals one round_bounded record naming the basis, the budget and every id's fate" do
      _, records = outcome

      expect(records.map(&:to_journal)).to eq([{ "type" => "round_bounded", "head" => "blake3:asked",
                                                 "basis" => "window", "budget" => 27_745,
                                                 "delivered" => %w[tu_1 tu_2 tu_3],
                                                 "deduplicated" => %w[tu_6 tu_7 tu_8 tu_11 tu_12 tu_13],
                                                 "withheld" => %w[tu_4 tu_5 tu_9 tu_10 tu_14 tu_15] }])
      expect(records.first).to be_deeply_frozen
    end
  end

  it "delivers a read, an edit and a read of one file whole, because the two reads' bytes differ" do
    blocks = [result("tu_1", "def a; end\n"), result("tu_2", "edited"), result("tu_3", "def b; end\n")]
    calls = [call("tu_1"), call("tu_2", subagent), call("tu_3")]

    delivered, records = bounded(round26, blocks, calls)

    expect(delivered).to eq(blocks)
    expect(records).to be_empty
  end

  it "withholds a small read after a large one was withheld, because the round has reached its budget" do
    blocks = [result("tu_1", "a" * 20_000), result("tu_2", "b" * 20_000), result("tu_3", "c" * 10)]

    delivered, records = bounded(round26, blocks, [call("tu_1"), call("tu_2"), call("tu_3")])

    expect(delivered.map { |block| block["is_error"] }).to eq([false, true, true])
    expect(records.first.withheld).to eq(%w[tu_2 tu_3])
  end

  it "answers an identical result by naming the earlier call whatever its size" do
    blocks = [result("tu_1", "abc"), result("tu_2", "abc")]

    delivered, records = bounded(round26, blocks, [call("tu_1"), call("tu_2")])

    expect(delivered.last["content"]).to eq("same result as call tu_1")
    expect(records.first.deduplicated).to eq(%w[tu_2])
  end

  it "withholds under a larger budget nothing a smaller one delivers, whatever the first id's length" do
    ids = ["toolu_0", "t1" * 11, "toolu_2", "toolu_3", "toolu_4"]
    blocks = ids.zip(["b" * 300, *(["d" * 40] * 4)]).map { |id, content| result(id, content) }
    calls = ids.zip([read_file, read_file, subagent, read_file, read_file]).map { |id, tool| call(id, tool) }
    withheld = lambda do |bytes|
      limit = described_class::Limit.new(bytes:, scope: "static")
      bounded(described_class::Round.new("static", limit, nil), blocks, calls).last.flat_map(&:withheld)
    end

    expect(withheld.call(377) - withheld.call(306)).to be_empty
  end

  it "answers a 2-byte result past the budget with a refusal larger than the result" do
    budget = described_class::Round.new("static", described_class::Limit.new(bytes: 0, scope: "static"), nil)
    blocks = [result("tu_1", "ok")]

    delivered, = bounded(budget, blocks, [call("tu_1")])

    expect(delivered.first["content"].bytesize).to be > blocks.first["content"].bytesize
    expect(delivered.first["is_error"]).to be(true)
  end

  it "still deduplicates under a budget of off, and withholds nothing" do
    blocks = [result("tu_1", "x" * 50_000), result("tu_2", "x" * 50_000), result("tu_3", "y" * 50_000)]
    budget = described_class.dedup_only.for(head: "blake3:asked") { raise "the room was computed" }

    delivered, records = bounded(budget, blocks, %w[tu_1 tu_2 tu_3].map { |id| call(id) })

    expect(delivered.map { |block| block["content"] }).to eq(["x" * 50_000, "same result as call tu_1", "y" * 50_000])
    expect(records.first).to have_attributes(withheld: [], head: "blake3:asked", basis: "dedup")
  end

  it "delivers a repeated result whole when dedup is off" do
    blocks = [result("tu_1", "same"), result("tu_2", "same")]
    budget = described_class.window.without_dedup.for(head: nil) { room(window: 32_768) }

    delivered, records = bounded(budget, blocks, [call("tu_1"), call("tu_2")])

    expect(delivered).to eq(blocks)
    expect(records).to be_empty
  end

  it "never asks for the room when there is no budget" do
    budget = described_class::NONE.for(head: nil) { raise "the room was computed" }

    expect(budget.call([result("tu_1", "a")], [call("tu_1")])).to eq([result("tu_1", "a")])
  end

  it "never withholds a subagent's result, and counts it against the budget" do
    blocks = [result("tu_1", "x" * 30_000), result("tu_2", "y" * 10)]

    delivered, records = bounded(round26, blocks, [call("tu_1", subagent), call("tu_2")])

    expect(delivered.first).to eq(blocks.first)
    expect(delivered.last["is_error"]).to be(true)
    expect(records.first).to have_attributes(delivered: %w[tu_1], withheld: %w[tu_2])
  end

  it "delivers an error result as it is" do
    blocks = [result("tu_1", "x" * 30_000), result("tu_2", "no such file", is_error: true)]

    delivered, = bounded(round26, blocks, [call("tu_1", subagent), call("tu_2")])

    expect(delivered.last).to eq(blocks.last)
  end

  it "holds a static budget to twice the per-result ceiling whatever the window" do
    budget = described_class.static.for(head: nil) { room(window: 1_000_000) }
    blocks = [result("tu_1", "a" * 20_000), result("tu_2", "b" * 20_000)]

    delivered, records = bounded(budget, blocks, [call("tu_1"), call("tu_2")])

    expect(delivered.last["content"]).to start_with("not delivered: this round reached its 32768-byte budget (static);")
    expect(records.first).to have_attributes(basis: "static", budget: 2 * Lain::Tool::Bounds::RESULT_BYTES)
  end

  it "takes the last turn's output and the reply reserve out of the window before converting to bytes" do
    usage = Lain::Usage.new(input_tokens: 2_000, output_tokens: 1_000)
    budget = described_class.window.for(head: nil) { room(window: 20_000, usage:, ceiling: 2_000) }

    _, records = bounded(budget, [result("tu_1", "a" * 25_000)], [call("tu_1")])

    expect(records.first.budget).to eq(19_650)
  end

  it "leaves a small window room for a small result despite the reply reserve's floor" do
    usage = Lain::Usage.new(input_tokens: 5_084, output_tokens: 643)
    budget = described_class.window.for(head: nil) { room(window: 8_192, usage:) }

    blocks = [result("tu_1", "a" * 60)]

    delivered, = bounded(budget, blocks, [call("tu_1")])

    expect(delivered).to eq(blocks)
  end

  it "holds back the whole reserve on a large window" do
    usage = Lain::Usage.new(input_tokens: 5_000, output_tokens: 1_000)
    budget = described_class.window.for(head: nil) { room(window: 200_000, usage:, ceiling: 4_096) }

    _, records = bounded(budget, [result("tu_1", "a" * 100), result("tu_2", "a" * 100)],
                         [call("tu_1"), call("tu_2")])

    expect(records.first.budget).to eq(((200_000 - 6_000 - 4_096) * 1.31).floor)
  end

  it "keeps the reserve the compaction trigger keeps, on an 8,192-token window" do
    reserve = Lain::ReplyReserve.tokens(window: 8_192, ceiling: 16_384)
    need = Lain::Compaction::Need.new(byte_threshold: 1_000_000, approaching_ratio: 0.99)
    fires = lambda { |used|
      need.check(window_tokens: 8_192, used_tokens: used, reply_ceiling: 16_384).signals.include?(:approaching_window)
    }
    budget = described_class.window.for(head: nil) { room(window: 8_192) }
    _, records = bounded(budget, [result("tu_1", "a" * 20_000)], [call("tu_1")])

    expect([fires.call(8_192 - reserve), fires.call(8_192 - reserve - 1)]).to eq([true, false])
    expect(records.first.budget).to eq(((8_192 - reserve) * Rational(131, 100)).floor)
  end

  # A Float and the Rational floor alike at every window, so only the absence of a second constant pins it.
  it "converts at the one shared density, not a constant of its own" do
    expect(described_class.const_defined?(:BYTES_PER_TOKEN, false)).to be(false)
  end

  it "delivers a result on an 8,192-token window after a 2,000-token last turn" do
    usage = Lain::Usage.new(input_tokens: 2_000)
    budget = described_class.window.for(head: nil) { room(window: 8_192, usage:) }
    blocks = [result("tu_1", "a" * 4_000)]

    delivered, = bounded(budget, blocks, [call("tu_1")])

    expect(delivered).to eq(blocks)
  end

  it "never answers a budget below nothing when the last turn already overfilled the window" do
    budget = described_class.window.for(head: nil) { room(window: 1_000, usage: Lain::Usage.new(input_tokens: 5_000), ceiling: 0) }

    _, records = bounded(budget, [result("tu_1", "a")], [call("tu_1")])

    expect(records.first.budget).to eq(0)
  end

  it "delivers everything and journals nothing with no budget" do
    blocks = [result("tu_1", "a" * 50_000), result("tu_2", "a" * 50_000)]
    budget = described_class::NONE.for(head: nil) { room(window: 1, usage: Lain::Usage.new(input_tokens: 5), ceiling: 1) }

    delivered, records = bounded(budget, blocks, [call("tu_1"), call("tu_2")])

    expect(delivered).to eq(blocks)
    expect(records).to be_empty
  end

  describe "which tools a result can be withheld from" do
    it "is none by default" do
      expect(subagent.rerunnable?).to be(false)
    end

    it "is the readers whose call can be repeated with nothing lost" do
      readers = [read_file, Lain::Tools::Grep.new, Lain::Tools::Glob.new, Lain::Tools::ListFiles.new,
                 Lain::Tools::MemoryRead.new(index: Lain::Memory::Index.empty)]

      expect(readers.map(&:rerunnable?)).to all(be(true))
    end
  end

  describe "the laws of a round (property-tested)" do
    contents = ["a" * 36, "b" * 44]
    draw = PropCheck::Generators.tuple(
      PropCheck::Generators.one_of(*contents.map { |content| PropCheck::Generators.constant(content) }),
      PropCheck::Generators.choose(0..29),
      PropCheck::Generators.choose(0..2),
      PropCheck::Generators.choose(1..8)
    )
    draws = PropCheck::Generators.array(draw, min: 3, max: 6)
    budget = PropCheck::Generators.one_of(PropCheck::Generators.choose(0..130),
                                          PropCheck::Generators.constant(described_class::UNLIMITED.bytes))

    def round_of(draws)
      draws.each_with_index.map do |(content, error, tool, width), index|
        id = "t#{index}" * width
        [result(id, content, is_error: error.zero?), call(id, [read_file, subagent, read_file][tool])]
      end.transpose
    end

    def answered(bytes, blocks, calls, dedup: true)
      limit = described_class::Limit.new(bytes:, scope: "static")
      bounded(described_class::Round.new("static", limit, nil, dedup:), blocks, calls)
    end

    it "never lets a call's fate depend on the calls after it", aggregate_failures: false do
      forall(draws:, budget:, keep: PropCheck::Generators.choose(0..8), dedup: PropCheck::Generators.one_of(
        PropCheck::Generators.constant(true), PropCheck::Generators.constant(false)
      )) do |draws:, budget:, keep:, dedup:|
        blocks, calls = round_of(draws)
        whole, = answered(budget, blocks, calls, dedup:)
        prefix, = answered(budget, blocks.take(keep), calls.take(keep), dedup:)

        expect(whole.take(keep)).to eq(prefix)
      end
    end

    it "withholds under a larger budget only what a smaller one withholds", aggregate_failures: false do
      forall(draws:, budget:, extra: PropCheck::Generators.choose(0..45), dedup: PropCheck::Generators.one_of(
        PropCheck::Generators.constant(true), PropCheck::Generators.constant(false)
      )) do |draws:, budget:, extra:, dedup:|
        blocks, calls = round_of(draws)
        withheld = ->(bytes) { answered(bytes, blocks, calls, dedup:).last.flat_map(&:withheld) }

        expect(withheld.call(budget + extra) - withheld.call(budget)).to be_empty
      end
    end

    it "withholds nothing at the top of the budget order", aggregate_failures: false do
      forall(draws:) do |draws:|
        blocks, calls = round_of(draws)

        expect(answered(described_class::UNLIMITED.bytes, blocks, calls).last.flat_map(&:withheld)).to be_empty
      end
    end
  end
end
