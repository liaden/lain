# frozen_string_literal: true

require "json"
require "open3"

# Ruby's secret shapes, translated into the Rust dialect and compiled into one Rust set on first use.
# Each translation rule is checked by what it scans: the compiled shape finds what the Ruby regex finds.
RSpec.describe Lain::Sensitivity::RustShapes do
  def ruby_matches(regexp, text)
    text.b.to_enum(:scan, regexp).map { Regexp.last_match }.map do |match|
      named = match.names.uniq.filter_map { |name| match.begin(name) && [name, [match.begin(name), match.end(name)]] }
      [0, match.begin(0), match.end(0), named.to_h]
    end
  end

  def rust_matches(regexp, text)
    described_class.compile({ "shape" => regexp }).scan(text.b).matches.map do |index, start, finish, groups|
      [index, start, finish, groups.reject { |name, _| name.match?(/\A\d+\z/) }]
    end
  end

  # A literal refuses a ] leading a class, so this one is built at runtime, where it only warns. Both class
  # examples are extended, where only the space inside the class tells where the class ends.
  leading_bracket = begin
    verbose = $VERBOSE
    $VERBOSE = nil
    Regexp.new("[]a ]+", Regexp::EXTENDED)
  ensure
    $VERBOSE = verbose
  end

  {
    "\\h as a hex digit" => [/\h{4}\H/, "x beef! 12ag 0A9fz"],
    "\\h inside a class" => [/[\h_]+/, "zz_ab_12 gg"],
    "\\H inside a class" => [/[\H.]+/, "ab.zz9 q"],
    "Ruby's m as a dot that crosses newlines" => [/a.+?b/m, "a\n\nb a b"],
    "a dot that stops at a newline without m" => [/a.+b/, "a\nb axb"],
    "line anchors on every line" => [/^\w+$/, "one\ntwo three\nfour\n"],
    "an inline (?-mix:) group inside an m pattern" => [/(?-mix:a.b)|c.d/m, "a\nb c\nd axb"],
    "an inline (?m:) group" => [/x(?m:.)y/, "x\ny xzy"],
    "case folding" => [/token/i, "TOKEN Token tOkEn"],
    "a space inside a class in x mode" => [/a [ \t]+ b  # spaced out
                                          /x, "a   b a\tb ab"],
    "a # inside a class in x mode" => [/[#!]+ x/x, "#! x #x"],
    "string anchors" => [/\Aab|cd\z/, "ab ab cd cd"],
    "\\Z before a final newline" => [/cd\Z/, "cd cd\n"],
    "a repeated name, the last group that took part" => [/(?<v>a)b|(?<v>c)d/, "ab cd"],
    "a backreference by name" => [/(?<q>["'])\w+\k<q>/, %("ab" 'cd" 'ef')],
    "an escaped slash" => [Regexp.new("a\\/b"), "a/b"],
    "invalid UTF-8 and NULs as plain bytes" => [/\w+=\S+/, "k=\xff\x00v x=\xfe"],
    "a ] leading a class" => [leading_bracket, "a] ]b x"],
    "a class nested in a class" => [/[a[bc] ]+/x, "abc ba x"],
    "an inline (?x) that turns extended mode on" => [/a (?x) b c/, "a bc a b c"],
    "a (?x:) group inside a plain pattern" => [/a (?x: b c )d/, "a bcd a b c d"]
  }.each do |rule, (regexp, text)|
    it "translates #{rule}" do
      expect(rust_matches(regexp, text)).to eq(ruby_matches(regexp, text))
    end
  end

  {
    "a \\G anchor" => /\Ga/,
    "a possessive quantifier" => /a++b/,
    "an absence operator" => /(?~ab)/,
    "a comment group" => /a(?#note)b/,
    "a \\K keep" => /a\Kb/,
    "a subexpression call" => /(?<x>a)\g<x>/,
    "a backreference to a repeated name" => /(?<v>a)|(?<v>b)\k<v>/,
    "a possessive interval" => /a{1,2}+b/
  }.each do |feature, regexp|
    it "refuses #{feature} by the shape's name" do
      expect { described_class.compile({ "odd shape" => regexp }) }
        .to raise_error(described_class::Untranslatable, /odd shape/)
    end
  end

  # fancy-regex skips an empty match right after a non-empty one, where Onigmo reports it, and an empty
  # match masks nothing.
  it "scans a shape that matches the empty string by the non-empty matches Onigmo finds" do
    non_empty = ->(matches) { matches.reject { |_, start, finish, _| start == finish } }
    found = ["axxbx", "abc", "xx\nx", ""].map do |text|
      [non_empty.call(rust_matches(/x*/, text)), non_empty.call(ruby_matches(/x*/, text))]
    end

    expect(found.map(&:first)).to eq(found.map(&:last))
    expect(found.flat_map(&:first)).not_to be_empty
  end

  describe "the single-line flags" do
    def corpus_texts
      path = File.expand_path("../../../ext/lain/corpus/regions.ndjson", __dir__)
      File.foreach(path).map { [JSON.parse(_1).dig("input", "bytes")].pack("H*") }
    end

    # Every corpus text with a newline put before each of its bytes, so a shape that can match across
    # one is given the chance to.
    def two_line_probes
      corpus_texts.flat_map { |text| (0...text.bytesize).map { "#{text.byteslice(0, _1)}\n#{text.byteslice(_1..)}".b } }
    end

    def crossing(probes)
      probes.each_with_object(Set.new) do |probe, names|
        described_class.compiled.scan(probe).matches.each do |index, start, finish, _|
          names << described_class.names[index] if probe.byteslice(start...finish).include?("\n")
        end
      end
    end

    it "flags exactly the shapes no match of which ever crosses a newline" do
      multi_line = described_class.names.reject { described_class.single_line?(_1) }

      expect(crossing(two_line_probes)).to match_array(multi_line)
    end
  end

  it "names its shapes in the order the compiled set indexes them" do
    expect(described_class.names).to eq(described_class::SHAPES.keys)
    expect(described_class.names).to include(*Lain::Sensitivity::Regions::CONTENT_SHAPES.keys, "TOKEN",
                                             "PEM_PUBLIC", "OPENSSH_PUBLIC", "CHECKSUM_FIELD", "INTEGRITY_FIELD")
  end

  it "compiles every shape once, on first use and never while lain boots" do
    script = <<~RUBY
      calls = 0
      probe = TracePoint.new(:c_call) { |call| calls += 1 if call.method_id == :compile && call.self.is_a?(Module) && call.self.name == "Lain::Ext::Regions" }
      probe.enable
      require "lain"
      booted = calls
      first = Lain::Sensitivity::RustShapes.compiled
      again = Lain::Sensitivity::RustShapes.compiled
      probe.disable
      puts booted, calls, first.equal?(again)
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", script)

    expect(status).to be_success, err
    expect(out.lines(chomp: true)).to eq(%w[0 1 true])
  end

  # The child slows the binding's compile, so every thread reaches a cold set inside one compile's window.
  it "compiles once when threads race on the first use" do
    script = <<~RUBY
      require "lain"
      calls = Queue.new
      Lain::Ext::Regions.singleton_class.prepend(Module.new { define_method(:compile) { |shapes| calls << 1; sleep 0.1; super(shapes) } })
      gate = Queue.new
      threads = Array.new(8) { Thread.new { gate.pop; Lain::Sensitivity::RustShapes.compiled } }
      8.times { gate << :go }
      sets = threads.map(&:value)
      puts calls.size, sets.uniq(&:object_id).size
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", script)

    expect(status).to be_success, err
    expect(out.lines(chomp: true)).to eq(%w[1 1])
  end
end
