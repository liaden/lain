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

  # A search over a large source runs for about a third of a second, with the lock between
  # threads released, so another thread runs meanwhile and an interrupt reaches it.
  describe ".search on another thread" do
    let(:big) { "def m(a)\n  a.save(1, 2)\nend\n" * 15_000 }
    let(:pattern) { "def $NAME($$$A)" }

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def searching
      Thread.new do
        Thread.current.report_on_exception = false
        described_class.search(big, "ruby", pattern)
      end
    end

    it "lets the calling thread keep running while it searches" do
      worker = searching
      ticks = 0
      (ticks += 1) && sleep(0.001) while worker.alive?

      expect(worker.value.size).to eq(15_000)
      expect(ticks).to be >= 20
    end

    # Timed from when the kill was meant to land: a search holding the lock also
    # keeps this thread's sleep from ending, so its kill reaches a finished thread.
    it "stops soon after its thread is killed, rather than at the end of the search" do
      meant = monotonic + 0.05
      worker = searching
      sleep 0.05
      expect(worker).to be_alive
      worker.kill.join

      expect(monotonic - meant).to be < 0.1
    end

    it "raises the interrupt's error rather than returning a partial list" do
      worker = searching
      sleep 0.05
      expect(worker).to be_alive
      worker.raise(IOError, "stopped")

      expect { worker.value }.to raise_error(IOError, "stopped")
    end

    it "answers the whole list when an interrupt that raises nothing lands mid-search" do
      worker = searching
      sleep 0.05
      expect(worker).to be_alive
      worker.wakeup

      expect(worker.value.size).to eq(15_000)
    end

    it "still finishes under a stream of interrupts that raise nothing, since its restarts are bounded" do
      worker = searching
      waker = Thread.new do
        while worker.alive?
          sleep 0.001
          worker.wakeup
        end
      rescue ThreadError
        nil
      end

      expect(worker.join(30)).to eq(worker)
      expect(worker.value.size).to eq(15_000)
    ensure
      waker&.kill&.join
    end

    it "answers every search when more run at once than it has slots for" do
      source = "def m(a)\n  a.save\nend\n" * 2_000
      results = Array.new(80) { Thread.new { described_class.search(source, "ruby", pattern).size } }.map(&:value)

      expect(results).to all(eq(2_000))
    end
  end

  describe ".search beside a busy thread" do
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Releasing hands the lock to a busy thread, and getting it back waits out that thread's time
    # slice, about 20 ms; the bound is loose for a loaded suite and well under a slice.
    it "keeps the lock for a small source, so a busy thread at the offload priority does not slow it" do
      source = "def m(a)\n  a.save(1, 2)\nend\n" * 20
      busy = Thread.new do
        Thread.current.priority = Lain::Tool::Offload::PRIORITY
        loop { nil }
      end
      sleep 0.05
      started = monotonic
      20.times { described_class.search(source, "ruby", "def $NAME($$$A)") }

      expect((monotonic - started) / 20).to be < 0.008
    ensure
      busy&.kill&.join
    end
  end

  describe ".dump" do
    it "dumps the CST so an agent can see the real node kinds" do
      # `def self.x` is a `singleton_method` node, NOT the `method` node an LLM's
      # `def $NAME` pattern matches -- the dump is how the agent self-corrects.
      expect(described_class.dump("def self.x; end", "ruby")).to include("singleton_method")
    end

    it "refuses a source nested past its depth cap, rather than building a 12 MB String" do
      # A 4 KB deeply nested source dumped to 12 MB (and overflowed the walk's
      # stack): the per-node indent is quadratic in depth. The refusal crosses
      # as Structural::Matcher::DumpCapped -- a Lain::Error, like every other
      # error this crate raises, and NOT a Ruby builtin the seam would have to
      # tell apart from an unrelated one.
      expect { described_class.dump("#{"(" * 2000}1#{")" * 2000}", "ruby") }
        .to raise_error(Lain::Structural::Matcher::DumpCapped, /capped at/)
    end

    it "truncates a dump past its output cap and discloses the cap in the text" do
      dumped = described_class.dump("x = 1\n" * 20_000, "ruby")

      expect(dumped).to start_with("program\n").and end_with("... capped at 65536 bytes\n")
      expect(dumped).to be_frozen
    end
  end

  # The shared `read_text` policy (ext/lain/src/read_text.rs), whose whole point
  # HERE is the index space: this binding's contract is byte offsets into the
  # caller's own String. magnus's `String` conversion transcodes a non-UTF-8
  # String on the way in, so without this refusal every `start`/`end` would
  # index a UTF-8 copy the caller never sees -- and `Structural::Matcher`'s
  # `source.byteslice(0, start)` line counting would read the wrong bytes with
  # nothing failing.
  describe "string boundary" do
    let(:utf16) { "record.save\n".encode("UTF-16LE") }

    it "refuses a source whose encoding is not UTF-8 rather than reinterpreting its bytes" do
      expect { described_class.search(utf16, "ruby", "$RECV.save") }
        .to raise_error(EncodingError, /source must be UTF-8, got UTF-16LE/)
      expect { described_class.dump(utf16, "ruby") }
        .to raise_error(EncodingError, /source must be UTF-8, got UTF-16LE/)
    end

    it "refuses a non-UTF-8 pattern and language too, one policy for every text argument" do
      expect { described_class.search("record.save\n", "ruby", "$RECV.save".encode("UTF-16LE")) }
        .to raise_error(EncodingError, /pattern must be UTF-8, got UTF-16LE/)
      expect { described_class.search("record.save\n", "ruby".encode("UTF-16LE"), "$RECV.save") }
        .to raise_error(EncodingError, /language must be UTF-8, got UTF-16LE/)
    end

    it "refuses bytes that are not valid UTF-8, and says where the first bad byte is" do
      # The offset is the only lever the message can offer: the bytes really are
      # broken, so there is no encoding to re-tag them with -- but "byte 2" tells
      # a caller which part of the file to look at.
      expect { described_class.search("# \xff\xfe\nrecord.save\n".b, "ruby", "$RECV.save") }
        .to raise_error(EncodingError, /source is not valid UTF-8 \(first invalid byte at offset 2\)/)
      expect { described_class.dump("# \xff\xfe\n".b, "ruby") }
        .to raise_error(EncodingError, /source is not valid UTF-8 \(first invalid byte at offset 2\)/)
    end

    # Deliberately MULTI-BYTE. A 7-bit fixture passes this example's name without
    # testing it, and that is exactly how the gap went unnoticed: magnus's
    # `RString::as_str` demands coderange SevenBit for an ASCII-8BIT string, so
    # `"# café".b` was refused with "not valid UTF-8" -- a false statement about
    # bytes that decode perfectly. read_text validates the bytes itself for this.
    it "accepts BINARY whose bytes are already valid UTF-8, including multi-byte ones" do
      binary = "# café\nrecord.save\n".b

      expect(binary.encoding).to eq(Encoding::BINARY)
      expect(described_class.search(binary, "ruby", "$RECV.save").size).to eq(1)
      expect(described_class.dump(binary, "ruby")).to include("call")
    end

    # US-ASCII promises 7-bit. A high byte makes the string one Ruby itself calls
    # invalid, so its bytes are UTF-8 only by accident -- refused by the same
    # rule as UTF-16LE, and the message names the fix, because this is a
    # MISLABELLED string rather than a broken one.
    it "refuses a US-ASCII string carrying a high byte, and names force_encoding" do
      mislabelled = (+"# café\nrecord.save\n").force_encoding(Encoding::US_ASCII)

      expect(mislabelled.valid_encoding?).to be(false)
      expect { described_class.search(mislabelled, "ruby", "$RECV.save") }
        .to raise_error(EncodingError, /tagged US-ASCII but byte 5 is not ASCII.*force_encoding/m)
    end

    it "tells a caller of a refused encoding what to do about it" do
      expect { described_class.search(utf16, "ruby", "$RECV.save") }
        .to raise_error(EncodingError, /String#encode it first -- lain never transcodes for you/)
    end

    it "refuses a non-String, non-Symbol argument by naming what it got" do
      expect { described_class.search(42, "ruby", "$RECV.save") }
        .to raise_error(TypeError, /source must be a String or Symbol, got an Integer/)
    end
  end
end
