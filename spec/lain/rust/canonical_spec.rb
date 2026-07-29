# frozen_string_literal: true

# The Rust canonicalizer (`Lain::Ext.canonical_dump`/`canonical_digest`) must be
# a byte-for-byte twin of `Lain::Canonical`. It drives the SAME shared
# determinism group the Ruby impl does (proving both satisfy one contract), and
# is then pinned directly against the Ruby output over a battery that includes
# the cases where a naive Rust port would silently diverge (float exponentials,
# bignums, non-ASCII, nested sorting).
RSpec.describe "Lain::Ext canonical (Rust)" do
  describe ".canonical_dump" do
    include_examples "canonical determinism",
                     dump: ->(input) { Lain::Ext.canonical_dump(input) },
                     ambiguous_key_error: Lain::Canonical::AmbiguousKey,
                     non_finite_float_error: Lain::Canonical::NonFiniteFloat,
                     unsupported_type_error: Lain::Canonical::UnsupportedType
  end

  # Values chosen to catch the byte-level divergences a reimplemented serializer
  # hides: Ruby's JSON float format differs from both `Float#to_s` and Rust's
  # shortest-float output in the exponential ranges, integers can exceed i64, and
  # object key order must be sorted recursively.
  def byte_parity_values
    [
      { "a" => 1 }, { a: 1 }, { "b" => 1, "a" => 2 },
      { "z" => { "b" => 1, "a" => 2 }, "y" => 3 },
      [3, 1, 2], "café", { "k" => "café" }, [:text],
      { "n" => nil, "t" => true, "f" => false },
      1, -1, 2**80, { "big" => 2**64 },
      0.0, 1.0, -0.0, 0.1, 3.14, 1e20, 1e-7, 123_456_789_012_345.0,
      { "content" => [{ "type" => "text", "text" => "hi" }], "meta" => { "spawned_from" => "blake3:abc" } }
    ]
  end

  describe "byte-for-byte agreement with Lain::Canonical" do
    it "dumps identically to the Ruby canonicalizer" do
      byte_parity_values.each do |value|
        expect(Lain::Ext.canonical_dump(value))
          .to eq(Lain::Canonical.dump(value)), "dump mismatch for #{value.inspect}"
      end
    end

    it "digests identically to the Ruby canonicalizer" do
      byte_parity_values.each do |value|
        expect(Lain::Ext.canonical_digest(value))
          .to eq(Lain::Canonical.digest(value)), "digest mismatch for #{value.inspect}"
      end
    end
  end

  describe ".canonical_digest" do
    it "is the prefixed blake3 of the canonical dump" do
      # Independently checked with `b3sum` over the bytes of `{"a":1}`.
      expected = "d59b6562d7c9b121bc9760873d787890ef4d429aad33a70b405baa0fa08a1f53"
      expect(Lain::Ext.canonical_digest({ "a" => 1 })).to eq("blake3:#{expected}")
    end
    # Order-independence of the digest is not re-asserted here: the shared
    # "canonical determinism" group already proves the dump is order-independent,
    # and the digest is a deterministic blake3 of that dump.
  end

  # The Rust reader recurses per nesting level, and an unbounded recursion over
  # a hostile structure is a stack overflow -- which Ruby's guard page turns
  # into a SystemStackError that longjmps through live Rust frames, running no
  # destructor (the failure prompt.rs's MAX_DEPTH was added for, measured there
  # at 16 MB leaked over 200 overflows). The bound is set where RUBY's own
  # boundary already is: `Canonical.dump` ends in `JSON.generate`, whose default
  # `max_nesting` is 100, so 100 containers is exactly the deepest structure the
  # Ruby implementation can serialize. Pinning both sides here is what makes the
  # bound a parity fact rather than a Rust-side preference -- if a JSON gem
  # upgrade moves Ruby's limit, the first example below fails and the constant
  # gets revisited.
  describe "nesting depth" do
    # `nest(n)` wraps `1` in n containers, so n IS the nesting depth.
    def nest_arrays(depth) = depth.zero? ? 1 : [nest_arrays(depth - 1)]

    def nest_hashes(depth) = depth.zero? ? 1 : { "a" => nest_hashes(depth - 1) }

    it "accepts the deepest structure the Ruby canonicalizer can dump" do
      expect(Lain::Canonical.dump(nest_arrays(100))).to eq("#{"[" * 100}1#{"]" * 100}")
      expect(Lain::Ext.canonical_dump(nest_arrays(100))).to eq(Lain::Canonical.dump(nest_arrays(100)))
    end

    it "refuses one level past that, where Ruby's own JSON.generate refuses too" do
      expect { Lain::Canonical.dump(nest_arrays(101)) }.to raise_error(JSON::NestingError)
      expect { Lain::Ext.canonical_dump(nest_arrays(101)) }
        .to raise_error(Lain::Canonical::UnsupportedType, /nested deeper than 100/)
    end

    it "bounds Hash nesting by the same count" do
      expect(Lain::Ext.canonical_dump(nest_hashes(100))).to eq(Lain::Canonical.dump(nest_hashes(100)))
      expect { Lain::Ext.canonical_dump(nest_hashes(101)) }
        .to raise_error(Lain::Canonical::UnsupportedType, /nested deeper than 100/)
    end

    it "bounds the digest entry point too, not only the dump" do
      expect { Lain::Ext.canonical_digest(nest_arrays(101)) }
        .to raise_error(Lain::Canonical::UnsupportedType, /nested deeper than 100/)
    end

    # The refusal must unwind Rust frames normally -- a returned Error, never an
    # overflow -- so repeating it reclaims everything. Mirrors prompt_spec.rb's
    # "leaks nothing across repeated refusals", with the RSS measurement the
    # card's AC names: a leaked frame per call would be visible over 100 of them.
    #
    # 101 levels, not a headroom number: the reader refuses at 101 and never
    # visits anything below it, so a deeper input exercises nothing extra while
    # making the fixture the expensive part.
    #
    # Sensitivity comes from the call COUNT, not from a tight threshold. RSS is
    # process-global, and inside a 6500-example suite the measured window picks
    # up unrelated allocation -- a 512 KiB bound over 100 calls failed once and
    # passed once here, which is a flaky test, not a sensitive one. 1000 calls
    # against a 2 MiB bound tolerates that noise while catching a leak of 2 KiB
    # per call; the leak this guards against (Rust frames abandoned by a
    # longjmp through ~100 recursion levels) would be an order of magnitude
    # above that. Both batches run before the measured one so nothing here is
    # measuring first-call warmup.
    it "leaks nothing across 1000 repeated refusals" do
      deep = nest_arrays(101)
      1_000.times { expect { Lain::Ext.canonical_dump(deep) }.to raise_error(Lain::Canonical::UnsupportedType) }
      GC.start
      before = resident_bytes

      1_000.times { expect { Lain::Ext.canonical_dump(deep) }.to raise_error(Lain::Canonical::UnsupportedType) }
      GC.start

      growth = resident_bytes - before
      expect(growth).to(be < 2 * 1024 * 1024, "RSS grew #{growth} bytes")
      expect(Lain::Ext.canonical_dump({ "a" => 1 })).to eq('{"a":1}')
    end

    # Resident pages, from procfs -- the same number `ps rss` reports.
    def resident_bytes
      File.read("/proc/self/statm").split[1].to_i * 4096
    rescue Errno::ENOENT
      skip "no /proc/self/statm on this platform"
    end
  end
end
