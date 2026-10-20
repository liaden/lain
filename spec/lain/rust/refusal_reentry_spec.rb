# frozen_string_literal: true

# Every refusal the extension raises names a Ruby class it looks up at raise
# time, and the lookup can run Ruby through `const_missing` or an autoload; see
# spec/support/reentry.rb for why a fiber dropped there can leak and how the
# leak is measured. Each example's payload is Rust state the refusing call
# owned: the text it quotes, or an argument it had already read.
RSpec.describe "Lain::Ext refusals re-entering Ruby" do
  include Reentry

  def suspend_lookup_of(path)
    *scope, name = path.split("::")
    owner = Object.const_get(scope.join("::"))
    found = owner.const_get(name)
    hide_const(path)
    allow(owner).to receive(:const_missing).and_wrap_original do |original, missing|
      Reentry.suspend_here
      missing == name.to_sym ? found : original.call(missing)
    end
  end

  def node(**answers)
    Class.new { answers.each { |name, answer| define_method(name, &answer) } }.new
  end

  let(:store) { Lain::Ext::Store.new }
  let(:big) { payload }

  it "frees the cited parent when Store#put refuses a dangling causal parent" do
    event = Lain::Dag::Factory.event(kind: :message, body: {}, from: "p", to: "c", causal_parents: ["blake3:#{big}"])
    store.put(event.carried_payload)
    suspend_lookup_of("Lain::Ext::Store::MissingObject")

    expect(leaked_by { store.put(event) }).to be < Reentry::PAYLOAD
  end

  it "frees the claimed digest when Store#put refuses a mismatched one" do
    claimed = "blake3:#{big}"
    mismatched = node(canonical: -> { {} }, digest: -> { claimed })
    suspend_lookup_of("Lain::Ext::Store::DigestMismatch")

    expect(leaked_by { store.put(mismatched) }).to be < Reentry::PAYLOAD
  end

  it "frees the head Timeline#checkout read when it refuses one the store lacks" do
    line = Lain::Ext::Timeline.empty(store:)
    head = "blake3:#{big}"
    suspend_lookup_of("Lain::Ext::Store::MissingObject")

    expect(leaked_by { line.checkout(head) }).to be < Reentry::PAYLOAD
  end

  it "frees the role text Event.new read when it refuses the role" do
    role = big
    suspend_lookup_of("Lain::Ext::Event::InvalidRole")

    expect(leaked_by { Lain::Ext::Event.new(role:, content: []) }).to be < Reentry::PAYLOAD
  end

  it "frees the key a canonical conversion read when it refuses an ambiguous one" do
    key = big
    suspend_lookup_of("Lain::Canonical::AmbiguousKey")

    expect(leaked_by { Lain::Ext.canonical_dump({ key => 1, key.to_sym => 2 }) }).to be < Reentry::PAYLOAD
  end

  it "frees the query Fuzzy#match read when it refuses a long one" do
    fuzzy = Lain::Ext::Fuzzy.new(["a"])
    query = big
    suspend_lookup_of("Lain::Ext::Fuzzy::QueryTooLong")

    expect(leaked_by { fuzzy.match(query) }).to be < Reentry::PAYLOAD
  end

  it "frees the source Prompt.from_toml read when it refuses it" do
    source = "format = \"[#{big}\"\n"
    suspend_lookup_of("Lain::Ext::Prompt::ConfigError")

    expect(leaked_by { Lain::Ext::Prompt.from_toml(source) }).to be < Reentry::PAYLOAD
  end

  it "frees the bindings Prompt#render read when it refuses a style" do
    prompt = Lain::Ext::Prompt.from_toml(%(format = "[x]($accent)$big"\n))
    bindings = { "accent" => "chartreuse", "big" => big }
    suspend_lookup_of("Lain::Ext::Prompt::StyleError")

    expect(leaked_by { prompt.render(bindings, color: true) }).to be < Reentry::PAYLOAD
  end

  it "frees the id Bm25.build read when it refuses a duplicate" do
    pairs = [[big, "a"], [big, "b"]]
    suspend_lookup_of("Lain::Ext::Bm25::DuplicateId")

    expect(leaked_by { Lain::Ext::Bm25.build(pairs) }).to be < Reentry::PAYLOAD
  end

  it "frees the source AstGrep.search read when it refuses the pattern" do
    source = "x = 1 # #{big}"
    suspend_lookup_of("Lain::Ext::AstGrep::BadPattern")

    expect(leaked_by { Lain::Ext::AstGrep.search(source, "ruby", "def (") }).to be < Reentry::PAYLOAD
  end

  it "frees the source TreeSitter.query read when it refuses the query" do
    source = "x = 1 # #{big}"
    suspend_lookup_of("Lain::Ext::TreeSitter::BadQuery")

    expect(leaked_by { Lain::Ext::TreeSitter.query(source, "ruby", "(method name: @nope") }).to be < Reentry::PAYLOAD
  end

  it "still refuses with the class it looked up" do
    expect { Lain::Ext::Event.new(role: "nobody", content: []) }.to raise_error(Lain::Ext::Event::InvalidRole)
  end
end
