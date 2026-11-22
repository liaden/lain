# frozen_string_literal: true

require "strscan"

module Lain
  class Sensitivity
    # Every shape {Regions} scans, translated from Onigmo into the dialect fancy-regex reads and
    # compiled into 1 {Ext::Regions} set. The set is built on first use and kept: eager load runs
    # every class body on every boot, and most sessions never scan a file.
    #
    # The translation is narrow on purpose. It knows what the shapes use, and refuses any other
    # Onigmo feature by the shape's name rather than guessing what fancy-regex would make of it.
    module RustShapes
      # A shape uses an Onigmo feature the translation does not carry.
      class Untranslatable < Lain::Error; end

      SHAPES = Regions::CONTENT_SHAPES.merge(
        %w[TOKEN PEM_PUBLIC OPENSSH_PUBLIC CHECKSUM_FIELD INTEGRITY_FIELD OBJECT_ID_FIELD NODE_ID_FIELD]
          .to_h { [_1, Regions.const_get(_1)] }
      ).freeze
      NAMES = SHAPES.keys.freeze
      # The shapes no match of which can cross a newline, so a line one cannot finish is over-masked
      # alone. A shape left off over-masks to the end of the text instead: the safe side.
      SINGLE_LINE = (NAMES - ["pem private key block", "credential assignment", "toml assignment",
                              "quoted password key", "credential literal assignment", "PEM_PUBLIC"]).freeze

      # Every detect reads the set, so threads can meet a cold one together; each would compile its own.
      COMPILING = Mutex.new
      private_constant :COMPILING

      class << self
        # @return [Ext::Regions::Set] every one of {SHAPES}, indexed as {names} lists them
        def compiled = @compiled || COMPILING.synchronize { @compiled ||= compile(SHAPES) }

        # @return [Array<String>] the shape names, at the indexes a scan reports
        def names = NAMES

        # @param name [String]
        # @return [Boolean] whether no match of the shape can cross a newline
        def single_line?(name) = SINGLE_LINE.include?(name)

        # @param shapes [Hash{String => Regexp}]
        # @return [Ext::Regions::Set]
        # @raise [Untranslatable] naming the first shape that uses a feature the translation lacks
        def compile(shapes)
          Ext::Regions.compile(shapes.map do |name, regexp|
            [name, Translation.new(name, regexp).source, single_line?(name)]
          end)
        end
      end

      # 1 Ruby regex in the Rust dialect. Line anchors are always multiline in Ruby, so `m` is always
      # on; Ruby's `m` is Rust's `s`. Extended mode is resolved here, by dropping its whitespace and
      # comments, so a space inside a class stays the literal Ruby reads it as.
      class Translation
        HEX = "0-9a-fA-F"
        # Letters fancy-regex reads as Onigmo does, over ASCII bytes.
        CLASS_ESCAPES = %w[w W s S d D n r t f v x].freeze
        ESCAPES = (CLASS_ESCAPES + %w[b B A z] + ("1".."9").to_a).freeze
        REWRITTEN = { "h" => "[#{HEX}]", "H" => "[^#{HEX}]", "Z" => "(?=\\n?\\z)" }.freeze
        REWRITTEN_IN_CLASS = { "h" => HEX, "H" => "[^#{HEX}]" }.freeze
        PLAIN_GROUP = /\(\?(?:<[=!]|[=!>:])/
        NAMED_GROUP = /\(\?<([A-Za-z_]\w*)>/
        FLAG_GROUP = /\(\?([imx]*)(?:-([imx]*))?([:)])/

        # @param name [String] the shape, for a refusal
        # @param regexp [Regexp]
        def initialize(name, regexp)
          @name = name
          @regexp = regexp
        end

        # @return [String]
        # @raise [Untranslatable]
        def source
          @scanner = StringScanner.new(@regexp.source)
          @names = Hash.new(0)
          @backrefs = []
          @extended = [@regexp.options.anybits?(Regexp::EXTENDED)]
          body = +""
          body << token until @scanner.eos?
          refuse("a backreference to a repeated name") if @backrefs.any? { @names[_1] > 1 }
          "#{prefix}#{body}"
        end

        private

        def prefix
          flags = "m"
          flags += "i" if @regexp.options.anybits?(Regexp::IGNORECASE)
          flags += "s" if @regexp.options.anybits?(Regexp::MULTILINE)
          "(?#{flags})"
        end

        def token
          return "" if @extended.last && skipped_extended?
          return escape if @scanner.scan("\\")
          return character_class if @scanner.scan("[")
          return group if @scanner.check(/\(/)
          return close if @scanner.scan(")")

          refuse("a possessive quantifier") if @scanner.check(/[*+?}]\+/)
          @scanner.getch
        end

        def skipped_extended? = !@scanner.scan(/\s+|#[^\n]*/).nil?

        def escape
          letter = @scanner.getch
          return backref if letter == "k"

          REWRITTEN.fetch(letter) { allowed_escape(letter, ESCAPES) }
        end

        def backref
          refuse("a backreference that is not \\k<name>") unless @scanner.scan(/<([A-Za-z_]\w*)>/)
          @backrefs << @scanner[1]
          "\\k<#{@scanner[1]}>"
        end

        def character_class
          out = +"["
          out << "^" if @scanner.scan("^")
          out << "\\]" if @scanner.scan("]")
          depth = 1
          until depth.zero?
            refuse("an unclosed class") if @scanner.eos?
            piece, depth = class_piece(depth)
            out << piece
          end
          out
        end

        def class_piece(depth)
          return [class_escape, depth] if @scanner.scan("\\")
          return ["[", depth + 1] if @scanner.scan("[")
          return ["]", depth - 1] if @scanner.scan("]")

          [@scanner.getch, depth]
        end

        def class_escape
          letter = @scanner.getch
          REWRITTEN_IN_CLASS.fetch(letter) { allowed_escape(letter, CLASS_ESCAPES) }
        end

        def allowed_escape(letter, letters)
          refuse("the escape \\#{letter}") if letter.nil? || (letter.match?(/[[:alnum:]]/) && !letters.include?(letter))
          "\\#{letter}"
        end

        def group
          return opened(@scanner.matched) if @scanner.scan(PLAIN_GROUP)
          return opened(counted(@scanner[1])) if @scanner.scan(NAMED_GROUP)
          return flagged if @scanner.scan(FLAG_GROUP)
          return opened(@scanner.matched) if @scanner.scan(/\((?!\?)/)

          refuse("the group #{@scanner.peek(3)}")
        end

        def opened(text)
          @extended.push(@extended.last)
          text
        end

        def close
          refuse("an unbalanced )") if @extended.size == 1
          @extended.pop
          ")"
        end

        def counted(name)
          @names[name] += 1
          "(?<#{name}>"
        end

        def flagged
          on = @scanner[1]
          off = @scanner[2].to_s
          ending = @scanner[3]
          extended = (@extended.last || on.include?("x")) && !off.include?("x")
          rust = flags(on, off)
          return inline(extended, rust) if ending == ")"

          @extended.push(extended)
          rust.empty? ? "(?:" : "(?#{rust}:"
        end

        def inline(extended, rust)
          @extended[-1] = extended
          rust.empty? ? "" : "(?#{rust})"
        end

        def flags(on, off)
          rust_on, rust_off = [on, off].map { _1.delete("x").tr("m", "s") }
          rust_off.empty? ? rust_on : "#{rust_on}-#{rust_off}"
        end

        def refuse(feature)
          raise Untranslatable, "shape #{@name.inspect} uses #{feature}, which the Rust scan does not carry"
        end
      end
      private_constant :Translation
    end
  end
end
