# frozen_string_literal: true

# A canonical render drops no field of the envelope, whatever is absent or exotic in it.
RSpec.describe Lain::Ext::Event, "round trip through its canon" do
  # Module functions, because the law's config is built at the group, where examples' methods are out of reach.
  canon = Module.new do
    module_function

    def render(event)
      Lain::Canonical.dump(
        "kind" => event.kind.to_s, "body" => event.body, "from" => event.from, "to" => event.to,
        "correlation" => event.correlation, "render_parent" => event.render_parent,
        "causal_parents" => event.causal_parents
      )
    end

    def rebuild(bytes, keep: %w[from to correlation render_parent causal_parents])
      fields = JSON.parse(bytes)
      Lain::Dag::Factory.event(kind: fields.fetch("kind").to_sym, body: fields.fetch("body"),
                               **keep.to_h { |key| [key.to_sym, fields[key]] }.compact)
    end

    def words
      ["a", "Z", "", "é", "日本", "\u{1f980}", "a\"b", "back\\slash", "tab\there", "nl\nx",
       "\u0000nul", "\u001fus", "\u007fdel", "\u202eevil"]
    end

    def drawn(count: 80, seed: 17)
      rng = Random.new(seed)
      store = Lain::Dag::Factory.store
      kinds = Lain::EventLog::Kinds::KINDS
      Array.new(count) { |index| index }.each_with_object([]) do |index, events|
        events << stored(store, events, kinds[index % kinds.size], rng)
      end
    end

    def stored(store, earlier, kind, rng)
      parents = earlier.sample(rng.rand(0..3), random: rng).map(&:digest)
      event = Lain::Dag::Factory.event(kind:, body: body_for(kind, rng), from: maybe(rng) { words.sample(random: rng) },
                                       to: maybe(rng) { words.sample(random: rng) },
                                       correlation: maybe(rng) { earlier.sample(random: rng)&.digest },
                                       render_parent: maybe(rng) { parents.first }, causal_parents: parents)
      store.put(event.carried_payload)
      store.put(event)
      event
    end

    def maybe(rng) = rng.rand < 0.4 ? nil : yield

    def body_for(kind, rng)
      word = -> { words.sample(random: rng) }
      case kind
      when :turn then { "role" => "user", "content" => [{ "type" => "text", "text" => word.call }], "meta" => {} }
      when :spawn then { "task" => word.call, "role" => word.call, "inherit" => [],
                         "limits" => { "turns" => rng.rand(0..9) } }
      when :message then { "text" => word.call, "refs" => [[word.call, { "nested" => [{}, []] }]] }
      else { "state" => { "files" => {}, "notes" => [word.call, nil, true] } }
      end
    end
  end

  it_behaves_like "a round trip", {
    render: ->(event) { canon.render(event) },
    parse: ->(bytes) { canon.rebuild(bytes) },
    population: -> { canon.drawn },
    equal: ->(rebuilt, original) { rebuilt == original }
  }

  it "draws events of all 4 kinds, some with parents and some with absent fields" do
    events = canon.drawn
    expect([events.map(&:kind).uniq.sort, events.any? { !_1.causal_parents.empty? }, events.any? { _1.from.nil? }])
      .to eq([Lain::EventLog::Kinds::KINDS.sort, true, true])
  end

  it "reads :fails when the render drops the causal parents" do
    battery = AlgebraLaws::RoundTrip.from(
      render: ->(event) { canon.render(event) },
      parse: ->(bytes) { canon.rebuild(bytes, keep: %w[from to correlation render_parent]) },
      population: -> { canon.drawn }
    )
    expect(AlgebraLaws.outcomes(battery)).to eq(AlgebraLaws::ROUND_TRIP_LAW => :fails)
  end
end
