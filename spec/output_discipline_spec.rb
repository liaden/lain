# frozen_string_literal: true

require "ripper"
require "pathname"

# Mechanical enforcement of the output-discipline rule: only the frontend may
# touch the terminal. Everything else is handed a sink (see {Lain::Sink}). A
# stray `warn` or `$stderr.puts` anywhere else can interleave plain text into
# the NDJSON Journal and silently corrupt the experiment record, so we forbid it
# here rather than in a paragraph of the README that nobody re-reads.
#
# Robustness: we parse each file with Ripper and inspect the *syntax tree*, not
# the raw text. That means the trigger words are never matched inside comments
# or string literals, and a call with an explicit receiver (`sink.puts`,
# `some_io.print`) is not mistaken for a bare terminal write. Only receiverless
# `puts`/`print`/`warn` calls and references to the terminal IO globals/consts
# count.
module OutputDiscipline
  # Receiverless calls to these Kernel methods write to `$stdout`/`$stderr`.
  TERMINAL_METHODS = %w[puts print warn].freeze
  # Direct references to the process's terminal IO handles.
  TERMINAL_GLOBALS = %w[$stdout $stderr].freeze
  TERMINAL_CONSTS = %w[STDOUT STDERR].freeze

  # The frontend is the one place the terminal is fair game.
  EXEMPT_PREFIXES = ["lain/frontend/"].freeze

  # Explicit, per-file exceptions. Keep this empty if you can; every entry is a
  # place the rule is deliberately broken and must be justified. Paths are
  # relative to `lib/`.
  #
  #   "lain/some_file.rb" => "why this file is allowed to write to the terminal"
  ALLOWLIST = {}.freeze

  # A single detected violation, with enough context to fix it.
  Violation = Struct.new(:path, :line, :snippet) do
    def to_s
      "#{path}:#{line} -> #{snippet}"
    end
  end

  # Walks a Ripper s-expression collecting terminal-write violations.
  class Scanner
    def initialize(path)
      @path = path
      @violations = []
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

    def inspect_node(node)
      head = node[0]
      case head
      when :command, :fcall, :vcall then check_call(node[1])
      when :@gvar then check_token(node, TERMINAL_GLOBALS)
      when :@const then check_token(node, TERMINAL_CONSTS)
      end
    end

    # A receiverless call node wraps its name in an `[:@ident, name, pos]`.
    def check_call(ident)
      return unless ident.is_a?(Array) && ident[0] == :@ident

      check_token(ident, TERMINAL_METHODS)
    end

    def check_token(token_node, forbidden)
      name = token_node[1]
      return unless forbidden.include?(name)

      line = token_node[2]&.first
      @violations << Violation.new(@path, line, name)
    end
  end

  module_function

  def lib_root
    Pathname(__dir__).join("..", "lib").expand_path
  end

  def exempt?(relative_path)
    EXEMPT_PREFIXES.any? { |prefix| relative_path.start_with?(prefix) } ||
      ALLOWLIST.key?(relative_path)
  end

  # @return [Array<Violation>] every violation across the non-exempt `lib/` tree
  def violations
    lib_root.glob("**/*.rb").flat_map do |file|
      relative = file.relative_path_from(lib_root).to_s
      next [] if exempt?(relative)

      Scanner.new(relative).scan(file.read)
    end
  end
end

RSpec.describe "output discipline" do
  it "has no terminal writes in lib/ outside lib/lain/frontend/" do
    violations = OutputDiscipline.violations

    expect(violations).to be_empty, lambda {
      listing = violations.map { |violation| "  #{violation}" }.join("\n")
      "Terminal writes (puts/print/warn/$stdout/$stderr/STDOUT/STDERR) are only " \
        "allowed in lib/lain/frontend/. Found:\n#{listing}\n" \
        "Route output through a Lain::Sink, or add a justified entry to " \
        "OutputDiscipline::ALLOWLIST."
    }
  end

  it "does not flag receiver calls, comments, or string literals (self-test)" do
    # Guards the guard: these look like violations textually but must not trip
    # the AST-based scanner.
    source = <<~RUBY
      # this comment mentions puts and $stdout and STDERR
      x = "a string with puts and $stderr in it"
      sink.puts("attributed")
      logger.print(x)
      def puts(*) = nil
    RUBY

    expect(OutputDiscipline::Scanner.new("self_test").scan(source)).to be_empty
  end

  it "flags a bare terminal write (self-test)" do
    found = OutputDiscipline::Scanner.new("self_test").scan("warn('boom')\n$stdout.puts('x')\n")
    expect(found.map(&:snippet)).to contain_exactly("warn", "$stdout")
  end
end
