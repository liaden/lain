# frozen_string_literal: true

# An error the extension raises is a Ruby class it looks up by name and builds
# at raise time, and both steps can run Ruby: a constant lookup through
# `const_missing` or an autoload, the build through the class's `#initialize`.
# See spec/support/reentry.rb for why a fiber dropped there can leak and how the
# leak is measured. The digest asked for is the payload, and the refusal quotes it.
RSpec.describe "Lain::Ext error lookup re-entering Ruby" do
  include Reentry

  let(:store) { Lain::Ext::Store.new }
  let(:missing) { "blake3:#{payload}" }

  it "frees the message when the fiber is dropped inside the class lookup" do
    found = Lain::Ext::Store::MissingObject
    hide_const("Lain::Ext::Store::MissingObject")
    allow(Lain::Ext::Store).to receive(:const_missing).and_wrap_original do |original, name|
      Reentry.suspend_here
      name == :MissingObject ? found : original.call(name)
    end
    digest = missing

    expect(leaked_by { store.fetch(digest) }).to be < Reentry::PAYLOAD
  end

  it "frees the message when the fiber is dropped inside the exception's #initialize" do
    suspending = Class.new(Lain::Ext::Store::MissingObject) do
      def initialize(*)
        Reentry.suspend_here
        super
      end
    end
    stub_const("Lain::Ext::Store::MissingObject", suspending)
    digest = missing

    expect(leaked_by { store.fetch(digest) }).to be < Reentry::PAYLOAD
  end

  it "still raises the class it looked up, quoting the digest" do
    expect { store.fetch("blake3:none") }
      .to raise_error(Lain::Ext::Store::MissingObject, 'no object "blake3:none" in store')
  end
end
