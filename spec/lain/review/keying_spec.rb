# frozen_string_literal: true

# Two properties, falsifiable on their own. They were a COMMENT inside
# Session.digest before they were an object, and a review-panel mutation pass
# deleted the framing and built two changesets that then addressed identically
# -- so a claim about a digest that is WRITTEN TO THE JOURNAL was one edit from
# being false with nothing red.
#
# Most of what follows is a PROPERTY rather than an example, because a property
# is what the doc claims. The deliberate exception is the golden vector at the
# bottom, and an earlier version of this header argued against having one on the
# grounds that a recorded hex "would fail on every legitimate scheme change".
# That was backwards. The scheme string exists precisely so a legitimate change
# BUMPS it, so a vector recorded against `review-changeset-v1` fails on exactly
# one case: the layout moving while the version does not, which is a silent
# migration of every address already written to a journal.
RSpec.describe Lain::Review::Keying do
  describe "length framing" do
    # The one the mutation pass broke. Without the count, both part lists
    # concatenate to the same bytes -- and these are not contrived shapes: a
    # changeset's parts are a base revision followed by file paths, so "a byte
    # moves across the boundary" is a shorter ref beside a longer path.
    it "addresses two part lists differently when one has a byte on the other side of a boundary" do
      expect(described_class.digest("s", %w[ab c])).not_to eq(described_class.digest("s", %w[a bc]))
    end

    it "holds when the boundary moves in the middle of a longer list" do
      expect(described_class.digest("s", %w[x ab c y])).not_to eq(described_class.digest("s", %w[x a bc y]))
    end

    it "holds for a part that contains the frame's own separator" do
      expect(described_class.digest("s", %W[a\n1\nb c])).not_to eq(described_class.digest("s", %W[a 1\nb\nc]))
    end

    it "distinguishes an empty part from no part at all" do
      expect(described_class.digest("s", ["a", "", "b"])).not_to eq(described_class.digest("s", %w[a b]))
    end

    it "counts BYTES, not characters, so a multibyte part cannot shift the count" do
      expect(described_class.digest("s", %w[é a])).not_to eq(described_class.digest("s", ["éa"]))
    end
  end

  describe "binding the scheme" do
    # Hashed as well as prefixed, and FRAMED like every part -- which the first
    # cut of this group did not check, because it could not have. Written as a
    # bare `"#{scheme}\n"` the scheme was the one unframed field in an otherwise
    # uniquely decodable blob, and a review panel found 47 cross-scheme hex
    # collisions against exactly that shape. The examples below are the general
    # statement those 47 are instances of, not a re-run of the search.
    def hex(scheme, parts) = described_class.digest(scheme, parts).split(":", 2).last

    it "changes the HEX, not only the prefix, when the scheme changes" do
      expect(hex("one", %w[a b])).not_to eq(hex("two", %w[a b]))
    end

    it "cannot be forged by a first part that mimics the scheme line" do
      expect(hex("one", %w[a b])).not_to eq(hex("", %W[one\n a b]))
    end

    # The panel's own witness pair, which collided before the scheme was framed
    # and cannot now. The two are only tellable apart at the hex if the scheme
    # carries its own length: `"1" + "2" + ""` and `"1\n1" + "0\n"` concatenate
    # identically once the scheme is written bare.
    it "cannot be collided by moving bytes between the scheme and the first part" do
      expect(hex("1", ["2", ""])).not_to eq(hex("1\n1", ["0\n"]))
    end

    it "prefixes the address with the scheme, so a reader can tell what it addresses" do
      expect(described_class.digest("review-changeset-v1", %w[a])).to start_with("review-changeset-v1:")
    end
  end

  describe "what it will accept" do
    it "is deterministic" do
      expect(described_class.digest("s", %w[a b])).to eq(described_class.digest("s", %w[a b]))
    end

    it "answers a frozen String, since an address is stored and compared, never edited" do
      expect(described_class.digest("s", %w[a])).to be_frozen
    end

    # Both halves of a real changeset's parts: a path scrubbed to UTF-8 beside a
    # ref that is ASCII, and a path whose bytes are not valid UTF-8 at all --
    # legal on this filesystem, and git does not quote it.
    it "hashes parts of differing encodings without raising" do
      expect { described_class.digest("s", ["café", (+"bad\xFF.rb").force_encoding(Encoding::BINARY)]) }
        .not_to raise_error
    end

    it "frames a non-String part through its own #to_s rather than refusing it" do
      expect(described_class.digest("s", [:modified])).to eq(described_class.digest("s", ["modified"]))
    end
  end

  # THE GOLDEN VECTOR: one recorded address, for the one scheme this module has
  # a caller for.
  #
  # Every property above is satisfied by infinitely many layouts. This pins the
  # layout itself -- the frame's trailing separator, the scheme's own framing,
  # the order of scheme-then-parts -- none of which any property can distinguish
  # and all of which move every address already in a journal.
  #
  # It is not a tautology and it is not brittle. `review-changeset-v1` is a
  # VERSION: change the bytes deliberately and you bump it, and this example
  # goes with it in the same edit. Change them by accident and this is the only
  # thing in the suite that notices. Regenerate it exactly once, and only after
  # deciding the scheme has moved.
  describe "the layout, pinned" do
    it "addresses review-changeset-v1 the way it has always addressed it" do
      expect(described_class.digest("review-changeset-v1", %w[a b]))
        .to eq("review-changeset-v1:df29a8547213c791ec45f21955eab9748679beef4d065f2c0361913ecf62ea82")
    end
  end
end
