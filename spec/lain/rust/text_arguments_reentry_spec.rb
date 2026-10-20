# frozen_string_literal: true

# Every binding that takes text reads a Symbol through `Symbol#to_s`, so a
# binding taking several texts can call Ruby while an earlier text is already a
# Rust String; see spec/support/reentry.rb for why a fiber dropped there can
# leak and how the leak is measured.
RSpec.describe "Lain::Ext text arguments re-entering Ruby" do
  include Reentry

  around { |example| Reentry.with_suspending_symbol_to_s(example) }

  {
    "AstGrep.search" => ->(text) { Lain::Ext::AstGrep.search(text, "ruby", :"$A = 1") },
    "AstGrep.dump" => ->(text) { Lain::Ext::AstGrep.dump(text, :ruby) },
    "TreeSitter.query" => ->(text) { Lain::Ext::TreeSitter.query(text, "ruby", :"(identifier) @id") },
    "Fuzzy.new" => ->(text) { Lain::Ext::Fuzzy.new([text, :b]) },
    "Bm25.build" => ->(text) { Lain::Ext::Bm25.build([["a", text], [:b, "y"]]) },
    "Prompt#render" => lambda { |text|
      Lain::Ext::Prompt.from_toml(%(format = "$a$b"\n)).render({ "a" => text, b: "y" }, color: false)
    }
  }.each do |binding, call|
    it "frees the text #{binding} read before a Symbol" do
      text = payload

      expect(leaked_by { call.call(text) }).to be < Reentry::PAYLOAD
    end
  end
end
