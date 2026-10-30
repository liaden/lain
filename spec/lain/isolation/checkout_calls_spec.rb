# frozen_string_literal: true

require "prism"
require "pathname"

# Ratchet: a checkout built with `new` skips Clone::Guard, so git would run in a
# clone lain cut through whatever its git dir now names; `Checkout.of` is the way in.
# It reads call syntax only, so a reflective spelling (send, public_send, method(:new),
# an alias, allocate) passes unseen; closing those means making `new` private.
module CheckoutCalls
  ROOT = Pathname.new(File.expand_path("../../..", __dir__))
  SOURCES = Dir[ROOT.join("lib/lain/**/*.rb")].map { Pathname.new(_1) }.freeze
  OWN_FILE = "lib/lain/isolation/checkout.rb"

  # path => [call count, reason]; a count that moves either way fails
  ALLOWED = {
    "lib/lain/isolation/clone/guard.rb" => [1, "the guard is what Checkout.of asks, and it answers a plain " \
                                               "checkout for a dir outside any clone lain cut"]
  }.freeze

  Call = Data.define(:path, :line)

  class Scanner < Prism::Visitor
    attr_reader :calls

    def initialize(path)
      @path = path
      @isolation = 0
      @calls = []
      super()
    end

    def visit_module_node(node) = scoped(node) { super }

    def visit_class_node(node) = scoped(node) { super }

    def visit_call_node(node)
      @calls << Call.new(@path, node.location.start_line) if node.name == :new && checkout?(node.receiver)
      super
    end

    private

    def scoped(node)
      inside = segments(node.constant_path).include?(:Isolation)
      @isolation += 1 if inside
      yield
    ensure
      @isolation -= 1 if inside
    end

    def segments(path)
      case path
      when Prism::ConstantPathNode then [*segments(path.parent), path.name]
      when Prism::ConstantReadNode then [path.name]
      else []
      end
    end

    # LocalBranch::Checkout and Factory::LandingCheckout are other classes: the first lives outside
    # module Isolation, and neither is named by an Isolation path.
    def checkout?(receiver)
      case receiver
      when Prism::ConstantReadNode then receiver.name == :Checkout && @isolation.positive?
      when Prism::ConstantPathNode then receiver.name == :Checkout && isolation?(receiver.parent)
      else false
      end
    end

    def isolation?(node)
      (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && node.name == :Isolation
    end
  end

  def self.scan(path, source)
    scanner = Scanner.new(path)
    Prism.parse(source).value.accept(scanner)
    scanner.calls
  end

  def self.calls
    SOURCES.map { _1.relative_path_from(ROOT).to_s }.reject { _1 == OWN_FILE }
           .flat_map { |relative| scan(relative, ROOT.join(relative).read) }
  end
end

RSpec.describe "Isolation::Checkout.new calls in lib" do
  def lines(source) = CheckoutCalls.scan("probe.rb", source).map(&:line)

  it "counts every spelling of the isolation checkout's constructor" do
    source = <<~RUBY
      Lain::Isolation::Checkout.new(dir)
      Isolation::Checkout.new(dir)
      module Lain
        module Isolation
          Checkout.new(dir)
        end
      end
      module Lain::Isolation::Worktree
        Checkout.new(dir)
      end
      class Isolation::Probe
        Checkout.new(dir)
      end
    RUBY

    expect(lines(source)).to eq([1, 2, 5, 9, 12])
  end

  it "does not count the other classes named Checkout, nor Checkout.of" do
    source = <<~RUBY
      module Lain
        module Review
          class LocalBranch
            Checkout.new(head_ref: ref)
          end
        end
        module Isolation
          Factory::LandingCheckout.new(repo_root:)
          LocalBranch::Checkout.new(head_ref: ref)
          Checkout.of(dir)
        end
      end
    RUBY

    expect(lines(source)).to eq([])
  end

  it "finds Isolation::Checkout.new in lib only where the allowlist says" do
    expect(CheckoutCalls.calls.map(&:path).tally).to eq(CheckoutCalls::ALLOWED.transform_values(&:first))
  end

  it "gives every allowlist entry a reason" do
    expect(CheckoutCalls::ALLOWED.values.map(&:last)).to all(be_a(String).and(satisfy { !_1.strip.empty? }))
  end
end
