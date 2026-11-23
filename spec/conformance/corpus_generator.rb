# frozen_string_literal: true

require "json"
require "fileutils"
require "yaml"

# The frozen conformance corpus under ext/lain/corpus, read by `cargo test` (ext/lain/src/corpus.rs) with no
# Ruby VM. The canonical vectors and the 3 masking vectors (detect, recurrences, entropy) still have a Ruby
# implementation to derive from; the other files are frozen fixtures that generation carries through unchanged
# and the manifest digests hold still. A masking input's `bytes` is hex in groups of 4 bytes split by spaces, and
# an input with a `fill` of at, chunk and times splices chunk repeated times at byte offset at into bytes.
# `rake conformance:corpus` runs this generator and spec/conformance_corpus_spec.rb re-runs it.
#
# Every line is `{"input": ..., "output": ...}`. Values travel as a tagged tree
# (see Tagged), because plain JSON would lose exactly what the corpus is for:
# Symbols, invalid UTF-8, NaN, -0.0 and Hashes spelling keys both ways.
module ConformanceCorpus
  DIR = File.expand_path("../../ext/lain/corpus", __dir__)
  MANIFEST = File.join(DIR, "MANIFEST.json")
  FILES = %w[canonical event_digest dag store errors regions toml detect recurrences entropy].freeze

  ABOUT = "A regression oracle, not a discovery one: the canonical vectors record what the Ruby implementation " \
          "answered at the commit named here, so a change in either implementation shows up as a mismatch. " \
          "The detect, recurrences and entropy vectors record the masking path's answers before it moved to Rust; " \
          "their hex holds spaces between 4-byte groups, and a detect input's fill (at, chunk, times) splices " \
          "chunk repeated times into its bytes at byte offset at. " \
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

  # The spike-labelled inputs are carried through the file, so regenerating never reads the tree. A BOM is
  # skipped for the scan and added back to every offset, as Regions.detect does.
  module RegionVectors
    module_function

    def shapes
      regions = Lain::Sensitivity::Regions
      regions::CONTENT_SHAPES.merge(%w[TOKEN PEM_PUBLIC OPENSSH_PUBLIC CHECKSUM_FIELD INTEGRITY_FIELD]
                                      .to_h { [_1, regions.const_get(_1)] })
    end

    def inputs(_draw) = (WRITTEN + carried).map { |shape, label, bytes| entry(shape, label, bytes) }

    def entry(shape, label, bytes) = { "shape" => shape, "label" => label, "bytes" => bytes.b.unpack1("H*") }

    def carried
      return [] unless File.exist?(ConformanceCorpus.path("regions"))

      spikes = ConformanceCorpus.records("regions").map { |record, _| record.fetch("input") }
                                .select { |input| input.fetch("label").match?(SPIKE_LABEL) }
      spikes.map { |input| [input.fetch("shape"), input.fetch("label"), [input.fetch("bytes")].pack("H*")] }
    end

    def derive(input)
      bytes = [input.fetch("bytes")].pack("H*")
      skip = bytes.start_with?(BOM) ? BOM.bytesize : 0
      shape = shapes.fetch(input.fetch("shape"))
      { "skip" => skip, "matches" => matches(shape, bytes.byteslice(skip..), skip) }
    end

    def matches(shape, scanned, skip)
      found = scanned.to_enum(:scan, shape).map { Regexp.last_match }
      found.map { |match| ["0", *shape.names.uniq].to_h { |name| [name, range(match, name, skip)] } }
    end

    def range(match, name, skip)
      group = name == "0" ? 0 : name
      match.begin(group) && [match.begin(group) + skip, match.end(group) + skip]
    end

    SPIKE_LABEL = /\Aspike /
    BOM = Lain::Sensitivity::Regions::BOM
    B64 = "Zq8vLm2xK9" * 8
    HEX = "a3f9c1d70b" * 7
    private_constant :B64, :HEX

    # Values are generated, never a credential anyone holds. A near-miss is text that looks like its
    # shape and must not match it.
    WRITTEN = [
      ["openai-style api key", "positive", "key = sk-#{B64[0, 24]}\n"],
      ["openai-style api key", "near_miss", "ask-someone-to-help-with-this-quickly\n"],
      ["aws access key id", "positive", "id = AKIA#{"ABCDEFGH" * 2}\n"],
      ["aws access key id", "near_miss", "id = AKIAABC123\n"],
      ["pem private key block", "positive",
       "-----BEGIN RSA PRIVATE KEY-----\n#{B64[0, 64]}\n-----END RSA PRIVATE KEY-----\nafter\n"],
      ["pem private key block", "near_miss",
       "-----BEGIN PUBLIC KEY-----\n#{B64[0, 64]}\n-----END PUBLIC KEY-----\n"],
      ["github token", "positive", "token ghp_#{("AbCd1234" * 5)[0, 36]} end\n"],
      ["github token", "near_miss", "token ghp_short end\n"],
      ["stripe key", "positive", "key = sk_live_#{B64[0, 24]}\n"],
      ["stripe key", "near_miss", "key = pk_live_#{B64[0, 24]}\n"],
      ["credential assignment", "positive", %(api_key = "#{B64[0, 12]}"\n)],
      ["credential assignment", "near_miss", "the token is unset\n"],
      ["dotenv assignment", "positive", "export DB_HOST=db.internal\n"],
      ["dotenv assignment", "near_miss", "a line of prose with no equals sign\n"],
      ["toml assignment", "positive", %(name = "lain"\n)],
      ["toml assignment", "near_miss", "name = bare\n"],
      ["yaml assignment", "positive", "adapter: postgresql\n"],
      ["yaml assignment", "near_miss", "adapter:\n  - postgresql\n"],
      ["netrc password", "positive", "machine example.com login lain password #{B64[0, 8]}\n"],
      ["netrc password", "netrc password first", "machine example.com password s3cretpw login lain\n"],
      ["netrc password", "near_miss", "default password reset\n"],
      ["pgpass entry", "positive", "db.internal:5432:lain:lain:#{B64[0, 10]}\n"],
      ["pgpass entry", "near_miss", "12:34:56:78:90\n"],
      ["htpasswd hash", "positive", "lain:$apr1$abcdefgh$#{B64[0, 22]}\n"],
      ["htpasswd hash", "near_miss", "lain:plaintext\n"],
      ["msmtprc password", "positive", "password #{B64[0, 10]}\n"],
      ["msmtprc password", "near_miss", "password required now\n"],
      ["quoted password key", "positive", %({"db_password": "#{B64[0, 10]}"}\n)],
      ["quoted password key", "near_miss", %({"db_password": "short"}\n)],
      ["url credentials", "positive", "postgres://lain:#{B64[0, 10]}@db.internal/app\n"],
      ["url credentials", "near_miss", "https://example.com:8080/path\n"],
      ["bearer header", "positive", "Authorization: Bearer abc123def456ghi\n"],
      ["bearer header", "near_miss", "Authorization: Bearer onlyletters\n"],
      ["suffixed password key", "positive", "db_password: #{B64[0, 10]}\n"],
      ["suffixed password key", "near_miss", "password: #{B64[0, 10]}\n"],
      ["mysql password flag", "positive", "mysql -u root -p#{B64[0, 10]} app\n"],
      ["mysql password flag", "near_miss", "mysql -u root app\n"],
      ["credential literal assignment", "positive", %(secret = "#{B64[0, 10]}"\n)],
      ["credential literal assignment", "near_miss", "secret = ENV['LAIN_SECRET']\n"],
      ["password variable assignment", "positive", "PGPASSWORD=#{B64[0, 10]} psql\n"],
      ["password variable assignment", "quoted", %(PGPASSWORD="#{B64[0, 10]}" psql\n)],
      ["password variable assignment", "near_miss", "OLDPWD=/home/lain\n"],
      ["TOKEN", "positive", "tok = #{B64[0, 30]}==\n"],
      ["TOKEN", "near_miss", "short-token\n"],
      ["PEM_PUBLIC", "positive", "-----BEGIN PUBLIC KEY-----\r\n#{B64[0, 40]}\r\n-----END PUBLIC KEY-----\n"],
      ["PEM_PUBLIC", "near_miss", "-----BEGIN PUBLIC KEY-----\n#{B64[0, 40]}\n-----END RSA PUBLIC KEY-----\n"],
      ["OPENSSH_PUBLIC", "positive", "ssh-ed25519 AAAAC3#{B64[0, 40]} lain@host\n"],
      ["OPENSSH_PUBLIC", "near_miss", "ssh-ed25519 notbase64key\n"],
      ["CHECKSUM_FIELD", "positive", %(checksum = "#{HEX[0, 64]}"\n)],
      ["CHECKSUM_FIELD", "near_miss", %(token = "#{HEX[0, 64]}"\n)],
      ["INTEGRITY_FIELD", "positive", "  integrity sha1-#{B64[0, 27]}=\n"],
      ["INTEGRITY_FIELD", "near_miss", "  integrity sha1-short=\n"],
      ["dotenv assignment", "bom", "#{BOM}API_KEY=#{B64[0, 12]}\n"],
      ["dotenv assignment", "invalid_utf8", "note = \xff\xfe\nAPI_KEY=#{B64[0, 12]}\n"],
      ["dotenv assignment", "utf16",
       "\xFF\xFE".b + "API_KEY=x".encode(Encoding::UTF_16LE).b + "\nAPI_KEY=#{B64[0, 12]}\n".b]
    ].map { |shape, label, text| [shape, label, text.b] }.freeze
  end

  # toml-test's vendored cases, in path order. The oracle is the expected JSON beside each valid case, so
  # regenerating reads the fixtures and no Ruby parser answers anything.
  module TomlVectors
    ROOT = File.expand_path("../fixtures/toml-test", __dir__)

    module_function

    def inputs(_draw) = names.map { |name| { "case" => name, "text" => Tagged.encode(source(name)) } }

    def names = Dir.glob("{valid,invalid}/**/*.toml", base: ROOT).sort

    def source(name) = File.read(File.join(ROOT, name), encoding: Encoding::UTF_8)

    def derive(input)
      name = input.fetch("case")
      return { "refused" => true } if name.start_with?("invalid/")

      { "expected" => JSON.parse(source(name.sub(/\.toml\z/, ".json"))) }
    end
  end

  # The answers Regions.detect, Regions.recurrences and Entropy gave before the masking path moved to Rust.
  # Texts and tokens travel as spaced hex so the file holds no credential-shaped plain text for a push scanner to
  # refuse; the labelled corpora's own values are written as parts for the same reason.
  module MaskingInputs
    FIXTURES = File.expand_path("../fixtures/sensitivity", __dir__)
    LOCKS = { "Cargo.lock" => "../../Cargo.lock", "Gemfile.lock" => "../../Gemfile.lock" }.freeze
    SLICES = 10
    SLICE_LINES = 40
    BASE64 = [*"A".."Z", *"a".."z", *"0".."9", "+", "/", "-", "_"].freeze
    HEXDIGITS = [*"0".."9", *"a".."f"].freeze
    PATHS = %w[/usr/lib/x86_64-linux-gnu/libssl.so.3 src/lain/sensitivity/regions.rb
               /tmp/d20261019-4211-1xk2p9 crates/lain-daemon/src/main.rs node_modules/.bin/eslint].freeze

    module_function

    # Groups of 4 bytes, because a scanner decodes a long unbroken hex run and reads the secret inside it.
    def hex(text) = text.b.unpack1("H*").scan(/.{1,8}/).join(" ")

    def unhex(text) = [text.delete(" ")].pack("H*")

    # A run too long to store is a chunk and a count, spliced in at a byte offset, so the file stays small.
    def text(input)
      bytes = unhex(input.fetch("bytes"))
      fill = input["fill"]
      return bytes unless fill

      at = fill.fetch("at")
      bytes.byteslice(0, at) + (unhex(fill.fetch("chunk")) * fill.fetch("times")) + bytes.byteslice(at..)
    end

    def corpus(name) = YAML.safe_load_file(File.join(FIXTURES, "#{name}_corpus.yml"))

    def hinted = corpus("hinted").map { |row| [row.fetch("label"), Array(row.fetch("value")).join] }

    def digests = corpus("digest").map { |row| [row.fetch("label"), Array(row.fetch("line")).join] }

    def public_texts = corpus("public").map { |row| [row.fetch("label"), Array(row.fetch("text")).join] }

    def token(draw, length, alphabet = BASE64) = Array.new(length) { draw.pick(alphabet) }.join

    def lock_slices
      LOCKS.flat_map do |name, relative|
        lines = File.readlines(File.expand_path(relative, __dir__), encoding: Encoding::UTF_8)
        step = (lines.size - SLICE_LINES) / SLICES
        Array.new(SLICES) { |index| ["slice #{name}: #{index}", lines[index * step, SLICE_LINES].join] }
      end
    end
  end

  # Every labelled corpus value in 4 framings, 20 slices of the repository's own lock files, and 200 texts
  # drawn from the seed. The slices are carried once written, so a lock file that moves later cannot move them.
  module DetectVectors
    FRAMINGS = {
      "bare" => ->(text) { text },
      "key" => ->(text) { "API_KEY=#{text}" },
      "yaml" => ->(text) { "token: #{JSON.generate(text)}\n" },
      "json" => ->(text) { %({"secret": #{JSON.generate(text)}}\n) }
    }.freeze

    module_function

    # The secrets are built from parts, so this file holds no credential-shaped plain text.
    NAMED = [
      ["toml assignment", "aws-secret-access-key = \"#{"Zq8vLm2xK9" * 2}\"\n"],
      ["yaml assignment", "aws-secret-access-key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n"],
      ["credential literal assignment", "api_secret: #{"Zq8vLm2xK9" * 2}\n"],
      ["password variable assignment", "env PGPASSWORD=#{"Zq8vLm2xK9" * 2} psql -h db\n"]
    ].freeze

    # Past the second backtrack limit a multi-line shape is masked whole, from its last finished match to the end.
    RUNAWAY_PEM = { "at" => 27, "chunk" => "A", "times" => 1_000_000 }.freeze

    def inputs(draw)
      framed + flagged + slices + Array.new(200) { |index| generated(draw, index) } + written + named + [over_masked]
    end

    def entry(label, text, checksums: false, hinted: false, fill: nil)
      { "label" => label, "bytes" => MaskingInputs.hex(text), "checksums" => checksums, "hinted" => hinted }
        .merge(fill ? { "fill" => fill.merge("chunk" => MaskingInputs.hex(fill.fetch("chunk"))) } : {})
    end

    def written
      RegionVectors::WRITTEN.reject { |_, label, _| label == "near_miss" }
                            .map { |shape, label, bytes| entry("written: #{shape} / #{label}", bytes) }
    end

    def named = NAMED.map { |reason, text| entry("named: #{reason}", text) }

    def over_masked
      text = "-----BEGIN PUBLIC KEY-----\n-----END RSA PUBLIC KEY-----\nAKIA#{"ABCDEFGH" * 2}\n"
      entry("over-masked: public key run", text, fill: RUNAWAY_PEM)
    end

    def framed
      { "hinted" => MaskingInputs.hinted, "digest" => MaskingInputs.digests, "public" => MaskingInputs.public_texts }
        .flat_map do |corpus, rows|
        FRAMINGS.flat_map do |framing, wrap|
          rows.map do |label, text|
            entry("#{corpus} #{framing}: #{label}", wrap.call(text))
          end
        end
      end
    end

    def flagged
      MaskingInputs.hinted.map { |label, text| entry("hinted flagged: #{label}", text, hinted: true) } +
        MaskingInputs.digests.map { |label, text| entry("digest checksums: #{label}", text, checksums: true) }
    end

    def slices
      path = ConformanceCorpus.path("detect")
      return MaskingInputs.lock_slices.map { |label, text| entry(label, text) } unless File.exist?(path)

      ConformanceCorpus.records("detect").map { |record, _| record.fetch("input") }
                       .select { _1.fetch("label").start_with?("slice ") }
    end

    def generated(draw, index)
      lines = Array.new(draw.int(2..8)) { line(draw) }
      entry("generated: #{index}", "#{lines.join("\n")}\n", checksums: draw.chance?(0.15), hinted: draw.chance?(0.15))
    end

    def line(draw)
      case draw.int(0..6)
      when 0 then "KEY_#{draw.int(0..99)}=#{MaskingInputs.token(draw, draw.int(8..48))}"
      when 1 then "#{draw.pick(%w[sha256 digest checksum])}: #{MaskingInputs.token(draw, draw.pick([32, 40, 64]), MaskingInputs::HEXDIGITS)}"
      when 2 then draw.pick(MaskingInputs::PATHS)
      when 3 then "token #{MaskingInputs.token(draw, draw.int(16..44))} end"
      when 4 then Array.new(draw.int(2..6)) { draw.pick(ConformanceCorpus::Draw::WORDS) }.join(" ")
      else "the #{draw.pick(%w[value file call])} is #{MaskingInputs.token(draw, draw.int(5..30))}"
      end
    end

    def derive(input)
      bytes = MaskingInputs.text(input)
      regions = Lain::Sensitivity::Regions.detect(bytes, checksums: input.fetch("checksums"),
                                                         hinted: input.fetch("hinted"))
      { "regions" => regions.map { [_1.start, _1.start + _1.length, _1.reason, _1.detector.to_s, _1.over_masked_by] } }
    end
  end

  # Texts holding secrets raw, escaped as inspect escapes them, overlapping, beside placeholders and in UTF-16.
  module RecurrenceVectors
    KINDS = %w[plain overlapping multibyte escaped placeholder short utf16].freeze
    PER_KIND = 20
    PLACEHOLDER = "<redacted:3>"

    module_function

    def inputs(draw) = KINDS.flat_map { |kind| Array.new(PER_KIND) { |index| send(kind, draw, "#{kind}: #{index}") } }

    def entry(label, text, secrets)
      { "label" => label, "bytes" => MaskingInputs.hex(text), "secrets" => secrets.map { MaskingInputs.hex(_1) } }
    end

    def secret(draw) = MaskingInputs.token(draw, draw.int(6..24))

    def plain(draw, label)
      value = secret(draw)
      entry(label, "a #{value} b #{value}\nc #{value}", [value])
    end

    def overlapping(draw, label)
      value = secret(draw) + MaskingInputs.token(draw, 6)
      inner = value[draw.int(1..4), draw.int(6..10)]
      entry(label, "x #{value} y #{inner} z", [value, inner, value])
    end

    def multibyte(draw, label)
      value = "#{draw.pick(%w[é 日本 \u{1f980}])}#{secret(draw)}#{draw.pick(%w[ü 語])}"
      entry(label, "k=#{value}; again #{value.inspect}", [value])
    end

    def escaped(draw, label)
      value = "#{secret(draw)}#{draw.pick(["\"", "\\", "\n", "\t", "\u0001"])}#{secret(draw)}"
      entry(label, "raw #{value} lit #{value.inspect}", [value])
    end

    def placeholder(draw, label)
      value = secret(draw)
      entry(label, "#{PLACEHOLDER}#{value} #{value}#{PLACEHOLDER} #{value}", [value])
    end

    def short(draw, label)
      value = secret(draw)[0, draw.int(1..5)]
      entry(label, "short #{value} and #{value}", [value, secret(draw)])
    end

    def utf16(draw, label)
      value = secret(draw)
      text = "\uFEFF".encode(Encoding::UTF_16LE).b + "k=#{value} #{PLACEHOLDER} #{value}".encode(Encoding::UTF_16LE).b
      entry(label, text + " #{value}".b, [value])
    end

    def derive(input)
      bytes = MaskingInputs.unhex(input.fetch("bytes"))
      secrets = input.fetch("secrets").map { MaskingInputs.unhex(_1).force_encoding(Encoding::UTF_8) }
      { "spans" => Lain::Sensitivity::Regions.recurrences(bytes, secrets).map { [_1.start, _1.finish] } }
    end
  end

  # Tokens as UTF-8 and again as binary, because each_char reads symbols for one and bytes for the other.
  module EntropyVectors
    RUNS = ["abcdefghijklmnop", "0123456789abcdef", "xabcdefyzzz", "ABCDEFGHIJKL1", "aaaaaaaaaaaaaaaa", "ab" * 12,
            ""].freeze
    ASCENDING = ["abcdefghijklmnopq", "ABCDEFGHIJKLMNOPQRS", "0123456789:;<=>?@A"].freeze
    MULTIBYTE_ENDS = %w[é 日本 ü \u{1f980}].freeze
    MULTIBYTE = ["éééééééééééé", "日本語日本語日本語", "caf\u00e9#{"x" * 10}", "\u{1f980}\u{1f980}\u{1f980}\u{1f980}",
                 "abc\u00e9def\u00e9ghi\u00e9jkl", "ñandú-ñandú-ñandú"].freeze

    module_function

    def inputs(draw)
      tokens = fixed + corpus_tokens + Array.new(60) { MaskingInputs.token(draw, draw.int(4..64)) } +
               Array.new(20) { Array.new(draw.int(4..16)) { [draw.codepoint] }.flatten.pack("U*") }
      tokens.uniq.flat_map { |token| [entry(token, false), entry(token, true)] }
    end

    def fixed = [*RUNS, *MULTIBYTE, *runs_beside_multibyte]

    def runs_beside_multibyte
      ASCENDING.product(MULTIBYTE_ENDS).flat_map { |run, wide| ["#{wide}#{run}", "#{run}#{wide}"] }
    end

    def corpus_tokens
      values = MaskingInputs.hinted.map(&:last) + MaskingInputs.digests.flat_map { _2.split }
      values.select { _1.bytesize.between?(4, 128) && _1.valid_encoding? }
    end

    def entry(token, binary) = { "token" => MaskingInputs.hex(token), "binary" => binary }

    def derive(input)
      token = MaskingInputs.unhex(input.fetch("token"))
      token.force_encoding(Encoding::UTF_8) unless input.fetch("binary")
      entropy = Lain::Ext::Entropy
      { "shannon" => Tagged.bits(entropy.shannon(token)), "alphabet_run" => entropy.alphabet_run?(token) }
    end
  end

  VECTORS = { "canonical" => CanonicalVectors, "regions" => RegionVectors, "toml" => TomlVectors,
              "detect" => DetectVectors, "recurrences" => RecurrenceVectors, "entropy" => EntropyVectors }.freeze
end
