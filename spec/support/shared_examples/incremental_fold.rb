# frozen_string_literal: true

require "stringio"

# The laws a journal projection holds so a reader can fold a file whole or follow it live and
# get one answer. Three, each of which can fail:
#
# - persistence: a projection and the one its step answers are both Ractor shareable, so a state
#   handed to another reader cannot move under it. Shareable is deeply frozen, so it is the whole
#   test: a step that moved its receiver would have had to find it unfrozen;
# - chunked equals whole: the projection over a file's newline-terminated lines equals the one
#   stepped through a Tail fed the same bytes cut anywhere, a multibyte character and an
#   unterminated last line included, which is what `lain watch` sees of a file still being written;
# - for a projection that declares `combine`, "a monoid homomorphism" from the record list, so two
#   halves folded apart combine to the whole. One that binds a record to a later one, with a state
#   that drops the later record's key, cannot, and its spec says so through the same battery.
#
# Include with a Hash, built at the `include_examples` site:
#
#   projection  [Class]                   answers `.unit` and `.over(records)`; its values `#step`
#   population  [#call -> Array<Array>]   record lists, typed as Telemetry.read answers them
#   generator   [PropCheck::Generator]    instead of a population: sampled
#   samples     [Integer]                 draws taken from the generator; defaults to 4
#   equal       [#call(a, b) -> bool]     over two projections; defaults to `==`
#   tail        [#call -> #<<]            a fresh byte buffer; defaults to Lain::Journal::Tail
#
# The chunked law rereads a draw once per byte, so a draw is a handful of short records.
module AlgebraLaws
  IncrementalFold = Data.define(:projection, :draws, :same, :tail) do
    def self.from(config)
      new(projection: config.fetch(:projection), draws: drawn(config),
          same: config.fetch(:equal, ->(a, b) { a == b }),
          tail: config.fetch(:tail, -> { Lain::Journal::Tail.new }))
    end

    def self.drawn(config)
      return config.fetch(:population).call if config.key?(:population)

      config.fetch(:generator).sample(config.fetch(:samples, 4))
    end

    def to_h
      laws = { "leaves the receiver as it was when stepped" => method(:persistent?),
               "folds the bytes cut at any byte as it folds the whole lines" => method(:chunked_equals_whole?) }
      combines? ? laws.merge(homomorphism.to_h) : laws
    end

    def combines? = projection.unit.respond_to?(:combine)

    def homomorphism
      MonoidHomomorphism.from(collapse: ->(records) { projection.over(records) }, unit: projection.unit,
                              combine: ->(a, b) { a.combine(b) }, spans: -> { draws }, equal: same)
    end

    def persistent? = draws.reject(&:empty?).all? { |records| persists?(records) }

    def persists?(records)
      before = projection.over(records[0...-1])
      after = before.step(records.last)
      Ractor.shareable?(before) && Ractor.shareable?(after)
    end

    def chunked_equals_whole? = draws.all? { |records| cut_anywhere?(journaled(records)) }

    # The draw's bytes and the same bytes with the last newline cut, which the Tail holds back.
    def cut_anywhere?(bytes)
      [bytes, bytes.chomp].all? do |file|
        whole = projection.over(file.lines.select { |line| line.end_with?("\n") }.map { |line| read(line) })
        bytewise_and_every_two_way_cut(file).all? { |chunks| same.call(chunked(chunks), whole) }
      end
    end

    def bytewise_and_every_two_way_cut(file)
      bytes = file.b
      [bytes.chars, *(0..bytes.bytesize).map { |at| [bytes.byteslice(0, at), bytes.byteslice(at..)] }]
    end

    def chunked(chunks)
      buffer = tail.call
      chunks.inject(projection.unit) do |state, chunk|
        (buffer << chunk).inject(state) { |stepped, hash| stepped.step(Lain::Telemetry.read(hash)) }
      end
    end

    def read(line) = Lain::Telemetry.read(Lain::Journal.parse(line))

    def journaled(records)
      io = StringIO.new
      journal = Lain::Journal.new(io:, clock: -> { "2026-10-29T00:00:00.000000Z" })
      records.each { |record| journal << (record.is_a?(Lain::Telemetry::Untyped) ? record.fields : record) }
      io.string
    end
  end
end

RSpec.shared_examples "an incremental fold" do |config|
  define_method(:battery) { @battery ||= AlgebraLaws::IncrementalFold.from(config) }

  AlgebraLaws::IncrementalFold.from(config.merge(population: -> { [] })).to_h.each_key do |law|
    it(law) { expect(battery.to_h.fetch(law).call).to be(true) }
  end

  context "when reading those laws over these record lists" do
    it "includes one with more than one record, so a step follows a step" do
      expect(battery.draws.map(&:size).max).to be > 1
    end
  end
end
