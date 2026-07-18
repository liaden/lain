# frozen_string_literal: true

RSpec.describe Lain::Structural::Patterns do
  describe ".fetch" do
    it "resolves the method_def query to both the plain and singleton forms" do
      patterns = described_class.fetch(:ruby, :method_def, name: "save")

      expect(patterns).to eq(["def save($$$A)", "def self.save($$$A)"])
    end

    it "resolves the method_call query to a receiver form and a bare-identifier form" do
      patterns = described_class.fetch(:ruby, :method_call, name: "save")

      expect(patterns).to eq(["$RECV.save", "save"])
    end

    it "covers every ag_helpers-derived query for :ruby" do
      %i[method_def class_def subclass_of mixin instance_var method_call].each do |query|
        expect { described_class.fetch(:ruby, query) }.not_to raise_error
      end
    end

    it "resolves class_def to the class and module forms" do
      expect(described_class.fetch(:ruby, :class_def)).to eq(["class $N", "module $N"])
    end

    it "resolves subclass_of to the superclass form, and interpolates a literal superclass" do
      expect(described_class.fetch(:ruby, :subclass_of)).to eq(["class $C < $SUPER"])
      expect(described_class.fetch(:ruby, :subclass_of, super: "ActiveRecord::Base"))
        .to eq(["class $C < ActiveRecord::Base"])
    end

    it "resolves mixin to the include and extend forms" do
      expect(described_class.fetch(:ruby, :mixin)).to eq(["include $M", "extend $M"])
      expect(described_class.fetch(:ruby, :mixin, name: "Comparable"))
        .to eq(["include Comparable", "extend Comparable"])
    end

    it "resolves instance_var to the bare ivar form, and interpolates a literal name" do
      expect(described_class.fetch(:ruby, :instance_var)).to eq(["@$VAR"])
      expect(described_class.fetch(:ruby, :instance_var, name: "digest")).to eq(["@digest"])
    end

    it "raises a named error for an unknown query, rather than returning nil" do
      expect { described_class.fetch(:ruby, :nonsense) }
        .to raise_error(Lain::Structural::Patterns::Unknown, /nonsense/)
    end

    it "raises a named error for an unknown language, rather than returning nil" do
      expect { described_class.fetch(:python, :method_def) }
        .to raise_error(Lain::Structural::Patterns::Unknown, /python/)
    end
  end
end
