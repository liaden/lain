# frozen_string_literal: true

RSpec.describe Lain::Skill::Invocation do
  describe ".parse" do
    it "parses a bare in-line invocation" do
      invocation = described_class.parse("/create-plan add a write_file tool")

      expect(invocation.skill).to eq("create-plan")
      expect(invocation.role).to be_nil
      expect(invocation.context).to be_nil
      expect(invocation.args).to eq("add a write_file tool")
    end

    it "parses a role-bound inheriting invocation" do
      invocation = described_class.parse("@researcher/create-plan foo")

      expect(invocation.skill).to eq("create-plan")
      expect(invocation.role).to eq("researcher")
      expect(invocation.context).to eq(:inherit)
      expect(invocation.args).to eq("foo")
    end

    it "parses a role-bound fresh-root invocation" do
      invocation = described_class.parse("@researcher[/create-plan] foo")

      expect(invocation.skill).to eq("create-plan")
      expect(invocation.role).to eq("researcher")
      expect(invocation.context).to eq(:fresh)
      expect(invocation.args).to eq("foo")
    end

    it "reports ordinary text as not-an-invocation" do
      expect(described_class.parse("please create a plan for me")).to be_nil
    end

    it "allows empty args -- the remainder of the line after the skill token" do
      expect(described_class.parse("/create-plan").args).to eq("")
      expect(described_class.parse("@researcher/create-plan").args).to eq("")
      expect(described_class.parse("@researcher[/create-plan]").args).to eq("")
    end

    describe "malformed invocations raise loudly" do
      it "raises Malformed naming the input for an empty role (\"@/create-plan\")" do
        expect { described_class.parse("@/create-plan") }
          .to raise_error(Lain::Skill::Invocation::Malformed, %r{@/create-plan})
      end

      it "raises Malformed naming the input for an empty skill (\"@researcher/\")" do
        expect { described_class.parse("@researcher/") }
          .to raise_error(Lain::Skill::Invocation::Malformed, %r{@researcher/})
      end

      it "raises Malformed for an unbalanced fresh-root bracket" do
        expect { described_class.parse("@researcher[/create-plan foo") }
          .to raise_error(Lain::Skill::Invocation::Malformed)
      end
    end

    describe "content that legitimately begins with / or @ is not swallowed" do
      it "leaves a path-shaped line as ordinary text, never raising" do
        expect(described_class.parse("/etc/passwd was modified")).to be_nil
      end

      it "leaves a bare @-mention with no slash as ordinary text" do
        expect(described_class.parse("@joel can you look at this")).to be_nil
      end
    end
  end

  describe "value semantics" do
    it "is a frozen, Ractor-shareable value" do
      invocation = described_class.parse("@researcher[/create-plan] foo")

      expect(invocation).to be_frozen
      expect(invocation).to be_ractor_shareable
    end

    it "normalizes role and context defaults when built directly" do
      invocation = described_class.new(skill: "create-plan")

      expect(invocation.role).to be_nil
      expect(invocation.context).to be_nil
      expect(invocation.args).to eq("")
      expect(invocation).to be_ractor_shareable
    end
  end
end
