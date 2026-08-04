# frozen_string_literal: true

# T26: where a review's surface opens. The value exists so the SECOND placement
# is additive, and today it has exactly one legal member -- so the examples that
# matter most here are the refusals, which are the whole reason the object is
# not just a Symbol passed around.
RSpec.describe Lain::Review::Placement do
  describe "the placement the review actually has" do
    it "opens in a tabpage" do
      expect(described_class.new(kind: :tabpage).kind).to eq(:tabpage)
    end

    it "names that placement as the default, so no caller has to spell it" do
      expect(described_class::DEFAULT.kind).to eq(:tabpage)
    end

    # A placement arrives from a config file or a CLI flag as often as from
    # Ruby, and both hand over Strings. Coercing the SPELLING is not the same as
    # widening the set: an unknown String is refused exactly as an unknown
    # Symbol is.
    it "reads the String spelling as the same placement" do
      expect(described_class.new(kind: "tabpage")).to eq(described_class::DEFAULT)
    end

    it "is deeply frozen, like every value object here" do
      expect(Ractor.shareable?(described_class::DEFAULT)).to be(true)
    end
  end

  describe "the placement that is deliberately out of scope" do
    it "refuses :tmux_window, naming it" do
      expect { described_class.new(kind: :tmux_window) }
        .to raise_error(described_class::Unsupported, /:tmux_window/)
    end

    # The distinction the message has to carry: :tmux_window is not a typo and
    # not a placement nobody thought of. It is a known placement blocked on an
    # architecture change, and a reader who cannot tell those apart will "fix"
    # it by adding the Symbol to the set.
    it "says a second editor attachment is what is missing" do
      expect { described_class.new(kind: :tmux_window) }
        .to raise_error(described_class::Unsupported, /second editor attachment is not yet supported/)
    end

    it "names the socket as the reason, so the next reader does not rediscover it" do
      expect { described_class.new(kind: :tmux_window) }
        .to raise_error(described_class::Unsupported, /socket/)
    end
  end

  describe "a placement nobody has defined" do
    it "refuses it by name" do
      expect { described_class.new(kind: :floating_window) }
        .to raise_error(described_class::Unsupported, /:floating_window/)
    end

    it "names the placements that do exist" do
      expect { described_class.new(kind: :floating_window) }
        .to raise_error(described_class::Unsupported, /:tabpage/)
    end

    # nil answers `to_sym` with a NoMethodError rather than a refusal, which
    # would name Symbol instead of naming the placement -- and nil is the value
    # a missing config key hands over.
    it "refuses a value that is not a name at all, without dying on the coercion" do
      expect { described_class.new(kind: nil) }
        .to raise_error(described_class::Unsupported, /nil/)
    end
  end
end
