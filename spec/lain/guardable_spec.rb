# frozen_string_literal: true

RSpec.describe Lain::Guardable do
  # Every example wants the same subject: a Data value whose constructor checks
  # its declared guard BEFORE `super`, because `super` is the moment the value
  # freezes and a frozen value can no longer be validated. Only the declaration
  # differs, so the surrounding shape is written once.
  def guarded_value_class(**options, &declaration)
    Data.define(:home) do
      include Lain::Guardable

      guard(**options, &declaration)

      def initialize(home:)
        self.class.check!(home:)
        super
      end
    end
  end

  it "refuses construction, naming the offending attribute" do
    value_class = guarded_value_class do
      attribute :home, :string
      validates :home, inclusion: { in: %w[near far] }
    end

    expect { value_class.new(home: "elsewhere") }
      .to raise_error(ArgumentError, "home is not included in the list")
  end

  it "reports every broken rule, not only the first" do
    value_class = Data.define(:home, :depth) do
      include Lain::Guardable

      guard do
        attribute :home
        attribute :depth
        validates :home, presence: { message: "must name where the work lands, got nil" }
        validates :depth, numericality: { greater_than: 0, message: "must be positive, got %<value>s" }
      end

      def initialize(home:, depth:)
        self.class.check!(home:, depth:)
        super
      end
    end

    expect { value_class.new(home: nil, depth: 0) }
      .to raise_error(ArgumentError,
                      "home must name where the work lands, got nil, depth must be positive, got 0")
  end

  it "leaves the guarded value deeply frozen and free of ActiveModel's ivars" do
    value_class = guarded_value_class do
      attribute :home, :string
      validates :home, presence: true
    end

    value = value_class.new(home: "near")

    expect(value).to be_deeply_frozen
    expect(value.instance_variables).to be_empty
  end

  it "raises the exception class the declaration names" do
    stub_const("RefusedHome", Class.new(Lain::Error))
    value_class = guarded_value_class(raising: RefusedHome) do
      attribute :home, :string
      validates :home, inclusion: { in: %w[near far] }
    end

    expect(value_class.refusal).to be(RefusedHome)
    expect { value_class.new(home: "elsewhere") }.to raise_error(RefusedHome, "home is not included in the list")
  end

  it "defaults to ArgumentError, the exception a Guard has always raised" do
    value_class = guarded_value_class do
      attribute :home, :string
      validates :home, presence: true
    end

    expect(value_class.refusal).to be(ArgumentError)
    expect { value_class.new(home: "") }.to raise_error(ArgumentError)
  end

  # This is what lets a guard cite a constant defined further down the load
  # manifest than the file declaring it: the lambda is called at validation time,
  # so the class body evaluates during `require` without resolving anything.
  it "defers a lambda's constants to validation time, not to the class body" do
    expect(defined?(DeferredHomes)).to be_nil

    value_class = guarded_value_class do
      attribute :home, :string
      validates :home, inclusion: { in: ->(_) { DeferredHomes } }
    end

    stub_const("DeferredHomes", %w[near far].freeze)

    expect(value_class.new(home: "near").home).to eq("near")
    expect { value_class.new(home: "elsewhere") }.to raise_error(ArgumentError, /\Ahome is not included/)
  end

  # Both shapes below used to fail SILENTLY. The plain class raised ArgumentError
  # -- the very class a refusal raises, so "you forgot to declare a guard" was
  # indistinguishable from "your value was refused" -- and the Data value, in the
  # exact shape this concern's docstring recommends, recursed check! -> new ->
  # check! into SystemStackError.
  it "names the omission when an includer never declared a guard" do
    stub_const("UnguardedClass", Class.new { include Lain::Guardable })

    expect { UnguardedClass.check!(home: "near") }
      .to raise_error(Lain::Guardable::NoGuardDeclared, /UnguardedClass/)
    expect(Lain::Guardable::NoGuardDeclared.ancestors).not_to include(ArgumentError)
  end

  it "refuses an undeclared Data value instead of recursing into the constructor that called it" do
    stub_const("UnguardedValue", Data.define(:home) do
      include Lain::Guardable

      def initialize(home:)
        self.class.check!(home:)
        super
      end
    end)

    expect { UnguardedValue.new(home: "near") }
      .to raise_error(Lain::Guardable::NoGuardDeclared, /UnguardedValue/)
  end

  it "validates a throwaway carrier, never the value class itself" do
    value_class = guarded_value_class do
      attribute :home, :string
      validates :home, presence: true
    end

    expect(value_class.guard_carrier).to be < Lain::Guard
    expect(value_class.new(home: "near")).not_to respond_to(:valid?)
  end
end
