# frozen_string_literal: true

require "stringio"

RSpec.describe Lain::Declarative do
  # Every example wants the same subject: a class that declares what it is
  # constructed under and then either refuses (`check!`) or takes the settled
  # values (`settle!`). Only the declaration differs, so the shape is written
  # once -- anonymous, because the subject is the mechanism, not a consumer.
  def declaring_class(**options, &declaration)
    Class.new do
      include Lain::Declarative

      declare(**options, &declaration)
    end
  end

  describe ".settle!" do
    it "returns the coerced, defaulted values, not only the ones supplied" do
      settling = declaring_class do
        attribute :name
        attribute :count, default: 7
        attribute :tags, default: -> { [] }
      end

      expect(settling.settle!(name: "x")).to eq(name: "x", count: 7, tags: [])
    end

    it "deeply freezes every settled value, which is what makes them safe to hold" do
      settling = declaring_class do
        attribute :name
        attribute :tags
      end

      settled = settling.settle!(name: +"x", tags: [+"a", { +"k" => [+"deep"] }])

      expect(settled.values).to all(satisfy { |value| Ractor.shareable?(value) })
    end

    it "never freezes an object the caller handed it, so a shared value stays mutable at its owner" do
      settling = declaring_class { attribute :tags }
      mine = [+"a"]

      settling.settle!(tags: mine)

      expect(mine).not_to be_frozen
      expect(mine.first).not_to be_frozen
    end

    it "refuses a live collaborator rather than freezing it, and names the attribute" do
      settling = declaring_class do
        attribute :surface
        validates :surface, presence: true
      end

      expect { settling.settle!(surface: Lain::Sink::Null.new) }
        .to raise_error(Lain::Declarative::UnsettleableAttribute, /surface/)
    end

    it "refuses an IO, the collaborator whose freezing would kill the process's own output" do
      settling = declaring_class { attribute :device }
      device = StringIO.new

      expect { settling.settle!(device:) }.to raise_error(Lain::Declarative::UnsettleableAttribute, /device/)
      expect(device).not_to be_frozen
    end

    it "still refuses an invalid value before it settles anything" do
      settling = declaring_class do
        attribute :name
        validates :name, presence: true
      end

      expect { settling.settle!(name: nil) }.to raise_error(ArgumentError, "name can't be blank")
    end

    it "leaves a value object that settles before freezing both shareable and free of ActiveModel's ivars" do
      value_class = Class.new do
        include Lain::Declarative

        declare do
          attribute :name
          attribute :count, default: 7
        end

        def initialize(**attrs)
          settled = self.class.settle!(**attrs)
          @name = settled[:name]
          @count = settled[:count]
          freeze
        end
      end

      value = value_class.new(name: +"x")

      expect(value).to be_deeply_frozen
      expect(value.instance_variables).to contain_exactly(:@name, :@count)
    end

    it "settles onto a Data value through super, the shape most of the tree wants" do
      value_class = Data.define(:name, :count) do
        include Lain::Declarative

        declare do
          attribute :name
          attribute :count, default: 7
        end

        def initialize(**attrs) = super(**self.class.settle!(**attrs))
      end

      value = value_class.new(name: +"x")

      expect(value.count).to eq(7)
      expect(value).to be_deeply_frozen
    end
  end

  describe ".check!" do
    it "refuses construction, naming the offending attribute" do
      declared = declaring_class do
        attribute :home, :string
        validates :home, inclusion: { in: %w[near far] }
      end

      expect { declared.check!(home: "elsewhere") }
        .to raise_error(ArgumentError, "home is not included in the list")
    end

    it "hands back nothing to hold, so no caller can retain the carrier" do
      declared = declaring_class do
        attribute :home
        validates :home, presence: true
      end

      expect(declared.check!(home: "near")).to be_nil
    end

    it "carries a live collaborator without complaint, because it settles nothing" do
      declared = declaring_class do
        attribute :surface
        validates :surface, presence: true
      end
      surface = Lain::Sink::Null.new

      expect(declared.check!(surface:)).to be_nil
      expect(surface).not_to be_frozen
    end
  end

  describe ".refusal" do
    it "answers the declared class on both the includer and its carrier" do
      stub_const("RefusedHome", Class.new(Lain::Error))
      declared = declaring_class(raising: RefusedHome) do
        attribute :home
        validates :home, presence: true
      end

      expect(declared.refusal).to be(RefusedHome)
      expect(declared.declared_carrier.refusal).to be(RefusedHome)
      expect { declared.check!(home: nil) }.to raise_error(RefusedHome, "home can't be blank")
    end

    it "defaults to ArgumentError when the declaration names no class" do
      declared = declaring_class do
        attribute :home
        validates :home, presence: true
      end

      expect(declared.refusal).to be(ArgumentError)
      expect { declared.check!(home: "") }.to raise_error(ArgumentError)
    end
  end

  # Both shapes below used to fail SILENTLY under the mechanism this replaces.
  # The plain class raised ArgumentError -- the very class a refusal raises, so
  # "you forgot to declare" was indistinguishable from "your value was refused"
  # -- and the Data value recursed check! -> new -> check! into SystemStackError.
  describe "a missing declaration" do
    it "names the omission rather than raising the class a refusal raises" do
      stub_const("UndeclaredClass", Class.new { include Lain::Declarative })

      expect { UndeclaredClass.declared_carrier }
        .to raise_error(Lain::Declarative::NoDeclaration, /UndeclaredClass/)
      expect { UndeclaredClass.check!(home: "near") }
        .to raise_error(Lain::Declarative::NoDeclaration, /UndeclaredClass/)
      expect(Lain::Declarative::NoDeclaration.ancestors).not_to include(ArgumentError)
    end

    it "refuses an undeclared Data value instead of recursing through its own constructor" do
      stub_const("UndeclaredValue", Data.define(:home) do
        include Lain::Declarative

        def initialize(home:)
          self.class.check!(home:)
          super
        end
      end)

      expect { UndeclaredValue.new(home: "near") }
        .to raise_error(Lain::Declarative::NoDeclaration, /UndeclaredValue/)
    end

    it "refuses an undeclared settle! the same way, from the same one place" do
      stub_const("UndeclaredSettler", Class.new { include Lain::Declarative })

      expect { UndeclaredSettler.settle!(home: "near") }
        .to raise_error(Lain::Declarative::NoDeclaration, /UndeclaredSettler/)
    end
  end

  # ORCHESTRATOR POLICY, applied here and in the sibling card: a malformed VALUE
  # is user-facing and belongs inside Lain::Error, so `exe/lain` can turn it into
  # a clean one-line Thor message; a malformed DECLARATION is a programmer error
  # in lib code and must stay OUTSIDE it, so the backtrace that locates the file
  # and line survives. Every error this concern raises is the second kind -- the
  # first kind is the declaration's own `raising:` class, which is untouched.
  describe "the errors it raises itself" do
    it "keeps every wiring mistake out of Lain::Error's reach, so exe/lain cannot strip its backtrace" do
      wiring_errors = [Lain::Declarative::NoDeclaration,
                       Lain::Declarative::UnsettleableAttribute,
                       Lain::Declarative::UndeclaredAttribute]

      expect(wiring_errors).to all(be < Lain::Declarative::DeclarationError)
      expect(wiring_errors).to all(be < StandardError)
      expect(wiring_errors.select { |wiring_error| wiring_error <= Lain::Error }).to be_empty
    end

    it "still delivers a refused VALUE as the declaration's own class, which may be a Lain::Error" do
      stub_const("RefusedValue", Class.new(Lain::Error))
      declared = declaring_class(raising: RefusedValue) do
        attribute :home
        validates :home, presence: true
      end

      expect { declared.check!(home: nil) }.to raise_error(RefusedValue)
    end
  end

  # ActiveModel is an implementation detail of HOW a declaration validates, not
  # part of a constructor's contract -- so its own exception must not be the one
  # a caller sees, least of all one whose message names an anonymous carrier by
  # heap address.
  it "names an undeclared constructor argument itself, rather than leaking ActiveModel's error" do
    declared = declaring_class do
      attribute :home
      validates :home, presence: true
    end

    expect { declared.check!(home: "near", bogus: 1) }
      .to raise_error(Lain::Declarative::UndeclaredAttribute, /:bogus.*declares home/m)
    expect { declared.settle!(home: "near", bogus: 1) }
      .to raise_error(Lain::Declarative::UndeclaredAttribute, /:bogus/)
  end

  # This is what lets a declaration cite a constant defined further down the load
  # manifest than the file declaring it: the lambda is called at validation time,
  # so the class body evaluates during `require` without resolving anything.
  it "defers a lambda's constants to validation time, not to the class body" do
    expect(defined?(DeferredHomes)).to be_nil

    declared = declaring_class do
      attribute :home, :string
      validates :home, inclusion: { in: ->(_) { DeferredHomes } }
    end

    stub_const("DeferredHomes", %w[near far].freeze)

    expect(declared.check!(home: "near")).to be_nil
    expect { declared.check!(home: "elsewhere") }.to raise_error(ArgumentError, /\Ahome is not included/)
  end

  it "validates a throwaway carrier, never the declaring class itself" do
    declared = declaring_class do
      attribute :home
      validates :home, presence: true
    end

    expect(declared.declared_carrier).to be < Lain::Declarative::Carrier
    expect(declared.new).not_to respond_to(:valid?)
  end
end
