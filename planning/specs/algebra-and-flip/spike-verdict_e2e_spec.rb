require "delegate"
# frozen_string_literal: true

require "async"
require "stringio"
require "tmpdir"
require "fileutils"

class VerdictSpikeJudge
  attr_reader :asked

  def initialize = @asked = 0
  def never_parking = self

  def call(_role, _mode, _prompt)
    @asked += 1
    Lain::Tool::Result.ok("approve")
  end
end

Ctx = Data.define(:worker_env, :requester, :automatic_approval_barred) do
  def automatic_approval_barred? = automatic_approval_barred
end

RSpec.describe "confined verdict relabel, end to end" do
  around do |ex|
    Dir.mktmpdir do |d|
      @home = File.join(d, "home"); @proj = File.join(d, "proj"); @other = File.join(d, "other")
      FileUtils.mkdir_p([@home, @proj, @other])
      @npmrc = File.join(@other, ".npmrc")
      ex.run
    end
  end

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:token) { "//registry.npmjs.org/:_authToken=npm_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5\n" }

  def plain
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: @home, cwd: @proj, root: @proj),
                                  home: @home, root: @proj)
  end
  # Confined lacks in_related_tree? (Judged calls it), so Judged cannot be handed one as shipped;
  # patch the one delegator onto the instance to ask the hypothetical.
  def confined
    base = plain
    c = base.confined(roots: [@proj])
    Class.new(SimpleDelegator) { define_method(:in_related_tree?) { |p| base.in_related_tree?(p) } }.new(c)
  end
  def effect = Lain::Effect::ToolCall.new(tool_use_id: "tu1", name: "read_file", input: { "path" => @npmrc })

  # Judged: what the real rung does with an approving judge.
  def judged(policy)
    judge = VerdictSpikeJudge.new
    asked = []
    asking = ->(_e, _c) { asked << 1; Lain::Approval::Escalation::Ruling.abstain(rung: "human", because: "parked") }
    rung = Lain::Approval::Judged.new(
      judge: Lain::Approval::Judge.new(role_spawn: judge, timeout: 5), policy:, asking:, journal:)
    ctx = Ctx.new(worker_env: Lain::WorkerEnv.new(cwd: @proj, env: {}), requester: "child", automatic_approval_barred: false)
    ruling = rung.call(effect, ctx)
    { verdict: ruling.verdict, judge_asked: judge.asked, parked_for_human: asked.size }
  end

  # SecretSurface: path-gate parked (NONE) or token regions; oracle says approve 0.95.
  def surface(policy, content)
    oracle = Class.new do
      def initialize = (@d = Lain::Oracle::SecretRead.definition; @n = 0)
      attr_reader :n
      def ask(_i = {}) = (@n += 1; @d.answer("verdict" => "approve", "confidence" => 0.95, "reason" => "s"))
    end.new
    surf = Lain::Approval::SecretSurface.new(oracle:, threshold: 0.8, journal: [], path_gate: Lain::Approval::PathGate.new(policy))
    regions = Lain::Sensitivity::Regions.detect(content)
    out = regions.empty? ? Lain::Approval::Queue::Outstanding::NONE : Lain::Approval::Queue::Outstanding.new(path: @npmrc, regions:)
    q = Lain::Approval::Queue.new(journal:, timeout: 0.05)
    settled = Sync do |task|
      g = task.async { q.adjudicate(effect, nil, outstanding: out) }
      task.with_timeout(1) { q.dequeue }
      surf.sweep(q)
      task.with_timeout(2) { g.wait }
    end
    { kinds: regions.map { _1.respond_to?(:kind) ? _1.kind : _1.class.name }, oracle_asked: oracle.n,
      approved: settled.approved?, signed: settled.surface }
  end

  [["empty file (path classifier only)", ""], ["token file (regions fire)", :token]].each do |label, c|
    it "#{label}" do
      content = c == :token ? token : c
      File.write(@npmrc, content)
      puts "\n== #{label}"
      puts "verdicts: plain=#{plain.judge(@npmrc, cwd: @proj).then { [_1.level, _1.reason] }} " \
           "confined=#{confined.judge(@npmrc, cwd: @proj).then { [_1.level, _1.reason] }}"
      { "Judged plain (production wiring: board policy)" => -> { judged(plain) },
        "Judged confined (what the defect would need)" => -> { judged(confined) },
        "SecretSurface plain (production wiring)" => -> { surface(plain, content) },
        "SecretSurface confined (hypothetical)" => -> { surface(confined, content) } }.each do |n, f|
        puts "  #{n}: #{(f.call rescue "RAISES #{$!.class}: #{$!.message[0,80]}").inspect}"
      end
    end
  end
end
