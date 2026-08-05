# frozen_string_literal: true

# The value that crosses the review/frontend seam. Its whole job is to be
# agreed on by two objects that never name each other, so what is pinned here
# is the two message names and the immutability the house rule requires -- the
# builder's spec cannot pin them (it would only be checking itself) and neither
# can the renderer's.
RSpec.describe Lain::Review::Surface::Message do
  it "answers exactly the two messages both sides of the seam read" do
    expect(described_class.members).to eq(%i[speaker text])
  end

  it "is deeply frozen, so a rendered conversation crosses a thread boundary" do
    message = described_class.new(speaker: "docent", text: +"because beta needed the same shape")

    expect(message).to be_frozen
    expect(message.speaker).to be_frozen
    expect(message.text).to be_frozen
    expect(Ractor.shareable?(message)).to be(true)
  end

  # A Symbol speaker and an interpolated text are both what a caller has to
  # hand; neither is frozen, and String interpolation returns a mutable String.
  it "interns whatever it is handed rather than trusting the caller" do
    message = described_class.new(speaker: :lain, text: "the docent could not answer #{"this".upcase}")

    expect(message.speaker).to eq("lain")
    expect(Ractor.shareable?(message)).to be(true)
  end
end
