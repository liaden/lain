# frozen_string_literal: true

RSpec.describe Lain::Config::Keys do
  it "defaults the approval cycle to Shift+Tab" do
    expect(described_class.empty.approval_cycle).to eq("S-Tab")
  end

  it "reads a declared approval cycle" do
    expect(described_class.from({ "approval_cycle" => "s-tab" }, path: "/u/config.rb:1").approval_cycle).to eq("s-tab")
  end

  it "refuses a control key the line editor holds, naming the action" do
    expect { described_class.from({ "approval_cycle" => "C-t" }, path: "/u/config.rb:2") }
      .to raise_error(Lain::Config::Refusal, %r{\A/u/config\.rb:2: .*C-t .*line editor.*ed_transpose_chars})
  end

  it "refuses the completion key by name" do
    expect { described_class.from({ "approval_cycle" => "C-x" }, path: "/u/config.rb:4") }
      .to raise_error(Lain::Config::Refusal, %r{\A/u/config\.rb:4: .*C-x is lain's completion key})
  end

  it "refuses the compose key by name, whatever its case" do
    expect { described_class.from({ "approval_cycle" => "c-G" }, path: nil) }
      .to raise_error(Lain::Config::Refusal, /c-G is lain's compose key/)
  end

  it "says in its accepted forms which control keys work" do
    expect { described_class.from({ "approval_cycle" => "Hyper-Q" }, path: nil) }
      .to raise_error(Lain::Config::Refusal, /S-Tab.*the key that works/)
  end

  it "refuses an unknown key name, naming the line and the accepted forms" do
    expect { described_class.from({ "approval_cycle" => "Hyper-Q" }, path: "/u/config.rb:3") }
      .to raise_error(Lain::Config::Refusal, %r{\A/u/config\.rb:3: `keys` .*"S-Tab".*"Hyper-Q"})
  end

  it "refuses a value that is not a string" do
    expect { described_class.from({ "approval_cycle" => 7 }, path: nil) }
      .to raise_error(Lain::Config::Refusal, /approval_cycle.*7/)
  end

  it "refuses a key it does not know" do
    expect { described_class.from({ "approval_cyle" => "C-x" }, path: nil) }
      .to raise_error(Lain::Config::Refusal, /approval_cyle.*approval_cycle/)
  end

  describe "under an inputrc that binds Shift+Tab" do
    around do |example|
      Dir.mktmpdir do |dir|
        path = File.join(dir, "inputrc")
        File.write(path, "\"\\e[Z\": menu-complete-backward\n")
        with_env("INPUTRC" => path) do
          Reline.core.config.reset_variables
          Lain::Frontend::LineEditor.unbind_all
          example.run
        ensure
          Reline.core.config.reset_variables
          Lain::Frontend::LineEditor.unbind_all
        end
      end
    end

    it "leaves the undeclared default alone, so a user who never wrote keys still loads" do
      expect(described_class.empty.approval_cycle).to eq("S-Tab")
    end

    it "refuses a declared S-Tab by name" do
      expect { described_class.from({ "approval_cycle" => "S-Tab" }, path: "/u/config.rb:5") }
        .to raise_error(Lain::Config::Refusal, %r{\A/u/config\.rb:5: .*S-Tab is held by .*inputrc})
    end
  end
end
