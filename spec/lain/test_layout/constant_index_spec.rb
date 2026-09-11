# frozen_string_literal: true

require "tmpdir"

# Where a constant is DEFINED, read with Prism: the direction the guard needs,
# constant to file, so no inflection table ever has to spell `CLI`.
RSpec.describe Lain::TestLayout::ConstantIndex do
  let(:layout_mini) { File.expand_path("../../fixtures/projects/layout_mini", __dir__) }

  def index_over(root) = described_class.new(root:, source_roots: ["app"], extension: ".rb")

  def write(root, relative, body)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  describe "#constants_in" do
    it "names every constant a file opens, qualified by its lexical nesting" do
      expect(index_over(layout_mini).constants_in("app/cli/backend.rb").names).to contain_exactly("CLI", "CLI::Backend")
    end

    it "names more than one constant from a file named for neither" do
      expect(index_over(layout_mini).constants_in("app/models/records.rb").names)
        .to contain_exactly("OrderTransition", "OrderRecord")
    end

    it "reads compact paths, root-qualified paths and constant assignments, and ignores method bodies" do
      Dir.mktmpdir do |root|
        write(root, "app/shapes.rb", <<~RUBY)
          module Shop
            class Cart::Line; end
            class ::Top; end
            Point = Data.define(:x) do
              Origin = 0
            end
            Shop::Limit = 3
            def self.build = Class.new
          end
        RUBY

        # `Cart` names no enclosing namespace, so `Cart::Line` keeps both
        # readings; `Shop::Limit` anchors on the `Shop` it sits in.
        expect(index_over(root).constants_in("app/shapes.rb").names)
          .to contain_exactly("Shop", "Shop::Cart::Line", "Cart::Line", "Top", "Shop::Point", "Shop::Origin",
                              "Shop::Limit")
      end
    end

    # Ruby resolves the head against the constants that exist when the line
    # runs, which a static read cannot know, so both readings are indexed.
    it "indexes a compact path whose head names no enclosing namespace under both readings" do
      Dir.mktmpdir do |root|
        write(root, "app/nested_head.rb", "module Wrap\n  class Order::Line; end\nend\n")

        expect(index_over(root).constants_in("app/nested_head.rb").names)
          .to contain_exactly("Wrap", "Wrap::Order::Line", "Order::Line")
      end
    end

    it "answers for a missing file rather than raising" do
      expect(index_over(layout_mini).constants_in("app/models/order_extra.rb")).not_to be_exists
    end

    it "reports a file Prism could not parse, with the parser's reason" do
      Dir.mktmpdir do |root|
        write(root, "app/models/broken.rb", "class Broken\n  def oops(\n")

        constants = index_over(root).constants_in("app/models/broken.rb")

        expect([constants.exists?, constants.parsed?, constants.error]).to match([true, false, /expected/])
      end
    end

    it "reuses its reading of an unchanged file and rereads a changed one" do
      Dir.mktmpdir do |root|
        write(root, "app/order.rb", "class Order; end\n")
        index = index_over(root)
        first = index.constants_in("app/order.rb")
        again = index.constants_in("app/order.rb")
        write(root, "app/order.rb", "class Order; end\nclass Refund; end\n")

        expect([again.equal?(first), index.constants_in("app/order.rb").names]).to eq([true, %w[Order Refund]])
      end
    end

    it "is deeply frozen" do
      expect(index_over(layout_mini).constants_in("app/cli/backend.rb")).to be_deeply_frozen
    end
  end

  describe "#definitions_of" do
    it "finds a constant defined in a file named for something else" do
      expect(index_over(layout_mini).definitions_of("OrderTransition").to_a).to eq(["app/models/records.rb"])
    end

    it "finds an acronym namespace's constant by its full name" do
      expect(index_over(layout_mini).definitions_of("CLI::Backend").first).to eq("app/cli/backend.rb")
    end

    it "offers the file named for the constant first when the constant is reopened elsewhere" do
      Dir.mktmpdir do |root|
        write(root, "app/models/a_extension.rb", "class Order; end\n")
        write(root, "app/models/order.rb", "class Order; end\n")

        expect(index_over(root).definitions_of("Order").to_a).to eq(%w[app/models/order.rb app/models/a_extension.rb])
      end
    end

    it "skips an unparseable file and anything outside the source roots or of another extension" do
      Dir.mktmpdir do |root|
        write(root, "app/broken.rb", "class Order\n  def oops(\n")
        write(root, "lib/order.rb", "class Order; end\n")
        write(root, "app/order.erb", "class Order; end\n")
        write(root, "app/real.rb", "class Order; end\n")

        expect(index_over(root).definitions_of("Order").to_a).to eq(["app/real.rb"])
      end
    end

    it "is empty for a constant defined nowhere" do
      expect(index_over(layout_mini).definitions_of("Refund").to_a).to be_empty
    end

    # The cost of a miss is the files parsed. A common last segment such as
    # `Error` appears in most of a tree, so only a file that spells every
    # segment of the name AND something shaped like a definition of the last
    # one is worth parsing.
    it "parses only files that spell every namespace segment and a definition of the last" do
      Dir.mktmpdir do |root|
        write(root, "app/errors.rb", "class Error < StandardError; end\n")
        write(root, "app/raiser.rb", "module Lain\n  def self.fail! = raise(Ghost::Error)\nend\n")
        write(root, "app/ghost.rb", "module Lain\n  module Ghost\n    class Error < StandardError; end\n  end\nend\n")
        parsed = []
        counting = lambda do |path|
          parsed << File.basename(path)
          Prism.parse_file(path)
        end
        index = described_class.new(root:, source_roots: ["app"], extension: ".rb", parse: counting)

        expect([index.definitions_of("Lain::Ghost::Error").to_a, parsed]).to eq([["app/ghost.rb"], ["ghost.rb"]])
      end
    end

    # Source is read as bytes, so a name outside ASCII must be compared as
    # bytes too, and its edge cannot rely on `\b`, which counts a UTF-8 byte
    # as a non-word character.
    it "finds a constant whose name is not ASCII, head or tail, among files that are not ASCII either" do
      Dir.mktmpdir do |root|
        write(root, "app/notes.rb", "# a note — with an em dash\nclass Other; end\n")
        write(root, "app/cafe.rb", "class Café; end\n")
        write(root, "app/unit.rb", "class Ünit; end\n")
        index = index_over(root)

        expect([index.definitions_of("Café").to_a, index.definitions_of("Ünit").to_a,
                index.definitions_of("Lain::Café").to_a]).to eq([["app/cafe.rb"], ["app/unit.rb"], []])
      end
    end

    it "indexes and finds a constant set with ||= or by multiple assignment" do
      Dir.mktmpdir do |root|
        write(root, "app/limits.rb", "Limit ||= 3\nLow, High = 1, 9\n")
        index = index_over(root)

        expect([index.constants_in("app/limits.rb").names,
                %w[Limit Low High].map { |name| index.definitions_of(name).to_a }])
          .to eq([%w[Limit Low High], [["app/limits.rb"]] * 3])
      end
    end

    it "still finds a constant assigned rather than opened" do
      Dir.mktmpdir do |root|
        write(root, "app/shapes.rb", "module Shop\n  Point = Data.define(:x)\nend\n")

        expect(index_over(root).definitions_of("Shop::Point").to_a).to eq(["app/shapes.rb"])
      end
    end
  end
end
