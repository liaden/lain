# frozen_string_literal: true

require "async"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock).
module JudgeSpecSupport
  # A {Skill::RoleSpawn} stand-in that answers through the injected block and
  # records each spawn, marking the ones made through its never-parking copy.
  class ScriptedRoleSpawn
    attr_reader :calls

    def initialize(calls = [], unparked: false, &answer)
      @answer = answer
      @calls = calls
      @unparked = unparked
    end

    def never_parking = self.class.new(@calls, unparked: true, &@answer)

    def call(role, context_mode, prompt)
      @calls << { role:, context_mode:, prompt:, unparked: @unparked }
      @answer.call(prompt)
    end
  end
end

RSpec.describe Lain::Approval::Judge do
  def answering(text) = JudgeSpecSupport::ScriptedRoleSpawn.new { Lain::Tool::Result.ok(text) }

  def verdict(spawn, timeout: described_class::TIMEOUT)
    described_class.new(role_spawn: spawn, timeout:).call(requester: "main", tool: "bash", input: { "command" => "ls" })
  end

  it "is bounded at 30 seconds by default" do
    expect(described_class::TIMEOUT).to eq(30)
  end

  it "reads a lone verdict token, a trailing period tolerated" do
    expect(%w[APPROVE deny. Defer].map { verdict(answering(_1)) }).to eq(%i[approve deny defer])
  end

  it "defers on prose, a hedge or an empty answer" do
    ["approve the read but deny the write", "APPROVE. It is safe.", ""].each do |text|
      expect(verdict(answering(text))).to eq(:defer)
    end
  end

  it "asks the auto_approver role on a fresh root through the never-parking spawn" do
    spawn = answering("defer")

    described_class.new(role_spawn: spawn).call(requester: "researcher", tool: "edit_file",
                                                input: { "path" => "/etc/hosts" })

    expect(spawn.calls.sole).to include(role: :auto_approver, context_mode: :fresh, unparked: true)
    expect(spawn.calls.sole[:prompt]).to include("researcher").and include("edit_file").and include("/etc/hosts")
  end

  it "answers fault for an error result, whatever it reads" do
    spawn = JudgeSpecSupport::ScriptedRoleSpawn.new { Lain::Tool::Result.error("approve") }

    expect(verdict(spawn)).to eq(:fault)
  end

  it "answers fault when the spawn raises" do
    expect(verdict(JudgeSpecSupport::ScriptedRoleSpawn.new { raise IOError, "provider down" })).to eq(:fault)
  end

  it "answers fault when the judge outlives its bound, inside a reactor" do
    hung = JudgeSpecSupport::ScriptedRoleSpawn.new { sleep 5 }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    answer = Sync { verdict(hung, timeout: 0.05) }

    expect(answer).to eq(:fault)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
  end

  it "is bounded even when called outside a reactor" do
    hung = JudgeSpecSupport::ScriptedRoleSpawn.new { sleep 5 }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect(verdict(hung, timeout: 0.05)).to eq(:fault)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
  end
end
