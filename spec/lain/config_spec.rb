# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"

RSpec.describe Lain::Config do
  describe "absence is all defaults" do
    it "resolves epics_home to :xdg without raising" do
      Dir.mktmpdir do |root|
        config = described_class.load(root:)

        expect(config.epics_home).to eq(:xdg)
      end
    end

    it "is the same value .empty returns" do
      Dir.mktmpdir do |root|
        expect(described_class.load(root:)).to eq(described_class.empty)
      end
    end

    it "gives the worktree lifecycle its ruled defaults" do
      Dir.mktmpdir do |root|
        expect(described_class.load(root:).isolation.to_h)
          .to eq(retain_days: 7, rebase_retries: 1, diff_algorithm: "histogram", conflict_style: "zdiff3",
                 verifier: "command", verify: [], verify_timeout: 1800, verify_keep: ["target/"],
                 batch_cap: 8, rebuild_cap: 3, check: [], lint: [], lint_files: [], check_retries: 1)
      end
    end
  end

  describe "the isolation table" do
    it "is read by .load" do
      Dir.mktmpdir do |root|
        write_config(root, "isolation retain_days: 3, rebase_retries: 0\n")

        expect(described_class.load(root:).isolation.to_h)
          .to include(retain_days: 3, rebase_retries: 0)
      end
    end

    it "refuses a bad value, naming the key and the file's line" do
      Dir.mktmpdir do |root|
        write_config(root, "\nisolation retain_days: -1\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(config_path(root))}:2.*retain_days/)
      end
    end

    it "reads a hand-built table through the same rules, rather than accepting it silently" do
      epics = Lain::Config::Epics.new(home: :xdg)

      expect(described_class.new(epics:, isolation: { "retain_days" => 3 }).isolation.retain_days).to eq(3)
      expect { described_class.new(epics:, isolation: { "retian_days" => 3 }) }
        .to raise_error(Lain::Config::Refusal, /retian_days/)
      expect { described_class.new(epics:, isolation: 3) }
        .to raise_error(Lain::Config::Refusal, /`isolation` must be a table/)
    end

    it "refuses a misspelt key, naming the key and the file" do
      Dir.mktmpdir do |root|
        write_config(root, "isolation retian_days: 7\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(config_path(root))}.*retian_days/)
      end
    end
  end

  describe "the approval timeout" do
    it "is 300 seconds when no config declares one" do
      Dir.mktmpdir do |root|
        expect(described_class.approval_timeout(root:)).to eq(300)
      end
    end

    it "is 300 seconds when the approval table sets no timeout" do
      Dir.mktmpdir do |root|
        write_config(root, "approval do\n  deny_tool \"web_fetch\"\nend\n")

        expect(described_class.approval_timeout(root:)).to eq(300)
      end
    end

    it "reads the timeout the approval table declares" do
      Dir.mktmpdir do |root|
        write_config(root, "approval timeout: 900\n")

        expect(described_class.approval_timeout(root:)).to eq(900)
      end
    end

    it "keeps the table's rules beside the timeout" do
      Dir.mktmpdir do |root|
        write_config(root, "approval timeout: 900 do\n  deny_tool \"web_fetch\"\nend\n")

        expect([described_class.approval_timeout(root:), described_class.load(root:).approval.deny_tools])
          .to eq([900, ["web_fetch"]])
      end
    end

    it "refuses a timeout of 0, naming it and saying it must be above 0" do
      Dir.mktmpdir do |root|
        write_config(root, "\napproval timeout: 0\n")

        expect { described_class.approval_timeout(root:) }
          .to raise_error(Lain::Config::Refusal, /config\.rb:2.*timeout.*must be above 0/)
      end
    end

    it "refuses a timeout that is not a number" do
      Dir.mktmpdir do |root|
        write_config(root, "approval timeout: \"soon\"\n")

        expect { described_class.approval_timeout(root:) }
          .to raise_error(Lain::Config::Refusal, /timeout.*must be above 0/)
      end
    end

    it "refuses a timeout that is not finite" do
      Dir.mktmpdir do |root|
        write_config(root, "approval timeout: Float::INFINITY\n")

        expect { described_class.approval_timeout(root:) }
          .to raise_error(Lain::Config::Refusal, /timeout.*must be above 0/)
      end
    end

    it "is refused while the file is untrusted" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, ".lain"))
        File.write(config_path(root), "# #{SecureRandom.hex}\napproval timeout: 900\n")

        expect { described_class.approval_timeout(root:) }.to raise_error(Lain::Project::Trust::Untrusted)
      end
    end
  end

  describe "the search table" do
    it "is empty when the file or the table is absent" do
      Dir.mktmpdir do |root|
        expect(described_class.search(root:)).to eq(Lain::SearchRules.empty)
      end
    end

    it "reads the include globs and the limits" do
      Dir.mktmpdir do |root|
        write_config(root, "search include: [\"notes/**/*.md\"], max_entries: 5, max_bytes: 10\n")

        rules = described_class.search(root:)

        expect([rules.include, rules.limit.entries, rules.limit.bytes]).to eq([["notes/**/*.md"], 5, 10])
      end
    end

    it "refuses a misspelt key, naming it, the file's line and the known keys" do
      Dir.mktmpdir do |root|
        write_config(root, "\nsearch incldue: [\"x\"]\n")

        expect { described_class.search(root:) }
          .to raise_error(Lain::Config::Refusal, /config\.rb:2.*incldue.*include, max_entries, max_bytes/)
      end
    end

    it "refuses an include glob that leaves the project" do
      Dir.mktmpdir do |root|
        write_config(root, "search include: [\"../other/**\"]\n")

        expect { described_class.search(root:) }
          .to raise_error(Lain::Config::Refusal, %r{\.\./other/\*\*.*stay under the project root})
      end
    end

    it "is refused while the file is untrusted" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, ".lain"))
        File.write(config_path(root), "search max_entries: 5\n")

        expect { described_class.search(root:) }.to raise_error(Lain::Project::Trust::Untrusted)
      end
    end
  end

  describe "a file Ruby cannot run" do
    it "refuses a syntax error, naming the file and line" do
      Dir.mktmpdir do |root|
        write_config(root, "epics home: :repo\nshell exclude: [\n")

        expect { described_class.load(root:) }
          .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(config_path(root))}:\d+/)
      end
    end

    it "refuses every reader alike, since the file is evaluated whole" do
      Dir.mktmpdir do |root|
        write_config(root, "epics home: :nowhere\nshell exclude: %w[curl]\n")

        expect { described_class.shell_exclusions(root:) }.to raise_error(Lain::Config::Refusal, /home/)
      end
    end
  end

  describe "trust" do
    # The spec state home is shared by the process, so the bytes are made
    # unique: a mark another example granted must not make these trusted.
    it "never evaluates an untrusted file" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, ".lain"))
        File.write(config_path(root), "# #{SecureRandom.hex}\nshell exclude: %w[curl]\n")
        allow(Lain::Config::Builder).to receive(:evaluate).and_call_original

        expect { described_class.load(root:) }.to raise_error(Lain::Project::Trust::Untrusted, /lain trust/)
        expect(Lain::Config::Builder).not_to have_received(:evaluate)
      end
    end

    it "is refused while a sibling .lain/*.rb is untrusted, since trust covers the set" do
      Dir.mktmpdir do |root|
        write_config(root, "shell exclude: %w[curl]\n")
        File.write(File.join(root, ".lain", "services.rb"), "# #{SecureRandom.hex}\n")

        expect { described_class.shell_exclusions(root:) }.to raise_error(Lain::Project::Trust::Untrusted)
      end
    end
  end

  describe "evaluation" do
    def unique = "# #{SecureRandom.hex}\n"

    it "evaluates the bytes trust judged, even when the file changes after they were read" do
      Dir.mktmpdir do |root|
        write_config(root, "#{unique}shell exclude: %w[curl]\n")
        allow(Lain::Project::Trust).to receive(:for).and_wrap_original do |original, **kwargs|
          original.call(**kwargs).tap { File.write(config_path(root), "shell exclude: %w[wget]\n") }
        end

        exclusions = described_class.shell_exclusions(root:)

        expect([exclusions.permits?("curl"), exclusions.permits?("wget")]).to eq([false, true])
      end
    end

    it "evaluates two roots holding the same bytes apart" do
      Dir.mktmpdir do |one|
        Dir.mktmpdir do |two|
          body = "#{unique}tests preset: :rspec\n"
          write_config(one, body)
          write_config(two, body)
          allow(Lain::Config::Builder).to receive(:evaluate).and_call_original

          described_class.test_layout(root: one)
          described_class.test_layout(root: two)

          expect(Lain::Config::Builder).to have_received(:evaluate).twice
        end
      end
    end

    it "runs a failing file once, refusing every reader with the same refusal" do
      Dir.mktmpdir do |root|
        write_config(root, "#{unique}nosuch 1\n")
        allow(Lain::Config::Builder).to receive(:evaluate).and_call_original

        refusals = %i[load sensitivity shell_exclusions test_layout].map do |reader|
          described_class.public_send(reader, root:)
        rescue Lain::Config::Refusal => e
          e.message
        end

        expect(Lain::Config::Builder).to have_received(:evaluate).once
        expect(refusals.uniq).to contain_exactly(a_string_including("nosuch"))
      end
    end

    it "refuses a file already evaluated once its trust mark is gone" do
      Dir.mktmpdir do |root|
        write_config(root, "#{unique}shell exclude: %w[curl]\n")
        described_class.shell_exclusions(root:)
        trust = Lain::Project::Trust.for(project_dir: Lain::ProjectDir.new(root:))
        File.delete(Lain::Project::Trust::Record.new.path_for(trust.digest))

        expect { described_class.shell_exclusions(root:) }.to raise_error(Lain::Project::Trust::Untrusted)
      end
    end

    # The restricting tables would be dropped in silence if this read as an
    # absent file.
    it "refuses a config.rb that is not a regular file" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(config_path(root))

        expect { described_class.shell_exclusions(root:) }
          .to raise_error(Lain::Project::Trust::Unreadable, /#{Regexp.escape(config_path(root))}/)
      end
    end

    it "evaluates the file once for all four readers in one process" do
      Dir.mktmpdir do |root|
        write_config(root, "shell exclude: %w[curl]\ntests preset: :rspec\n")
        allow(Lain::Config::Builder).to receive(:evaluate).and_call_original

        described_class.load(root:)
        described_class.sensitivity(root:)
        described_class.shell_exclusions(root:)
        described_class.test_layout(root:)

        expect(Lain::Config::Builder).to have_received(:evaluate).once
      end
    end

    it "evaluates an edited file afresh once its new bytes are trusted" do
      Dir.mktmpdir do |root|
        write_config(root, "shell exclude: %w[curl]\n")
        described_class.shell_exclusions(root:)
        write_config(root, "shell exclude: %w[wget]\n")

        expect(described_class.shell_exclusions(root:).permits?("curl")).to be(true)
      end
    end
  end

  describe "an absent table" do
    it "loads and epics_home is still the default" do
      Dir.mktmpdir do |root|
        write_config(root, "shell exclude: %w[curl]\n")

        expect(described_class.load(root:).epics_home).to eq(:xdg)
      end
    end
  end

  describe "Config.empty" do
    it "is deeply frozen" do
      expect(described_class.empty).to be_deeply_frozen
    end

    # Panel probe: .empty allocated a fresh instance on every call; a real
    # Null Object is one singleton, not a factory.
    it "is the same object every time, not a fresh allocation" do
      expect(described_class.empty).to equal(described_class.empty)
    end
  end

  describe "equality" do
    it "is symmetric for a subclass instance (instance_of?, not is_a?)" do
      sub = Class.new(described_class)
      a = described_class.empty
      b = sub.new(epics: Lain::Config::Epics.new(home: :xdg))

      expect(a == b).to eq(b == a)
    end

    it "agrees with #hash: equal values never land in different Hash buckets" do
      a = described_class.empty
      b = described_class.new(epics: Lain::Config::Epics.new(home: :xdg))

      expect(a).to eq(b)
      expect({ a => 1 }[b]).to eq(1)
    end

    # A member that equality forgot is a config that compares equal while
    # remembering different answers -- exactly the bug the epics member's own
    # `instance_of?` note is guarding against one field over.
    it "distinguishes two configs that remember different answers" do
      epics = Lain::Config::Epics.new(home: :xdg)
      a = described_class.new(epics:, approval: { "deny_tool" => [{ "tool" => "bash" }] })
      b = described_class.new(epics:)

      expect(a).not_to eq(b)
      expect(a.hash).not_to eq(b.hash)
    end

    it "distinguishes two configs with different worktree lifecycles" do
      epics = Lain::Config::Epics.new(home: :xdg)
      isolation = Lain::Config::Isolation.from({ "retain_days" => 3 }, path: "config.rb")
      a = described_class.new(epics:, isolation:)
      b = described_class.new(epics:)

      expect(a).not_to eq(b)
      expect(a.hash).not_to eq(b.hash)
    end
  end

  describe ".sensitivity" do
    # No working-directory default, unlike {.load}: the caller holds a resolved
    # project root, and defaulting one here is the divergence the resolved
    # project exists to remove.
    it "takes its root from the caller rather than the working directory" do
      expect { described_class.sensitivity }.to raise_error(ArgumentError, /root/)
    end

    it "compiles the project's patterns into rules the classifier can hold" do
      Dir.mktmpdir do |root|
        write_config(root, "sensitivity denied: %w[*.secret], gated: %w[*.private], exempt: %w[.gitconfig]\n")

        rules = described_class.sensitivity(root:)

        expect([rules.denied.size, rules.gated.size, rules.exempt.size]).to eq([1, 1, 1])
      end
    end

    # Null Object, not nil: an absent table leaves the built-in tables in force,
    # which is the difference between "this project adds nothing" and "this
    # project has no boundary".
    it "answers empty rules when a config file carries no sensitivity table" do
      Dir.mktmpdir do |root|
        write_config(root, "epics home: :repo\n")

        expect(described_class.sensitivity(root:)).to eq(Lain::Sensitivity::Rules.empty)
      end
    end

    it "answers empty rules for a root with no config file at all" do
      Dir.mktmpdir do |root|
        expect(described_class.sensitivity(root:)).to eq(Lain::Sensitivity::Rules.empty)
      end
    end

    it "refuses a list where a keyword belongs, naming the file" do
      Dir.mktmpdir do |root|
        write_config(root, "sensitivity denied: \"*.secret\"\n")

        expect { described_class.sensitivity(root:) }
          .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(config_path(root))}/)
      end
    end

    it "refuses a pattern that could never match, naming the file" do
      Dir.mktmpdir do |root|
        write_config(root, "sensitivity denied: %w[config/secrets/prod.key]\n")

        expect { described_class.sensitivity(root:) }
          .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(config_path(root))}/)
      end
    end
  end

  describe ".shell_exclusions" do
    it "takes its root from the caller rather than the working directory" do
      expect { described_class.shell_exclusions }.to raise_error(ArgumentError, /root/)
    end

    it "permits every program for a root with no config file at all" do
      Dir.mktmpdir do |root|
        expect(described_class.shell_exclusions(root:).permits?("curl")).to be(true)
      end
    end

    it "permits every program when the file carries no shell table" do
      Dir.mktmpdir do |root|
        write_config(root, "epics home: :repo\n")

        expect(described_class.shell_exclusions(root:)).to eq(Lain::Shell::Exclusions.empty)
      end
    end

    it "excludes the programs the table names, by basename" do
      Dir.mktmpdir do |root|
        write_config(root, "shell exclude: %w[curl wget]\n")

        exclusions = described_class.shell_exclusions(root:)

        expect([exclusions.permits?("/usr/bin/curl"), exclusions.permits?("cat")]).to eq([false, true])
      end
    end

    # The strictest posture the file can express, and legal precisely because
    # this table can only ever restrict.
    it "honours a wildcard entry" do
      Dir.mktmpdir do |root|
        write_config(root, "shell exclude: %w[*]\n")

        expect(described_class.shell_exclusions(root:).permits?("cat")).to be(false)
      end
    end

    it "refuses a key it does not read, naming the file" do
      Dir.mktmpdir do |root|
        write_config(root, "shell excluded: %w[curl]\n")

        expect { described_class.shell_exclusions(root:) }
          .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(config_path(root))}/)
      end
    end

    it "refuses a pattern that could never match, naming the file" do
      Dir.mktmpdir do |root|
        write_config(root, "shell exclude: %w[/usr/bin/curl]\n")

        expect { described_class.shell_exclusions(root:) }
          .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(config_path(root))}/)
      end
    end
  end

  describe ".test_layout" do
    it "takes its root from the caller rather than the working directory" do
      expect { described_class.test_layout }.to raise_error(ArgumentError, /root/)
    end

    it "is TestLayout::None for a root with no config file and no detected framework" do
      Dir.mktmpdir do |root|
        expect(described_class.test_layout(root:)).to be(Lain::TestLayout::None)
      end
    end

    it "falls back to a detected framework's preset when the file carries no tests table" do
      Dir.mktmpdir do |root|
        write_config(root, "epics home: :repo\n")

        expect(described_class.test_layout(root:, framework: "rspec").preset.name).to eq("rspec")
      end
    end

    it "reads the table's preset and source roots" do
      Dir.mktmpdir do |root|
        write_config(root, "tests preset: :rspec, source_roots: %w[app]\n")

        expect(described_class.test_layout(root:).mapping.test_path("app/models/order.rb", level: "unit"))
          .to eq("spec/unit/models/order_spec.rb")
      end
    end

    it "refuses a misspelt key, naming the key and the file" do
      Dir.mktmpdir do |root|
        write_config(root, "tests prest: :rspec\n")

        expect { described_class.test_layout(root:) }
          .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(config_path(root))}.*prest/)
      end
    end
  end

  describe ".middleware" do
    let(:stamp) { "class Stamp < Lain::Middleware::Base; end\n" }

    it "takes its root from the caller rather than the working directory" do
      expect { described_class.middleware }.to raise_error(ArgumentError, /root/)
    end

    it "reads a trusted project's registrations" do
      Dir.mktmpdir do |root|
        write_config(root, "#{stamp}middleware do\n  tool Stamp\n  model { |env, &down| down.call(env) }\nend\n")

        middleware = described_class.middleware(root:)

        expect([middleware.members(:tool).size, middleware.members(:model).map(&:class)])
          .to eq([1, [Lain::Middleware::Inline]])
      end
    end

    it "names the file and line of an unknown area" do
      Dir.mktmpdir do |root|
        write_config(root, "#{stamp}middleware { modle Stamp }\n")

        expect { described_class.middleware(root:) }
          .to raise_error(Lain::Config::Refusal, %r{\.lain/config\.rb:2: .*model, tool, turn, repl, http})
      end
    end

    it "answers the empty value for a root with no config file" do
      Dir.mktmpdir do |root|
        expect(described_class.middleware(root:).members(:tool)).to be_empty
      end
    end

    it "refuses an untrusted file before reading any middleware" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, ".lain"))
        File.write(config_path(root), "# #{SecureRandom.hex}\nmiddleware { }\n")

        expect { described_class.middleware(root:) }.to raise_error(Lain::Project::Trust::Untrusted)
      end
    end

    it "evaluates one file once for middleware and the shell table" do
      Dir.mktmpdir do |root|
        write_config(root, "#{stamp}middleware { tool Stamp }\nshell exclude: %w[curl]\n")
        allow(Lain::Config::Builder).to receive(:evaluate).and_call_original

        described_class.middleware(root:)
        described_class.shell_exclusions(root:)

        expect(Lain::Config::Builder).to have_received(:evaluate).once
      end
    end
  end

  describe ".middleware with the user's config.rb" do
    around do |example|
      Dir.mktmpdir("lain-user-config") do |tmp|
        @tmp = tmp
        example.run
      end
    end

    # Its own config and state home, so no other example's file or mark is seen.
    let(:paths) do
      Lain::Paths.new(env: { "HOME" => @tmp, "XDG_CONFIG_HOME" => File.join(@tmp, "config"),
                             "XDG_STATE_HOME" => File.join(@tmp, "state") })
    end
    let(:root) { File.join(@tmp, "project").tap { |dir| FileUtils.mkdir_p(dir) } }

    def middleware_class(name) = "class #{name} < Lain::Middleware::Base; end\n"

    def write_user(body, trusted: true)
      FileUtils.mkdir_p(File.dirname(paths.user_config))
      File.write(paths.user_config, body)
      Lain::Project::Trust.for_user(paths:).grant! if trusted
    end

    def names(members) = members.map { |member| member.class.name.split("::").last }

    it "puts the user's registrations before the project's" do
      write_user("#{middleware_class("A")}middleware { tool A }\n")
      write_config(root, "#{middleware_class("B")}middleware { tool B }\n", paths:)

      expect(names(described_class.middleware(root:, paths:).members(:tool))).to eq(%w[A B])
    end

    it "reads the user file alone when the root has no .lain/" do
      write_user("#{middleware_class("A")}middleware { model A }\n")

      expect(names(described_class.middleware(root:, paths:).members(:model))).to eq(%w[A])
    end

    it "finds the user mark and the project mark in the injected state home" do
      write_user("# #{SecureRandom.hex}\n#{middleware_class("A")}middleware { turn A }\n")
      write_config(root, "# #{SecureRandom.hex}\n#{middleware_class("B")}middleware { turn B }\n", paths:)

      expect(names(described_class.middleware(root:, paths:).members(:turn))).to eq(%w[A B])
    end

    it "refuses an untrusted user file, naming it, its reach, and the remedy" do
      write_user("middleware { }\n", trusted: false)

      expect { described_class.middleware(root:, paths:) }.to raise_error(Lain::Project::Trust::Untrusted) { |error|
        expect(error.message).to include(paths.user_config).and include("every project")
          .and include("lain trust --user")
      }
    end

    it "is not trusted by a project mark over the same bytes" do
      body = "middleware { }\n"
      write_config(root, body, paths:)
      write_user(body, trusted: false)

      expect { described_class.middleware(root:, paths:) }
        .to raise_error(Lain::Project::Trust::Untrusted, /#{Regexp.escape(paths.user_config)}/)
    end

    it "loses its trust when one byte changes" do
      write_user("middleware { }\n")
      File.write(paths.user_config, "middleware { }\t")

      expect { described_class.middleware(root:, paths:) }.to raise_error(Lain::Project::Trust::Untrusted)
    end

    it "evaluates the bytes trust judged, even when the file changes after they were read" do
      write_user("#{middleware_class("A")}middleware { model A }\n")
      allow(Lain::Project::Trust).to receive(:for_user).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap do
          File.write(paths.user_config, "#{middleware_class("B")}middleware { model B }\n")
        end
      end

      expect(names(described_class.middleware(root:, paths:).members(:model))).to eq(%w[A])
    end

    it "refuses a project table in the user file at its line" do
      write_user("shell exclude: [\"rm\"]\n")

      expect { described_class.middleware(root:, paths:) }
        .to raise_error(Lain::Config::Refusal,
                        %r{#{Regexp.escape(paths.user_config)}:1: .*shell belongs in a project's \.lain/config\.rb})
    end

    it "refuses a user config.rb that is not a regular file" do
      FileUtils.mkdir_p(paths.user_config)

      expect { described_class.middleware(root:, paths:) }
        .to raise_error(Lain::Project::Trust::Unreadable, /#{Regexp.escape(paths.user_config)}/)
    end

    it "reads the approval cycle key the user declared" do
      write_user("keys approval_cycle: \"C-x\"\n")

      expect(described_class.keys(paths:).approval_cycle).to eq("C-x")
    end

    it "is Shift+Tab when the user has no config.rb" do
      expect(described_class.keys(paths:).approval_cycle).to eq("S-Tab")
    end

    it "refuses an unknown key name at the user's file and line" do
      write_user("\nkeys approval_cycle: \"Hyper-Q\"\n")

      expect { described_class.keys(paths:) }
        .to raise_error(Lain::Config::Refusal, /#{Regexp.escape(paths.user_config)}:2: .*Hyper-Q/)
    end

    it "refuses keys in a project's config.rb" do
      write_config(root, "keys approval_cycle: \"C-x\"\n", paths:)

      expect { described_class.middleware(root:, paths:) }
        .to raise_error(Lain::Config::Refusal, /keys belongs in the user's config\.rb/)
    end

    it "is never read by the project's own readers" do
      with_env("XDG_CONFIG_HOME" => File.join(@tmp, "config")) do
        write_user("# #{SecureRandom.hex}\nmiddleware { }\n", trusted: false)
        write_config(root, "shell exclude: %w[curl]\nisolation retain_days: 3\n")

        expect([described_class.shell_exclusions(root:).permits?("curl"),
                described_class.load(root:).isolation.retain_days])
          .to eq([false, 3])
        expect { described_class.middleware(root:) }.to raise_error(Lain::Project::Trust::Untrusted)
      end
    end
  end
end
