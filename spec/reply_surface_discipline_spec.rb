# frozen_string_literal: true

require "ripper"
require "pathname"

# Mechanical enforcement of a declaration: A COMMAND THAT READS THE HUMAN'S
# ANSWER ITSELF SAYS SO ({Lain::CLI::Command::Registry#serves_replies?}).
#
# The declaration once decided which reply surfaces a dispatched line was given,
# since two readers on one stdin sent a keystroke to whichever fiber won it.
# Those surfaces now live for the whole conversation and every prompt takes its
# turn on the input rail, so that race is the rail's to prevent. What still
# reads the declaration is the reply prompt's `/inbox` detour
# ({Lain::CLI::HumanReplies::Reply#classify}), pinned below.
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

  # `#decide` is as generic as `prompt`, so it counts only on a receiver NAMED
  # for the approval prompt it asks through: `/approve`'s `@prompt.decide`, a
  # `[y/N]` read no name above could see.
  PROMPT_RECEIVERS = %w[@prompt prompt].freeze
  PROMPT_READERS = %w[decide].freeze

  # A command file that reads the terminal, and where it does it. `klass` is
  # the SIMPLE name of the enclosing `class` node the read was found inside
  # (nil for a read at module level, which no shipped file has) -- carried
  # explicitly because a fold can put more than one command class in one
  # file, so "which file" no longer answers "which command".
  Read = Struct.new(:path, :line, :name, :klass) do
    def to_s = "#{path}:#{line} -> #{name}"
  end

  # Walks a Ripper s-expression collecting terminal reads, tagging each with
  # the class it was found inside. A stack, not a single name, because a
  # nested class (`Pin::Target`) would otherwise un-attribute its parent's
  # reads; entering one pushes, leaving it pops, and a read between them
  # belongs to whichever class is innermost.
  class Scanner
    def initialize(path)
      @path = path
      @reads = []
      @class_stack = []
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

      entering_class = class_node?(node)
      @class_stack.push(class_name(node)) if entering_class
      inspect_node(node)
      node.each { |child| walk(child) }
      @class_stack.pop if entering_class
    end

    def class_node?(node) = node[0] == :class && node[1].is_a?(Array) && node[1][0] == :const_ref

    def class_name(node) = node[1][1][1]

    # `:call` is the explicit-receiver form (`tty.prompt`), which is the only one
    # that can mean the terminal for a name as common as `prompt`.
    def inspect_node(node)
      case node[0]
      when :@ident then record(node, READERS)
      when :call
        record(node.last, RECEIVER_READERS)
        record(node.last, PROMPT_READERS) if PROMPT_RECEIVERS.include?(receiver_name(node[1]))
      end
    end

    def receiver_name(node)
      return unless node.is_a?(Array)

      case node[0]
      when :var_ref, :vcall then receiver_name(node[1])
      when :@ivar, :@ident then node[1]
      end
    end

    def record(token, names)
      return unless token.is_a?(Array) && token[0] == :@ident && names.include?(token[1])

      @reads << Read.new(@path, token[2]&.first, token[1], @class_stack.last)
    end
  end

  # One command file's subject: what a failure listing calls it, and whether it
  # declares itself a reply surface.
  Built = Struct.new(:command) do
    def declared? = command.respond_to?(:serves_replies?) && command.serves_replies?
    def named = command.class.to_s
  end

  # A command CLASS whose reads the Scanner attributed to it by name. Asked of
  # the class rather than of a built instance, because a declaration is a method
  # and `/approve` -- a terminal reader -- takes a collaborator no guard can
  # invent. `allocate` gives the predicate a receiver without running a
  # constructor; a declaration is a constant answer, never one that reads state.
  Declared = Struct.new(:klass) do
    def declared? = klass.method_defined?(:serves_replies?) && klass.allocate.serves_replies?
    def named = klass.to_s
  end

  # The file whose command class this guard could not reach or build. Its own
  # object, and it answers `declared?` false like any other failure, because the
  # FIX is different and a reader who is shown a bare `uninitialized constant`
  # from two examples at once goes looking for the wrong thing.
  Unreachable = Struct.new(:file, :reason) do
    def declared? = false

    def named
      "#{file} -- could not reach its command class (#{reason}). This guard finds a " \
        "command under Lain::CLI::Command by the class a read was found in, so a new " \
        "command must be required from lib/lain/cli/command.rb (a guess by file name maps " \
        "<name>.rb to <CamelCase> and builds it with no arguments)"
    end
  end

  module_function

  def command_root = Pathname(__dir__).join("..", "lib", "lain", "cli", "command").expand_path

  # The command a FILE defines, by this namespace's one naming convention --
  # or the {Unreachable} that says why the convention did not hold. This is
  # the single-class-per-file guess, kept for the one place that is actually
  # about a file: a brand new command not yet required anywhere ({.subject_for}
  # the self-test below exercises). It is NOT how a read gets attributed to a
  # class -- see {.built_for} for that, which is told the class by name rather
  # than guessing it from a path, because a fold can leave more than one
  # command class in one file.
  def subject_for(file)
    Built.new(Lain::CLI::Command.const_get(file.basename(".rb").to_s.camelize).new)
  rescue NameError, ArgumentError => e
    Unreachable.new(file.basename.to_s, e.message)
  end

  # The class a read was found in, told by NAME -- what {.terminal_readers}
  # uses once the Scanner has already found which class a read lives in by
  # walking the syntax tree, rather than guessing one name per file.
  def built_for(klass_name, file)
    Declared.new(Lain::CLI::Command.const_get(klass_name))
  rescue NameError => e
    Unreachable.new(file.basename.to_s, e.message)
  end

  # Every class this directory defines that answers the command duck --
  # asked of the CLASS rather than of an instance, which is what lets it see
  # the whole shipped set. {Built} cannot serve here: it must CONSTRUCT, and
  # nine of the commands take collaborators, so an instance-based census
  # silently omits `/help`, `/approve`, `/review` and six more. Measured while
  # writing this: 15 of 21.
  #
  # The duck is asked rather than a denylist kept, because this directory also
  # holds {Lain::CLI::Command::Registry}, {Lain::CLI::Command::Surface} and
  # {Lain::CLI::Command::Env}, and a list of their filenames would need
  # editing every time a fourth arrived. `Registry` is the one that matters:
  # it answers `serves_replies?` itself, as the object commands are asked
  # THROUGH.
  #
  # Asked of the MODULE's own constants, not of one filename per file: a class
  # is a class regardless of which file loaded it, so a command that does not
  # sit at the path its name implies is still seen.
  def command_classes
    Lain::CLI::Command.constants.filter_map do |name|
      klass = Lain::CLI::Command.const_get(name)
      klass if klass.is_a?(Class) && klass.method_defined?(:name) && klass.method_defined?(:call)
    end
  end

  # Every command that declares itself a reply surface. The declaration IS a
  # method, so this is a question about the class and needs no instance -- and
  # a command that defines it and answers false still counts as a declarer
  # here, deliberately: the point is to notice the second one being written.
  def declarers = command_classes.select { |klass| klass.method_defined?(:serves_replies?) }

  # Every command CLASS that reads the terminal, paired with its reads. Scans
  # per FILE (Ripper needs real source text) but groups the file's reads by
  # the enclosing class the Scanner recorded on each one, so a file holding
  # more than one command attributes each read to the command that makes it,
  # not to whichever class the filename would guess.
  # A read with no enclosing class (module-level code) has no shipped example
  # and is dropped rather than misattributed to a `nil` command.
  def terminal_readers
    command_root.glob("*.rb").flat_map do |file|
      reads = Scanner.new(file.basename.to_s).scan(file.read)
      reads.group_by(&:klass).reject { |klass_name, _| klass_name.nil? }
                             .map do |klass_name, klass_reads|
        [
          built_for(klass_name, file), klass_reads
        ]
      end
    end
  end
end

RSpec.describe "reply-surface discipline" do
  # Not `be_empty`: the guard is worthless if the scan silently stops matching,
  # and `/inbox` is the one shipped command that reads the human's answer.
  it "finds the commands that read the terminal, so the scan is known to work" do
    expect(ReplySurfaceDiscipline.terminal_readers.map { |subject, _reads| subject.named })
      .to include("Lain::CLI::Command::Inbox", "Lain::CLI::Command::Approve")
  end

  it "requires every command that reads the terminal to declare it serves replies" do
    undeclared = ReplySurfaceDiscipline.terminal_readers.reject { |subject, _reads| subject.declared? }

    expect(undeclared).to be_empty, lambda {
      listing = undeclared.map { |subject, reads| "  #{subject.named}: #{reads.join(", ")}" }.join("\n")
      "A command that reads the terminal must answer `serves_replies? => true`, so the " \
        "reply prompt's /inbox detour has been checked against it. Found:\n#{listing}"
    }
  end

  # `serves_replies?` has TWO readers that once meant different things by it.
  #
  # A per-line bracket of reply surfaces once read it as "this line reads the
  # terminal itself, so open no second reader over it".
  # {Lain::CLI::HumanReplies::Reply#classify} used to read it as "this line is
  # the inbox detour, so drain THIS parked item instead of dispatching", which
  # was true only because `/inbox` was the sole declarer -- and `/approve`,
  # whose `[y/N]` read this file now sees, is a second one. Swallowed at
  # `human> ` it would never have run, and the human's next line would have
  # answered the parked set.
  #
  # So the reply prompt asks WHICH command a declaring line names, and this pins
  # the declarers it has been checked against. A third one belongs here after
  # the same check: `human_replies_spec` runs a declarer that is not `/inbox` at
  # the reply prompt, and that example is what a new declarer must keep green.
  it "pins the declarers the reply prompt's detour has been checked against" do
    expect(ReplySurfaceDiscipline.declarers.map(&:to_s))
      .to contain_exactly("Lain::CLI::Command::Approve", "Lain::CLI::Command::Inbox")
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

  it "flags decide on an approval prompt, and not decide on anything else (self-test)" do
    source = <<~RUBY
      class Probe
        def call(_a, env) = env.approvals.each { |pending| @prompt.decide(pending) }
        def other(policy) = policy.decide(:yes)
      end
    RUBY

    expect(ReplySurfaceDiscipline::Scanner.new("probe.rb").scan(source).map(&:name)).to eq(["decide"])
  end

  it "flags a receiver call on prompt, which is the terminal read a command can hide (self-test)" do
    source = "class Probe\n  def call(_a, env) = env.tty.prompt(\"pick> \")\nend\n"

    expect(ReplySurfaceDiscipline::Scanner.new("probe.rb").scan(source).map(&:name)).to eq(["prompt"])
  end
end

# The other half of the terminal rule, and the mechanical half of the input
# rail: on the chat path ONE object reads the process's stdin, and every prompt
# reaches the chat as a line that object put on the rail. A second reader is
# not a race to arbitrate but a defect to find, so the scan looks for every
# route to the terminal's bytes -- the stream itself, a line editor, and the
# typeahead sweep that drains the kernel beneath one -- rather than for reads
# that happen to look like reads.
module StdinReaders
  LIB = Pathname(__dir__).join("..", "lib", "lain").expand_path

  # The producer, and the line editor it alone runs.
  READERS = %w[frontend/stdin_pump.rb frontend/line_editor.rb].freeze

  # `lain epic submit` asks its own question at its own terminal, with no chat
  # and no rail behind it.
  OUTSIDE_THE_CHAT = %w[cli/epic_submit.rb].freeze

  # By the Ripper token each is spelled with: the stream, the gate beneath the
  # line editor, and the two calls that take bytes through it.
  NAMES = { :@gvar => %w[$stdin], :@const => %w[STDIN IOGate], :@ident => %w[readmultiline typed_ahead] }.freeze

  # A route to stdin, found by syntax rather than text so a comment naming one
  # is not one.
  Route = Struct.new(:path, :line, :name) do
    def to_s = "#{path}:#{line} -> #{name}"
  end

  module_function

  def routes(source, path)
    walk(Ripper.sexp(source) || raise("could not parse #{path}"), path)
  end

  def walk(node, path)
    return [] unless node.is_a?(Array)

    [*route(node, path), *node.flat_map { |child| walk(child, path) }]
  end

  # A stream or an editor named, or a line editor built -- `LineEditor.new` is
  # a reader in waiting.
  def route(node, path)
    named = named(node)
    built = built(node)
    return [Route.new(path, named.dig(2, 0), named[1])] if named
    return [Route.new(path, built.dig(2, 0), "LineEditor.new")] if built

    []
  end

  def named(node)
    node if NAMES.fetch(node[0], []).include?(node[1])
  end

  def built(node)
    node[3] if node[0] == :call && node.dig(1, 1, 1) == "LineEditor" && node.dig(3, 1) == "new"
  end

  def chat_path
    %w[cli frontend].flat_map { |unit| LIB.glob("#{unit}/**/*.rb") }
                    .map { |file| file.relative_path_from(LIB).to_s }
                    .reject { |path| READERS.include?(path) || OUTSIDE_THE_CHAT.include?(path) }
  end

  def offenders = chat_path.flat_map { |path| routes(LIB.join(path).read, path) }
end

RSpec.describe "one reader of stdin on the chat path" do
  it "finds no route to the process's stdin outside Frontend::StdinPump and the line editor it runs" do
    expect(StdinReaders.offenders).to be_empty, lambda {
      "Only Frontend::StdinPump reads stdin in a chat; everything else takes lines from the " \
        "Intake it feeds. Found:\n#{StdinReaders.offenders.map { |route| "  #{route}" }.join("\n")}"
    }
  end

  it "sees every route it names, so an empty listing means none rather than a blind scan (self-test)" do
    source = <<~RUBY
      # $stdin and STDIN in a comment
      class Probe
        USAGE = "readmultiline"
        def a = $stdin.gets
        def b = STDIN.read
        def c = ::Reline::IOGate.getc(0)
        def d = LineEditor.typed_ahead(@input)
        def e = ::Reline.readmultiline("> ", true) { true }
        def f = LineEditor.new(vi_mode: -> { false })
      end
    RUBY

    expect(StdinReaders.routes(source, "probe.rb").map(&:name))
      .to eq(%w[$stdin STDIN IOGate typed_ahead readmultiline LineEditor.new])
  end

  it "reads the pump and its editor, which the scan exempts, as the readers they are (self-test)" do
    readers = StdinReaders::READERS.flat_map do |path|
      StdinReaders.routes(StdinReaders::LIB.join(path).read, path)
    end

    expect(readers.map(&:path).uniq).to match_array(StdinReaders::READERS)
  end
end
