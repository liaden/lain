# frozen_string_literal: true

require "ripper"
require "pathname"

# Mechanical enforcement of the desktop-consent rule, and deliberately the same
# shape {OutputDiscipline} is: only a caller that OWNS the human's attention may
# build a real {Lain::Notify}. `dunstify` being on PATH says the desktop can be
# reached; it never says this process may reach it, and every spec, probe and
# subagent in this repository runs on the same machine -- with the same PATH --
# as the human whose screen it would interrupt. On 2026-08-05 that cost nine
# real notifications fired onto a working human's desktop by agents, from
# `Wiring#wire_agent`'s unconditional `Lain::Notify.for`.
#
# So the rule is: {Lain::Notify.for} is always passed an explicit `desktop:`,
# and the real adapter is never constructed directly outside its own file.
#
# Robustness, and the limits: like OutputDiscipline this parses each file with
# Ripper and inspects the SYNTAX TREE, so the trigger words are never matched
# inside comments or string literals, and `Notify::Null.new` (whose receiver is
# `Null`) is not mistaken for the real adapter. What it CANNOT see is a spec
# that constructs one, or a caller that threads `desktop:` from something that
# resolves true -- the first is closed by the default being off (a spec has to
# ask in as many words), the second by the behavioural examples in
# `spec/lain/cli/wiring_spec.rb`, which drive the real call site.
module DesktopDiscipline
  # The class whose `.new`/`.for` reach the human's screen. Matched on the
  # TRAILING constant, so `Lain::Notify` and a bare `Notify` both count.
  REAL_ADAPTER = "Notify"

  # The keyword that says a caller owns the human's attention.
  CONSENT = "desktop:"

  # Explicit, per-file exceptions. Paths are relative to `lib/`.
  ALLOWLIST = {
    "lain/notify.rb" => "defines the adapter and its own consent gate"
  }.freeze

  # A single detected violation, with enough context to fix it.
  Violation = Struct.new(:path, :line, :message) do
    def to_s
      "#{path}:#{line} -> #{message}"
    end
  end

  # Walks a Ripper s-expression collecting ungated notifier constructions.
  class Scanner
    def initialize(path)
      @path = path
      @violations = []
      @seen = []
    end

    # @return [Array<Violation>]
    def scan(source)
      sexp = Ripper.sexp(source)
      raise "could not parse #{@path}" if sexp.nil?

      walk(sexp)
      @violations
    end

    private

    def walk(node)
      return unless node.is_a?(Array)

      inspect_node(node)
      node.each { |child| walk(child) }
    end

    # A call carrying arguments arrives as its own node wrapping the bare
    # `:call`, and the wrapper is walked FIRST -- so recording the callee token's
    # position is what stops the inner node being read a second time as argless.
    def inspect_node(node)
      case node[0]
      when :method_add_arg then examine(node[1], node[2])
      when :command_call then examine([:call, node[1], node[2], node[3]], node[4])
      when :call then examine(node, nil)
      end
    end

    def examine(call, args)
      method = notifier_call(call)
      return if method.nil?

      position = call[3][2]
      return if @seen.include?(position)

      @seen << position
      record(method, args, position&.first)
    end

    def record(method, args, line)
      message = violation_for(method, args)
      @violations << Violation.new(@path, line, message) unless message.nil?
    end

    def violation_for(method, args)
      return "#{REAL_ADAPTER}.new -- build it through .for, which owns the consent gate" if method == "new"

      "#{REAL_ADAPTER}.for with no `#{CONSENT}` -- presence on PATH is not consent" unless consent?(args)
    end

    # `[:call, receiver, period, [:@ident, name, position]]`, where the receiver
    # is the real adapter and the name builds one.
    def notifier_call(call)
      return nil unless call.is_a?(Array) && call[0] == :call

      ident = call[3]
      return nil unless ident.is_a?(Array) && ident[0] == :@ident && %w[for new].include?(ident[1])

      ident[1] if receiver_const(call[1]) == REAL_ADAPTER
    end

    def receiver_const(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :const_path_ref then const_name(node[2])
      when :var_ref, :const_ref, :top_const_ref then const_name(node[1])
      end
    end

    def const_name(token) = token.is_a?(Array) && token[0] == :@const ? token[1] : nil

    def consent?(node)
      return false unless node.is_a?(Array)

      (node[0] == :@label && node[1] == CONSENT) || node.any? { |child| consent?(child) }
    end
  end

  module_function

  def lib_root
    Pathname(__dir__).join("..", "lib").expand_path
  end

  # @return [Array<Violation>] every violation across the non-exempt `lib/` tree
  def violations
    lib_root.glob("**/*.rb").flat_map do |file|
      relative = file.relative_path_from(lib_root).to_s
      ALLOWLIST.key?(relative) ? [] : Scanner.new(relative).scan(file.read)
    end
  end
end

RSpec.describe "desktop discipline" do
  it "never builds a real notifier in lib/ without explicit consent" do
    violations = DesktopDiscipline.violations

    expect(violations).to be_empty, lambda {
      listing = violations.map { |violation| "  #{violation}" }.join("\n")
      "A real Lain::Notify reaches the human's DESKTOP, so it is built only where a caller " \
        "owns their attention -- pass `desktop:` (the CLI resolves it from --desktop/--no-desktop " \
        "and LAIN_DESKTOP). Found:\n#{listing}\n" \
        "Use Lain::Notify::Null.new, or add a justified entry to DesktopDiscipline::ALLOWLIST."
    }
  end

  it "does not flag the Null, a receiverless new, or the words in prose (self-test)" do
    source = <<~RUBY
      # a comment mentioning Notify.for and Notify.new
      x = "Notify.for in a string"
      Lain::Notify::Null.new
      notifier.for(desktop: false)
      new(command:)
    RUBY

    expect(DesktopDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  it "flags an ungated .for and a direct .new, and clears a consented .for (self-test)" do
    found = DesktopDiscipline::Scanner.new("self_test").scan(<<~RUBY)
      Lain::Notify.for
      Notify.for(command: "dunstify")
      Lain::Notify.new(command: "dunstify")
      Lain::Notify.for(desktop: options[:desktop])
    RUBY

    expect(found.map(&:line)).to contain_exactly(1, 2, 3)
  end
end
