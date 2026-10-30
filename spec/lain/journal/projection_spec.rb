# frozen_string_literal: true

RSpec.describe Lain::Journal::Projection do
  head = "blake3:#{"a" * 64}"
  turn = "blake3:#{"b" * 64}"
  identity = { "device" => 1, "inode" => 2, "mtime" => 3, "size" => 4 }

  read_of = lambda do |path|
    Lain::Telemetry::SessionRead.new(path:, lines: [1, 2], identity:, tool_use_id: "tu_1", head:)
  end
  turn_line = Lain::Telemetry::Untyped.new(fields: { "type" => "turn", "digest" => turn, "parent" => head,
                                                     "content" => [{ "type" => "text", "text" => "näive ✓" }] })
  palette = [read_of.call("lib/a.rb"), read_of.call("lib/ünïcode/日本.rb"), turn_line,
             Lain::Telemetry::TurnLabeled.new(digest: turn, label: "café ☕"),
             Lain::Telemetry::TurnLabeled.new(digest: turn, label: "")]
  g = PropCheck::Generators
  record_lists = g.array(g.one_of(*palette.map { g.constant(_1) }), min: 2, max: 4)

  type_of = ->(record) { record.respond_to?(:journal_type) ? record.journal_type : record.type }

  # How many of each type: a value projection, so folding halves apart and adding agrees with the whole.
  counts = Class.new(described_class) do
    define_singleton_method(:unit) { new({}) }
    define_method(:step) do |record|
      type = type_of.call(record)
      self.class.new(value.merge(type => value.fetch(type, 0) + 1))
    end
    define_method(:combine) { |other| self.class.new(value.merge(other.value) { |_, a, b| a + b }) }
  end

  # A read binds to the turn that lands after it on the head its round opened on, so a read and its
  # turn folded in different halves never meet.
  reads = Class.new(described_class) do
    define_singleton_method(:unit) { new({ pending: [], bound: {} }) }
    define_method(:value) { state.fetch(:bound) }
    define_method(:step) do |record|
      case record
      when Lain::Telemetry::SessionRead then self.class.new(state.merge(pending: [*state[:pending], record]))
      when Lain::Telemetry::Untyped then record.type == "turn" ? bound_to(record) : self
      else self
      end
    end
    define_method(:bound_to) do |line|
      binding, pending = state[:pending].partition { |read| read.head == line["parent"] }
      paths = [*state[:bound].fetch(line["digest"], []), *binding.map(&:path)]
      self.class.new({ pending:, bound: state[:bound].merge(line["digest"] => paths) })
    end
  end
  # The combine a reads projection would declare if it could: the halves' pending reads and bindings, joined.
  joined = lambda do |left, right|
    reads.new({ pending: left.state[:pending] + right.state[:pending],
                bound: left.state[:bound].merge(right.state[:bound]) { |_, a, b| a + b } })
  end

  describe "a value projection" do
    include_examples "an incremental fold", projection: counts, generator: record_lists
  end

  describe "a projection that binds a record to a later one, with a state that drops the later record's key" do
    include_examples "an incremental fold", projection: reads, generator: record_lists, samples: 3
  end

  it "answers the inject of its steps from the unit" do
    expect(counts.over(palette).value).to eq("session_read" => 2, "turn" => 1, "turn_labeled" => 2)
  end

  it "continues a fold from where it stands" do
    expect(counts.over(palette.first(2)).over(palette.drop(2))).to eq(counts.over(palette))
  end

  it "leaves a 30-record projection as it was when a 31st is stepped, both shareable" do
    thirty = counts.over(palette.cycle.first(30))
    thirty_one = thirty.step(turn_line)
    expect([thirty.value.values.sum, thirty_one.value.values.sum]).to eq([30, 31])
    expect([thirty, thirty_one]).to all(satisfy { |projection| Ractor.shareable?(projection) })
  end

  it "is equal to a projection of the same class over the same state" do
    expect([counts.over(palette).hash, counts.over(palette)]).to eq([counts.over(palette).hash, counts.over(palette)])
  end

  it "is not equal to another projection class over the same state" do
    expect(counts.new({})).not_to eq(Class.new(described_class).new({}))
  end

  it "refuses to fold a projection that names no unit" do
    expect { Class.new(described_class).over([]) }.to raise_error(NotImplementedError, /unit/)
  end

  describe "the reads projection as a homomorphism" do
    battery = AlgebraLaws::MonoidHomomorphism.from(
      collapse: ->(records) { reads.over(records) }, unit: reads.unit, combine: joined,
      spans: -> { [[read_of.call("lib/a.rb")], [turn_line]] }
    )

    it "fails the concatenation law without raising" do
      expect(AlgebraLaws.outcomes(battery).values).to eq(%i[holds fails])
    end

    it "names the split that lost the binding as the witness" do
      expect(battery.witness).to eq([[read_of.call("lib/a.rb")], [turn_line]])
    end
  end

  describe AlgebraLaws::IncrementalFold do
    population = -> { [palette.first(3), palette.last(2)] }

    it "reads persistence as :fails for a projection whose step moves the receiver" do
      moving = Class.new do
        attr_reader :seen

        define_singleton_method(:unit) { new }
        define_singleton_method(:over) { |records| records.inject(unit) { |p, r| p.step(r) } }
        define_method(:initialize) { @seen = [] }
        define_method(:step) { |record| tap { @seen << record } }
        define_method(:==) { |other| seen == other.seen }
      end
      outcomes = AlgebraLaws.outcomes(described_class.from(projection: moving, population:))
      expect(outcomes.fetch("leaves the receiver as it was when stepped")).to eq(:fails)
    end

    it "reads persistence as :fails for a projection that answers a fresh unshareable value per step" do
      unshareable = Class.new do
        attr_reader :seen

        define_singleton_method(:unit) { new([]) }
        define_singleton_method(:over) { |records| records.inject(unit) { |p, r| p.step(r) } }
        define_method(:initialize) { |seen| @seen = seen }
        define_method(:step) { |record| self.class.new([*seen, record]) }
        define_method(:==) { |other| seen == other.seen }
      end
      outcomes = AlgebraLaws.outcomes(described_class.from(projection: unshareable, population:))
      expect(outcomes.fetch("leaves the receiver as it was when stepped")).to eq(:fails)
    end

    # Each tail is right for all but 1 family of cuts, so each family has a negative only it can catch.
    describe "a tail wrong for 1 family of cuts" do
      chunked_law = "folds the bytes cut at any byte as it folds the whole lines"
      chunked_outcome = lambda do |tail|
        AlgebraLaws.outcomes(described_class.from(projection: counts, population:, tail:))
                   .fetch(chunked_law)
      end

      it "reads :fails for one that takes only the first newline of a chunk, which only a 2-way cut shows" do
        first_newline_only = Class.new do
          define_method(:initialize) { @fragment = "".b }
          define_method(:<<) do |chunk|
            @fragment << chunk.b
            at = @fragment.index("\n")
            line, @fragment = at ? [@fragment.byteslice(0, at + 1), @fragment.byteslice((at + 1)..)] : ["", @fragment]
            [Lain::Journal.parse(line)].compact
          end
        end
        expect(chunked_outcome.call(-> { first_newline_only.new })).to eq(:fails)
      end

      it "reads :fails for one that keeps only the last chunk's fragment, which only byte-at-a-time shows" do
        short_memory = Class.new do
          define_method(:initialize) { @fragment = "".b }
          define_method(:<<) do |chunk|
            lines = (@fragment + chunk.b).lines
            last = chunk.b.lines.last.to_s
            @fragment = last.end_with?("\n") ? "".b : last
            lines.select { |line| line.end_with?("\n") }.filter_map { |line| Lain::Journal.parse(line) }
          end
        end
        expect(chunked_outcome.call(-> { short_memory.new })).to eq(:fails)
      end

      it "reads :fails for one that answers a fragment that already parses, which only the chomped file shows" do
        eager_fragment = Class.new do
          define_method(:initialize) { restart }
          define_method(:restart) do
            @tail = Lain::Journal::Tail.new
            @pending = "".b
          end
          define_method(:<<) do |chunk|
            completed = @tail << chunk
            @pending = (@pending + chunk.b).lines.reject { |line| line.end_with?("\n") }.last.to_s
            early = Lain::Journal.parse(@pending)
            restart if early
            [*completed, *([early] if early)]
          end
        end
        expect(chunked_outcome.call(-> { eager_fragment.new })).to eq(:fails)
      end
    end

    it "reads chunked-equals-whole as :fails for a tail that drops a torn line's first half" do
      forgetful = Class.new do
        define_method(:<<) { |chunk| chunk.lines.filter_map { |line| Lain::Journal.parse(line) } }
      end
      outcomes = AlgebraLaws.outcomes(described_class.from(projection: counts, population:, tail: -> { forgetful.new }))
      expect(outcomes.fetch("folds the bytes cut at any byte as it folds the whole lines")).to eq(:fails)
    end

    it "carries the homomorphism laws only for a projection that declares combine" do
      sizes = [counts, reads].map { |projection| described_class.from(projection:, population:).to_h.size }
      expect(sizes).to eq([4, 2])
    end
  end
end
