# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Declarative::Carrier do
  # The entry point a named consumer uses: a subclass declaring
  # `attribute`/`validates`, checked or settled from a constructor. Anonymous
  # here because the subject is the mechanism, not any one consumer's rules --
  # which also exercises the model_name fallback every DSL-built carrier needs.
  def carrier(&body) = Class.new(described_class, &body)

  describe "refusal" do
    it "raises ArgumentError naming the attribute and the validator's message" do
      capacity = carrier do
        attribute :capacity
        validates :capacity, numericality: { only_integer: true, greater_than: 0,
                                             message: "must be a positive Integer, got %<value>s" }
      end

      expect { capacity.check!(capacity: 0) }
        .to raise_error(ArgumentError, "capacity must be a positive Integer, got 0")
    end

    it "joins every error, so one raise reports the whole refusal" do
      partition = carrier do
        attribute :epic_slug
        attribute :stage
        validates :epic_slug, presence: { message: "must name the epic this sign-off belongs to, got nil" }
        validates :stage, presence: { message: "must name the stage it was parked at, got nil" }
      end

      expect { partition.check!(epic_slug: nil, stage: nil) }
        .to raise_error(ArgumentError,
                        "epic_slug must name the epic this sign-off belongs to, got nil, " \
                        "stage must name the stage it was parked at, got nil")
    end

    it "generates a default message for an anonymous carrier, which has no constant name" do
      item = carrier do
        attribute :artifact_digest
        validates :artifact_digest, presence: true
      end

      expect(item.name).to be_nil
      expect { item.check!(artifact_digest: nil) }.to raise_error(ArgumentError, "artifact_digest can't be blank")
    end

    it "passes silently when every rule holds, and returns no carrier to hold on to" do
      item = carrier do
        attribute :artifact_digest
        validates :artifact_digest, presence: true
      end

      expect(item.check!(artifact_digest: "abc")).to be_nil
    end

    it "is its own carrier, which is what makes it the same mechanism a declaration uses" do
      item = carrier do
        attribute :artifact_digest
        validates :artifact_digest, presence: true
      end

      expect(item.declared_carrier).to be(item)
    end
  end

  describe "#settled" do
    it "keeps the defaulting and coercion work `check!` throws away" do
      settling = carrier do
        attribute :name
        attribute :count, default: 7
      end

      expect(settling.new(name: "x").settled).to eq(name: "x", count: 7)
    end

    it "gives each construction its own default, so two carriers never share one collection" do
      settling = carrier { attribute :tags, default: -> { [] } }

      first = settling.new.settled[:tags]
      second = settling.new.settled[:tags]

      expect(first).to eq(second)
      expect(first).not_to be(second)
    end

    it "rebuilds a collection frozen rather than freezing the one it was given" do
      settling = carrier { attribute :tags }
      mine = [+"a", { +"k" => +"v" }]

      settled = settling.new(tags: mine).settled[:tags]

      expect(settled).to eq(mine)
      expect(settled).to be_deeply_frozen
      expect(mine).not_to be_frozen
      expect(mine.first).not_to be_frozen
    end

    it "hands back a value that is already shareable untouched, having nothing to freeze" do
      already = %w[near far].freeze
      settling = carrier { attribute :homes }

      expect(settling.new(homes: already).settled[:homes]).to be(already)
    end

    it "freezes the hash it returns, so the settled set cannot be edited after the fact" do
      settling = carrier { attribute :name }

      expect(settling.new(name: "x").settled).to be_frozen
    end

    it "refuses a live collaborator, naming the attribute and the offender" do
      settling = carrier { attribute :surface }

      expect { settling.new(surface: Lain::Sink::Null.new).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute,
                        /\Asurface cannot be settled: it reaches Lain::Sink::Null/)
    end

    it "refuses a Proc, which is a collaborator wearing a value's clothes" do
      settling = carrier { attribute :resolver }

      expect { settling.new(resolver: -> { 1 }).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /\Aresolver cannot be settled: it reaches Proc/)
    end
  end

  # The refusal is only worth raising if it says which object to go and fix. A
  # message naming the CONTAINER tells you an attribute holds an Array and that
  # an Array is allowed -- the two facts that together mean nothing.
  describe "#settled names the offender" do
    it "reaches past the containers a collaborator is nested inside" do
      settling = carrier { attribute :surfaces }

      expect { settling.new(surfaces: [[[Lain::Sink::Null.new]]]).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute,
                        /\Asurfaces cannot be settled: it reaches Lain::Sink::Null/)
    end

    it "says what is wrong with a String rather than that a String is allowed" do
      stateful = +"x"
      stateful.instance_variable_set(:@live, +"mutable")
      settling = carrier { attribute :name }

      expect { settling.new(name: stateful).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /\Aname cannot be settled.*instance variables/m)
    end
  end

  # SystemStackError is one of the two failures NoDeclaration's docstring exists
  # to prevent. A recursive copy is exactly where it comes back.
  describe "#settled over a cycle" do
    it "refuses an Array that contains itself" do
      cyclic = []
      cyclic << cyclic
      settling = carrier { attribute :tags }

      expect { settling.new(tags: cyclic).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /\Atags cannot be settled.*contains itself/m)
    end

    it "refuses a Hash that contains itself" do
      cyclic = {}
      cyclic[:x] = cyclic
      settling = carrier { attribute :index }

      expect { settling.new(index: cyclic).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /\Aindex cannot be settled.*contains itself/m)
    end

    it "refuses two containers that reach each other" do
      one = []
      two = [one]
      one << two
      settling = carrier { attribute :tags }

      expect { settling.new(tags: one).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /contains itself/)
    end

    # The open set is the current PATH, not everything already visited: the same
    # container reached twice side by side is shared, not cyclic, and copies.
    it "copies a container reached twice side by side" do
      shared = [+"x"]
      settling = carrier { attribute :pairs }

      settled = settling.new(pairs: [shared, shared]).settled[:pairs]

      expect(settled).to eq([["x"], ["x"]])
      expect(settled).to be_deeply_frozen
    end
  end

  # Rebuilding a container as a plain frozen literal is only honest for a plain
  # literal. Everything below came back from a rebuild quietly changed, and the
  # shareability assert cannot see any of it.
  describe "#settled refuses a container whose behaviour a copy would lose" do
    it "refuses a Hash carrying a default" do
      settling = carrier { attribute :counts }

      expect { settling.new(counts: Hash.new(0)).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /\Acounts cannot be settled.*lookup behaviour/m)
    end

    it "refuses a Hash carrying a default_proc" do
      settling = carrier { attribute :counts }

      expect { settling.new(counts: Hash.new { |hash, key| hash[key] = key }).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /lookup behaviour/)
    end

    it "refuses a compare_by_identity Hash, whose distinct-but-equal keys a rebuild collides" do
      identity = {}.compare_by_identity
      identity[+"k"] = 1
      identity[+"k"] = 2
      settling = carrier { attribute :index }

      expect(identity.size).to eq(2)
      expect { settling.new(index: identity).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /lookup behaviour/)
    end

    it "refuses a Hash subclass rather than collapsing it to a plain Hash" do
      settling = carrier { attribute :index }

      expect { settling.new(index: Class.new(Hash).new).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /\Aindex cannot be settled/)
    end

    it "refuses an Array subclass rather than collapsing it to a plain Array" do
      settling = carrier { attribute :tags }

      expect { settling.new(tags: Class.new(Array).new).settled }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /\Atags cannot be settled/)
    end

    it "still settles a plain Hash and a plain Array, which lose nothing" do
      settling = carrier { attribute :index }

      expect(settling.new(index: { +"k" => [+"v"] }).settled[:index]).to eq({ "k" => ["v"] })
    end
  end
end
