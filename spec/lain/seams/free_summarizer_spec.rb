# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# T4: the project's own `.lain/summarizers.rb` reaches the rendered prompt.
#
# The chain nothing tested end to end: {Lain::CLI::Backend#tool_observer} ->
# {Lain::Oracle::Eager#fire} -> {Lain::Oracle::RoutedSummarizer} -> the loaded
# {Lain::Summarizer::Catalog} -> {Lain::Compaction::SummarySnapshot} -> the
# messages a compacting turn renders. Every component here is the real one; the
# only stub is which PROVIDER the model tier would have called, which is how an
# example can say "no model was asked" rather than "the network was down".
#
# The defect this file exists to catch: a declared summarizer costs no tokens
# and no latency, but the free tier was consulted only for results over the
# MODEL tier's 4096-byte cost threshold -- so a project's own declarations were
# dead for every ordinary tool result.
module FreeSummarizerSeam
  # A project's `.lain/summarizers.rb`, routing on BOTH halves of a
  # {Lain::Summarizer::Result}: the tool that produced it and its text.
  DECLARATION = <<~RUBY
    summarizer "coverage" do
      def suitable?(result) = result.tool_name == "bash" && result.text.include?("Coverage report")
      def compact(result) = "coverage: 94.2% of lines"
    end
  RUBY

  # Exactly 200 bytes: far below the model tier's threshold, and the size an
  # ordinary `bash` result actually is.
  HANDLED = "Coverage report\n#{"covered line\n" * 14}".ljust(200, "-").freeze

  # The same size from a tool the declaration refuses.
  REFUSED = "module Lain; end\n".ljust(200, "-").freeze

  # Over the model tier's cost threshold, so the fallthrough it guards is still
  # reachable -- the half of the policy this card KEEPS.
  BULKY = ("a directory listing line\n" * 400).freeze

  # The state a `.lain/summarizers.rb` is in while it is being written. Every
  # tool result runs these predicates now, so it is reached far more often than
  # it was.
  RAISING = <<~RUBY
    summarizer "broken" do
      def suitable?(result) = raise("suitable? exploded")
      def compact(result) = "never reached"
    end
  RUBY
end

RSpec.describe "Free summarizer tier seam", :seam do
  let(:journal) { RecordingChannel.new }

  # One response the summarizer schema accepts, so a model fallthrough SUCCEEDS
  # rather than erroring: "the model was not called" then means what it says,
  # instead of being a failure the Eager's task boundary swallowed.
  let(:model_provider) do
    reply = Lain::Response.new(content: [{ "type" => "text", "text" => %({"summary":"the model's summary"}) }],
                               stop_reason: :end_turn,
                               usage: Lain::Usage.new(input_tokens: 12, output_tokens: 7))
    Lain::Provider::Mock.new(responses: [reply])
  end

  # A real project tree with a real declaration file, entered so that
  # {Lain::Summarizer::Catalog.load}'s `Dir.pwd` root finds it.
  def in_project(declaration = FreeSummarizerSeam::DECLARATION, &block)
    Dir.mktmpdir("lain-free-summarizer") do |dir|
      FileUtils.mkdir_p(File.join(dir, ".lain"))
      File.write(File.join(dir, ".lain", "summarizers.rb"), declaration)
      Dir.chdir(dir, &block)
    end
  end

  # The compaction knobs are turned down so six messages are enough to force a
  # rewrite; nothing else about the wiring is a test fixture.
  def backend
    Lain::CLI::Backend.new(provider: "ollama", max_tokens: 1024,
                           compact_bytes: 100, compact_cap: 100, compact_keep: 2).tap do |built|
      allow(built).to receive(:summarizer_provider).and_return(model_provider)
      built.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)
    end
  end

  def result_block(content) = { "type" => "tool_result", "tool_use_id" => "call-2", "content" => content }

  def text_block(index) = { "type" => "text", "text" => "the quick brown fox, message #{index}. " * 15 }

  # The only shape `Agent#perform_tools` commits: an assistant `tool_use`
  # answered by the `user` tool_result immediately after it. The pair sits
  # wholly inside the droppable span at `compact_keep: 2`.
  def timeline_carrying(content, tool_name)
    [["user", [text_block(1)]],
     ["assistant", [{ "type" => "tool_use", "id" => "call-2", "name" => tool_name, "input" => {} }]],
     ["user", [result_block(content)]],
     ["assistant", [text_block(4)]], ["user", [text_block(5)]], ["user", [text_block(6)]]]
      .inject(Lain::Timeline.empty(store: Lain::Store.new)) { |line, (role, content_blocks)| line.commit(role:, content: content_blocks) }
  end

  def observe(built, content, tool_name)
    built.tool_observer.observe(result_block(content).merge("is_error" => false), tool_name)
  end

  def compacted(built, line)
    context = built.pipeline_source(cache_profile: Lain::CacheProfile::NO_CACHING, journal:)
                   .context_for(base: base_context, timeline: line, usage: nil, session: Lain::Session.new)
    Lain::Canonical.dump(context.render(timeline: line, toolset: Lain::Toolset.new).messages)
  end

  def base_context = Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024, system: "a system prompt")

  def oracle_answers = journal.events.grep(Lain::Telemetry::OracleAnswer)

  it "puts a 200-byte declared summary into the compacted render, with no model call" do
    in_project do
      Sync do
        built = backend
        line = timeline_carrying(FreeSummarizerSeam::HANDLED, "bash")
        observe(built, FreeSummarizerSeam::HANDLED, "bash")

        expect(FreeSummarizerSeam::HANDLED.bytesize).to eq(200)
        expect(compacted(built, line)).to include("coverage: 94.2% of lines")
        expect(model_provider.call_count).to eq(0)
        expect(oracle_answers).to be_empty
      end
    end
  end

  it "fires no model summarization for a small result the declaration refuses" do
    in_project do
      Sync do
        built = backend
        observe(built, FreeSummarizerSeam::REFUSED, "read_file")

        expect(model_provider.call_count).to eq(0)
        expect(oracle_answers).to be_empty
        expect(built.eager.held(Lain::Canonical.digest(FreeSummarizerSeam::REFUSED))).to be_nil
      end
    end
  end

  # Consulting the catalog for EVERY result widened the blast radius of user
  # code: {Lain::Summarizer::Catalog#for} raises whatever a `suitable?` raises,
  # and it now runs against every tool result rather than the large ones alone.
  # Two containments cover it -- {Lain::Oracle::RoutedSummarizer}'s rescue and
  # {Lain::Oracle::Eager}'s task boundary -- and the real observer drives both.
  it "survives a declaration that raises on every result, holding nothing and killing no turn" do
    in_project(FreeSummarizerSeam::RAISING) do
      Sync do
        built = backend

        expect { observe(built, FreeSummarizerSeam::HANDLED, "bash") }.not_to raise_error
        expect(built.eager.held(Lain::Canonical.digest(FreeSummarizerSeam::HANDLED))).to be_nil
        expect(model_provider.call_count).to eq(0)
      end
    end
  end

  # The half of the policy the card KEEPS: the 4096-byte gate still guards the
  # model tier, so an unhandled BULKY result is still worth a model call.
  it "still spends a model call on an unhandled result over the cost threshold" do
    in_project do
      Sync do
        built = backend
        observe(built, FreeSummarizerSeam::BULKY, "read_file")

        expect(model_provider.call_count).to eq(1)
        expect(oracle_answers.size).to eq(1)
      end
    end
  end
end
