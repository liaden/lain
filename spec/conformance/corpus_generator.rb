# frozen_string_literal: true

require "json"
require "fileutils"

# The frozen conformance corpus under ext/lain/corpus, read by `cargo test` (ext/lain/src/corpus.rs) with no
# Ruby VM. Only the canonical vectors still have a Ruby implementation to derive from; the other files are
# frozen fixtures that generation carries through unchanged and the manifest digests hold still.
# `rake conformance:corpus` runs this generator and spec/conformance_corpus_spec.rb re-runs it.
#
# Every line is `{"input": ..., "output": ...}`. Values travel as a tagged tree
# (see Tagged), because plain JSON would lose exactly what the corpus is for:
# Symbols, invalid UTF-8, NaN, -0.0 and Hashes spelling keys both ways.
module ConformanceCorpus
  DIR = File.expand_path("../../ext/lain/corpus", __dir__)
  MANIFEST = File.join(DIR, "MANIFEST.json")
  FILES = %w[canonical event_digest dag store errors].freeze

  ABOUT = "A regression oracle, not a discovery one: the canonical vectors record what the Ruby implementation " \
          "answered at the commit named here, so a change in either implementation shows up as a mismatch. " \
          "The other 4 files are frozen fixtures whose Ruby is gone (see ruby_oracle_retired); only their digests " \
          "hold them still. They cannot find a bug both implementations share."

  RETIRED = {
    "sha" => "a62537cad4fe16747d961a41d262eb1f7b6961d0",
    "vectors" => %w[event_digest dag store errors],
    "why" => "the Ruby implementations these vectors were derived from are deleted; only the digests hold them still"
  }.freeze

  # Where the extension answers differently from Ruby on purpose, matched on Ruby's class and the start of
  # its message. A null rust_message means the extension's message is Ruby's.
  DIVERGENCES = [
    { "ruby_class" => "Lain::Store::MissingObject", "ruby_message_prefix" => "no object",
      "rust_class" => "Lain::Ext::Store::MissingObject", "rust_message" => nil,
      "why" => "the extension raises its own store's class; the message is the same" },
    { "ruby_class" => "Lain::Error", "ruby_message_prefix" => "role must be one of",
      "rust_class" => "Lain::Ext::Event::InvalidRole", "rust_message" => nil,
      "why" => "the extension names the role refusal; Ruby raises its base error" },
    { "ruby_class" => "Lain::Canonical::UnsupportedType", "ruby_message_prefix" => "string is not convertible to UTF-8",
      "rust_class" => "Lain::Canonical::UnsupportedType", "rust_message" => "string is not valid UTF-8",
      "why" => "Ruby transcodes a binary String and reports the failed conversion; the extension reports bad bytes" },
    { "ruby_class" => "JSON::NestingError", "ruby_message_prefix" => "nesting of",
      "rust_class" => "Lain::Canonical::UnsupportedType",
      "rust_message" => "cannot canonicalize a structure nested deeper than 100 levels",
      "why" => "Ruby's limit is JSON.generate's own; the extension refuses the same depth while reading" }
  ].freeze

  # Known differences no vector samples, because the extension refuses or words them differently by design.
  UNSAMPLED = [
    "a render or causal edge naming a stored non-event, or a payload or canonical parent naming an event: " \
    "Ruby's one map accepts it, the extension refuses it as no event or no member",
    "an envelope whose payload digest names a stored payload of another kind: Ruby accepts it, " \
    "the extension refuses it as not its payload",
    "a value with 2 defects: Ruby refuses the first it meets, the extension reads a whole Hash before it " \
    "checks for a key spelled both ways",
    "a refusal quoting a control character or a '\#{': String#inspect and Rust's Debug escape them differently",
    "a role that is neither a String nor a Symbol"
  ].freeze

  module_function

  def path(name) = File.join(DIR, "#{name}.ndjson")

  def blake3(bytes) = "blake3:#{Lain::Ext.blake3_hex(bytes)}"

  # A tagged tree is 2 JSON levels per container, so the deepest vectors pass JSON's default limit of 100.
  def unbounded_json(record) = JSON.generate(record, max_nesting: false)

  # Each corpus file draws from its own stream, so a change to one file's generator leaves the others byte-identical.
  def generate(seed:, sha:)
    in_utf8 do
      files = FILES.each_with_index.to_h { |name, index| ["#{name}.ndjson", contents(name, seed + index)] }
      files.merge("MANIFEST.json" => "#{JSON.pretty_generate(manifest(files, seed:, sha:))}\n")
    end
  end

  def contents(name, seed) = VECTORS.key?(name) ? vectors(name, seed) : read(path(name))

  def vectors(name, seed)
    vectors = VECTORS.fetch(name)
    inputs = vectors.inputs(Draw.new(Random.new(seed)))
    inputs.map { |input| "#{unbounded_json({ "input" => input, "output" => vectors.derive(input) })}\n" }.join
  end

  # The locale decides what encoding a String read without one gets, and how String#inspect quotes non-ASCII
  # in Ruby's own refusal messages, so generating and re-deriving under LC_ALL=C must give a UTF-8 locale's bytes.
  def in_utf8
    external = Encoding.default_external
    Encoding.default_external = Encoding::UTF_8
    yield
  ensure
    Encoding.default_external = external
  end

  def write!(seed:, sha:)
    FileUtils.mkdir_p(DIR)
    generate(seed:, sha:).each { |file, text| File.write(File.join(DIR, file), text, encoding: Encoding::UTF_8) }
  end

  def manifest(files, seed:, sha:)
    { "about" => ABOUT, "seed" => seed, "sha" => sha, "ruby" => RUBY_VERSION, "json" => JSON::VERSION,
      "default_external" => Encoding.default_external.name,
      "files" => files.transform_values { { "blake3" => blake3(_1), "records" => _1.lines.size } },
      "ruby_oracle_retired" => RETIRED, "divergences" => DIVERGENCES, "unsampled" => UNSAMPLED }
  end

  def read(file) = File.read(file, encoding: Encoding::UTF_8)

  def tampered(dir)
    recorded = JSON.parse(read(File.join(dir, "MANIFEST.json"))).fetch("files")
    FILES.filter_map do |name|
      file = "#{name}.ndjson"
      expected = recorded.dig(file, "blake3")
      actual = File.exist?(File.join(dir, file)) ? blake3(File.binread(File.join(dir, file))) : "no file"
      "#{file}: expected #{expected}, found #{actual}" unless actual == expected
    end
  end

  def underived(name)
    vectors = VECTORS.fetch(name)
    in_utf8 do
      records(name).reject { |record, _| vectors.derive(record.fetch("input")) == record.fetch("output") }.map(&:last)
    end
  end

  def recorded = JSON.parse(read(MANIFEST))

  # What the extension must raise where Ruby raised `ruby`: the same, unless DIVERGENCES names the difference.
  def extension_refusal(ruby)
    known = DIVERGENCES.find do |divergence|
      divergence["ruby_class"] == ruby["class"] && ruby["message"].start_with?(divergence["ruby_message_prefix"])
    end
    known ? [known["rust_class"], known["rust_message"] || ruby["message"]] : ruby.values_at("class", "message")
  end

  def records(name)
    File.foreach(path(name), encoding: Encoding::UTF_8).with_index(1).map do |line, number|
      [JSON.parse(line, max_nesting: false), "#{name}.ndjson:#{number}"]
    end
  end

  def recorded_seed = recorded.fetch("seed")

  # The tagged tree. Every node is a JSON array whose head names the Ruby type it stands for:
  # nil, true, false, int (decimal text), float (the 64 IEEE bits as 16 hex digits, so NaN payloads and -0.0
  # survive), str (a valid UTF-8 String), bin (a binary String, hex), bad (a UTF-8 String holding invalid
  # bytes, hex), sym, arr, hash (key and value pairs in insertion order, so mixed spellings survive) and obj.
  module Tagged
    module_function

    def encode(value)
      case value
      when nil then ["nil"]
      when true then ["true"]
      when false then ["false"]
      when Integer then ["int", value.to_s]
      when Float then ["float", bits(value)]
      when Symbol then ["sym", value.name]
      when String then string(value)
      when Array then ["arr", value.map { encode(_1) }]
      when Hash then ["hash", value.map { |key, item| [encode(key), encode(item)] }]
      else ["obj", value.class.name]
      end
    end

    def string(value)
      case value.encoding
      when Encoding::BINARY then ["bin", value.unpack1("H*")]
      when Encoding::UTF_8 then value.valid_encoding? ? ["str", value] : ["bad", value.b.unpack1("H*")]
      else raise ArgumentError, "the corpus encodes UTF-8 and binary Strings only, not #{value.encoding}"
      end
    end

    def decode(tag)
      case tag
      in ["arr", items] then items.map { decode(_1) }
      in ["hash", pairs] then pairs.to_h { |key, item| [decode(key), decode(item)] }
      in ["bin" | "bad", hex] then bytes(*tag)
      else scalar(*tag)
      end
    end

    def scalar(head, operand = nil)
      case head
      when "nil" then nil
      when "true" then true
      when "false" then false
      when "int" then Integer(operand, 10)
      when "float" then float(operand)
      when "sym" then operand.to_sym
      when "str" then operand
      else Object.const_get(operand).new
      end
    end

    def bytes(head, hex)
      binary = [hex].pack("H*")
      head == "bad" ? binary.force_encoding(Encoding::UTF_8) : binary
    end

    def bits(float) = [float].pack("G").unpack1("H*")

    def float(hex) = [hex].pack("H*").unpack1("G")

    # Ruby's own text for every finite float in `tag`, keyed by its bits: the one thing the extension cannot
    # re-derive (canonical.rs), so a reader without Ruby takes it from here.
    def floats(tag)
      case tag
      in ["float", hex] then float(hex).finite? ? { hex => JSON.generate(float(hex)) } : {}
      in ["arr", items] then texts(items)
      in ["hash", pairs] then texts(pairs.flatten(1))
      else {}
      end
    end

    def texts(tags) = tags.map { floats(_1) }.reduce({}, :merge).sort.to_h

    # Structural identity that tells apart what `==` collapses: -0.0 from 0.0, a NaN from itself, a Symbol
    # from a String, and one encoding from another.
    def identical?(one, other)
      return false unless one.instance_of?(other.class)

      case one
      when Float then bits(one) == bits(other)
      when String then one.encoding == other.encoding && one.b == other.b
      when Array then one.size == other.size && one.zip(other).all? { identical?(*_1) }
      when Hash then identical?(one.to_a, other.to_a)
      when Integer, Symbol, NilClass, TrueClass, FalseClass then one == other
      else true
      end
    end
  end

  # Every random choice the generator makes, from one seeded stream.
  class Draw
    WORDS = ["a", "b", "Z", "aa", "é", "日本", "\u{1f980}", "a\"b", "back\\slash", "tab\there",
             "nl\nx", "\u0000nul", "\u001fus", "\u007fdel", "sl/ash", " ls", "é", "", "parent"].freeze
    FLOATS = [0.0, -0.0, 1.0, -1.0, 0.1, 0.5, 100.0, 1e15, 1e16, 1e17, 1e20, 1e21, 1e22, 1e23, 1e-4, 1e-5,
              1e-6, 1e-7, 5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, 9_007_199_254_740_992.0,
              9_007_199_254_740_993.0, 123_456_789.12345679, 0.30000000000000004, -1.5e-300, 1.0e+100].freeze
    INTEGERS = [0, -1, 2**31, -2**31, 2**53, (2**63) - 1, -2**63, 2**63, -2**63 - 1, 2**64, 10**40].freeze

    def initialize(rng) = @rng = rng

    def chance?(probability) = @rng.rand < probability

    def pick(list) = list.empty? ? nil : list[@rng.rand(list.size)]

    def int(range) = @rng.rand(range)

    def text
      case int(0..3)
      when 0 then pick(WORDS)
      when 1 then Array.new(int(0..8)) { int(32..126).chr }.join.encode(Encoding::UTF_8)
      when 2 then Array.new(int(0..6)) { codepoint }.pack("U*")
      else Array.new(int(1..3)) { pick(WORDS) }.join.encode(Encoding::UTF_8)
      end
    end

    def codepoint = int(pick([0..0x7f, 0x80..0x7ff, 0x800..0xd7ff, 0xe000..0xffff, 0x10000..0x10ffff]))

    def integer
      case int(0..3)
      when 0 then int(-10..10)
      when 1 then pick(INTEGERS)
      when 2 then int(10**30) * pick([1, -1])
      else int((-2**62)..(2**62))
      end
    end

    def float
      case int(0..3)
      when 0 then pick(FLOATS)
      when 1 then Enumerator.produce { @rng.bytes(8).unpack1("G") }.find(&:finite?)
      when 2 then (@rng.rand * (10.0**int(-12..25))).round(int(0..6))
      else int((-10**18)..(10**18)).to_f
      end
    end

    def leaf
      case int(0..8)
      when 0 then pick([nil, true, false])
      when 1, 2 then integer
      when 3, 4 then float
      when 5, 6 then text
      when 7 then text.to_sym
      else Array.new(int(0..6)) { int(0..127).chr }.join.b
      end
    end

    def value(depth = 0)
      return leaf if depth >= 4 || chance?(0.4)

      chance?(0.5) ? Array.new(int(0..4)) { value(depth + 1) } : table(depth + 1)
    end

    def table(depth = 1)
      Array.new(int(0..4)) { text }.uniq.to_h { [spelled(_1), value(depth)] }
    end

    def spelled(text) = chance?(0.5) ? text.to_sym : text
  end

  # Values Canonical accepts: its dump and digest.
  module CanonicalVectors
    module_function

    def inputs(draw) = edges.map { { "value" => Tagged.encode(_1) } } + Array.new(2000) { random(draw) }

    def random(draw) = { "value" => Tagged.encode(draw.value) }

    def edges
      deepest = 99.times.inject([]) { |inner, _| [inner] }
      [deepest, [], {}, "", { a: 1, "b" => 2 }, { "é" => 1, "z" => 2, "Z" => 3, "aa" => 4, "a" => 5 },
       *Draw::FLOATS, *Draw::INTEGERS, "/\u007f ", "a".b, :sym, [:text, "text"]]
    end

    def derive(input)
      value = Tagged.decode(input.fetch("value"))
      { "floats" => Tagged.floats(input.fetch("value")), "dump" => Lain::Canonical.dump(value),
        "digest" => Lain::Canonical.digest(value) }
    end
  end

  VECTORS = { "canonical" => CanonicalVectors }.freeze
end
