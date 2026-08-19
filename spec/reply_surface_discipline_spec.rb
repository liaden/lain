# frozen_string_literal: true

require "ripper"
require "pathname"

# Mechanical enforcement of T1's terminal rule: A LINE THAT OWNS THE TERMINAL
# READ GETS NO TERMINAL SURFACE.
#
# {Lain::CLI::Repl::LineScope} brackets every dispatched line in the surfaces
# that read stdin -- the ask_human reply loop and the approval prompt -- and asks
# the command surface first whether the LINE reads the terminal itself, so that
# such a line is the only reader ({Lain::CLI::Command::Registry#serves_replies?}).
# A command that reads the terminal and forgets to declare it gets a second
# reader in silence, and the keystroke then goes to whichever fiber won it: an
# answer meant for an inbox question landing as the `y` on a gated `bash`.
#
# Silence is the whole problem, so the declaration is checked here rather than
# left to whoever writes the next command -- {OutputDiscipline}'s idiom, for its
# reason. This is a *syntax tree* walk, not a text scan, so the trigger names are
# never matched inside comments or string literals, and the generic `prompt` is
# counted only as a call on an explicit receiver (`tty.prompt`) rather than as
# the local variable `/meta` names its argument.
module ReplySurfaceDiscipline
  # Reading the human's answer, by every route a command has to one. The first
  # three are unambiguous names; `prompt` is generic and is handled separately.
  READERS = %w[read_reply drain_at_prompt drain_inbox].freeze
  RECEIVER_READERS = %w[prompt].freeze

  # A command file that reads the terminal, and where it does it.
  Read = Struct.new(:path, :line, :name) do
    def to_s = "#{path}:#{line} -> #{name}"
  end

  # Walks a Ripper s-expression collecting terminal reads.
  class Scanner
    def initialize(path)
      @path = path
      @reads = []
    end

    # @return [Array<Read>]
    def scan(source)
      sexp = Ripper.sexp(source)
      raise "could not parse #{@path}" if sexp.nil?

      walk(sexp)
      @reads
    end

    private

    def walk(node)
      return unless node.is_a?(Array)

      inspect_node(node)
      node.each { |child| walk(child) }
    end

    # `:call` is the explicit-receiver form (`tty.prompt`), which is the only one
    # that can mean the terminal for a name as common as `prompt`.
    def inspect_node(node)
      case node[0]
      when :@ident then record(node, READERS)
      when :call then record(node.last, RECEIVER_READERS)
      end
    end

    def record(token, names)
      return unless token.is_a?(Array) && token[0] == :@ident && names.include?(token[1])

      @reads << Read.new(@path, token[2]&.first, token[1])
    end
  end

  # One command file's subject: what a failure listing calls it, and whether it
  # declares itself a reply surface.
  Built = Struct.new(:command) do
    def declared? = command.respond_to?(:serves_replies?) && command.serves_replies?
    def named = command.class.to_s
  end

  # The file whose command class this guard could not reach or build. Its own
  # object, and it answers `declared?` false like any other failure, because the
  # FIX is different and a reader who is shown a bare `uninitialized constant`
  # from two examples at once goes looking for the wrong thing.
  Unreachable = Struct.new(:file, :reason) do
    def declared? = false

    def named
      "#{file} -- could not reach its command class (#{reason}). This guard maps " \
        "<name>.rb to Lain::CLI::Command::<CamelCase> and builds it with no arguments, " \
        "so a new command must be required from lib/lain/cli/command.rb, and one whose " \
        "constructor takes arguments needs this mapping widened"
    end
  end

  module_function

  def command_root = Pathname(__dir__).join("..", "lib", "lain", "cli", "command").expand_path

  # The command a file defines, by this namespace's one naming convention --
  # or the {Unreachable} that says why the convention did not hold.
  def subject_for(file)
    Built.new(Lain::CLI::Command.const_get(file.basename(".rb").to_s.camelize).new)
  rescue NameError, ArgumentError => e
    Unreachable.new(file.basename.to_s, e.message)
  end

  # Every class this directory defines that answers the command duck, by the
  # one naming convention {.subject_for} uses -- asked of the CLASS rather than
  # of an instance, which is what lets it see the whole shipped set. {Built}
  # cannot serve here: it must CONSTRUCT, and nine of the commands take
  # collaborators, so an instance-based census silently omits `/help`,
  # `/approve`, `/review` and six more. Measured while writing this: 15 of 21.
  #
  # The duck is asked rather than a denylist kept, because this directory also
  # holds {Lain::CLI::Command::Registry}, {Lain::CLI::Command::Surface} and
  # {Lain::CLI::Command::Env}, and a list of their filenames would need editing
  # every time a fourth arrived. `Registry` is the one that matters: it answers
  # `serves_replies?` itself, as the object commands are asked THROUGH.
  def command_classes
    command_root.glob("*.rb").filter_map do |file|
      klass = Lain::CLI::Command.const_get(file.basename(".rb").to_s.camelize)
      klass if klass.is_a?(Class) && klass.method_defined?(:name) && klass.method_defined?(:call)
    rescue NameError
      nil
    end
  end

  # Every command that declares itself a reply surface. The declaration IS a
  # method, so this is a question about the class and needs no instance -- and
  # a command that defines it and answers false still counts as a declarer
  # here, deliberately: the point is to notice the second one being written.
  def declarers = command_classes.select { |klass| klass.method_defined?(:serves_replies?) }

  # Every command file that reads the terminal, paired with its reads.
  def terminal_readers
    command_root.glob("*.rb").filter_map do |file|
      reads = Scanner.new(file.basename.to_s).scan(file.read)
      [subject_for(file), reads] unless reads.empty?
    end
  end
end

RSpec.describe "reply-surface discipline" do
  # Not `be_empty`: the guard is worthless if the scan silently stops matching,
  # and `/inbox` is the one shipped command that reads the human's answer.
  it "finds the command that reads the terminal, so the scan is known to work" do
    expect(ReplySurfaceDiscipline.terminal_readers.map { |subject, _reads| subject.named })
      .to include("Lain::CLI::Command::Inbox")
  end

  it "requires every command that reads the terminal to declare it serves replies" do
    undeclared = ReplySurfaceDiscipline.terminal_readers.reject { |subject, _reads| subject.declared? }

    expect(undeclared).to be_empty, lambda {
      listing = undeclared.map { |subject, reads| "  #{subject.named}: #{reads.join(", ")}" }.join("\n")
      "A command that reads the terminal must answer `serves_replies? => true`, or " \
        "Repl::LineScope will open a second reader over it and the human's keystroke " \
        "can reach a surface they were not answering. Found:\n#{listing}"
    }
  end

  # T4, and the reason this example sits HERE rather than beside the reply
  # prompt: `serves_replies?` now has TWO readers that mean different things by
  # it, and only one of them is written above.
  #
  # {Lain::CLI::Repl::LineScope} reads it as "this line reads the terminal
  # itself, so open no second reader over it" -- the rule this file enforces.
  # {Lain::CLI::HumanReplies::Reply#typed} reads it as "this line is the inbox
  # detour, so drain THIS parked item instead of dispatching" -- which is the
  # only way the reply prompt can keep `/inbox` item-scoped without a string
  # literal (see that method, and Open decision 5 of the QA round 6 chunk).
  #
  # The second reading is true of `/inbox` and of nothing else, and it is true
  # by accident of `/inbox` being the sole declarer. A SECOND declarer -- the
  # very command this file exists to require the declaration from -- would be
  # swallowed at `human> `: it would never run, and the human's next line would
  # answer the parked set instead. Measured at review: zero calls, silently.
  #
  # So this pins the coincidence until the two readings are given two
  # predicates. If you are here because you added a terminal-reading command and
  # this went red, that is the guard working: the fix is a distinct predicate
  # for the reply prompt's own detour, not deleting this example.
  it "pins /inbox as the ONLY declarer, which the reply prompt's detour depends on" do
    expect(ReplySurfaceDiscipline.declarers.map(&:to_s)).to eq(["Lain::CLI::Command::Inbox"])
  end

  # The census must be known to SEE the commands, or the example above passes by
  # finding nothing -- and it must see the ones no instance-based walk can build.
  # The exact count is not the point and would be churn; that it is most of the
  # directory is.
  it "sees the whole shipped set, including commands that take collaborators (self-test)" do
    census = ReplySurfaceDiscipline.command_classes.map(&:to_s)

    expect(census).to include("Lain::CLI::Command::Inbox", "Lain::CLI::Command::Quit",
                              "Lain::CLI::Command::Help", "Lain::CLI::Command::Approve")
    expect(census.size).to be > 15
  end

  # The guard's OWN failure mode, said in its own words: a new command file that
  # nothing requires yet resolves to no constant, and without this it would take
  # both examples above down with a bare `uninitialized constant` -- loud, but
  # pointing at the wrong thing.
  it "names the likely cause when a command file's class cannot be reached (self-test)" do
    subject = ReplySurfaceDiscipline.subject_for(Pathname("not_yet_required.rb"))

    expect(subject.declared?).to be(false)
    expect(subject.named).to include("not_yet_required.rb", "lib/lain/cli/command.rb")
  end

  # Guards the guard: these look like reads textually but must not trip the
  # AST-based scanner, and the receiver-less `prompt` is exactly the shape
  # `/meta` has as an ordinary local.
  it "does not flag comments, strings, or a bare local named prompt (self-test)" do
    source = <<~RUBY
      # read_reply and drain_at_prompt in a comment
      class Probe
        USAGE = "read_reply drain_inbox"
        def call(prompt, _env) = generate(prompt)
      end
    RUBY

    expect(ReplySurfaceDiscipline::Scanner.new("probe.rb").scan(source)).to be_empty
  end

  it "flags a receiver call on prompt, which is the terminal read a command can hide (self-test)" do
    source = "class Probe\n  def call(_a, env) = env.tty.prompt(\"pick> \")\nend\n"

    expect(ReplySurfaceDiscipline::Scanner.new("probe.rb").scan(source).map(&:name)).to eq(["prompt"])
  end
end
