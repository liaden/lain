# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A progress record is only ever read as part of a tree, so it must name
      # the spawn whose branch it belongs to, and its turn count must be a
      # count: a row saying a child is "nil turns in" is worse than no row.
      class ChildProgress < Declarative::Carrier
        attribute :spawn
        attribute :turns
        validates :spawn, presence: { message: "must name the :spawn this child belongs to, got nil" }
        validates :turns,
                  numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                  message: "must be how many turns the child has committed, got %<value>s" }
      end
    end

    ChildProgress = Data.define(:spawn, :role, :task_line, :worker, :turns, :head)

    # How far a spawned child has got, while it is still getting there.
    #
    # THE SPAWN BODY IS UNTOUCHED AND THIS RECORD IS WHY, which is the one
    # argument the rest of the fleet tree is built on. A `:spawn`'s digest is an
    # address -- a bench arm joins two runs on it, `lain watch` follows it, an
    # actor is told by it -- so growing its body by a prompt's first line would
    # re-address every spawn in the project for a status line. The facts a live
    # fleet view needs ride here instead, beside the spawn, naming it.
    #
    # TWO SHAPES, ONE RECORD. The dispatch one carries what does not change:
    # `role`, `task_line` and the `worker` key its lease was cut under. Each
    # later one carries only what moved, `turns` and `head`, so a fifteen-turn
    # child costs one task line rather than fifteen. A reader folds them onto
    # one row by `spawn`, which is what makes the omissions safe.
    #
    # `head` IS THE TREE'S PARENT EDGE: a grandchild's `:spawn` names the head
    # it came from and nothing else, so only these place it. `worker` is nil
    # where no worker was minted ({Isolation::Leases::InPlace}).
    #
    # Reopened for the constants and the constructor, since one declared inside
    # a `Data.define` block lands in the enclosing module. The docstring lives
    # on the reopen because YARD keeps only one and discards the other.
    class ChildProgress
      include Journalable

      # The bound on the JOURNAL, so one runaway prompt cannot put a megabyte
      # in every session file; the drawn row is clamped by display columns
      # where the whole line is known ({StatusFeed::Fleet::Row}). Silent,
      # because refusing an over-long prompt would lose the row, not the words.
      MAX_TASK_LINE = 96

      # The role a spawn wears when its tool was never named one.
      DEFAULT_ROLE = "subagent"

      # {Tools::AskHuman::InboxRow}'s scrub rather than a second copy: that
      # object's whole job is one row of somebody else's text drawn on a
      # terminal, which is what these become. A role is config and not model
      # output, but it joins the same line, so it takes the same rule. The
      # constant resolves at call time, so load order does not matter.
      def self.line(text) = Tools::AskHuman::InboxRow.one_line(text)

      def initialize(spawn:, turns:, role: nil, task_line: nil, worker: nil, head: nil)
        Carriers::ChildProgress.check!(spawn:, turns:)

        super(spawn: -spawn.to_s, role: role && -ChildProgress.line(role),
              task_line: task_line && -ChildProgress.line(task_line)[0, MAX_TASK_LINE],
              worker: worker && -worker.to_s, turns: Integer(turns), head: head && -head.to_s)
      end
    end
  end
end
