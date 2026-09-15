# frozen_string_literal: true

require "tmpdir"

# A transcript every catalog stage has something to do to: a failed tool call
# for the purge, a repeated identical call for the dedupe, and more messages
# than the prune window keeps. Module-scoped for the reason
# `CompactionStrategyTranscript` is: a constant in the group would leak.
module ContextPipelineTranscript
  module_function

  def text(body) = [{ "type" => "text", "text" => body }]

  def tool_use(id) = [{ "type" => "tool_use", "id" => "toolu_#{id}", "name" => "echo", "input" => { "text" => "x" } }]

  def tool_result(id, error: false)
    [{ "type" => "tool_result", "tool_use_id" => "toolu_#{id}", "content" => "out", "is_error" => error }]
  end

  def exchange(timeline, id, error: false)
    timeline.commit(role: :assistant, content: tool_use(id))
            .commit(role: :user, content: tool_result(id, error:))
  end

  def timeline(exchanges:)
    opened = Lain::Timeline.empty(store: Lain::Store.new).commit(role: :user, content: text("start"))
    (1..exchanges).inject(opened) { |chain, id| exchange(chain, id, error: id == 1) }
                  .commit(role: :assistant, content: text("done"))
  end
end

RSpec.describe Lain::CLI::ContextPipeline do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:workspace) { Lain::Workspace.new(reminders: ["mind the tests"]) }
  let(:long) { ContextPipelineTranscript.timeline(exchanges: 30) }
  let(:attributes) { { model: "claude-opus-4-8", max_tokens: 1024, system: "be terse" } }

  def render(context, timeline: long) = context.render(timeline:, toolset:, workspace:)

  describe "an unset flag" do
    subject(:unset) { described_class.named(nil).context(**attributes) }

    it "renders the reminder and the cache breakpoints, byte-identical to a Context built without one" do
      expect(render(unset)).to have_same_digest_as(render(Lain::Context.new(**attributes)))
    end

    it "names no pipeline, so the record it writes is the one it always wrote" do
      expect(unset.pipeline_name).to be_nil
    end

    it "renders the same bytes the default name does" do
      expect(render(unset)).to have_same_digest_as(render(described_class.named("default").context(**attributes)))
    end
  end

  describe "a named pipeline on a real launch" do
    around do |example|
      Dir.mktmpdir("lain-context-pipeline") do |dir|
        @root = File.realpath(dir)
        example.run
      end
    end

    include ChatLaunchProbe

    it "reaches the agent's context through the graft, and that pipeline renders the request" do
      agent, = launch_chat({ context_pipeline: "prune" }, root: @root)

      expect(agent.context.pipeline_name).to eq("prune")
      recent = long.to_a.last(described_class::RECENT_MESSAGES)
      expect(render(agent.context).messages)
        .to eq(recent.map { |turn| { "role" => turn.role, "content" => turn.content } })
    end

    it "renders the default through the same launch when the flag is unset" do
      agent, = launch_chat({}, root: @root)

      expect(agent.context.pipeline_name).to be_nil
      expect(render(agent.context).messages.size).to eq(long.to_a.size)
    end
  end

  describe "composition" do
    it "folds the parts left to right, as >> would" do
      composed = described_class.named("dedupe-tool-calls+cache-breakpoints").context(**attributes)
      by_hand = Lain::Context.new(**attributes,
                                  pipeline: Lain::Context::DedupeToolCalls.new >> Lain::Context::CacheBreakpoints.new)

      expect(render(composed)).to have_same_digest_as(render(by_hand))
    end

    it "records the name as typed, parts and order intact" do
      expect(described_class.named("prune+reminder").context(**attributes).pipeline_name).to eq("prune+reminder")
    end

    # A Context whose pipeline is not shareable dies inside the compaction
    # source's `Ractor.make_shareable` on the first compacting turn, not here.
    it "hands the Context a Ractor-shareable pipeline, composed or not" do
      %w[default prune dedupe-tool-calls+reminder+cache-breakpoints].each do |name|
        context = described_class.named(name).context(model: "m", max_tokens: 1)
        expect(Ractor.make_shareable(context)).to be_frozen
      end
    end
  end

  # Every word is a combinator or a composition of them, and five of those had
  # never been constructed anywhere in lib/ before the flag could name them.
  describe "every word in the catalog" do
    described_class::PIPELINES.each_key do |name|
      it "renders #{name.inspect} without error, over a transcript every stage has work in" do
        context = described_class.named(name).context(**attributes)

        expect(render(context)).to be_a(Lain::Request)
      end
    end

    it "prunes to the recent window, and the window really is shorter than the transcript" do
      pruned = render(described_class.named("prune").context(**attributes))

      expect(long.to_a.size).to be > described_class::RECENT_MESSAGES
      expect(pruned.messages.size).to eq(described_class::RECENT_MESSAGES)
    end

    it "purges a failed call's input once it is older than the recent window" do
      purged = render(described_class.named("purge-failed-inputs").context(**attributes))

      expect(purged.messages[1]["content"].first["input"]).to eq({})
      expect(purged.messages[3]["content"].first["input"]).to eq("text" => "x")
    end
  end

  describe "a name that does not exist" do
    it "is refused, listing every pipeline that does" do
      expect { described_class.named("nope") }
        .to raise_error(described_class::Unknown) do |error|
          expect(error.message).to include('--context-pipeline "nope"')
          expect(described_class::PIPELINES.keys.reject { |name| error.message.include?(name.inspect) }).to be_empty
        end
    end

    it "refuses an empty part at either end rather than dropping it" do
      expect { described_class.named("prune+") }
        .to raise_error(described_class::Unknown, /unknown part "" in --context-pipeline "prune\+"/)
      expect { described_class.named("") }
        .to raise_error(described_class::Unknown, /unknown part "" in --context-pipeline ""/)
    end

    # A repeated stage is never what an arm means: two cache-breakpoint passes
    # put five markers on the wire, which the API refuses mid-chat rather
    # than at launch, and two reminders send the workspace twice. `default`
    # IS reminder+cache-breakpoints, so naming either beside it repeats it.
    it "refuses a repeated word, naming the repeat" do
      expect { described_class.named("default+default") }
        .to raise_error(described_class::Unknown, /repeated part "default" in --context-pipeline "default\+default"/)
      expect { described_class.named("prune+dedupe-tool-calls+prune") }
        .to raise_error(described_class::Unknown, /repeated part "prune"/)
    end

    # The explanatory tail names what "default" expands to, which is only a
    # useful thing to say when "default" is one of the words that were typed
    # -- a human who never wrote it should not be told what it means.
    it "mentions what \"default\" expands to only when \"default\" is involved" do
      expect { described_class.named("default+default") }
        .to raise_error(described_class::Unknown, /"default" is reminder\+cache-breakpoints/)
      expect { described_class.named("prune+dedupe-tool-calls+prune") }
        .to raise_error(described_class::Unknown) do |error|
          expect(error.message).not_to include("is reminder+cache-breakpoints")
        end
    end

    it "refuses a word that repeats a stage the default already holds" do
      expect { described_class.named("default+reminder") }
        .to raise_error(described_class::Unknown, /repeated part "reminder" in --context-pipeline "default\+reminder"/)
      expect { described_class.named("cache-breakpoints+prune+default") }
        .to raise_error(described_class::Unknown, /repeated part "cache-breakpoints"/)
    end

    it "refuses a non-String name at the door, naming the type it got" do
      expect { described_class.named(:prune) }
        .to raise_error(described_class::Unknown, /takes a String, got Symbol: :prune/)
    end

    # The two flags are one kind of mistake made on two knobs, so an operator
    # who has read one refusal has read both. Normalizing away the flag and its
    # set leaves what is left to compare, and it has to be the same sentence.
    describe "in the same shape as the compaction strategy flag's refusal" do
      def refusal(resolving)
        resolving.call
      rescue Lain::Error => e
        e
      end

      def shape(error, flag:, names:)
        [error.class.superclass, error.message.sub(flag, "FLAG").sub(names.inspect, "NAMES")]
      end

      it "for an unknown part inside a composition" do
        pipeline = refusal(-> { described_class.named("prune+nope") })
        strategy = refusal(-> { Lain::CLI::CompactionStrategy.resolve("elide+nope") })

        expect(shape(pipeline, flag: "--context-pipeline", names: described_class::PIPELINES.keys)
                 .map { |part| part.to_s.sub("prune", "LEAF") })
          .to eq(shape(strategy, flag: "--compact-strategy", names: Lain::CLI::CompactionStrategy::STRATEGIES)
                   .map { |part| part.to_s.sub("elide", "LEAF") })
      end

      it "for a name that is not a String" do
        pipeline = refusal(-> { described_class.named(:prune) })
        strategy = refusal(-> { Lain::CLI::CompactionStrategy.resolve(:prune) })

        expect(shape(pipeline, flag: "--context-pipeline", names: described_class::PIPELINES.keys))
          .to eq(shape(strategy, flag: "--compact-strategy", names: Lain::CLI::CompactionStrategy::STRATEGIES))
      end
    end
  end
end
