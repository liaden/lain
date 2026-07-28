# frozen_string_literal: true

# The Rust prompt formatter (`ext/lain/src/prompt.rs`): starship's four-production
# format DSL, compiled once and rendered per prompt.
#
# The architectural line this spec exists to hold is that COLOR IS AN ARGUMENT.
# `NO_COLOR`, `FORCE_COLOR`, `isatty` and `TERM` are properties of the stream Ruby
# owns, so Ruby resolves them and passes the answer in; the renderer is the pure
# `(format, vars, color) -> String` that `Context#render`'s purity rule wants.
# Nothing below sets an environment variable, because nothing in the extension
# reads one.
RSpec.describe Lain::Ext::Prompt do
  # A single SGR-styled span: prefix, the text, reset. anstyle emits one SGR
  # sequence per attribute, so the prefix is matched loosely and the text and
  # the reset exactly.
  def styled(text)
    /\A(?:\e\[[\d;]*m)+#{Regexp.escape(text)}\e\[0m/
  end

  describe ".compile" do
    it "returns a Ractor-shareable compiled format" do
      expect(described_class.compile("[lain](bold green) ")).to be_deeply_frozen
    end

    it "reports the source it was compiled from" do
      expect(described_class.compile("$model ").source).to eq("$model ")
    end

    it "names every variable the format references, once, in appearance order" do
      format = described_class.compile("$b [$a$b]($style) ($a)")

      expect(format.variables).to eq(%w[b a style])
    end

    it "carries no settings" do
      expect(described_class.compile("$model").settings).to eq({})
    end

    it "refuses a malformed format, naming the position" do
      expect { described_class.compile("[unclosed") }
        .to raise_error(described_class::ParseError, /unclosed.*byte offset 0/)
    end

    it "refuses an unknown style word at compile time" do
      expect { described_class.compile("[x](chartreuse)") }
        .to raise_error(described_class::ParseError, /chartreuse/)
    end

    # From the review probe: an unbounded parser survived depth 10_000 and blew
    # the stack at 10_312. Ruby's guard page turned that into a SystemStackError,
    # which is a longjmp through live Rust frames -- no destructor ran, and 200
    # overflowed compiles leaked 16 MB that GC.start never reclaimed. A depth
    # limit turns it into an ordinary refusal.
    it "refuses a format nested past the limit instead of overflowing the stack" do
      expect { described_class.compile("(" * 20_000) }
        .to raise_error(described_class::ParseError, /nested deeper/)
    end

    it "refuses deep bracket nesting the same way" do
      expect { described_class.compile("[" * 20_000) }
        .to raise_error(described_class::ParseError, /nested deeper/)
    end

    it "leaks nothing across repeated refusals" do
      100.times { expect { described_class.compile("(" * 20_000) }.to raise_error(described_class::ParseError) }
      GC.start

      expect { described_class.compile("$ok") }.not_to raise_error
    end
  end

  describe "string boundary" do
    # `nil` is accepted only as a variable VALUE, and read_vars answers that
    # before read_text is reached -- so nowhere read_text can print the message
    # is `nil` actually allowed.
    it "does not advertise nil where nil is refused" do
      expect { described_class.width(nil) }
        .to raise_error(TypeError, /must be a String or Symbol, got a NilClass/)
      expect { described_class.compile(nil) }.to raise_error(TypeError, /String or Symbol/)
      expect { described_class.width(nil) }.to raise_error(TypeError) { |e| expect(e.message).not_to include("nil") }
    end

    it "refuses a String whose encoding is not UTF-8 rather than reinterpreting its bytes" do
      expect { described_class.compile("abc".encode("UTF-16LE")) }
        .to raise_error(EncodingError, /UTF-16LE/)
    end

    it "refuses bytes that are not valid UTF-8, saying so" do
      expect { described_class.compile("\xff\xfe".b) }
        .to raise_error(EncodingError, /not valid UTF-8/)
    end

    it "accepts BINARY whose bytes are already valid UTF-8" do
      expect(described_class.compile("abc".b).source).to eq("abc")
    end

    it "applies the same policy to from_toml, width, and render" do
      expect { described_class.from_toml(%(format = "x").encode("UTF-16LE")) }.to raise_error(EncodingError)
      expect { described_class.width("abc".encode("UTF-16LE")) }.to raise_error(EncodingError)
      expect { described_class.compile("$n").render({ "n" => "abc".encode("UTF-16LE") }, color: false) }
        .to raise_error(EncodingError)
    end

    # Widening Canonical's coercion helper made a caller nowhere near Canonical
    # rescue a Canonical error. The taxonomy is the binding's own.
    it "never raises a Canonical error out of the prompt formatter" do
      expect { described_class.compile("$n").render({ "n" => "\xff".b }, color: false) }
        .to raise_error(EncodingError)
      expect { described_class.compile("$n").render({ "n" => "\xff".b }, color: false) }
        .not_to raise_error(Lain::Canonical::UnsupportedType)
    end
  end

  describe "escape-byte injection" do
    # A DIFFERENT attack from format-syntax injection: that one targets lain's
    # grammar, this one targets the terminal's. T13 interpolates a cwd, a git
    # branch and a model id, and a directory name containing an ESC byte is legal.
    it "cannot smuggle SGR through an uncolored render" do
      out = described_class.compile("$x").render({ "x" => "\e[31mRED\e[0m" }, color: false)

      expect(out).not_to include("\e")
      expect(out).to eq("[31mRED[0m")
    end

    it "cannot clear the screen" do
      expect(described_class.compile("$x").render({ "x" => "\e[2J" }, color: false)).to eq("[2J")
    end

    it "cannot rewrite the terminal title" do
      expect(described_class.compile("$x").render({ "x" => "\e]0;title\a" }, color: false)).to eq("]0;title")
    end

    it "strips control bytes with color enabled too" do
      out = described_class.compile("[$x](red)").render({ "x" => "\e[2J" }, color: true)

      expect(out).to eq("\e[31m[2J\e[0m")
    end

    it "treats a value of nothing but control bytes as unset" do
      expect(described_class.compile("a(-$x-)b").render({ "x" => "\e\a" }, color: false)).to eq("ab")
    end
  end

  describe "#render" do
    it "styles a text group" do
      out = described_class.compile("[lain](bold green) ").render({}, color: true)

      expect(out).to match(styled("lain"))
      expect(out).to end_with(" ")
    end

    it "interpolates a variable" do
      out = described_class.compile("$model").render({ "model" => "qwen3:4b" }, color: false)

      expect(out).to eq("qwen3:4b")
    end

    it "accepts Symbol keys and Symbol values" do
      out = described_class.compile("$model").render({ model: :qwen3 }, color: false)

      expect(out).to eq("qwen3")
    end

    it "elides a conditional group when every variable inside it is empty" do
      out = described_class.compile("a(-$missing-)b").render({}, color: false)

      expect(out).to eq("ab")
    end

    it "keeps a conditional group when any variable inside it is set" do
      out = described_class.compile("a(-$present-)b").render({ "present" => "x" }, color: false)

      expect(out).to eq("a-x-b")
    end

    it "treats an empty value as unset" do
      out = described_class.compile("a(-$present-)b").render({ "present" => "" }, color: false)

      expect(out).to eq("ab")
    end

    it "emits no escape sequences when color is disabled" do
      out = described_class.compile("[x](red)").render({}, color: false)

      expect(out).to eq("x")
    end

    it "cannot be made to interpret an interpolated value as format syntax" do
      out = described_class.compile("$evil").render({ "evil" => "[evil](red)" }, color: true)

      expect(out).to eq("[evil](red)")
      expect(out).not_to include("\e")
    end

    it "returns a frozen String" do
      expect(described_class.compile("x").render({}, color: false)).to be_frozen
    end

    it "resolves a style supplied by a variable" do
      out = described_class.compile("[x]($accent)").render({ "accent" => "bold red" }, color: true)

      expect(out).to match(styled("x"))
    end

    it "raises StyleError when a variable supplies an unknown style word" do
      expect { described_class.compile("[x]($accent)").render({ "accent" => "chartreuse" }, color: true) }
        .to raise_error(described_class::StyleError, /chartreuse/)
    end

    it "refuses a value that is neither a String, a Symbol, nor nil" do
      expect { described_class.compile("$n").render({ "n" => 3 }, color: false) }
        .to raise_error(TypeError, /Integer/)
    end

    it "gets the article right for a vowel-initial class name" do
      expect { described_class.compile("$n").render({ "n" => 3 }, color: false) }
        .to raise_error(TypeError, /got an Integer/)
      expect { described_class.compile("$n").render({ "n" => 3.0 }, color: false) }
        .to raise_error(TypeError, /got a Float/)
    end

    it "is pure: the same inputs give the same bytes" do
      format = described_class.compile("[$a](bold red) ($b) $c")
      vars = { "a" => "one", "c" => "three" }

      expect(format.render(vars, color: true)).to eq(format.render(vars, color: true))
    end
  end

  describe ".from_toml" do
    it "compiles the format key" do
      config = described_class.from_toml(%(format = "$model "\n))

      expect(config.source).to eq("$model ")
    end

    it "exposes the settings table, deeply frozen" do
      config = described_class.from_toml(%(format = "x"\n[settings]\nmax_width = 40\nnested = { a = true }\n))

      expect(config.settings).to eq({ "max_width" => 40, "nested" => { "a" => true } })
      expect(config.settings).to be_deeply_frozen
    end

    it "refuses TOML that does not parse" do
      expect { described_class.from_toml("format = ") }
        .to raise_error(described_class::ConfigError)
    end

    it "refuses a config with no format" do
      expect { described_class.from_toml("[settings]\na = 1\n") }
        .to raise_error(described_class::ConfigError, /format/)
    end

    it "refuses an unknown top-level key rather than ignoring the typo" do
      expect { described_class.from_toml(%(format = "x"\nfromat = "y"\n)) }
        .to raise_error(described_class::ConfigError, /fromat/)
    end

    it "refuses a config whose format does not compile" do
      expect { described_class.from_toml(%(format = "[unclosed"\n)) }
        .to raise_error(described_class::ConfigError, /byte offset/)
    end

    # Settings recurse on the way in, on the way out to Ruby, and in their own
    # drop glue. That recursion is bounded by the toml crate's parser rather than
    # by MAX_DEPTH, which governs the format only -- pinned here so the thing we
    # depend on is tested, not merely assumed.
    it "refuses a deeply nested settings table instead of overflowing the stack" do
      nested = %(format = "x"\n[settings]\na = #{"[" * 500}#{"]" * 500}\n)

      expect { described_class.from_toml(nested) }.to raise_error(described_class::ConfigError)
    end
  end

  describe ".width" do
    it "counts a wide glyph as two columns" do
      expect(described_class.width("日本")).to eq(4)
    end

    it "counts graphemes, not characters" do
      # A ZWJ family emoji is many chars and one glyph; unicode-width 0.2 stopped
      # defining str width as the sum of per-char widths precisely for this.
      expect(described_class.width("👨‍👩‍👧")).to be < "👨‍👩‍👧".chars.sum { |c| described_class.width(c) }
    end

    it "ignores the escape sequences the renderer itself emits" do
      styled = described_class.compile("[lain](bold green)").render({}, color: true)

      expect(described_class.width(styled)).to eq(4)
    end

    # ST is two bytes, "\e\\". Consuming only the ESC left the backslash to be
    # counted, and T13 places a cursor with this number.
    it "consumes both bytes of a string terminator" do
      expect(described_class.width("\e]0;t\e\\x")).to eq(1)
    end

    it "counts a control character as zero columns" do
      expect(described_class.width("a\ab")).to eq(2)
      expect(described_class.width("a\nb")).to eq(2)
    end
  end

  describe "error classes" do
    it "hang off Lain::Error so an existing rescue site catches them" do
      expect(described_class::ParseError.ancestors).to include(Lain::Error)
      expect(described_class::ConfigError.ancestors).to include(Lain::Error)
      expect(described_class::StyleError.ancestors).to include(Lain::Error)
    end
  end
end
