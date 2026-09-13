# frozen_string_literal: true

require "async"
require "stringio"

# The nine built-ins `lib/lain/cli/command/small.rb` holds, one `RSpec.describe`
# block per class -- a fold of six formerly-mirrored spec files
# (sessions/inbox/model/approve/implement_epic/help) plus a first spec for
# `Quit`, which had none beyond the interface-shape checks in
# `registry_spec.rb`. `Unpin` and `Keep` are NOT here: their behavioural specs
# already live beside `Pin` (`pin_spec.rb`) and `Btw` (`btw_spec.rb`) because
# they share setup with those commands, and folding their SOURCE into
# `small.rb` changes nothing those specs read -- a constant's home file is not
# part of what they assert.

RSpec.describe Lain::CLI::Command::Quit do
  subject(:command) { described_class.new }

  it "is the /quit command and describes itself" do
    expect(command.name).to eq("quit")
    expect(command.usage).to include("/quit")
  end

  it "hands the Repl its :quit action, without printing" do
    action = nil
    expect { action = command.call("", instance_double(Lain::CLI::Command::Env)) }.not_to output.to_stdout
    expect(action).to eq(:quit)
  end
end

# /sessions renders Command::Env's `sessions` reader ({Lain::CLI::Sessions}'s
# own #listing) verbatim -- no re-derivation here, matching /status's "one
# definition, read twice" shape.
RSpec.describe Lain::CLI::Command::Sessions do
  def env_with(sessions:) = build_command_env(sessions:)

  let(:command) { described_class.new }
  let(:sessions) { instance_double(Lain::CLI::Sessions) }

  it "renders CLI::Sessions#listing with the default (durable-only) view" do
    allow(sessions).to receive(:listing).with(all: false).and_return("a.ndjson  ...\nb.ndjson  ...")

    expect(command.call("", env_with(sessions:))).to eq("a.ndjson  ...\nb.ndjson  ...")
  end

  it "passes all: true for --all, including ephemeral .btw sessions" do
    allow(sessions).to receive(:listing).with(all: true).and_return("a.btw.ndjson  ...")

    expect(command.call("--all", env_with(sessions:))).to eq("a.btw.ndjson  ...")
  end

  it "treats a bare 'all' argument the same as --all" do
    allow(sessions).to receive(:listing).with(all: true).and_return("a.btw.ndjson  ...")

    expect(command.call("all", env_with(sessions:))).to eq("a.btw.ndjson  ...")
  end

  it "answers a one-line usage and returns rendered text without printing" do
    allow(sessions).to receive(:listing).with(all: false).and_return("no sessions recorded under here")

    text = nil
    expect { text = command.call("", env_with(sessions:)) }.not_to output.to_stdout
    expect(text).to be_a(String)
    expect(command.usage).to start_with("/sessions")
  end
end

# /inbox at `you>` delegates ENTIRELY to Command::Env's `replies` reader
# (the SAME HumanReplies#drain_at_prompt human_replies_spec.rb covers) -- this
# command owns only the argument-free call, never a second listing/answer
# path or a second rendering of what the drain already showed through @tty.
#
# The last example documents the escalation instead of asserting a fix:
# StatusFeed's inbox_count is Projection-parity-pinned (see
# status_feed_spec.rb and Frontend::Neovim::InboxView's parity spec) to
# retire ONLY on a committed :turn's causal_parents, and that :turn Event
# never reaches the live tee in production (status_feed.rb's class doc says
# so) -- so answering here, exactly like answering at `human>`, does NOT
# retire the count by itself. Hand-back flags this as the known constraint
# rather than forking a second counter or breaking the parity spec.
RSpec.describe Lain::CLI::Command::Inbox do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:tty_output) { StringIO.new }
  let(:tty) do
    Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: tty_output, input: StringIO.new,
                            history_path: File.join(@dir, "history"))
  end
  let(:status_feed) { Lain::StatusFeed.new(path: File.join(@dir, "state.json")) }
  let(:store) { Lain::Store.new }
  let(:parent) { Lain::Timeline.empty(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }]) }
  let(:ask_human) { Lain::Tools::AskHuman.new(parent:, observer: ->(event) { status_feed << event }) }
  let(:questions) { Async::Queue.new }
  let(:conductor) { instance_double(Lain::CLI::Conductor) }
  let(:replies) { Lain::CLI::HumanReplies.new(tty:, conductor:, ask_human:, questions:) }
  let(:command) { described_class.new }

  def env_with(replies:, status: instance_double(Lain::StatusFeed))
    build_command_env(replies:, status:)
  end

  # What rides the arrival queue is the inbox item, not the question's
  # bytes -- it carries the digest an answer names its set by, and the asker
  # that asked ({Lain::CLI::Wiring::Askers#announce} is what does this in a
  # run). The reply seam here is the lone asker rather than the run's
  # directory, which is the single-agent case: it answers the same
  # `#reply(answer, digest)`, and this command's job is the same either way.
  def announced(question)
    ask_human.ask(question)
    questions.enqueue(Lain::CLI::HumanReplies::InboxItem.asked(question, ask_human.last_question))
  end

  it "runs the same drain UX HumanReplies exposes for human> -- TTY renders it, the command adds nothing" do
    Sync do
      announced("two pending?")
      allow(conductor).to receive(:read_reply).and_return("yes")

      text = command.call("", env_with(replies:))

      # nil: the drain already delivered the listing + read through @tty
      # (asserted below); a returned String here would render a second,
      # redundant confirmation over the one the drain just printed.
      expect(text).to be_nil
      expect(tty_output.string).to include("two pending?")
      expect(ask_human.last_answer.body["answer"]).to eq("yes")
    end
  end

  it "answers honestly (via the TTY drain's own empty-state render) when nothing is pending" do
    text = command.call("", env_with(replies:))

    expect(text).to be_nil
    expect(tty_output.string).to include("no questions pending")
  end

  # AC ("answered items retire from StatusFeed's count"), as delivered: the
  # A message DOES reach the live StatusFeed (same ChainWriter observer the
  # Q rode), but per Projection/InboxView parity it is lineage, not
  # consumption, so the count is UNCHANGED right after the reply -- matching
  # exactly what typing the same answer at `human>` would do. Retiring in
  # real time needs a live :turn signal StatusFeed cannot see at its
  # construction point (see the class doc's note on this); escalated in the
  # hand-back, not solved here by diverging from the parity spec.
  it "does not retire on the reply alone -- the pre-existing, escalated gap, unchanged by this card" do
    Sync do
      announced("q1?")
      expect(status_feed.state["inbox_count"]).to eq(1)
      allow(conductor).to receive(:read_reply).and_return("42")

      command.call("", env_with(replies:, status: status_feed))

      expect(status_feed.state["inbox_count"]).to eq(1)
    end
  end

  # Review BLOCKER 1. This command opens its OWN `human> ` read through the
  # drain, and {Lain::CLI::Repl::LineScope} now brackets every dispatched line in
  # the reply surfaces -- so without this declaration the loop and the drain
  # would both read the one stdin, and the human's answer would land on
  # whichever fiber won the dequeue (against `@inbox.oldest`, which by then is
  # the loop's own item). It is the ONE command in the set that says this.
  it "declares that it serves replies itself, so no second reply surface opens over it" do
    expect(command.serves_replies?).to be(true)
  end

  # Round 11. The drain resolves its answer through {HumanReplies#resolve_reply},
  # which SETTLES on a refusal -- deliberately, so a dead question does not list
  # forever and refuse every time it is offered. What was not deliberate is that
  # it settled a NIL digest too: an answer naming nothing marked nothing
  # answered and retired nothing, and asking the views and the list to do so
  # anyway put nil into both.
  describe "a refusal's settle" do
    let(:views) { instance_double(Lain::Frontend::Neovim::Buffers, answered: nil) }

    # An item listed for a set the asker does not hold: the inbox line that
    # outlived its question, which is what a stopped run leaves behind.
    def listing(digest)
      questions.enqueue(Lain::CLI::HumanReplies::InboxItem.new(question: "which db?", from: "orchestrator",
                                                               digest:, asked_at: Time.now))
    end

    before { replies.bind_editor(nil, views:) }

    it "retires a refusal that DOES name a dead question, exactly as before" do
      Sync do
        dead = parent.commit(role: :assistant, content: [{ "type" => "text", "text" => "gone" }]).head_digest
        listing(dead)
        allow(conductor).to receive(:read_reply).and_return("42")

        command.call("", env_with(replies:))

        expect(tty_output.string).to include(dead)
        expect(views).to have_received(:answered).with(dead)
        expect(replies.pending?).to be(false)
      end
    end

    it "retires nothing, and marks no view answered, when the reply names no question at all" do
      Sync do
        listing(nil)
        allow(conductor).to receive(:read_reply).and_return("42")

        command.call("", env_with(replies:))

        expect(tty_output.string).to include("stale")
        expect(views).not_to have_received(:answered)
        expect(replies.pending?).to be(true)
      end
    end
  end

  it "answers a one-line usage, and the command file itself never prints (only TTY, the exempted frontend, does)" do
    text = :unset
    expect { text = command.call("", env_with(replies:)) }.not_to output.to_stdout
    expect(text).to be_nil
    expect(command.usage).to start_with("/inbox")
  end
end

RSpec.describe Lain::CLI::Command::Model do
  subject(:model) { described_class.new }

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:switch) { Lain::Context::ModelSwitch.new("claude-opus-4-8", journal:) }
  let(:env) { instance_double(Lain::CLI::Command::Env, model_switch: switch) }

  def switches
    Lain::Journal.records(journal_io.string.lines, type: "model_switch").to_a
  end

  it "registers as /model with a one-line usage" do
    expect(model.name).to eq("model")
    expect(model.usage).to include("/model")
  end

  describe "/model <id>" do
    it "switches the slot the next render reads" do
      model.call("claude-haiku-4-5", env)
      expect(switch.current).to eq("claude-haiku-4-5")
    end

    it "returns rendered text naming both models, never printing" do
      text = nil
      expect { text = model.call("claude-haiku-4-5", env) }.not_to output.to_stdout
      expect(text).to include("claude-opus-4-8").and include("claude-haiku-4-5")
    end

    it "journals the change" do
      model.call("claude-haiku-4-5", env)
      expect(switches).to contain_exactly(
        a_hash_including("from" => "claude-opus-4-8", "to" => "claude-haiku-4-5", "surface" => "tty")
      )
    end

    it "passes an unknown id VERBATIM -- dispatch fails loudly, never a silent fallback" do
      model.call("totally-bogus-model", env)
      expect(switch.current).to eq("totally-bogus-model")
    end

    it "strips the surrounding whitespace the invocation grammar leaves" do
      model.call("  claude-haiku-4-5  ", env)
      expect(switch.current).to eq("claude-haiku-4-5")
    end
  end

  describe "bare /model" do
    it "reports the model in force without switching or journaling" do
      expect(model.call("", env)).to include("claude-opus-4-8")
      expect(switch.current).to eq("claude-opus-4-8")
      expect(switches).to be_empty
    end
  end
end

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module ApproveSpecSupport
  # The minimal effect a {Approval::Queue::Pending} reads: a name, an input, and
  # the tool_use_id the park's journal record correlates on.
  Effect = Struct.new(:name, :input, :tool_use_id)
end

RSpec.describe Lain::CLI::Command::Approve do
  subject(:approve) { described_class.new(prompt:) }

  let(:answers) { [] }
  let(:asked) { [] }
  # The drain UX is Frontend::ApprovalPolicy's own prompt loop, its reader
  # scripted the way the Repl scripts it over the conductor -- so decisions are
  # signed with its "tty" surface, not a name this command invents.
  let(:prompt) do
    Lain::Frontend::ApprovalPolicy.new(reader: lambda { |question|
      asked << question
      answers.shift
    })
  end

  def pending(tool = "bash", input = { "command" => "ls" })
    Lain::Approval::Queue::Pending.new(effect: ApproveSpecSupport::Effect.new(tool, input, "tu_#{tool}"),
                                       requester: "agent", clock: -> { 0.0 })
  end

  def env_over(parked)
    instance_double(Lain::CLI::Command::Env, approvals: parked)
  end

  it "registers as /approve with a one-line usage" do
    expect(approve.name).to eq("approve")
    expect(approve.usage).to include("/approve")
  end

  describe "draining three parked pendings inline" do
    let(:parked) { [pending("bash"), pending("edit_file", { "path" => "/etc/passwd" }), pending("bash")] }
    let(:answers) { %w[y n y] }

    it "renders each pending for y/N in turn" do
      approve.call("", env_over(parked))

      expect(asked.size).to eq(3)
      expect(asked.first).to include("bash")
      expect(asked[1]).to include("edit_file")
    end

    it "decides each pending as answered, signed tty" do
      approve.call("", env_over(parked))

      expect(parked.map(&:decision)).to eq(%i[approve deny approve])
      expect(parked.map(&:surface)).to eq(%w[tty tty tty])
    end

    it "returns the decisions as rendered text, never printing" do
      text = nil
      expect { text = approve.call("", env_over(parked)) }.not_to output.to_stdout
      expect(text).to be_a(String).and include("approved").and include("denied")
    end
  end

  it "skips a pending another surface already decided -- no human is asked about a settled call" do
    settled = pending("bash")
    settled.approve(surface: "editor")
    live = pending("edit_file")
    answers << "y"

    approve.call("", env_over([settled, live]))

    expect(asked.size).to eq(1)
    expect(settled.surface).to eq("editor")
  end

  it "names the deciding surface when another surface wins mid-drain" do
    racy = pending("bash")
    race_prompt = Lain::Frontend::ApprovalPolicy.new(reader: lambda { |_question|
      racy.deny(surface: "timeout")
      "y"
    })

    text = described_class.new(prompt: race_prompt).call("", env_over([racy]))

    expect(text).to include("bash: denied (timeout)")
  end

  it "renders an honest empty drain when nothing is parked" do
    expect(approve.call("", env_over([]))).to include("no pending approvals")
  end

  it "degrades to the same empty drain over NoApprovals (a session that wired no queue)" do
    expect(approve.call("", env_over(Lain::CLI::Command::Env::NoApprovals))).to include("no pending approvals")
  end
end

# A driver that ran, as the command sees one.
class ImplementEpicSpecDriver
  def initialize(reply) = @reply = reply
  attr_reader :width, :budget

  def run(width: nil, budget: nil)
    @width = width
    @budget = budget
    @reply
  end
end

# `/implement-epic` at `you>`: work the mounted epic's approved issues to its
# working branch, reporting each as it lands. The driving lives in
# {CLI::EpicDriver::Run}; this command is only the door onto it, so what these
# examples pin is the door -- what it is called, what it hands back, and how it
# refuses a chat that is in no epic.
RSpec.describe Lain::CLI::Command::ImplementEpic do
  let(:command) { described_class.new }

  it "is named for the verb a human types, and says what it does" do
    expect(command.name).to eq("implement-epic")
    expect(command.usage).to include("/implement-epic")
  end

  it "runs the mounted epic's driver and hands back what it reported" do
    driver = ImplementEpicSpecDriver.new("landed a at sha-a")

    expect(command.call("", build_command_env(epic_driver: driver))).to include("landed a at sha-a")
  end

  # The refusal is the Null's, raised rather than returned: a chat in no epic
  # must not read a line of success, and the Repl renders a Lain::Error loudly.
  it "refuses by name when no epic is mounted, naming --epic" do
    env = build_command_env(epic_driver: Lain::CLI::EpicDriver::Factory::Unmounted)

    expect { command.call("", env) }.to raise_error(Lain::Error, /this chat is in no epic/)
  end

  # The width is a knob, so a human who wants the issues taken one at a time can
  # say so without editing a config file.
  it "passes a width the human typed through to the run" do
    driver = ImplementEpicSpecDriver.new("done")

    command.call("--width 3", build_command_env(epic_driver: driver))

    expect(driver.width).to eq(3)
  end

  it "refuses a width that is not a positive number, rather than driving with a default" do
    env = build_command_env(epic_driver: ImplementEpicSpecDriver.new("done"))

    expect { command.call("--width nope", env) }.to raise_error(Lain::Error, /width/)
  end
end

# /help answers a {Lain::Renderable} now. The WORDS are unchanged -- the
# section headers name a token so the listing under them reads as content
# rather than as one flat colour.
RSpec.describe Lain::CLI::Command::Help do
  let(:registry) { Lain::CLI::Command::Registry.new([Lain::CLI::Command::Quit.new]) }
  let(:catalog) do
    Lain::Skill::Catalog.new(
      { brew: Lain::Skill.new(name: "brew", description: "steep the pot", scaffold: "scaffold") }
    )
  end
  let(:help) { described_class.new(registry:, catalog:) }
  let(:env) { instance_double(Lain::CLI::Command::Env) }

  before { registry.register(help) }

  it "lists every registered command with its one-line usage" do
    rendered = help.call("", env)

    expect(rendered.text).to include(Lain::CLI::Command::Quit.new.usage)
    expect(rendered.text).to include(help.usage)
  end

  it "lists the catalog's skills beside the commands" do
    expect(help.call("", env).text).to include("/brew", "steep the pot")
  end

  it "sees a command registered after it was built -- the registry reference is live" do
    late = Struct.new(:name) do
      def usage = "/#{name} -- landed by a later card"

      def call(_args, _env) = ""
    end
    registry.register(late.new("status"))

    expect(help.call("", env).text).to include("/status -- landed by a later card")
  end

  it "renders an honest empty skills section" do
    bare = described_class.new(registry:, catalog: Lain::Skill::Catalog.new({}))

    expect(bare.call("", env).text).to include("(none)")
  end

  it "returns a renderable and never prints" do
    rendered = nil
    expect { rendered = help.call("", env) }.not_to output.to_stdout

    expect(rendered).to be_a(Lain::Renderable)
  end

  describe "the renderable it answers" do
    it "says exactly the words the String return said" do
      expect(help.call("", env).text)
        .to eq("commands:\n  #{Lain::CLI::Command::Quit.new.usage}\n  #{help.usage}\n\nskills:\n  " \
               "/brew -- steep the pot")
    end

    it "names its section headers with the label token" do
      headers = help.call("", env).select { |segment| segment.token == :label }.map(&:text)

      expect(headers).to include("commands:", "skills:")
    end

    it "leaves the entries out of the header's token" do
      entries = help.call("", env).reject { |segment| segment.token == :label }.map(&:text).join

      expect(entries).to include("/brew -- steep the pot", help.usage)
    end

    it "renders more than one token -- the listing is never one flat colour" do
      expect(help.call("", env).map(&:token).uniq.size).to be > 1
    end
  end
end
