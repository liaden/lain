# frozen_string_literal: true

# T8: parks several gated tool calls on one REAL Lain::Approval::Queue at
# once, and hands the block a queue whose every pending has already been
# admitted. spec/lain/frontend/neovim/approval_view_spec.rb's `gated` helper
# (T36, see :311-322) proved this shape out for two pendings -- a real queue,
# real async fibers each calling into it, `spun_until` rather than a sleep --
# and this generalises it to N so a future round (this chunk's own
# integration check 7 among them) can park a queue's worth of approvals in
# one call instead of rebuilding the same Sync/async-task dance per file.
#
# A fixture, not a matcher or a double, because the claim it exists to let a
# spec make -- N pendings observable together via Approval::Queue#each,
# without draining Approval::Queue#dequeue -- is a QUEUE property. Only a
# real queue holding real parked fibers can make it; a plain Array of
# hand-built Pendings (this file's sibling `parked` helpers elsewhere in this
# suite) cannot, because there is no #dequeue to fail to drain.
module ParkedApprovals
  # One gated tool call, distinguishable by its tool_use_id -- the only thing
  # that tells two pendings, two notifications, or two decisions apart once
  # several are parked together. The input carries the same id as the
  # "command", the way spec/lain/notify_spec.rb's own `gated_call` fixture
  # does, so a recording dunstify double can correlate a notification back to
  # the pending that raised it by matching this string inside the argv.
  def self.effect(id)
    Lain::Effect::ToolCall.new(tool_use_id: id, name: "bash", input: { "command" => id })
  end

  # Park `count` gated calls on `queue` and yield only once every one has
  # been admitted (Approval::Queue#each lists it, undecided) -- polled for
  # rather than slept for a guessed duration, the discipline this suite's own
  # `spun_until`/`until_true` helpers already established, so this never
  # asserts that a race is merely usually won.
  #
  # `timeout:` bounds the whole thing on the SAME reactor the parked fibers
  # run on: a queue that never admits every pending would otherwise hang the
  # fixture rather than fail loudly, which under `pspec` reads as "fewer
  # examples, zero failures" -- the same trap CLAUDE.md records for an
  # unrescued SystemExit.
  #
  # @param queue [Lain::Approval::Queue] built by the CALLER, so a spec keeps
  #   control of its own timeout and journal rather than this fixture
  #   choosing one for it
  # @param count [Integer] how many gated calls to park
  # @param timeout [Numeric] seconds this fixture itself waits for every
  #   pending to be admitted, independent of the queue's own answer window
  # @yieldparam queue [Lain::Approval::Queue] the same queue, every pending
  #   admitted and still undecided
  # @return whatever the block returns
  def self.park(queue, count:, timeout: 5)
    Sync do |task|
      fibers = Array.new(count) { |n| task.async { queue.call(effect("tu_#{n}"), nil) } }
      task.with_timeout(timeout) do
        Async::Task.current.sleep(0.001) until queue.count == count

        yield(queue)
      end
    ensure
      fibers&.each(&:stop)
    end
  end
end
