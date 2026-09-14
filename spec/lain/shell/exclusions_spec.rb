# frozen_string_literal: true

RSpec.describe Lain::Shell::Exclusions do
  # The whole interface {Shell::Verdict} uses. Answering it is what makes this a
  # drop-in for the permissive default that ships today.
  describe "#permits?" do
    it "permits every program when nothing is excluded" do
      exclusions = described_class.empty

      expect(%w[cat curl rm sh].map { |program| exclusions.permits?(program) }).to all(be(true))
    end

    it "answers the same for an absent table as for an empty one" do
      expect(described_class.from(nil)).to eq(described_class.empty)
    end

    it "refuses a program the table names and permits every other" do
      exclusions = described_class.from({ "exclude" => ["curl"] })

      expect([exclusions.permits?("curl"), exclusions.permits?("cat")]).to eq([false, true])
    end

    # The denylist direction of the basename asymmetry: qualifying a name is how
    # an exclusion would be evaded, so the last segment is what is matched.
    it "refuses a qualified spelling of an excluded program" do
      exclusions = described_class.from({ "exclude" => ["curl"] })
      spellings = ["/usr/bin/curl", "./curl", "../bin/curl", "bin/curl"]

      expect(spellings.map { |spelling| exclusions.permits?(spelling) }).to all(be(false))
    end

    it "matches a glob against the program name" do
      exclusions = described_class.from({ "exclude" => ["*sh"] })

      expect([exclusions.permits?("zsh"), exclusions.permits?("cat")]).to eq([false, true])
    end

    # A table that only ever restricts has no unbounded pattern to refuse: this
    # is the strictest posture the file can express, and it fails closed.
    it "honours a wildcard rather than refusing it" do
      exclusions = described_class.from({ "exclude" => ["*"] })

      expect(%w[cat ls .hidden].map { |program| exclusions.permits?(program) }).to all(be(false))
    end

    # A NUL byte parses clean into an ordinary word, so it reaches this object
    # from any tool call, and `File.fnmatch?` raises on one.
    it "refuses a program name no matcher can read rather than raising" do
      exclusions = described_class.from({ "exclude" => ["curl"] })

      expect(exclusions.permits?("ca\0t")).to be(false)
    end

    # The other unreadable shape, and the one that catches a guard placed a line
    # too late: splitting the name is itself what raises here, so the
    # readability question has to be asked before the string is touched.
    it "refuses a program name in an encoding no matcher can read" do
      exclusions = described_class.from({ "exclude" => ["curl"] })

      expect(exclusions.permits?("curl".encode("UTF-16LE"))).to be(false)
    end

    # The one direction this object must never fail in. Unreachable while the
    # parse yields only Strings, and still the wrong answer to give.
    it "refuses a program name that is not a string at all" do
      exclusions = described_class.from({ "exclude" => ["curl"] })
      answers = [nil, 42, [], :curl].map { |value| exclusions.permits?(value) }

      expect(answers).to all(be(false))
    end

    # An empty table restricts nothing, so it must answer exactly as the
    # permissive default does -- including for every name the guards above
    # refuse, or a project with no config would start denying what it permits.
    it "still permits an unreadable name when nothing is excluded" do
      unreadable = ["ca\0t", "curl".encode("UTF-16LE"), nil, 42]

      expect(unreadable.map { |value| described_class.empty.permits?(value) }).to all(be(true))
    end
  end

  describe ".from" do
    it "refuses a scalar where the table belongs, naming the file" do
      expect { described_class.from("curl", path: "/p/.lain/config.toml") }
        .to raise_error(Lain::Config::Refusal, %r{/p/\.lain/config\.toml})
    end

    it "refuses a key it does not read rather than ignoring it" do
      expect { described_class.from({ "excluded" => ["curl"] }) }
        .to raise_error(Lain::Config::Refusal, /excluded/)
    end

    # One refusal class across every config table; the correction the message
    # offers back is what makes a single class as useful as seven.
    it "refuses an unknown key as a config refusal, naming the key and the keys that exist" do
      expect { described_class.from({ "excluded" => ["curl"] }) }
        .to raise_error(Lain::Config::Refusal, /"excluded".*known keys: exclude/)
    end

    it "refuses a single value where the shape is a list" do
      expect { described_class.from({ "exclude" => "curl" }) }
        .to raise_error(Lain::Config::Refusal, /exclude is a list of program names/)
    end

    it "refuses a pattern that is not a string" do
      expect { described_class.from({ "exclude" => [42] }) }
        .to raise_error(Lain::Config::Refusal, /must be a string/)
    end

    it "refuses a blank pattern" do
      expect { described_class.from({ "exclude" => ["  "] }) }
        .to raise_error(Lain::Config::Refusal, /must not be blank/)
    end

    it "refuses a pattern carrying a NUL byte" do
      expect { described_class.from({ "exclude" => ["cu\0rl"] }) }
        .to raise_error(Lain::Config::Refusal, /matchable text/)
    end

    # A pattern with a path separator could never match what this object is
    # asked about, which is the same failure as an entry nobody wrote.
    it "refuses a path-shaped pattern" do
      expect { described_class.from({ "exclude" => ["/usr/bin/curl"] }) }
        .to raise_error(Lain::Config::Refusal, /program name/)
    end

    # A bare argv[0] a shell hands to exec never contains whitespace, so a
    # pattern that does can never match one -- the same failure as an entry
    # nobody wrote.
    it "refuses an entry that can never match an unquoted command" do
      expect { described_class.from({ "exclude" => ["cu rl"] }) }
        .to raise_error(Lain::Config::Refusal, /can never match an unquoted command/)
    end

    # A malformed entry and an unknown key are two different mistakes; a
    # config broken both ways should not cost two runs to discover.
    it "reports a malformed entry and an unknown key in the same refusal" do
      expect { described_class.from({ "exclude" => ["cu rl"], "excluded" => ["curl"] }) }
        .to raise_error(Lain::Config::Refusal) { |error|
          expect(error.message).to match(/"excluded".*known keys: exclude/)
          expect(error.message).to include("can never match an unquoted command")
        }
    end
  end

  describe "the value" do
    it "is shareable across Ractors" do
      expect(Ractor.shareable?(described_class.from({ "exclude" => ["curl"] }))).to be(true)
    end

    # The patterns arrive from a TOML parse, so the caller keeps a mutable Array
    # of mutable Strings and this value has to outlive their edits.
    it "keeps frozen copies of the patterns it was handed" do
      patterns = [+"curl"]
      exclusions = described_class.from({ "exclude" => patterns })
      patterns.first << "x"
      patterns.clear

      expect(exclusions.permits?("curl")).to be(false)
    end

    it "validates a table built by hand as closely as one read from a file" do
      expect { described_class.new(patterns: ["/usr/bin/curl"]) }
        .to raise_error(Lain::Config::Refusal, /must be a program name, not a path/)
    end
  end
end
