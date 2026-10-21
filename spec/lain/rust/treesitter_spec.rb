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

    # Compiled queries are reused between calls; a reuse must never change an answer.
    it "answers a repeated query from each call's own source and language, and keeps raising a bad one" do
      query = "(identifier) @i"

      expect(described_class.query("total", "ruby", query).map { |c| c["text"] }).to eq(["total"])
      expect(described_class.query("other", "ruby", query).map { |c| c["text"] }).to eq(["other"])
      expect(described_class.query("fn f() {}", "rust", query).map { |c| c["text"] }).to eq(["f"])
      2.times do
        expect { described_class.query("x", "ruby", "(method name: @nope") }
          .to raise_error(described_class::BadQuery)
      end
    end
  end

  # A query over a large source runs for about a third of a second, with the lock between
  # threads released, so another thread runs meanwhile and an interrupt reaches it.
  describe ".query on another thread" do
    let(:big) { "def m(a)\n  a.save(1, 2)\nend\n" * 12_000 }
    let(:query) { "(method name: (identifier) @name) (call method: (identifier) @call)" }

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def querying
      Thread.new do
        Thread.current.report_on_exception = false
        described_class.query(big, "ruby", query)
      end
    end

    it "lets the calling thread keep running while it queries" do
      worker = querying
      ticks = 0
      (ticks += 1) && sleep(0.001) while worker.alive?

      expect(worker.value.size).to eq(24_000)
      expect(ticks).to be >= 20
    end

    # Timed from when the kill was meant to land: a query holding the lock also
    # keeps this thread's sleep from ending, so its kill reaches a finished thread.
    it "stops soon after its thread is killed, rather than at the end of the query" do
      meant = monotonic + 0.05
      worker = querying
      sleep 0.05
      expect(worker).to be_alive
      worker.kill.join

      expect(monotonic - meant).to be < 0.1
    end

    it "raises the interrupt's error rather than returning a partial list" do
      worker = querying
      sleep 0.05
      expect(worker).to be_alive
      worker.raise(IOError, "stopped")

      expect { worker.value }.to raise_error(IOError, "stopped")
    end

    it "answers every capture when an interrupt that raises nothing lands mid-query" do
      worker = querying
      sleep 0.05
      expect(worker).to be_alive
      worker.wakeup

      expect(worker.value.size).to eq(24_000)
    end

    it "still finishes under a stream of interrupts that raise nothing, since its restarts are bounded" do
      worker = querying
      waker = Thread.new do
        while worker.alive?
          sleep 0.001
          worker.wakeup
        end
      rescue ThreadError
        nil
      end

      expect(worker.join(30)).to eq(worker)
      expect(worker.value.size).to eq(24_000)
    ensure
      waker&.kill&.join
    end

    it "answers every query when more run at once than it has slots for" do
      source = "def m(a)\n  a.save\nend\n" * 2_000
      results = Array.new(80) { Thread.new { described_class.query(source, "ruby", query).size } }.map(&:value)

      expect(results).to all(eq(4_000))
    end

    # Releasing hands the lock to a busy thread, and getting it back waits out
    # that thread's time slice, which is far longer than a small query.
    it "keeps the lock for a small query, so a busy thread at the offload priority does not slow it" do
      source = "def m(a)\n  a.save(1, 2)\nend\n" * 20
      busy = Thread.new do
        Thread.current.priority = Lain::Tool::Offload::PRIORITY
        loop { nil }
      end
      sleep 0.05
      started = monotonic
      20.times { described_class.query(source, "ruby", query) }

      # Loose for a loaded suite; a convoy costs at least 1 slice, about 20 ms.
      expect((monotonic - started) / 20).to be < 0.008
    ensure
      busy&.kill&.join
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
