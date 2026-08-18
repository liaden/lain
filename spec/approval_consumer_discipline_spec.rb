# frozen_string_literal: true

require "ripper"
require "pathname"

# Mechanical enforcement of the one-consumer rule, and deliberately the same
# shape {DesktopDiscipline} and {OutputDiscipline} are.
#
# {Lain::Approval::Queue}'s arrival queue delivers each parked call to exactly
# ONE `#dequeue` caller -- `Async::Queue` delegates to a `Thread::Queue`, so a
# second consumer does not observe the pending, it TAKES it. Exactly one surface
# may therefore drain it, and it has to be the one that can ask a person:
# {Lain::Frontend::ApprovalPolicy}. Every other surface observes the parked set
# through `Queue#each` ({Lain::Approval::QueueSurface}, {Lain::Notify},
# {Lain::Frontend::Neovim::ApprovalView}).
#
# The rule was already written down -- `queue_surface.rb`'s class comment says
# it in as many words -- and `Lain::Notify` broke it anyway, because a comment in
# one file is not reachable from the file that has to obey it. From the second
# gated call of a turn onward the notifier took the pending and held it for the
# whole of dunstify's blocking wait, so the chat pane rendered nothing and read
# nothing; on `--no-nvim` that is a session with NO approval surface (T15,
# manual-QA round 4 F18). A live suite of 13690 examples could not see it,
# because every spec's stand-in surface was written to observe rather than
# consume -- so the guard has to be structural, and it has to fail at commit.
#
# WHY A LINT AND NOT A RUNTIME GUARD. Refusing a second consumer inside
# `Queue#dequeue` was considered and rejected: it has legitimate non-concurrent
# callers, a fresh watcher fiber per dispatched line makes object identity
# useless as a key, and `#dequeue`'s own recursive already-decided skip makes
# "who is consuming" hard to even define. That is a design question for its own
# card; this is the ten-line answer that stops the regrowth meanwhile.
#
# Robustness, and the limits: this parses each file with Ripper and inspects the
# SYNTAX TREE, so `dequeue` in a comment or a string is never matched. What it
# CANNOT do is tell WHICH queue a receiver names -- `queue.dequeue` in
# `approval_policy.rb` and `queue.dequeue` in `human_replies.rb` are the same
# two tokens over different queues. So the rule is stricter and simpler than
# type inference: every `.dequeue` site in `lib/` is named here with its
# receiver, and a new one anywhere fails until somebody rules on it. That
# ruling is the review this exists to force.
#
# The bluntness is the point, and it is a deliberate choice over a cleverer
# matcher. Anything that tried to decide from the syntax tree WHICH queue
# `queue.dequeue` drains would be a guess wearing a lint's clothes: it would
# pass while being wrong, which is the failure mode this whole card is about.
# A rule that asks a human to write one sentence per call site cannot be wrong
# in that direction -- at worst it asks for a sentence that was obvious. So the
# message below tells the reader WHICH of the two things to do, because a guard
# that stops a commit without saying what to do next gets suppressed rather
# than answered.
module ApprovalConsumerDiscipline
  # The one surface that may drain the arrival queue, and the file it lives in.
  APPROVAL_CONSUMER = "lain/frontend/approval_policy.rb"

  # Every `#dequeue` receiver in `lib/`, by file, with what it drains. Paths are
  # relative to `lib/`; a receiver not listed for its file is a violation.
  ALLOWLIST = {
    "lain/approval/queue.rb" => { "@arrivals" => "the queue's own arrival buffer -- this IS the seam" },
    APPROVAL_CONSUMER => { "queue" => "THE approval consumer: the surface that can ask a person" },
    "lain/cli/human_replies.rb" => {
      "@questions" => "ask_human's own queue, not an approval queue",
      "queue" => "ask_human's own queue, drained non-blockingly by Pending#gather"
    }
  }.freeze

  # A single detected violation, with enough context to fix it.
  Violation = Struct.new(:path, :line, :receiver) do
    def to_s = "#{path}:#{line} -> #{receiver}.dequeue"
  end

  # Walks a Ripper s-expression collecting `.dequeue` calls and their receivers.
  class Scanner
    def initialize(path, allowed)
      @path = path
      @allowed = allowed
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

      examine(node) if node[0] == :call
      node.each { |child| walk(child) }
    end

    # `[:call, receiver, period, [:@ident, "dequeue", position]]`.
    def examine(call)
      ident = call[3]
      return unless ident.is_a?(Array) && ident[0] == :@ident && ident[1] == "dequeue"

      receiver = receiver_name(call[1]) || "(unreadable receiver)"
      @violations << Violation.new(@path, ident[2]&.first, receiver) unless @allowed.key?(receiver)
    end

    # An ivar, a local/method call, or nothing this rule can name -- in which
    # case it is reported, because an unnameable consumer is one nobody ruled on.
    def receiver_name(node)
      return nil unless node.is_a?(Array)

      case node[0]
      when :@ivar, :@ident, :@const then node[1]
      when :var_ref, :vcall then receiver_name(node[1])
      end
    end
  end

  module_function

  def lib_root = Pathname(__dir__).join("..", "lib").expand_path

  # @return [Array<Violation>] every unruled `.dequeue` across the `lib/` tree
  def violations
    lib_root.glob("**/*.rb").flat_map do |file|
      relative = file.relative_path_from(lib_root).to_s
      Scanner.new(relative, ALLOWLIST.fetch(relative, {})).scan(file.read)
    end
  end
end

RSpec.describe "approval consumer discipline" do
  it "drains no queue in lib/ that this rule has not ruled on" do
    violations = ApprovalConsumerDiscipline.violations

    expect(violations).to be_empty, lambda {
      listing = violations.map { |violation| "  #{violation}" }.join("\n")
      "Lain::Approval::Queue's arrival queue hands each parked call to exactly ONE #dequeue " \
        "caller, so a second consumer STEALS pendings the human's surface then never asks about " \
        "-- on --no-nvim that is a session with no approval surface at all (T15). Found:\n" \
        "#{listing}\n" \
        "If it drains an approval queue, it must not exist: observe the parked set through " \
        "Queue#each, as Approval::QueueSurface, Notify and Neovim::ApprovalView do. If it drains " \
        "some OTHER queue, add it to ApprovalConsumerDiscipline::ALLOWLIST with its reason."
    }
  end

  # The generating half is the example above; this one is the ruling, written
  # where a reader looking for "who may drain approvals" will find it.
  it "names exactly one approval consumer, and it is the surface that can ask a person" do
    expect(ApprovalConsumerDiscipline::APPROVAL_CONSUMER).to eq("lain/frontend/approval_policy.rb")
    expect(Lain::Frontend::ApprovalPolicy.instance_method(:watch).source_location.first)
      .to end_with(ApprovalConsumerDiscipline::APPROVAL_CONSUMER)
  end

  it "reads the syntax tree, so prose and strings are not consumers (self-test)" do
    source = <<~RUBY
      # a comment about approvals.dequeue
      x = "@approvals.dequeue in a string"
      :dequeue
    RUBY

    expect(ApprovalConsumerDiscipline::Scanner.new("self_test", {}).scan(source)).to be_empty
  end

  it "flags an unruled receiver and clears a ruled one (self-test)" do
    found = ApprovalConsumerDiscipline::Scanner.new("self_test", { "questions" => "ok" }).scan(<<~RUBY)
      loop { decide(@approvals.dequeue) }
      questions.dequeue(timeout: 0)
    RUBY

    expect(found.map(&:receiver)).to contain_exactly("@approvals")
  end
end
