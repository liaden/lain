# frozen_string_literal: true

# The Rust ast-grep matcher (`ast-grep-core`, in-process under the ext's
# data-structure placement rules): a STATELESS structural search. Each call
# parses an in-memory source string, matches a metavariable pattern against the
# concrete syntax tree, and returns an owned, deeply frozen array of matches --
# no index handle, no `TypedData` wrapper, nothing shared across calls. The
# matcher answers "where does this code SHAPE appear"; it deliberately cannot
# resolve a name across files (that is the graph layer's job), and it matches
# structure so comments and string literals never false-positive. Byte offsets
# only -- byte->line/column conversion is the Ruby wrapper's job.
RSpec.describe Lain::Ext::AstGrep do
  describe ".search" do
    it "matches a metavariable pattern and captures NAME with a byte range" do
      matches = described_class.search("def total(x)\n  x\nend", "ruby", "def $NAME($$$A)")
      expect(matches.size).to eq(1)

      name = matches.first["captures"]["NAME"]
      expect(name["text"]).to eq("total")
      expect(name["start"]).to be_a(Integer)
      expect(name["end"]).to be_a(Integer).and be > name["start"]

      match = matches.first
      expect(match["start"]).to be_a(Integer)
      expect(match["end"]).to be_a(Integer).and be > match["start"]
    end

    it "matches structure, so `save` in a comment or a string never counts" do
      src = <<~RUBY
        # remember to record.save the row
        note = "call record.save when ready"
        record.save
      RUBY

      matches = described_class.search(src, "ruby", "$RECV.save")
      expect(matches.size).to eq(1)
      expect(matches.first["captures"]["RECV"]["text"]).to eq("record")
    end

    it "raises BadPattern (a Lain::Error) on a malformed pattern" do
      expect(described_class::BadPattern.ancestors).to include(Lain::Error)
      expect { described_class.search("x = 1", "ruby", "def (") }
        .to raise_error(described_class::BadPattern)
    end

    it "raises BadPattern rather than silently matching nothing for an ERROR-node pattern" do
      # A bare `)` parses to a top-level ERROR node that `has_error()` does not
      # flag -- without the full-tree walk it returned a silent [].
      expect { described_class.search("record.save", "ruby", ")") }
        .to raise_error(described_class::BadPattern)
    end

    it "returns an empty array for a valid pattern with zero matches" do
      expect(described_class.search("x = 1", "ruby", "$RECV.save")).to eq([])
    end

    it "returns a deeply frozen result" do
      expect(described_class.search("def total(x)\n  x\nend", "ruby", "def $NAME($$$A)"))
        .to be_deeply_frozen
    end
  end

  describe ".dump" do
    it "dumps the CST so an agent can see the real node kinds" do
      # `def self.x` is a `singleton_method` node, NOT the `method` node an LLM's
      # `def $NAME` pattern matches -- the dump is how the agent self-corrects.
      expect(described_class.dump("def self.x; end", "ruby")).to include("singleton_method")
    end
  end
end
