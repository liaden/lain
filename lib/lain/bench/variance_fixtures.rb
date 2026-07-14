# frozen_string_literal: true

require "fileutils"

module Lain
  module Bench
    # The committed variance fixtures, as code: three scripted mock recordings
    # of ONE task (an aspirin-dosing lookup -- tool_use, then end_turn) whose
    # response lengths differ, so {Variance} has real divergence and a real
    # distribution to report offline. `bin/regenerate-session-fixtures` calls
    # {.write} against spec/fixtures/sessions/variance; the fixture spec calls
    # it against a tmpdir and asserts byte identity with the committed files.
    # That identity proves REPRODUCIBILITY -- the committed bytes are exactly
    # what this code writes -- not correctness, which the session and variance
    # specs pin independently over live-built objects.
    #
    # Byte-reproducibility is the design constraint everything here serves: a
    # FIXED clock (the only nondeterministic input a Journal stamps), a fixed
    # model, scripted responses, and content-addressed digests derived from
    # those bytes alone. All dosing content is synthetic bench data, not
    # medical guidance.
    module VarianceFixtures
      CLOCK = -> { "1970-01-01T00:00:00Z" }
      MODEL = "claude-sonnet-4-6"
      TASK = "what is the aspirin dosing?"
      FILES = %w[one two three].freeze

      # The one scripted capability: echoes a synthetic dosing line so the
      # tool_result bytes are a pure function of the scripted tool_use input.
      # Raw-hash schema on purpose, against the Tool::Input house rule: the
      # committed fixture bytes embed this schema, and byte-stability must not
      # couple to Tool::Input's JSON-Schema generator, where an unrelated
      # output tweak would silently invalidate every fixture.
      class DosingLookup < Tool
        def name = "dosing_lookup"
        def description = "Looks up dosing guidance for a drug (synthetic bench data)."
        def input_schema = { type: :object, properties: { drug: { type: :string } }, required: [:drug] }

        def perform(input, _context)
          Tool::Result.ok("#{input.fetch("drug")}: 325-650 mg PO q4h PRN (synthetic)")
        end
      end

      class << self
        # Write the three fixture sessions into `dir`, replacing what is there.
        #
        # @param dir [String] created if absent
        # @return [Array<String>] the written paths, in {FILES} order
        def write(dir:)
          FileUtils.mkdir_p(dir)
          scripts.map { |name, responses| write_session(File.join(dir, "#{name}.ndjson"), responses) }
        end

        private

        # One task, three samples: the first model call is identical across
        # them (same prompt, same Context, same tools), and the scripted
        # tool_use inputs and final answers differ in length from there --
        # exactly the shape Variance's divergence section exists to localize.
        def scripts
          { "one" => terse_run, "two" => thorough_run, "three" => clipped_run }
        end

        def terse_run
          [lookup("aspirin", output: 24),
           answer("Typical adult dosing is 325-650 mg every 4 hours as needed.", input: 210, output: 31)]
        end

        def thorough_run
          [lookup("aspirin (adult analgesic, with daily maximum)", output: 41),
           answer("Typical adult analgesic dosing is 325-650 mg orally every 4 hours as " \
                  "needed, not exceeding 4 g in 24 hours; low-dose cardioprotective " \
                  "regimens use 81 mg once daily.", input: 268, output: 74)]
        end

        def clipped_run
          [lookup("asa", output: 18), answer("325-650 mg q4h PRN.", input: 190, output: 12)]
        end

        def lookup(drug, output:)
          Response.new(
            content: [{ "type" => "tool_use", "id" => "tu_1", "name" => "dosing_lookup",
                        "input" => { "drug" => drug } }],
            stop_reason: :tool_use, model: MODEL,
            usage: Usage.new(input_tokens: 120, output_tokens: output)
          )
        end

        def answer(text, input:, output:)
          Response.new(content: [{ "type" => "text", "text" => text }],
                       stop_reason: :end_turn, model: MODEL,
                       usage: Usage.new(input_tokens: input, output_tokens: output))
        end

        # Journal.open appends, so regeneration REPLACES the file first --
        # otherwise a second run would double it instead of reproducing it.
        def write_session(path, responses)
          FileUtils.rm_f(path)
          journal = Journal.open(path, clock: CLOCK)
          begin
            record(journal, responses)
          ensure
            journal.close
          end
          path
        end

        # The same wiring a real bench run uses (JournalRequests INNERMOST, the
        # Agent's own journal:), so the fixture bytes exercise exactly the
        # records Session.load rebuilds a Recording from. It deliberately keeps
        # its own copy of the spec suite's mock-recording idiom: committed
        # fixture bytes must not couple to spec/support helpers.
        def record(journal, responses)
          toolset = Toolset.new([DosingLookup.new])
          context = Context.new(model: MODEL, max_tokens: 1024, system: "be terse")
          agent = Agent.new(provider: Provider::Mock.new(responses:),
                            toolset:, context:, journal:,
                            model_middleware: journaling_stack(journal))
          agent.ask(TASK)
          Session.write(journal, timeline: agent.timeline, context:, toolset:)
        end

        def journaling_stack(journal)
          Middleware::Stack.new([Middleware::JournalRequests.new(journal:)])
        end
      end
    end
  end
end
