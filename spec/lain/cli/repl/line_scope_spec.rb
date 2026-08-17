# frozen_string_literal: true

require "async"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module LineScopeSpecSupport
  # A surface with the real ones' SHAPE: it parks forever, exactly as
  # {Lain::CLI::HumanReplies#answer_loop}'s reply fiber and
  # {Lain::Frontend::ApprovalPolicy#watch} both do -- so an example can tell
  # "given a fiber and stopped" from "never given one at all", which a stand-in
  # that fell off the end of its block could not.
  class ParkingSurface
    POLL = 0.01

    def self.spawn(task) = task.async { loop { Async::Task.current.sleep(POLL) } }
  end

  # The reply seam as the scope asks it ({Lain::CLI::HumanReplies#surfaces}).
  class Replies
    def initialize(body) = @body = body
    def surfaces(task) = @body.call(task)
  end

  # The approval seam ({Lain::CLI::Repl::ApprovalSurfaces#watch}), which answers
  # nil rather than an empty set under --yolo. `terminal:` is RECORDED rather
  # than ignored: whether the one stdin-reading approval surface was asked for is
  # the whole of what the scope decides for this seam.
  class Approvals
    def initialize(body) = @body = body

    attr_reader :terminal

    def watch(task, terminal: true)
      @terminal = terminal
      @body.call(task)
    end
  end
end

# T1's answer to "which object owns the reply and approval fibers' lifetime".
# It is one DISPATCHED LINE, because a human question can be raised from any
# frame that line reaches -- a command running lib-side, or the subagent a
# `@role[/skill]` line spawns -- and not only from the ask {Repl#respond} makes.
# It is not the CONVERSATION, because the TTY reply read parks on the stdin the
# next `you>` prompt needs back.
RSpec.describe Lain::CLI::Repl::LineScope do
  def scope_over(replies:, surfaces:)
    described_class.new(replies: LineScopeSpecSupport::Replies.new(replies),
                        surfaces: LineScopeSpecSupport::Approvals.new(surfaces))
  end

  def nothing = ->(_task) { [] }
  def unwired = ->(_task) {}

  # Spawns a real parked fiber AND keeps it, so an example can ask afterwards
  # whether it is still running.
  def parking(into)
    lambda do |task|
      surface = LineScopeSpecSupport::ParkingSurface.spawn(task)
      into << surface
      [surface]
    end
  end

  it "returns what the line itself returned, so a Repl action reaches converse" do
    Sync do
      expect(scope_over(replies: nothing, surfaces: unwired).serve { :quit }).to eq(:quit)
    end
  end

  it "starts both sets on ONE task, so a question and an approval are answerable at once" do
    given = {}

    Sync do
      scope_over(replies: ->(task) { [].tap { given[:replies] = task } },
                 surfaces: ->(task) { [].tap { given[:approvals] = task } }).serve { nil }
    end

    expect(given.keys).to contain_exactly(:replies, :approvals)
    expect(given[:replies]).to equal(given[:approvals])
  end

  it "stops every surface it started, so the next you> read has the terminal back" do
    parked = []

    Sync { scope_over(replies: parking(parked), surfaces: parking(parked)).serve { nil } }

    expect(parked.size).to eq(2) # the size is what keeps `none?` from passing vacuously
    expect(parked.none?(&:running?)).to be(true)
  end

  # The --yolo shape: no queue was wired, so the approval watcher answers nil
  # rather than an empty set, and the splat has to add nothing.
  it "survives an approval set that answers nil" do
    Sync do
      expect { scope_over(replies: nothing, surfaces: unwired).serve { nil } }.not_to raise_error
    end
  end

  # T1 review, SHOULD-FIX 1 (probe 3). The two halves used to be one array
  # literal, so a raise from the SECOND left the first's fibers unassigned and
  # the ensure stopped nothing -- a reply fiber parked on the terminal outliving
  # its line, which holds the Sync open forever. That is a HANG, not an error,
  # and the "stops them when the line raises" example below cannot see it:
  # by then both halves have already been assigned.
  it "stops the reply fibers when the approval half raises" do
    parked = []
    blowing_up = ->(_task) { raise(Lain::Error, "the approval half blew up") }
    scope = scope_over(replies: parking(parked), surfaces: blowing_up)

    Timeout.timeout(5) do
      Sync { expect { scope.serve { :never } }.to raise_error(Lain::Error, "the approval half blew up") }
    end

    expect(parked.size).to eq(1)
    expect(parked.none?(&:running?)).to be(true)
  end

  # A LINE THAT OWNS THE TERMINAL READ GETS NO TERMINAL SURFACE. A line that
  # reads stdin itself ({Command::Inbox}) must be the only reader, so NEITHER is
  # spawned over it -- not the reply loop, and not the approval prompt, which
  # reads the same `conductor.read_reply(tty, ...)` stdin. Two readers means the
  # keystroke goes to whichever won it, and the approval half of that is a `y`
  # typed at an inbox question landing as the verdict on a gated `bash`.
  #
  # Only for such a line: an ORDINARY one still spawns both, so the ask path can
  # still put two reads on one stdin. See {Repl::LineScope#serve}'s comment for
  # why that residual is out of this card's scope rather than covered here.
  it "opens no reply surface for a line that owns the terminal" do
    parked = []

    Sync { scope_over(replies: parking(parked), surfaces: nothing).serve(owns_terminal: true) { nil } }

    expect(parked).to be_empty
  end

  # The approval seam is still ASKED -- its non-terminal watchers (desktop, the
  # editor's list, the oracles) keep answering the queue -- but it is told not to
  # open the one surface that reads stdin.
  it "tells the approval seam to spawn no terminal surface for such a line" do
    seam = LineScopeSpecSupport::Approvals.new(nothing)

    Sync { described_class.new(replies: LineScopeSpecSupport::Replies.new(nothing), surfaces: seam).serve(owns_terminal: true) { nil } }

    expect(seam.terminal).to be(false)
  end

  it "asks for the terminal surface on an ordinary line" do
    seam = LineScopeSpecSupport::Approvals.new(nothing)

    Sync { described_class.new(replies: LineScopeSpecSupport::Replies.new(nothing), surfaces: seam).serve { nil } }

    expect(seam.terminal).to be(true)
  end

  # The ensure is the whole point: a line that raises past the boundary's rescue
  # must not leave a fiber parked on stdin.
  it "stops them when the line raises" do
    parked = []

    Sync do
      scope = scope_over(replies: parking(parked), surfaces: unwired)
      expect { scope.serve { raise Lain::Error, "torn mid-line" } }.to raise_error(Lain::Error, "torn mid-line")
    end

    expect(parked.size).to eq(1)
    expect(parked.none?(&:running?)).to be(true)
  end
end
