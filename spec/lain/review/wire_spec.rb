# frozen_string_literal: true

# `Wire.unquote` alone. The rest of {Lain::Review::Wire} is exercised through the
# records that cross it (`records_spec.rb`); this one has two callers that are not
# records at all, which is why it is worth pinning on its own.
RSpec.describe Lain::Review::Wire do
  describe ".unquote" do
    def unquote(field) = described_class.unquote(field)

    it "leaves a field git had no reason to quote exactly as it found it" do
      expect(unquote("src/pkg/file.rb")).to eq("src/pkg/file.rb")
    end

    it "leaves a path carrying a space alone, since git does not quote for a space" do
      expect(unquote("has space.rb")).to eq("has space.rb")
    end

    it "decodes the escapes git spells with a backslash" do
      expect(unquote('"we\\"ird.rb"')).to eq('we"ird.rb')
      expect(unquote('"ta\\tb.rb"')).to eq("ta\tb.rb")
      expect(unquote('"back\\\\slash.rb"')).to eq("back\\slash.rb")
    end

    # OCTAL, which is what git writes for a byte outside ASCII. `String#undump`
    # handles `\xNN` and `\uXXXX` and cannot do this, which is why the decoding
    # is hand-rolled rather than delegated.
    it "decodes octal byte escapes, which is how a non-ASCII path arrives" do
      expect(unquote('"caf\\303\\251.rb"').force_encoding(Encoding::UTF_8)).to eq("café.rb")
    end

    # The reason this is a gsub over quoted RUNS rather than a check on the whole
    # field: git quotes a rename's two sides INDEPENDENTLY and leaves the ` => `
    # between them bare, so a whole-field test sees an unquoted string and hands
    # back a composite still carrying its escapes.
    it "decodes each side of a rename composite, leaving the arrow between them alone" do
      expect(unquote('"d1/we\\"ird.rb" => "d2/we\\"ird.rb"')).to eq('d1/we"ird.rb => d2/we"ird.rb')
    end

    it "decodes the quoted side of a half-quoted rename" do
      expect(unquote('renameme.rb => "ren\\"amed.rb"')).to eq('renameme.rb => ren"amed.rb')
    end

    it "leaves a brace-form rename alone when neither side needed quoting" do
      expect(unquote("{d1 => d2}/plain.rb")).to eq("{d1 => d2}/plain.rb")
    end

    it "leaves nil alone, as every other normalization here does" do
      expect(unquote(nil)).to be_nil
    end
  end
end
