# frozen_string_literal: true

RSpec.describe Lain::Config::Builder do
  let(:path) { ".lain/config.rb" }

  def build(source) = described_class.evaluate(source, path:)

  describe ".evaluate" do
    let(:source) do
      <<~RUBY
        epics home: :repo, width: 3 do
          gate :research, :hands_off
        end
        approval do
          deny_tool "web_fetch"
          allow "bash", command: "bundle exec rspec"
        end
        isolation retain_days: 3
        sensitivity gated: %w[secrets.yml]
        shell exclude: %w[curl]
        tests preset: :rspec
      RUBY
    end

    it "builds every table" do
      built = build(source)

      expect([built.epics.home, built.epics.width, built.epics.gates.policy_for(:research)])
        .to eq([:repo, 3, "hands_off"])
    end

    it "builds the approval table with its tool-wide deny and its remembered allow" do
      approval = build(source).approval

      expect([approval.deny_tools, approval.allow])
        .to eq([["web_fetch"], [{ "tool" => "bash", "input" => { "command" => "bundle exec rspec" } }]])
    end

    it "builds the remaining tables" do
      built = build(source)

      expect([built.isolation.retain_days, built.shell.permits?("curl"), built.tests.preset.name])
        .to eq([3, false, "rspec"])
    end

    it "gates the sensitivity pattern it names" do
      expect(build(source).sensitivity.gated.map(&:label)).to eq(["secrets.yml"])
    end

    it "yields every default for an empty file" do
      expect(build("").to_h.except(:middleware)).to eq(epics: Lain::Config::Epics.new(home: :xdg),
                                                       keys: Lain::Config::Keys.empty,
                                                       approval: Lain::Config::Answers.empty,
                                                       isolation: Lain::Config::Isolation.empty,
                                                       sensitivity: Lain::Sensitivity::Rules.empty,
                                                       shell: Lain::Shell::Exclusions.empty,
                                                       search: Lain::SearchRules.empty,
                                                       tests: nil,
                                                       approval_timeout: 300)
    end

    it "leaves the framework fallback reachable when no tests table is declared" do
      built = build("")

      expect([built.test_layout, built.test_layout(framework: "rspec").preset.name])
        .to eq([Lain::TestLayout::None, "rspec"])
    end

    it "lets a declared tests table win over the detected framework" do
      expect(build("tests preset: :minitest").test_layout(framework: "rspec").preset.name).to eq("minitest")
    end

    it "refuses an unknown verb at its line, naming it and the known verbs" do
      expect { build("\n\n\nshel exclude: %w[curl]\n") }
        .to raise_error(Lain::Config::Refusal, %r{\.lain/config\.rb:4: .*:shel.*epics, approval, isolation})
    end

    it "refuses an unknown verb inside a block at its line" do
      expect { build("approval do\n  alow \"bash\"\nend\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: .*:alow.*allow, deny, deny_tool/)
    end

    it "names the middleware verb among the known verbs" do
      expect { build("\n\n\nshel exclude: %w[curl]\n") }
        .to raise_error(Lain::Config::Refusal,
                        /epics, approval, isolation, sensitivity, shell, search, tests, middleware/)
    end

    it "builds a middleware table whose registrations keep their class and block" do
      built = build(<<~RUBY)
        class Stamp < Lain::Middleware::Base; end
        middleware do
          tool Stamp
          model { |env, &down| down.call(env) }
        end
      RUBY

      expect([built.middleware.members(:tool).map do |m|
        m.class.name.split("::").last
      end, built.middleware.members(:model).map(&:class)])
        .to eq([["Stamp"], [Lain::Middleware::Inline]])
    end

    it "defaults to no members in any area" do
      middleware = build("").middleware

      expect(Lain::Config::Middleware::AREAS.flat_map { |area| middleware.members(area) }).to be_empty
    end

    it "refuses an unknown area at its line, listing the areas" do
      expect { build("class Stamp < Lain::Middleware::Base; end\nmiddleware { modle Stamp }\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: .*:modle.*model, tool, turn, repl, http/)
    end

    it "refuses middleware declared twice" do
      expect { build("middleware { }\nmiddleware { }\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: .*declares middleware twice/)
    end

    it "ignores a block handed to an approval entry as today" do
      expect(build("approval do\n  allow(\"bash\", command: \"x\") { 1 }\nend\n").approval)
        .to eq(build("approval do\n  allow \"bash\", command: \"x\"\nend\n").approval)
    end

    it "keeps a semantic refusal, at the line of the verb" do
      expect { build("\nisolation retain_days: 0\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: `isolation` retain_days: 0 .*at least 1/)
    end

    it "refuses a gate with the wrong number of arguments at its line" do
      expect { build("epics do\n  gate :research\nend\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: /)
    end

    it "translates Ruby's own argument error into a refusal at the user's line" do
      expect { build("\nisolation 3\n") }.to raise_error(Lain::Config::Refusal, /config\.rb:2: /)
    end

    it "translates a type error at the user's line" do
      expect { build("\nsensitivity gated: %w[a] + nil\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: /)
    end

    it "translates a NoMethodError at the user's line" do
      expect { build("\nshell exclude: %w[curl].frist\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: .*frist/)
    end

    it "translates a NameError at the user's line" do
      expect { build("\nshell exclude: [Curl]\n") }.to raise_error(Lain::Config::Refusal, /config\.rb:2: .*Curl/)
    end

    it "translates a SyntaxError" do
      expect { build("\nshell exclude: [\n") }.to raise_error(Lain::Config::Refusal, /config\.rb:/)
    end

    it "translates a plain raise at its line" do
      expect { build("\nraise \"boom\"\n") }.to raise_error(Lain::Config::Refusal, /config\.rb:2: boom/)
    end

    it "refuses the Kernel#test typo of tests as an unknown verb" do
      expect { build("test preset: :rspec\n") }.to raise_error(Lain::Config::Refusal, /config\.rb:1: .*:test/)
    end

    it "reads a source string carried in another encoding as UTF-8" do
      source = (+"shell exclude: %w[résumé]\n").force_encoding(Encoding::US_ASCII)

      expect(build(source).shell.patterns).to eq(["résumé"])
    end

    it "refuses a field beside deny_tool, naming it as the file wrote it" do
      expect { build("approval do\n  deny_tool \"bash\", command: \"rm\"\nend\n") }
        .to raise_error(Lain::Config::Refusal,
                        /config\.rb:2: `deny_tool` takes a tool name and no fields, got command: "rm"\z/)
    end

    it "refuses an extra positional argument to allow" do
      expect { build("approval do\n  allow \"bash\", \"oops\", command: \"x\"\nend\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: /)
    end

    it "accepts an allow for a tool that takes no fields" do
      expect(build("approval do\n  allow \"list_skills\"\nend\n").approval.allow)
        .to eq([{ "tool" => "list_skills", "input" => {} }])
    end

    it "refuses a duplicate gate at its line" do
      expect { build("epics do\n  gate :research, :hands_off\n  gate :research, :interactive\nend\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:3: .*research/)
    end

    it "refuses gates given both as a keyword and as a block" do
      expect { build("epics gates: { research: :hands_off } do\n  gate :implementation, :hands_off\nend\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:1: .*both as a keyword and as a block/)
    end

    it "refuses the same key given as a symbol and as a string" do
      expect { build("shell exclude: %w[curl], \"exclude\" => []\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:1: `shell` .*exclude.*twice/)
    end

    it "carries file:line as the path of a translated refusal" do
      expect { build("\nraise \"boom\"\n") }
        .to raise_error(Lain::Config::Refusal) { |e| expect(e.path).to eq(".lain/config.rb:2") }
    end

    it "names the line of the approval entry that is wrong" do
      expect { build("approval do\n  deny \"bash\", command: \"x\"\n  allow \"bash\", command: [\"a\"]\nend\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:3: /)
    end

    it "carries the table an epics refusal is about" do
      expect { build("epics width: 0\n") }.to raise_error(Lain::Config::Refusal) { |e| expect(e.table).to eq("`epics`") }
    end

    it "refuses a table declared twice" do
      expect { build("shell exclude: []\nshell exclude: []\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: `shell` declares shell twice/)
    end
  end

  describe "the user's config.rb" do
    let(:path) { "/home/someone/.config/lain/config.rb" }

    def build_user(source) = described_class.evaluate(source, path:, verbs: described_class::USER_VERBS)

    it "builds a middleware table" do
      built = build_user("middleware { model { |env, &down| down.call(env) } }\n")

      expect(built.middleware.members(:model).map(&:class)).to eq([Lain::Middleware::Inline])
    end

    it "refuses a project table at its line, saying where it belongs" do
      expect { build_user("shell exclude: [\"rm\"]\n") }
        .to raise_error(Lain::Config::Refusal,
                        %r{\A#{Regexp.escape(path)}:1: .*shell belongs in a project's \.lain/config\.rb})
    end

    it "refuses a block-taking project table before running its block" do
      expect { build_user("approval do\n  raise \"ran\"\nend\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:1: .*approval belongs in a project's/)
    end

    it "lists only the user's verbs as known" do
      expect { build_user("\nmiddlewear { }\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: .*:middlewear; known verbs: middleware, keys\z/)
    end

    it "builds a keys table" do
      expect(build_user("keys approval_cycle: \"s-tab\"\n").keys.approval_cycle).to eq("s-tab")
    end

    it "leaves the approval cycle at Shift+Tab when keys is not declared" do
      expect(build_user("").keys.approval_cycle).to eq("S-Tab")
    end

    it "names the line of a key it refuses" do
      expect { build_user("\nkeys approval_cycle: \"Hyper-Q\"\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:2: .*Hyper-Q/)
    end
  end

  describe "a project's config.rb" do
    it "refuses keys as a verb only the user's config may use" do
      expect { build("keys approval_cycle: \"C-x\"\n") }
        .to raise_error(Lain::Config::Refusal, /config\.rb:1: .*keys belongs in the user's config\.rb/)
    end
  end
end
