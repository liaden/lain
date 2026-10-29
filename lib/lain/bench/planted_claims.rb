# frozen_string_literal: true

require "fileutils"

module Lain
  module Bench
    # A corpus of synthetic sessions that each plant ONE fact inside one tool
    # result, so a compaction sweep can ask whether a strategy kept it. Every
    # session is the same shape (3 asks of 5 lookup rounds, 36 turns) and the
    # claim sits at a different depth in each, which is what makes the corpus
    # discriminate between strategies that keep the head, the tail or neither.
    #
    # Scripted Provider::Mock recordings through the Scribe a chat writes
    # through, under an injected clock and a fixed writer, so the committed
    # bytes under spec/fixtures/compaction/planted are exactly what
    # {.generate} writes under {CLOCK}. All content is synthetic bench data.
    module PlantedClaims
      CLOCK = -> { "1970-01-01T00:00:00Z" }
      MODEL = "claude-sonnet-4-6"
      PROMPTS = ["review the intake records", "now the storage records", "finish with the audit records"].freeze
      ROUNDS = 5
      TOPICS = %w[alder birch cedar dogwood elm fir ginkgo hazel iris juniper larch maple nettle oak pine].freeze
      # On no host a reader runs on, so a watch reads its liveness as unknown.
      WRITER = Liveness::Writer.new(pid: 1, start: "0", host: "planted-fixture")

      # @!attribute [r] path
      #   @return [String] the session file
      # @!attribute [r] claim
      #   @return [String] the planted sentence, verbatim as the tool returned it
      # @!attribute [r] carrier_digest
      #   @return [String] the digest of the tool-result turn that carries it
      Fixture = Data.define(:path, :claim, :carrier_digest)

      # The claim and the lookup (counted across all asks) whose result carries it.
      Plant = Data.define(:name, :claim, :at)

      PLANTS = [
        Plant.new("one", "the harbor ledger caps nightly export retries at 7", 1),
        Plant.new("two", "the quarry gate badge reader resets every 40 minutes", 4),
        Plant.new("three", "the lantern archive keeps exactly 12 snapshots", 6),
        Plant.new("four", "the orchard relay drops frames above 900 per second", 8),
        Plant.new("five", "the saltwater cache evicts entries after 15 days", 11),
        Plant.new("six", "the beacon mirror signs manifests with key tag moss-3", 13)
      ].freeze

      # The one scripted capability. Raw-hash schema on purpose, against the
      # Tool::Input house rule: committed bytes embed this schema, and they
      # must not move when the schema generator's output does.
      class Lookup < Tool
        def initialize(plant:)
          super()
          @plant = plant
        end

        def name = "ledger_lookup"
        def description = "Looks up the record for a topic (synthetic bench data)."
        def input_schema = { type: :object, properties: { topic: { type: :string } }, required: [:topic] }

        def perform(input, _context)
          topic = input.fetch("topic")
          finding = topic == TOPICS.fetch(@plant.at) ? @plant.claim : "nothing notable (synthetic)"
          Tool::Result.ok("#{topic}: #{finding}")
        end
      end

      class << self
        # Write the corpus into `dir`, replacing what is there.
        #
        # @param dir [String] created if absent
        # @param clock [#call] the stamp source for every journal line
        # @return [Array<String>] the written paths, in {PLANTS} order
        def generate(dir, clock: CLOCK)
          FileUtils.mkdir_p(dir)
          PLANTS.map { |plant| write_session(File.join(dir, "#{plant.name}.ndjson"), plant, clock) }
        end

        # @param dir [String] a corpus {.generate} wrote
        # @return [Array<Fixture>] one per session file, in name order
        # @raise [Lain::Error] when a file holds none of the corpus's claims
        def in(dir)
          Dir.glob("*.ndjson", base: dir).sort.map { |name| fixture_of(File.join(dir, name)) }
        end

        private

        def fixture_of(path)
          timeline = Session.load(path).timeline.to_a
          plant = PLANTS.find { |candidate| timeline.any? { |turn| carries?(turn, candidate.claim) } }
          raise Lain::Error, "#{path} carries none of the planted claims" if plant.nil?

          Fixture.new(path: -path, claim: -plant.claim,
                      carrier_digest: -timeline.find { |turn| carries?(turn, plant.claim) }.digest)
        end

        def carries?(turn, claim)
          turn.content.any? { |block| block["type"] == "tool_result" && block["content"].to_s.include?(claim) }
        end

        # Journal.open appends, so regeneration REPLACES the file first.
        def write_session(path, plant, clock)
          FileUtils.rm_f(path)
          journal = Journal.open(path, clock:)
          begin
            record(journal, plant)
          ensure
            journal.close
          end
          path
        end

        # The same wiring a real bench run uses, so the bytes carry exactly
        # the records Session.load rebuilds a Recording from.
        def record(journal, plant)
          toolset = Toolset.new([Lookup.new(plant:)])
          context = Context.new(model: MODEL, max_tokens: 1024, system: "be terse")
          scribe = SessionRecord::Scribe.new(journal:, context:, toolset:, writer: WRITER,
                                             sections: FixtureSections.for(toolset))
          agent = Agent.new(provider: Provider::Mock.new(responses:),
                            toolset:, context:, journal:,
                            model_middleware: Middleware::Stack.new([Middleware::JournalRequests.new(journal:)]))
          PROMPTS.each { |prompt| agent.ask(prompt) }
          scribe.catch_up(agent.timeline).close(reason: :exit)
        end

        def responses
          PROMPTS.each_index.flat_map do |ask|
            rounds = (0...ROUNDS).map { |round| lookup((ask * ROUNDS) + round) }
            [*rounds, answer("records reviewed, part #{ask + 1}")]
          end
        end

        def lookup(index)
          Response.new(
            content: [{ "type" => "tool_use", "id" => "tu_#{index}", "name" => "ledger_lookup",
                        "input" => { "topic" => TOPICS.fetch(index) } }],
            stop_reason: :tool_use, model: MODEL, usage: Usage.new(input_tokens: 120, output_tokens: 20)
          )
        end

        def answer(text)
          Response.new(content: [{ "type" => "text", "text" => text }], stop_reason: :end_turn, model: MODEL,
                       usage: Usage.new(input_tokens: 200, output_tokens: 12))
        end
      end
    end
  end
end
