# frozen_string_literal: true

# What a spawned child has come to, as the tee carries it. The record exists so
# the `:spawn` body does not have to grow a prompt's first line, so the two
# facts pinned hardest here are that it NAMES the spawn and that whatever the
# model wrote reaches a row as one terminal line.
require "json"

RSpec.describe Lain::Telemetry::ChildProgress do
  describe "the dispatch record" do
    it "names the spawn, the role, the task line and the worker its lease was cut under" do
      record = described_class.new(spawn: "blake3:spawn", label: "dev-2", role: "dev", skill: "gherkin-tests",
                                   task_line: "port the parser", worker: "spawn.dev.1", turns: 0)

      expect(record.to_h).to eq({ spawn: "blake3:spawn", label: "dev-2", role: "dev", skill: "gherkin-tests",
                                  task_line: "port the parser", worker: "spawn.dev.1", turns: 0, head: nil })
    end

    # A child lent its spawner's own checkout runs under a lease nobody minted
    # a worker for, and saying so is the honest row.
    it "carries no worker where none was minted" do
      expect(described_class.new(spawn: "blake3:spawn", turns: 0).worker).to be_nil
    end
  end

  describe "a turn record" do
    it "carries the count and the new head, and leaves the standing fields out" do
      record = described_class.new(spawn: "blake3:spawn", turns: 3, head: "blake3:t3")

      expect(record.to_h).to eq({ spawn: "blake3:spawn", label: nil, role: nil, skill: nil,
                                  task_line: nil, worker: nil, turns: 3, head: "blake3:t3" })
    end
  end

  describe "the task line" do
    # A lone \r redraws a terminal line from column 0, so everything drawn
    # before it is overwritten by whatever follows.
    it "collapses every line break, so a forged task cannot overwrite the row" do
      record = described_class.new(spawn: "blake3:spawn", turns: 0,
                                   task_line: "look around\rfleet:0 inbox:0")

      expect(record.task_line).to eq("look around fleet:0 inbox:0")
    end

    # A lone CR was only the beginning: a task line is model-written and the
    # pane prints it, so `\e[1A\e[2K` walks the cursor onto the row above and
    # erases it. Captured off a real pane before the scrub moved to the owner.
    it "removes a terminal escape whole, so a forged task cannot rewrite the row above" do
      record = described_class.new(spawn: "blake3:spawn", turns: 0,
                                   task_line: "clean\e[1A\e[2KPWNED THE HUD LINE")

      expect(record.task_line).to eq("cleanPWNED THE HUD LINE")
    end

    it "removes a bidi override, a backspace run and a zero-width space" do
      record = described_class.new(spawn: "blake3:spawn", turns: 0,
                                   task_line: "safe\b\bx \u202Edne \u200By")

      expect(record.task_line).to eq("safex dne y")
    end

    # A role is config rather than model text, but it is joined into the same
    # drawn line, so it is held to the same rule.
    it "scrubs the role by the same rule as the task" do
      record = described_class.new(spawn: "blake3:spawn", turns: 0, role: "dev\e[2Kx")

      expect(record.role).to eq("devx")
    end

    it "clamps a long prompt rather than refusing the row" do
      record = described_class.new(spawn: "blake3:spawn", turns: 0, task_line: "x" * 400)

      expect(record.task_line.length).to eq(described_class::MAX_TASK_LINE)
    end
  end

  describe "what it refuses" do
    it "refuses a record naming no spawn, since a row with no branch cannot be placed" do
      expect { described_class.new(spawn: nil, turns: 0) }
        .to raise_error(ArgumentError, /spawn must name/)
    end

    it "refuses a turn count that is not a count" do
      expect { described_class.new(spawn: "blake3:spawn", turns: -1) }
        .to raise_error(ArgumentError, /turns must be how many turns/)
    end
  end

  it "journals under its own discriminator, string-keyed" do
    journal = described_class.new(spawn: "blake3:spawn", turns: 1, head: "blake3:t1").to_journal

    expect(journal).to include({ "type" => "child_progress", "spawn" => "blake3:spawn", "turns" => 1 })
  end

  describe "the journal line" do
    it "prints every field of a dispatch record" do
      record = described_class.new(spawn: "blake3:spawn", label: "dev-2", role: "dev", skill: "gherkin-tests",
                                   task_line: "port the parser", worker: "spawn.dev.1", turns: 2, head: "blake3:t2")

      expect(JSON.generate(record.to_journal)).to eq(
        '{"type":"child_progress","spawn":"blake3:spawn","label":"dev-2","role":"dev","skill":"gherkin-tests",' \
        '"task_line":"port the parser","worker":"spawn.dev.1","turns":2,"head":"blake3:t2"}'
      )
    end

    it "prints null for every optional field" do
      expect(JSON.generate(described_class.new(spawn: "blake3:spawn", turns: 0).to_journal)).to eq(
        '{"type":"child_progress","spawn":"blake3:spawn","label":null,"role":null,"skill":null,' \
        '"task_line":null,"worker":null,"turns":0,"head":null}'
      )
    end

    it "is shareable when built from mutable input" do
      record = described_class.new(spawn: +"blake3:spawn", label: +"dev", turns: 1, head: +"blake3:t1")

      expect(record).to be_deeply_frozen
    end
  end

  it "interns every String field, so equal records share their Strings" do
    build = lambda do
      described_class.new(spawn: +"blake3:s", label: +"dev-2", role: +"dev", skill: +"gherkin", task_line: +"port it",
                          worker: +"spawn.dev.1", turns: 1, head: +"blake3:t1")
    end
    first = build.call
    second = build.call

    %i[spawn label role skill task_line worker head].each do |field|
      expect(first.public_send(field)).to equal(second.public_send(field)), field.to_s
    end
  end

  it "refuses an unknown keyword with an ArgumentError" do
    expect { described_class.new(spawn: "blake3:s", turns: 0, bogus: 1) }.to raise_error(ArgumentError, /bogus/)
  end
end
