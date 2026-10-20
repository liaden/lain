# frozen_string_literal: true

# An event's constructors read several arguments, and reading one can call
# Ruby while an earlier one is already Rust state; see spec/support/reentry.rb
# for why a fiber dropped there can leak and how the leak is measured.
RSpec.describe "Lain::Ext event arguments re-entering Ruby" do
  include Reentry

  let(:content) { [{ "type" => "text", "text" => payload }] }

  context "when a float's JSON.generate suspends" do
    before do
      allow(JSON).to receive(:generate).and_wrap_original do |original, *args|
        Reentry.suspend_here
        original.call(*args)
      end
    end

    it "frees the content Timeline#commit read before the meta" do
      line = Lain::Ext::Timeline.empty
      body = content

      expect(leaked_by { line.commit(role: "user", content: body, meta: { "cost" => 1.5 }) })
        .to be < Reentry::PAYLOAD
    end

    it "frees the content Event.new read before the meta" do
      body = content

      expect(leaked_by { Lain::Ext::Event.new(role: "user", content: body, meta: { "cost" => 1.5 }) })
        .to be < Reentry::PAYLOAD
    end
  end

  context "when Symbol#to_s suspends" do
    around { |example| Reentry.with_suspending_symbol_to_s(example) }

    it "frees the turn Event.new read before a Symbol sender" do
      body = content

      expect(leaked_by { Lain::Ext::Event.new(role: "user", content: body, from: :alice) })
        .to be < Reentry::PAYLOAD
    end

    it "frees the payload Event.new read before a Symbol recipient" do
      body = content

      expect(leaked_by { Lain::Ext::Event.new(kind: "message", body:, to: :bob) }).to be < Reentry::PAYLOAD
    end
  end
end
