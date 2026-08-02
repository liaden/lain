# frozen_string_literal: true

# T8: the mode as the HUD publishes it. StatusFeed's own spec covers what
# reaches `.lain/state.json` and when a flip earns a write; this one covers the
# composition itself -- which is where the "one rule, one home" argument for
# publishing a composed lighter instead of the raw names actually has to hold.
RSpec.describe Lain::StatusFeed::ModeState do
  def record(to:, to_layers: [], from: :manual, from_layers: [], surface: "tty")
    Lain::Telemetry::ModeSwitch.new(from:, to:, from_layers:, to_layers:, surface:)
  end

  describe ".of" do
    it "reads the `to` side, since a HUD publishes what is in force now" do
      state = described_class.of(record(from: :auto, to: :plan))

      expect(state.published).to eq({ "posture" => "plan", "layers" => [], "mode_lighter" => "PLAN" })
    end

    # The exclusive slot already shipped as data; publishing the composable
    # half only as a substring of a rendered string was an asymmetry with no
    # argument behind it. A bench arm asks a set, not a `String#include?`.
    it "publishes the layer names as data beside the rendered lighter" do
      state = described_class.of(record(to: :manual, to_layers: %i[auto_approve goal]))

      expect(state.published["layers"]).to eq(%w[auto_approve goal])
    end

    it "publishes a name the lighter dropped, so an empty lighter still names what is on" do
      state = described_class.of(record(to: :accept_edits, to_layers: %i[auto_approve]))

      expect(state.published.values_at("posture", "layers")).to eq(["accept_edits", %w[auto_approve]])
    end

    it "appends every active layer's lighter after the posture's" do
      state = described_class.of(record(to: :manual, to_layers: %i[auto_approve goal]))

      expect(state.published["mode_lighter"]).to eq("MAN AA GOAL")
    end

    # The record's own doc promises precedence order, so this reads that order
    # rather than re-deriving it -- a second copy of a rule LayerSet owns.
    it "keeps the record's layer order, which LayerSet already canonicalized" do
      layers = Lain::Mode.new(posture: :manual, layers: %i[goal auto_approve]).layers.names

      expect(described_class.of(record(to: :manual, to_layers: layers)).published["mode_lighter"])
        .to eq("MAN AA GOAL")
    end

    # accept_edits declares an EMPTY lighter: the default posture is silent, and
    # that rule lives in Posture's table rather than in three renderers.
    it "composes an empty lighter for the silent default posture" do
      state = described_class.of(record(to: :accept_edits))

      expect(state.published).to eq({ "posture" => "accept_edits", "layers" => [], "mode_lighter" => "" })
    end

    it "still names the layers under a posture whose own lighter is empty" do
      state = described_class.of(record(to: :accept_edits, to_layers: %i[auto_approve]))

      expect(state.published["mode_lighter"]).to eq("AA")
    end

    # Posture.for/Layer.for raise ArgumentError on an undeclared name, and
    # StatusFeed rides the JournalTee, which re-raises a sink's failure -- so a
    # record from a newer lain would cost the agent its turn over a status line.
    it "renders a posture this build does not declare as itself, rather than raising" do
      expect { described_class.of(record(to: :turbo)) }.not_to raise_error
      expect(described_class.of(record(to: :turbo)).published)
        .to eq({ "posture" => "turbo", "layers" => [], "mode_lighter" => "turbo" })
    end

    it "renders a layer this build does not declare as itself, rather than raising" do
      state = described_class.of(record(to: :manual, to_layers: %i[telepathy]))

      expect(state.published["mode_lighter"]).to eq("MAN telepathy")
    end

    # Falling back to "" would be the worse half of the same rescue: a posture
    # nobody here can resolve is exactly the one a human must not be left
    # guessing about, and silence is what the DEFAULT posture earns.
    it "never renders an unresolvable name as the silence the default earns" do
      expect(described_class.of(record(to: :turbo)).published["mode_lighter"]).not_to eq("")
    end

    # mode_lighter is the first free-form string on the HUD, and the
    # degradation path above can put a foreign journal's raw name in it --
    # straight into tmux's status-right, where nothing else bounds the width.
    it "caps the lighter, so a foreign name cannot push the status bar off the screen" do
      state = described_class.of(record(to: "x" * 400))

      expect(state.published["mode_lighter"].length).to eq(described_class::LIGHTER_CAP)
    end

    it "caps by CHARACTERS, so a multibyte name is never sliced into invalid UTF-8" do
      state = described_class.of(record(to: "日" * 400))

      expect(state.published["mode_lighter"]).to eq("日" * described_class::LIGHTER_CAP)
      expect(state.published["mode_lighter"]).to be_valid_encoding
    end

    it "leaves every declared combination untouched -- the cap only trims degradation" do
      state = described_class.of(record(to: :accept_edits, to_layers: Lain::Mode::Layer::NAMES))

      expect(state.published["mode_lighter"]).to eq("AA GOAL NOTIFY VI")
    end
  end

  describe "NONE" do
    # nil layers, not []: an empty list is a perfectly ordinary layer set and
    # would claim "nothing is active" for a feed that was told nothing at all.
    it "publishes absence for every key, so the roster never gains or loses one" do
      expect(described_class::NONE.published)
        .to eq({ "posture" => nil, "layers" => nil, "mode_lighter" => nil })
    end

    it "is a value, so an unchanged mode compares equal and earns no republish" do
      expect(described_class.of(record(to: :plan))).to eq(described_class.of(record(to: :plan)))
      expect(described_class.of(record(to: :plan))).not_to eq(described_class::NONE)
    end
  end
end
