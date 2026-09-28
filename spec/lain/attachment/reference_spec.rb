# frozen_string_literal: true

# The address itself, apart from the middleware that resolves one and the
# encoders that read one. Driven through the PUBLIC doors only -- `.new`, `#with`
# and `.of` -- because a value proved frozen through a factory nobody calls is
# not proved frozen at all.
RSpec.describe Lain::Attachment::Reference do
  let(:hex) { "ab" * 32 }
  let(:digest) { "blake3:#{hex}" }
  let(:reference) { described_class.new(digest:, media_type: "image/png") }

  # A PNG signature, a NUL, a high byte and a lone continuation byte: bytes that
  # do not survive being read as text.
  let(:png) { (+"\x89PNG\r\n\x1a\n\x00\xff\x80pixels").force_encoding(Encoding::BINARY) }

  # An image block wearing the addressed source type, over whatever source a
  # caller hands -- which is how a block that is NOT this subsystem's is written.
  def lookalike(source) = { "type" => "image", "source" => { "type" => "attachment", **source } }

  describe "the value" do
    # Mutable Strings on the way in, deliberately: a caller holding the String it
    # passed can append to it, and an address that relocated under a frozen value
    # is the failure the interning is there to remove.
    it "is deeply frozen through .new, whatever the caller handed it" do
      built = described_class.new(digest: +digest, media_type: +"image/png")

      expect(Ractor.shareable?(built)).to be(true)
      expect(built.digest).to be_frozen
      expect(built.media_type).to be_frozen
    end

    # `#with` is a second constructor and the one a reader forgets: `Data#with`
    # re-runs #initialize, so it must land on the same freeze and the same
    # refusals rather than on a copy that skipped both.
    it "is deeply frozen through #with, and validated by it" do
      copied = reference.with(media_type: +"image/jpeg")

      expect(Ractor.shareable?(copied)).to be(true)
      expect(copied.media_type).to eq("image/jpeg")
      expect { reference.with(media_type: "text/plain") }.to raise_error(ArgumentError, %r{text/plain})
      expect { reference.with(digest: hex) }.to raise_error(ArgumentError, /blake3/)
    end
  end

  # {Lain::Attachment::Store} refuses a bare hex digest from BOTH its doors, and
  # normalizes case, so an address written in any other spelling is corrected
  # here rather than becoming a miss -- or worse, a Corrupt alarm -- there.
  describe "the spelling of an address" do
    it "carries the prefixed, down-cased form the store answers to" do
      expect(described_class.new(digest: "blake3:#{"AB" * 32}", media_type: "image/png").digest).to eq(digest)
      expect(reference.block.dig("source", "digest")).to eq(digest)
    end

    it "compares two spellings of one picture equal, so a block makes no false Merkle claim" do
      expect(described_class.new(digest: "blake3:#{"AB" * 32}", media_type: "image/png")).to eq(reference)
    end

    it "refuses an address with no algorithm prefix, where it was written" do
      expect { described_class.new(digest: hex, media_type: "image/png") }
        .to raise_error(ArgumentError, /not a blake3 address/)
    end

    it "refuses something that is not a digest at all" do
      expect { described_class.new(digest: "blake3:not-hex", media_type: "image/png") }
        .to raise_error(ArgumentError, /blake3/)
    end

    it "refuses a media type that is not an image's" do
      expect { described_class.new(digest:, media_type: "application/pdf") }
        .to raise_error(ArgumentError, %r{application/pdf})
    end

    it "carries a media type down-cased, as it does a digest" do
      expect(described_class.new(digest:, media_type: "IMAGE/PNG").media_type).to eq("image/png")
    end
  end

  describe "the two blocks" do
    it "addresses the picture in about a hundred bytes, deeply frozen" do
      expect(reference.block).to eq("type" => "image",
                                    "source" => { "type" => "attachment", "media_type" => "image/png",
                                                  "digest" => digest })
      expect(Ractor.shareable?(reference.block)).to be(true)
      expect(Lain::Canonical.dump(reference.block).bytesize).to be < 200
    end

    it "inlines the picture as base64 that decodes back to the exact bytes" do
      inline = reference.inline(png)

      expect(inline["source"]).to include("type" => "base64", "media_type" => "image/png")
      expect(inline["source"]["data"].unpack1("m0")).to eq(png)
      expect(Ractor.shareable?(inline)).to be(true)
    end

    # The payload is frozen but must NOT be interned: `-@` would hold a few
    # hundred kilobytes for the life of the process, which is the cost the
    # address exists to remove.
    it "freezes the payload without interning it" do
      data = reference.inline(png)["source"]["data"]

      expect(data).to be_frozen
      expect(data.equal?(-data.dup)).to be(false)
    end

    it "reads an addressed block back into the value that wrote it" do
      expect(described_class.of(reference.block)).to eq(reference)
    end
  end

  describe "telling the two apart" do
    it "answers addressed? for an address and inline? for a payload, never both" do
      expect(described_class).to be_addressed(reference.block)
      expect(described_class).not_to be_inline(reference.block)
      expect(described_class).to be_inline(reference.inline(png))
      expect(described_class).not_to be_addressed(reference.inline(png))
    end

    # A text block, a bare String and a half-built image all reach these
    # predicates, and none of them is a picture.
    it "answers false for anything that is not an image block" do
      expect(described_class).not_to be_addressed("type" => "text", "text" => "hello")
      expect(described_class).not_to be_addressed("a string")
      expect(described_class).not_to be_addressed("type" => "image")
      expect(described_class).not_to be_addressed("type" => "image", "source" => "not a hash")
    end

    # A LOOKALIKE is simply not an address. Model-authored content lands on the
    # Timeline verbatim and `"image"` is deliberately absent from
    # {Lain::Context::Conversation::BLOCK_ROLES}, so a block read as an address
    # it cannot satisfy would be refused from inside the model phase on EVERY
    # later render of that chain -- naming neither the turn nor the picture, and
    # reaching the model as a tool error with its class stripped, since
    # {Lain::Effect::Handler::Live} turns any StandardError into a result.
    it "does not read a malformed lookalike as an address" do
      %w[digest media_type].each do |missing|
        expect(described_class).not_to be_addressed(lookalike(reference.block.fetch("source").except(missing)))
      end
      expect(described_class).not_to be_addressed(lookalike("digest" => hex, "media_type" => "image/png"))
      expect(described_class).not_to be_addressed(lookalike("digest" => digest, "media_type" => "text/plain"))
    end

    it "leaves a lookalike where it stands rather than refusing from the model phase" do
      block = lookalike("digest" => "not a digest at all", "media_type" => "image/png")

      expect(described_class.each_in([block]).to_a).to be_empty
      expect(described_class.refuse_unresolved!([block])).to eq([block])
      expect(described_class.resolve([block]) { raise "asked for bytes it has no address for" }).to eq([block])
    end

    # RFC 6838 makes a media type case-insensitive, and {#initialize} normalizes
    # one -- so a block written in another case is an address, and reading it
    # back gives the canonical spelling. The two members answer spelling variance
    # the same way, which is the whole reason this is asserted next to the digest's.
    it "reads an address whose media type is written in another case" do
      block = lookalike("digest" => digest, "media_type" => "IMAGE/PNG")

      expect(described_class).to be_addressed(block)
      expect(described_class.of(block).media_type).to eq("image/png")
    end
  end

  # A tool_result's content nests, and that is where a tool's picture arrives, so
  # every reader here walks rather than scanning one level.
  describe "walking a payload" do
    let(:nested) do
      [{ "role" => "user",
         "content" => [{ "type" => "tool_result", "tool_use_id" => "call_1",
                         "content" => [{ "type" => "text", "text" => "the page" }, reference.block] }] }]
    end

    it "finds an address nested inside a tool result" do
      expect(described_class.each_in(nested).map(&:digest)).to eq([digest])
    end

    it "yields an Enumerator when handed no block, so a caller composes" do
      expect(described_class.each_in(nested)).to be_a(Enumerator)
    end

    it "finds nothing in a text-only payload" do
      expect(described_class.each_in([{ "role" => "user", "content" => "hi" }]).to_a).to be_empty
    end

    it "collects nested payloads in the order their blocks stand" do
      pair = [reference.inline(png), reference.with(media_type: "image/jpeg").inline("other")]

      expect(described_class.data_in([{ "content" => pair }])).to eq(pair.map { |b| b["source"]["data"] })
    end
  end

  describe ".resolve" do
    it "replaces each address with the bytes the block answers for it, deeply frozen" do
      resolved = described_class.resolve([reference.block]) { |found| found.digest == digest ? png : "wrong" }

      expect(resolved.dig(0, "source", "data").unpack1("m0")).to eq(png)
      expect(Ractor.shareable?(resolved)).to be(true)
    end

    it "leaves the structure around an address intact" do
      payload = [{ "role" => "user", "content" => [{ "type" => "text", "text" => "look" }, reference.block] }]

      resolved = described_class.resolve(payload) { png }

      expect(resolved.dig(0, "role")).to eq("user")
      expect(resolved.dig(0, "content", 0)).to eq("type" => "text", "text" => "look")
    end

    # {Lain::Context::CacheBreakpoints} is in the DEFAULT pipeline and marks a
    # message's LAST block. A screenshot turn is `[text, image]`, so the marker
    # lands on the ADDRESS -- and a resolution that REPLACED the block instead of
    # merging into it threw the marker away, after which Anthropic received a
    # turn with no `cache_control` at all: full input price for pasting a
    # picture, with no error anywhere. {Lain::Workspace::WORKSPACE_MARKER} went
    # the same way.
    it "keeps every other key on the block, the markers among them" do
      marked = reference.block.merge("cache" => true, Lain::Workspace::WORKSPACE_MARKER => true)

      resolved = described_class.resolve([marked]) { png }

      expect(resolved.first).to include("cache" => true, Lain::Workspace::WORKSPACE_MARKER => true)
      expect(resolved.first["source"]).to include("type" => "base64")
      expect(Ractor.shareable?(resolved)).to be(true)
    end

    it "never calls for bytes a payload did not ask for" do
      expect { described_class.resolve([{ "type" => "text", "text" => "hi" }]) { raise "asked anyway" } }
        .not_to raise_error
    end
  end

  describe ".refuse_unresolved!" do
    it "hands back a payload whose pictures are all inline" do
      payload = [reference.inline(png)]

      expect(described_class.refuse_unresolved!(payload)).to be(payload)
    end

    # The digest is what a reader goes looking with, and the sentence has to say
    # what to wire, because the fix is a missing middleware and not a bad block.
    it "refuses an address, naming it and the middleware that resolves one" do
      expect { described_class.refuse_unresolved!([reference.block]) }
        .to raise_error(described_class::Unresolved, /#{digest}.*ResolveAttachments/m)
    end

    it "names every address it found, not just the first" do
      second = reference.with(digest: "blake3:#{"cd" * 32}")

      expect { described_class.refuse_unresolved!([reference.block, second.block]) }
        .to raise_error(described_class::Unresolved, /#{second.digest}/)
    end
  end
end
