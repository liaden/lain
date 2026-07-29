# frozen_string_literal: true

# The Rust tree-sitter query binding (`tree-sitter`'s own Query/QueryCursor, in
# process under the ext's data-structure placement rules): a STATELESS raw
# structural query. Each call parses an in-memory source string, runs a
# tree-sitter S-expression query against the concrete syntax tree, and returns
# an owned, deeply frozen array of named captures -- no index handle, no
# `TypedData` wrapper, nothing shared across calls. Where `AstGrep` matches a
# metavariable *pattern* (the ergonomic surface), this exposes the raw query
# engine directly: an agent that knows the grammar can name nodes and fields
# precisely. The grammars are reused from `ast-grep-language` via
# `SupportLang::get_ts_language()`, so there is no second grammar dependency.
# Byte offsets only -- byte->line/column conversion is the Ruby wrapper's job.
RSpec.describe Lain::Ext::TreeSitter do
  describe ".query" do
    it "returns named captures with the node text and byte range" do
      captures = described_class.query("def total(x)\n  x\nend", "ruby", "(method name: (identifier) @name)")

      name = captures.find { |c| c["name"] == "name" }
      expect(name).not_to be_nil
      expect(name["text"]).to eq("total")
      expect(name["start"]).to be_a(Integer)
      expect(name["end"]).to be_a(Integer).and be > name["start"]
      # The capture's byte range addresses `total` in the source.
      expect("def total(x)\n  x\nend"[name["start"]...name["end"]]).to eq("total")
    end

    it "raises BadQuery (a Lain::Error) on a malformed S-expression" do
      expect(described_class::BadQuery.ancestors).to include(Lain::Error)
      expect { described_class.query("def x; end", "ruby", "(method name: @nope") }
        .to raise_error(described_class::BadQuery)
    end

    it "raises ArgumentError on an unknown language" do
      expect { described_class.query("x = 1", "klingon", "(identifier) @i") }
        .to raise_error(ArgumentError)
    end

    it "returns an empty array for a valid query with zero matches" do
      expect(described_class.query("x = 1", "ruby", "(method) @m")).to eq([])
    end

    it "raises BadQuery on a capture-less query rather than silently matching nothing" do
      # A query that binds no `@capture` can never yield a result for any source,
      # so it is a typo, not a no-match -- the empty string is the canonical
      # fat-finger; `(method)` matches `def x` structurally but emits nothing.
      ["", "(method)", "[(method) (class)]"].each do |query_src|
        expect { described_class.query("def x; end", "ruby", query_src) }
          .to raise_error(described_class::BadQuery)
      end
    end

    it "returns a deeply frozen result" do
      expect(described_class.query("def total(x)\n  x\nend", "ruby", "(method name: (identifier) @name)"))
        .to be_deeply_frozen
    end
  end

  # The shared `read_text` policy (ext/lain/src/read_text.rs). Same reason as
  # `AstGrep`'s group: this binding's pinned contract is byte offsets into the
  # caller's own String, and magnus's `String` conversion would transcode a
  # non-UTF-8 String on the way in -- so every `start`/`end` would silently
  # index a UTF-8 copy the caller has no handle on.
  describe "string boundary" do
    let(:query) { "(method name: (identifier) @name)" }

    it "refuses a source whose encoding is not UTF-8 rather than reinterpreting its bytes" do
      expect { described_class.query("def total(x)\n  x\nend".encode("UTF-16LE"), "ruby", query) }
        .to raise_error(EncodingError, /source must be UTF-8, got UTF-16LE/)
    end

    it "refuses a non-UTF-8 query and language too, one policy for every text argument" do
      expect { described_class.query("def x; end", "ruby", query.encode("UTF-16LE")) }
        .to raise_error(EncodingError, /query must be UTF-8, got UTF-16LE/)
      expect { described_class.query("def x; end", "ruby".encode("UTF-16LE"), query) }
        .to raise_error(EncodingError, /language must be UTF-8, got UTF-16LE/)
    end

    it "refuses bytes that are not valid UTF-8, and says where the first bad byte is" do
      expect { described_class.query("# \xff\xfe\ndef x; end".b, "ruby", query) }
        .to raise_error(EncodingError, /source is not valid UTF-8 \(first invalid byte at offset 2\)/)
    end

    # Deliberately MULTI-BYTE -- a 7-bit fixture passes this example's name
    # without testing it. See the twin in `astgrep_spec.rb` for what that hid.
    it "accepts BINARY whose bytes are already valid UTF-8, including multi-byte ones" do
      binary = "# café\ndef total(x)\n  x\nend".b

      expect(binary.encoding).to eq(Encoding::BINARY)
      expect(described_class.query(binary, "ruby", query).size).to eq(1)
    end

    it "refuses a US-ASCII string carrying a high byte, and names force_encoding" do
      mislabelled = (+"# café\ndef total(x)\n  x\nend").force_encoding(Encoding::US_ASCII)

      expect(mislabelled.valid_encoding?).to be(false)
      expect { described_class.query(mislabelled, "ruby", query) }
        .to raise_error(EncodingError, /tagged US-ASCII but byte 5 is not ASCII.*force_encoding/m)
    end

    it "refuses a non-String, non-Symbol argument by naming what it got" do
      expect { described_class.query(42, "ruby", query) }
        .to raise_error(TypeError, /source must be a String or Symbol, got an Integer/)
    end
  end
end
