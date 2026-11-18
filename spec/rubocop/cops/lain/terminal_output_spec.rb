# frozen_string_literal: true

require "open3"
require "rubocop"
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require_relative "../../../../.rubocop/lain"

# CopHelper and ExpectOffense are included in this group alone: rubocop/rspec/support
# includes them in every group of whichever parallel worker loads this file.
RSpec.describe RuboCop::Cop::Lain::TerminalOutput do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  let(:config) { RuboCop::Config.new("AllCops" => { "DisplayCopNames" => false }) }
  let(:ruby_version) { 3.2 }
  let(:cop) { described_class.new(config) }

  it "flags a bare puts, and says where the output goes instead" do
    offenses = expect_offense(<<~RUBY, "lib/lain/x.rb")
      puts "hi"
      ^^^^ `puts` writes to the terminal. [...]
    RUBY

    expect(offenses.map(&:message)).to all(include("Lain::Sink", "lib/lain/frontend/", ".rubocop.yml"))
  end

  it "flags warn, the terminal globals and the terminal constants, bare or qualified" do
    expect_offense(<<~RUBY)
      warn "x"
      ^^^^ `warn` writes to the terminal. [...]
      $stdout.write("x")
      ^^^^^^^ `$stdout` writes to the terminal. [...]
      STDERR.write("x")
      ^^^^^^ `STDERR` writes to the terminal. [...]
      Foo::STDOUT.write("x")
      ^^^^^^^^^^^ `Foo::STDOUT` writes to the terminal. [...]
    RUBY
  end

  it "flags rebinding a terminal global" do
    expect_offense(<<~RUBY)
      $stderr = StringIO.new
      ^^^^^^^ `$stderr` writes to the terminal. [...]
    RUBY
  end

  it "does not flag a comment, a string, a call with a receiver, or a method named puts" do
    expect_no_offenses(<<~RUBY)
      # this comment mentions puts and $stdout and STDERR
      x = "a string with puts and warn and $stderr in it"
      sink.puts("attributed")
      logger.print(x)
      def puts(*) = nil
    RUBY
  end

  describe "through the real .rubocop.yml", :seam do
    let(:root) { File.expand_path("../../../..", __dir__) }

    def rubocop(*args, chdir:)
      env = { "BUNDLE_GEMFILE" => File.join(root, "Gemfile") }
      Open3.capture3(env, "bundle", "exec", "rubocop", "--only", "Lain/TerminalOutput", *args, chdir:)
    end

    def plant(tree, path, source)
      FileUtils.mkdir_p(File.dirname(File.join(tree, path)))
      File.write(File.join(tree, path), "# frozen_string_literal: true\n\n#{source}\n")
    end

    it "names a planted write, and spares the frontend and the forked run's spawner" do
      Dir.mktmpdir do |tree|
        FileUtils.cp(File.join(root, ".rubocop.yml"), tree)
        FileUtils.cp_r(File.join(root, ".rubocop"), tree)
        plant(tree, "lib/lain/scratch.rb", '$stderr.write("x")')
        plant(tree, "lib/lain/daemon/spawner.rb", "$stdout.reopen(log)")
        plant(tree, "lib/lain/frontend/tty.rb", 'puts "hi"')

        out, err, status = rubocop("--cache", "false", "--format", "json", chdir: tree)
        offended = JSON.parse(out).fetch("files").reject { |file| file["offenses"].empty? }.map { |file| file["path"] }

        expect([status.exitstatus, offended]).to eq([1, ["lib/lain/scratch.rb"]]), err
      end
    end
  end
end
