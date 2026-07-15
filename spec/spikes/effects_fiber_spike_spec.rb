# frozen_string_literal: true

# 5-0.2: is "effects interpreted via a Fiber-driven coroutine" a genuinely different
# way to run the SAME Effect algebra, or does it silently need a different Middleware
# surface -- and what does routing a tool's own code through a Fiber cost when that
# tool raises? The plan's open question ("Effects via Fiber vs plain handler objects")
# claims fibers make multi-shot resumption (speculative branching, 3c-5.6) natural but
# wreck stack traces; both halves are measured here, not assumed. See docs/concurrency.md
# for the recorded backtraces and the recommendation this spike produced.
#
# Both prototypes below are adapted into the IDENTICAL public shape
# Lain::Effect::Handler#to_app already exposes -- an env -> env lambda writing :result
# -- and are driven through the actual Lain::Middleware::Stack#call(env, &app) boundary,
# so "the same Middleware#call(env) surface" (5-0.2's acceptance criterion) is not
# asserted by analogy; it is the literal call both prototypes go through.
#
# Handler::Mock, not Live, stands in for "the existing handler-object interpreter":
# Live's correctness-gate-3 rescue (StandardError -> Tool::Result.error) converts a
# raise into a message-only Result before either interpreter's OWN calling convention
# could be compared -- that conversion is doing its own job, not answering this
# spike's question. Mock lets a raise reach the caller unconverted, on both sides.
module Spikes
  # The fiber-based prototype under comparison: the SAME public shape as
  # Lain::Effect::Handler#to_app (an env -> env lambda writing :result), but the
  # resolver runs INSIDE a Fiber's own call stack rather than as a nested Ruby call
  # -- the shape a tool's own code will actually have once 5-0.3 hosts tool dispatch
  # on Async::Task fibers for the reason 5-0.1 measured (cooperative IO), not a fake
  # reactor invented for this spike. `#resume` returns the fiber block's return
  # value once it finishes, so no internal Fiber.yield is needed to round-trip a
  # single effect through it.
  class FiberEffectInterpreter
    def initialize(&resolver)
      @resolver = resolver
    end

    def to_app
      lambda do |env|
        env.merge(result: run(env.fetch(:effect), env[:context]))
      end
    end

    def run(effect, context)
      Fiber.new { @resolver.call(effect, context) }.resume
    end
  end
end

RSpec.describe "Effects via Fiber vs handler objects", :spike do
  let(:resolver) do
    lambda do |effect, _context|
      raise "kaboom from tool" if effect.name == "boom"

      Lain::Tool::Result.ok("echo:#{effect.input[:text]}")
    end
  end

  let(:handler_object_app) { Lain::Effect::Handler::Mock.new(&resolver).to_app }
  let(:fiber_app) { Spikes::FiberEffectInterpreter.new(&resolver).to_app }

  # One real pass-through member ({Middleware::Identity}, an instance of
  # {Middleware::Base}) sits in the Stack, so the fold builds an actual composed
  # chain link around each prototype rather than degenerating to the
  # zero-middleware case -- equivalence is proven through composition, not just
  # through the boundary wrap.
  def run_through_stack(app, effect)
    Lain::Middleware::Stack.new([Lain::Middleware::Identity]).call({ effect:, context: nil }, &app)
  end

  describe "equivalence" do
    it "produces the same Tool::Result through the identical Middleware#call(env) surface" do
      effect = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "echo", input: { text: "hi" })

      handler_result = run_through_stack(handler_object_app, effect)
      fiber_result = run_through_stack(fiber_app, effect)

      expect(fiber_result.result).to eq(handler_result.result)
      expect(fiber_result.result).to eq(Lain::Tool::Result.ok("echo:hi"))
    end
  end

  describe "when a tool raises" do
    let(:boom) { Lain::Effect::ToolCall.new(tool_use_id: "tu_boom", name: "boom", input: {}) }

    # Rescues and returns the backtrace, or :did_not_raise -- a sentinel rather than
    # relying on `rescue` alone, so a prototype that stops raising (a real bug) fails
    # the example instead of silently comparing two "did not raise" sentinels as if
    # they were equivalent backtraces.
    def capture_backtrace(app, effect)
      run_through_stack(app, effect)
      :did_not_raise
    rescue StandardError => e
      e.backtrace
    end

    it "captures a backtrace from each prototype for docs/concurrency.md" do
      handler_backtrace = capture_backtrace(handler_object_app, boom)
      fiber_backtrace = capture_backtrace(fiber_app, boom)

      expect(handler_backtrace).not_to eq(:did_not_raise)
      expect(fiber_backtrace).not_to eq(:did_not_raise)

      # MEASURED: the handler-object interpreter is one continuous Ruby call stack, so
      # its backtrace reaches all the way out to the frame that drove it -- this very
      # method is on it.
      expect(handler_backtrace.join("\n")).to match(/capture_backtrace/)

      # MEASURED: the fiber prototype's raise happens INSIDE Fiber.new's own block,
      # which has its own independent call stack -- Exception#backtrace is captured by
      # walking that stack alone, so it does NOT include capture_backtrace, #run, or
      # anything outside the fiber, even though #resume is what re-raises it at the
      # caller. This is the "wrecked stack trace" the plan's open question named.
      expect(fiber_backtrace.join("\n")).not_to match(/capture_backtrace/)
    end
  end

  it "cannot resume after completion " \
     "(measured, not assumed -- the 'multi-shot resumption' the open question hoped for)" do
    fiber = Fiber.new { 1 + 1 }
    fiber.resume

    # MEASURED (ruby 4.0.5): the message is "attempt to resume a terminated fiber",
    # not "dead fiber" -- the initial guess before running this.
    expect { fiber.resume }.to raise_error(FiberError, /terminated fiber/)
  end
end
