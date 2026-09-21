# frozen_string_literal: true

# {Lain::Frontend::Neovim::ThreadView} -- the Ruby half of the thread pane: it
# takes an anchor and a rendered conversation and hands the editor's inlet the
# identity, the lines and the position the pane has to watch. The editor half is
# `spec/lain/frontend/neovim/runtime/51_thread_spec.rb`, which needs a real nvim;
# nothing here does.

RSpec.describe Lain::Frontend::Neovim::ThreadView do
  subject(:view) { described_class.new(rpc: inlet) }

  let(:inlet) { RecordingThreadInlet.new }

  def anchor(id: "a-20", line: 20, side: :new, path: "docs/counter.txt")
    Lain::Review::Anchor.new(path:, side:, line:, anchor_text: "line 20", revision: "head1ff", id:)
  end

  def entry(speaker, text) = described_class::Entry.new(speaker:, text:)

  it "posts the anchor's identity AND the position the pane has to watch" do
    view.show(anchor, [entry("you", "why this way?")])

    expect(inlet.posts.first.first)
      .to eq("id" => "a-20", "path" => "docs/counter.txt", "side" => "new", "line" => 20)
  end

  it "renders each message under a heading naming who said it, under the position" do
    view.show(anchor, [entry("you", "why this way?"), entry("docent", "because the store owns it")])

    expect(inlet.posts.first.last)
      .to eq(["-- thread at docs/counter.txt:20 --", "", "## you", "why this way?",
              "", "## docent", "because the store owns it"])
  end

  # Both halves of the position, because a header naming the file and losing
  # the line points at the top of a diff rather than at the note -- the same law
  # the review-surface shared group states for `#thread`.
  it "names where the conversation hangs, file and line" do
    view.show(anchor(path: "lib/b.rb", line: 3), [entry("you", "why?")])

    expect(inlet.posts.first.last.first).to eq("-- thread at lib/b.rb:3 --")
  end

  # `nvim_buf_set_lines` raises on a String holding a newline, so a paragraph
  # has to arrive already cut into buffer lines.
  it "cuts a multi-line message into buffer lines" do
    view.show(anchor, [entry("docent", "first\nsecond")])

    expect(inlet.posts.first.last).to eq(["-- thread at docs/counter.txt:20 --", "", "## docent",
                                          "first", "second"])
  end

  it "invites the first question rather than posting an empty buffer" do
    view.show(anchor)

    expect(inlet.posts.first.last).to eq(["-- thread at docs/counter.txt:20 --", described_class::EMPTY])
  end

  it "answers the refusal the editor gave rather than raising" do
    refused = described_class.new(rpc: RecordingThreadInlet.new(refusal: "no editor"))

    expect(refused.show(anchor)).to eq("no editor")
  end

  it "answers nothing when the conversation landed" do
    expect(view.show(anchor)).to be_nil
  end

  # The default is the Null editor, so an unwired view refuses honestly rather
  # than reporting a thread that never landed ({QuestionView::Detached}'s shape).
  it "refuses honestly when no editor is wired" do
    expect(described_class.new.show(anchor)).to eq(described_class::DETACHED)
  end

  # The port's promise, and this chunk's deletion map depends on it: a view
  # holding conversation state is a second copy of the session's.
  it "holds no thread state of its own" do
    view.show(anchor(id: "a-1", line: 4), [entry("you", "one")])
    view.show(anchor(id: "a-2", line: 8), [entry("you", "two")])

    held = view.instance_variables.map { |name| view.instance_variable_get(name) }
    expect(held.map(&:class)).to eq([RecordingThreadInlet])
  end

  # ⚠️ A CROSS-CARD SHAPE, pinned from the only side this tree can see. The
  # docent renders its exchange into these two members from its own value
  # object, by duck rather than by construction, so renaming one here breaks it
  # at RUNTIME with nothing red. This is half a pin: it fails if this side
  # drifts, and it cannot see the other. The whole pin is one example asserting
  # the two member lists equal, and it belongs wherever both constants are
  # loadable -- not here, where the docent's is not.
  it "takes a message as a speaker and their text, in those names" do
    expect(described_class::Entry.members).to eq(%i[speaker text])
  end

  it "refuses an anchor whose id names nothing, because every ask cites it back" do
    expect { view.show(Struct.new(:id, :path, :side, :line).new(nil, "a.rb", :new, 1)) }
      .to raise_error(ArgumentError, /names nothing/)
  end

  # `[deletable]`: removing this capability means deleting its files, so nothing
  # outside them may name it. Runs without an editor.
  describe "the thread pane's deletability" do
    it "is one runtime module, at the prefix the thread pane was given" do
      modules = Lain::Frontend::Neovim::RuntimeLoader.new.module_paths.map { |path| File.basename(path) }

      expect(modules).to include("51_thread.lua")
    end

    # ⚠️ REWRITTEN, because the first version proved the wrong thing. It asserted
    # that NOTHING outside the thread pane's own files names the capability --
    # which is not deletability, it is "this feature has no users", a property no
    # shipped feature can satisfy and the very state that let this one ship broken (the
    # port adapter posted a shape the editor refuses, and no spec reached the
    # rail). It also made prose pay: a sibling card's comments had to say "the
    # thread pane's editor half" rather than cite {ThreadView::Entry}, because
    # naming a thing failed a test.
    #
    # So: CODE may name the capability only from an enumerated set of consumers,
    # and PROSE may name it anywhere. A whole-line comment is stripped before the
    # scan; a new unlisted reference in code still fails, which is what keeps a
    # deletion able to find everything by deleting and reading the reds.
    #
    # The row, and what a deletion owes each entry:
    #
    #   1. `lib/lain/review/surface/neovim.rb` -- the port adapter renders
    #      `#annotate` and `#thread` through {ThreadView}. Those two messages are
    #      the PORT's, so deleting the pane does not delete them: a deletion has
    #      to decide what they become. Left as they are they would post to a lua
    #      entry point that no longer exists -- a silent nil call inside a notify,
    #      not a LoadError, which is exactly the failure this row exists to make
    #      impossible.
    #   2. `lib/lain/review/docent.rb` -- the docent asks a review surface whether
    #      it has a pane to draw an answer into, and takes the one it finds. It
    #      costs a deletion nothing extra: the deletion map already records that removing
    #      the pane forces the docent out with it, so this reference goes with the
    #      file it lives in. It is listed because THIS sweep is a flat allowlist
    #      and knows nothing about that nesting. Its own spec is here for the same
    #      reason: it stands a surface in that answers `#thread_view`.
    #   3. the two specs that drive the rail.
    #
    # There is no require line to list: nothing under lib/ requires anything
    # under lib/, so deleting thread_view.rb leaves the two consumers above
    # naming a constant the loader can no longer find -- a NameError at the
    # site that wanted it, which is what the rows exist to route a deletion to.
    #
    # THE CAPABILITY OWNS TWO SPEC FILES, not one: the editor half at
    # `spec/lain/frontend/neovim/runtime/51_thread_spec.rb` and the Ruby half
    # here, plus the recorder in `spec/support/` that both of them build. All
    # three are `own`, and all three are in the deletion map's row.
    def names_it_in_code?(path)
      comment = path.end_with?(".lua") ? /^\s*--/ : /^\s*#/
      File.readlines(path).grep_v(comment).join.match?(/ThreadView|thread_view|51_thread/)
    end

    it "is named in CODE only by its own files and an enumerated set of consumers" do
      root = File.expand_path("../../../..", __dir__)
      own = ["lib/lain/frontend/neovim/thread_view.rb", "lib/lain/frontend/neovim/runtime/51_thread.lua",
             "spec/lain/frontend/neovim/runtime/51_thread_spec.rb",
             "spec/lain/frontend/neovim/thread_view_spec.rb", "spec/support/recording_thread_inlet.rb"]
      consumers = ["lib/lain/review/docent.rb", "lib/lain/review/surface/neovim.rb",
                   "spec/lain/review/docent_spec.rb", "spec/lain/review/surface/neovim_spec.rb"]
      # `deletability_spec.rb` is the MAP, so it names every deletable
      # capability by construction and exempts itself from its own sweep for the
      # same reason. It is not a consumer: the thread pane's deletion takes its
      # ROW there, which is an edit, not the file.
      sources = (Dir[File.join(root, "{lib,spec,exe}/**/*.{rb,lua}")] + [File.join(root, "exe/lain")])
                .reject { |path| path.end_with?("spec/lain/review/deletability_spec.rb") }

      unlisted = "a file outside the thread pane's deletion row now names it in CODE. If that is a " \
                 "legitimate new consumer, add it to `consumers` above AND to the chunk's deletion map, so " \
                 "a deletion removes it with the capability. If it is only a mention in prose, a " \
                 "whole-line comment is already exempt."

      naming = sources.select { |path| File.file?(path) && names_it_in_code?(path) }
                      .map { |path| path.delete_prefix("#{root}/") }

      expect((naming - own).sort).to eq(consumers.sort), unlisted
    end

    # The manual is not in the glob above and cannot be: it names `:LainThread`
    # and `lain://thread` in prose, and `nvim_plugin_spec.rb`'s own check is
    # one-directional (a documented command must exist, never the reverse). So the
    # stanza would survive a deletion green, leaving a manual entry for a command
    # that is gone. Named here, in the row, so a deletion finds it by failing.
    it "is documented in one stanza of the manual, which goes with it" do
      doc = File.read(File.expand_path("../../../../plugin/nvim/doc/lain.txt", __dir__))

      expect(doc).to include("*:LainThread*").and include("*lain://thread*")
    end
  end
end
