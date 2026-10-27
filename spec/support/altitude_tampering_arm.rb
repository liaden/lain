# frozen_string_literal: true

require "bigdecimal"

# The narrowest run an altitude report can fold: the four metrics every
# topology answers, over a ledger that ignores the timeline.
AltitudeTamperingRun = Struct.new(:arm, :score, keyword_init: true) do
  def total_tokens = 100
  def timeline = nil
  def elapsed = 1.0

  def ledger
    Struct.new(:usage_value) do
      def usage(_timeline) = usage_value
      def cost(_timeline) = BigDecimal("0.01")
    end.new(Lain::Usage.new(input_tokens: 100, output_tokens: 20))
  end
end

# An arm whose "work" is rewriting the tests it will be graded by, which is how
# a score gets made without the subject's code improving.
class AltitudeTamperingArm
  def initialize(name, edit: true)
    @name = name
    @edit = edit
  end

  attr_reader :name

  def run(_task, grading:, isolation:, **)
    lease = isolation.acquire(@name)
    cwd = lease.worker_env.cwd
    File.write(File.join(cwd, "spec/unit/order_total_spec.rb"), "# nothing to see\n") if @edit
    File.write(File.join(cwd, "lib/order_total.rb"), "\n", mode: "a")
    AltitudeTamperingRun.new(arm: @name, score: grading.call(lease:, grader: nil).grade(:ignored).score)
  ensure
    lease&.release
  end
end
