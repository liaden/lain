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
end
