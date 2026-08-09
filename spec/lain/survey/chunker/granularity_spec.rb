# frozen_string_literal: true

RSpec.describe Lain::Survey::Chunker::Granularity do
  def units_of(sizes, path: "doc.md", label: "")
    sizes.inject([[], 1]) do |(units, line), size|
      [units + [Lain::Survey::Unit.new(path:, label:, start_line: line, lines: Array.new(size, "x"))], line + size]
    end.first
  end

  def sizes_of(units) = units.map { |unit| unit.lines.size }

  describe "#coalesce" do
    subject(:granularity) { described_class.new(minimum: 5) }

    it "merges consecutive units too small to be worth a mark" do
      expect(sizes_of(granularity.coalesce(units_of([1, 1, 1, 1, 1, 9])))).to eq([5, 9])
    end

    it "leaves a unit already at the minimum alone" do
      expect(sizes_of(granularity.coalesce(units_of([5, 5, 5])))).to eq([5, 5, 5])
    end

    it "stops merging as soon as the run reaches the minimum" do
      expect(sizes_of(granularity.coalesce(units_of([1, 1, 1, 1, 1, 1, 1, 1, 1, 1])))).to eq([5, 5])
    end

    # Without this the bound is off by one exactly where the AC measures: a file
    # of n*minimum + 1 lines ends on a one-line unit.
    it "absorbs a trailing runt backward rather than shipping it" do
      expect(sizes_of(granularity.coalesce(units_of([5, 5, 1])))).to eq([5, 6])
    end

    it "leaves a single under-minimum unit alone, there being nothing to merge it into" do
      expect(sizes_of(granularity.coalesce(units_of([2])))).to eq([2])
    end

    it "answers nothing for nothing" do
      expect(granularity.coalesce([])).to eq([])
    end

    # The invariant the granularity AC rests on, stated where it can be
    # falsified directly rather than only through a chunker.
    it "guarantees at most one unit per minimum lines, for any shape of input" do
      [[1] * 21, [1, 9, 1, 1, 4, 1], [3, 3, 3, 3], [60], [1, 1], (1..12).to_a].each do |sizes|
        coalesced = granularity.coalesce(units_of(sizes))
        expect(coalesced.size).to be <= [sizes.sum / 5, 1].max
      end
    end

    it "keeps every line, in order, at its original position" do
      units = units_of([1, 2, 1, 7])
      coalesced = granularity.coalesce(units)

      expect(coalesced.flat_map(&:lines)).to eq(units.flat_map(&:lines))
      expect(coalesced.first.start_line).to eq(1)
    end

    it "names every label a merged unit swallowed, in order" do
      units = [Lain::Survey::Unit.new(path: "a.rb", label: "method alpha", start_line: 1, lines: %w[a]),
               Lain::Survey::Unit.new(path: "a.rb", label: "method beta", start_line: 2, lines: %w[b]),
               Lain::Survey::Unit.new(path: "a.rb", label: "method gamma", start_line: 3, lines: %w[c d e])]

      expect(granularity.coalesce(units).map(&:label)).to eq(["method alpha, method beta, method gamma"])
    end

    it "collapses a repeated label rather than saying it twice" do
      units = units_of([1, 1, 3], label: "Intro")

      expect(granularity.coalesce(units).map(&:label)).to eq(["Intro"])
    end

    # A chunker that reordered or dropped units would otherwise be silently
    # rewritten into one that did not.
    it "refuses to merge units that are not adjacent" do
      out_of_order = [Lain::Survey::Unit.new(path: "a.rb", label: "", start_line: 1, lines: %w[a]),
                      Lain::Survey::Unit.new(path: "a.rb", label: "", start_line: 40, lines: %w[b])]

      expect { granularity.coalesce(out_of_order) }.to raise_error(ArgumentError, /non-adjacent/)
    end
  end

  describe "at a minimum of one" do
    it "is the identity, so a chunker can be read without it" do
      units = units_of([1, 1, 5])

      expect(described_class.new(minimum: 1).coalesce(units)).to eq(units)
    end
  end

  describe "as a value" do
    it "equals another built the same way, so a rebuilt chunker compares equal" do
      expect(described_class.new(minimum: 5)).to eq(described_class.new(minimum: 5))
    end

    it "is Ractor-shareable" do
      expect(Ractor.shareable?(described_class.new(minimum: 5))).to be(true)
    end
  end
end
