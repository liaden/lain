# frozen_string_literal: true

RSpec.describe Lain::Middleware do
  # A "tag" middleware records its entry and exit around the downstream in a
  # purely functional way -- it appends to `env[:trace]` on the way in and to the
  # returned env's trace on the way out, never mutating shared state, so a
  # stack's nesting order reads straight off the trace it produces.
  def tag(symbol)
    Class.new(Lain::Middleware::Base) do
      define_method(:call) do |env, &downstream|
        entered = env.merge(trace: env.fetch(:trace, []) + [[symbol, :in]])
        exited = downstream.call(entered)
        exited.merge(trace: exited.fetch(:trace) + [[symbol, :out]])
      end
    end.new
  end

  # The observation: run a middleware over an empty-trace env, terminating in the
  # identity app, and read the trace it produced. The env is wrapped so the trace
  # threads through Env#merge.
  def observe(middleware)
    middleware.call(Lain::Middleware::Env.wrap({ trace: [] })) { |env| env }.fetch(:trace)
  end

  # Every production chain is a Stack, whose order is readable and adjustable;
  # a binary operator nesting two middlewares into an opaque pair had no caller
  # in lib/, so it and its unit are gone rather than held to laws.
  describe "composition" do
    it "is a Stack's job: no middleware answers the composition operator" do
      expect(described_class::Base.new).not_to respond_to(:>>)
      expect(described_class::Stack.new).not_to respond_to(:>>)
      expect(described_class.constants).not_to include(:Composable, :Composed, :Identity)
    end
  end

  describe described_class::Stack do
    let(:a) { tag(:a) }
    let(:b) { tag(:b) }
    let(:c) { tag(:c) }

    it "nests in declared order: first #use is outermost" do
      stack = described_class.new
      stack.use(a).use(b).use(c)
      expect(observe(stack)).to eq([%i[a in], %i[b in], %i[c in], %i[c out], %i[b out], %i[a out]])
    end

    it "#insert_before places a middleware ahead of a matched class" do
      stack = described_class.new([a, c])
      stack.insert_before(c.class, b)
      expect(stack.to_a).to eq([a, b, c])
    end

    it "#insert_after places a middleware behind a matched class" do
      stack = described_class.new([a, c])
      stack.insert_after(a.class, b)
      expect(stack.to_a).to eq([a, b, c])
    end

    it "#to_a is a copy -- inspecting the order cannot mutate the stack" do
      stack = described_class.new([a])
      stack.to_a << b
      expect(stack.to_a).to eq([a])
    end

    it "raises when insert targets a middleware that is not present" do
      expect { described_class.new([a]).insert_before(b.class, c) }
        .to raise_error(ArgumentError, /no middleware matching/)
    end

    it "nests as a member of another Stack -- a Stack is a middleware" do
      nested = described_class.new([a, described_class.new([b]), c])
      expect(observe(nested)).to eq([%i[a in], %i[b in], %i[c in], %i[c out], %i[b out], %i[a out]])
    end
  end

  # A bare `yield` inside a middleware raises LocalJumpError the moment anyone
  # calls it outside a stack, and no RuboCop cop can catch that statically. So
  # every middleware routes through Base#downstream, which is the identity when
  # there is no downstream. These specs pin that totality down.
  describe "a middleware called with no downstream" do
    let(:env) { { a: 1 } }

    it "passes env through for Base" do
      expect(described_class::Base.new.call(env)).to eq(env)
    end

    it "passes env through for an empty Stack" do
      # Stack wraps at its boundary, so its return is an Env; to_h recovers the hash.
      expect(described_class::Stack.new.call(env).to_h).to eq(env)
    end
  end

  # Logging and Timeout were constructed only here, never by production
  # wiring -- deleting them removes nothing a real stack ever held.
  describe "the spec-only middlewares" do
    it "are gone: nothing production could have built into a stack remains" do
      expect(described_class.constants).not_to include(:Logging, :Timeout)
    end
  end

  # Timeout did not preempt -- it published a monotonic env[:deadline] and
  # took its clock as an injected collaborator, which is what let a spec move
  # time without sleeping. That seam outlives the class: these five sites cited
  # Middleware::Timeout as the idiom's worked example, and deleting the class
  # must correct what they name rather than orphan the citation.
  #
  # The check is scoped to the CITING COMMENT BLOCK, not the whole file: four
  # of these five files mention an unrelated injected clock elsewhere (tty.rb's
  # countdown ticker, shutdown.rb's grace-window comment, and their specs' own
  # asides about it), so a whole-file regexp would still pass with the citing
  # sentence gutted -- a check met without its reason present, which is
  # exactly the failure this rewrite exists to guard against.
  describe "the injected-clock idiom the deleted Timeout demonstrated" do
    root = File.expand_path("../..", __dir__)

    # `anchor` is text found only inside the rewritten sentence, used to find
    # the comment block that sentence lives in -- not the sentence's own
    # "injected clock" wording, so the search does not just refind what it is
    # about to assert on.
    citations = {
      "lib/lain/frontend/tty.rb" => "monotonic time source for {#render_countdown}",
      "lib/lain/frontend/neovim/compose.rb" => "monotonic seconds bounding {#settle}'s wait",
      "lib/lain/cli/shutdown.rb" => "monotonic time source, injectable for tests",
      "spec/lain/frontend/neovim/compose_spec.rb" => "every sibling seam takes",
      "spec/lain/cli/shutdown_spec.rb" => "A clock stub returning the given values in order"
    }

    # The contiguous run of comment lines around `anchor`, expanding while a
    # neighboring line is still a `#` comment -- the paragraph a human editing
    # the citation would actually touch, and nothing elsewhere in the file.
    def comment_block(path, anchor)
      lines = File.readlines(path)
      index = lines.index { |line| line.include?(anchor) }
      raise "anchor #{anchor.inspect} not found in #{path}" unless index

      comment_line = ->(i) { i.between?(0, lines.size - 1) && lines[i].match?(/^\s*#/) }
      first = index
      first -= 1 while comment_line.call(first - 1)
      last = index
      last += 1 while comment_line.call(last + 1)
      lines[first..last].join
    end

    citations.each do |relative_path, anchor|
      it "#{relative_path} names the idiom, not a class that no longer exists, in the citing block" do
        block = comment_block(File.join(root, relative_path), anchor)

        expect(block).not_to include("Middleware::Timeout"),
                             "the citing block in #{relative_path} still names the deleted class:\n#{block}"
        expect(block).to match(/injected.clock/i),
                         "the citing block in #{relative_path} no longer explains the idiom:\n#{block}"
      end
    end
  end
end
