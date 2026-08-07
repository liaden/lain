# frozen_string_literal: true

require "fileutils"
require "ripper"
require "tmpdir"

# Support kept out of the RSpec block (Lint/ConstantDefinitionInBlock). The
# denied-rule table below is built at class-definition time, where `let` does
# not exist, so the home has to be a constant.
module SensitivitySpecSupport
  # A home that is a STRING and nothing else. Every example in this file runs
  # against it without any directory of that name existing, which is half of
  # what "no filesystem access" means; the other half is the stubbed-raise
  # group at the bottom.
  HOME = "/home/tester"
  # Deliberately NOT under HOME, so every relative path in this file resolves
  # somewhere a home-anchored rule cannot reach and the two axes stay separable.
  CWD = "/srv/project"
  # A project checkout that IS under home, for the examples about `..` climbing
  # back out of one.
  NESTED_CWD = "#{HOME}/projects/lain".freeze

  REFUSAL = "the classifier must not touch the filesystem"

  # Every door out of a lexical classifier into the filesystem or the process
  # environment, as `receiver => [[method, *args], ...]`. The args are there so
  # the canary can CALL each one: proving two stubs bit says nothing about the
  # other eleven.
  #
  # `Dir.home` earns its place twice over -- it is the other getpwnam call, and
  # it is exactly what somebody closing the named-tilde hole would reach for.
  FORBIDDEN = {
    "File" => [%i[exist? /tmp], %i[file? /tmp], %i[directory? /tmp], %i[stat /tmp], %i[lstat /tmp],
               %i[readable? /tmp], %i[realpath /tmp], %i[realdirpath /tmp], [:expand_path, "~"],
               [:absolute_path, "x"], %i[read /tmp], %i[readlines /tmp], %i[symlink? /tmp], %i[size /tmp]],
    "Dir" => [[:home], [:home, "someone"], [:pwd], [:glob, "*"], %i[exist? /tmp], %i[entries /tmp],
              %i[children /tmp], [:[], "*"]],
    "FileTest" => [%i[exist? /tmp], %i[file? /tmp], %i[directory? /tmp], %i[readable? /tmp]],
    "IO" => [%i[read /tmp], %i[readlines /tmp]],
    "ENV" => [[:[], "HOME"], [:fetch, "HOME", nil]]
  }.freeze

  # Pathname's instance side: an implementation holding a Pathname could reach
  # the filesystem without ever naming File.
  FORBIDDEN_PATHNAME = %i[exist? directory? symlink? children realpath expand_path].freeze

  # A constant that can reach the filesystem, the environment or a subprocess.
  # `File` is absent because the classifier legitimately calls three PURE
  # methods on it, which the example below pins by name.
  BANNED_CONSTANTS = %w[Dir ENV IO FileTest Kernel Process Open3 FileUtils Tempfile Etc Socket].freeze
  PURE_FILE_METHODS = %w[basename fnmatch?].freeze

  # Ripper, not a text scan, for `output_discipline_spec.rb`'s reason: a trigger
  # word inside a comment or a string literal is not a call, and this file's
  # comments discuss `File.expand_path` at length.
  def self.nodes(sexp, &)
    return unless sexp.is_a?(Array)

    yield sexp
    sexp.each { |child| nodes(child, &) }
  end

  def self.constants_named_in(source)
    found = []
    nodes(Ripper.sexp(source)) { |node| found << node[1] if node[0] == :@const }
    found.uniq
  end

  # `[:call, <File>, [:@period, ...], [:@ident, "basename", ...]]`. The receiver
  # is matched EXACTLY rather than by searching its subtree: the subtree of
  # `File.dirname(path).split(...)` contains "File" too, and reported `split`.
  def self.file_methods_called_in(source)
    found = []
    nodes(Ripper.sexp(source)) do |node|
      found << node[3][1] if node[0] == :call && file_const?(node[1]) && node[3].is_a?(Array)
    end
    found.uniq
  end

  def self.file_const?(receiver)
    receiver.is_a?(Array) && receiver[0] == :var_ref && receiver[1].is_a?(Array) &&
      receiver[1][0] == :@const && receiver[1][1] == "File"
  end

  # Backticks and `%x` are both `xstring_literal` in Ripper's tree; there is no
  # `@backtick` token to look for, which is what the canary caught.
  def self.backticks_in?(source)
    found = false
    nodes(Ripper.sexp(source)) { |node| found ||= node[0] == :xstring_literal }
    found
  end
end

RSpec.describe Lain::Sensitivity do
  let(:home) { SensitivitySpecSupport::HOME }
  let(:cwd) { SensitivitySpecSupport::CWD }
  let(:sensitivity) { described_class.new(home:, cwd:) }

  def classify(path) = sensitivity.classify(path)

  describe "denied paths" do
    it "denies a private key and leaves the public half ordinary" do
      expect(classify("#{home}/.ssh/id_ed25519")).to be_denied
      expect(classify("#{home}/.ssh/id_ed25519.pub")).to be_ordinary
    end

    it "denies a private key by the name it has, not only the algorithm we thought of" do
      expect(classify("#{home}/.ssh/id_rsa")).to be_denied
      expect(classify("#{home}/.ssh/id_dsa")).to be_denied
    end

    it "leaves the rest of ~/.ssh alone, so the rule is id_* and not the directory" do
      expect(classify("#{home}/.ssh/known_hosts")).to be_ordinary
      expect(classify("#{home}/.ssh/config")).to be_ordinary
    end

    # One example per denied rule. Dropping any single entry from the table must
    # turn exactly one of these red -- a single representative example survives
    # deleting eleven of the twelve.
    {
      "#{SensitivitySpecSupport::HOME}/.ssh/id_ed25519" => "an ssh private key",
      "#{SensitivitySpecSupport::HOME}/.gnupg/pubring.kbx" => "anything under ~/.gnupg",
      "#{SensitivitySpecSupport::HOME}/.gnupg/private-keys-v1.d/AB.key" => "a nested ~/.gnupg file",
      "#{SensitivitySpecSupport::HOME}/.aws/credentials" => "aws credentials",
      "#{SensitivitySpecSupport::HOME}/.config/gh/hosts.yml" => "the gh token store",
      "#{SensitivitySpecSupport::HOME}/.netrc" => "a netrc",
      "#{SensitivitySpecSupport::HOME}/vault.kdbx" => "a keepass database anywhere",
      "#{SensitivitySpecSupport::HOME}/.password-store/work/aws.gpg" => "anything under ~/.password-store",
      "#{SensitivitySpecSupport::HOME}/.config/google-chrome/Default/Cookies" => "a browser cookie jar",
      "#{SensitivitySpecSupport::HOME}/.config/google-chrome/Default/Login Data" => "a browser password store",
      "#{SensitivitySpecSupport::HOME}/.mozilla/firefox/abc.default/key4.db" => "a firefox key database",
      "#{SensitivitySpecSupport::HOME}/.docker/config.json" => "a docker registry auth",
      "#{SensitivitySpecSupport::HOME}/.kube/config" => "a kubeconfig"
    }.each do |path, what|
      it "denies #{what}" do
        expect(classify(path)).to be_denied
      end
    end

    it "reports a protected reason rather than a credential-shaped one" do
      verdict = classify("#{home}/.ssh/id_ed25519")

      expect(verdict.reason).to eq(:protected)
      expect(verdict).not_to be_credential
      expect(verdict.explanation).to include("protected")
    end

    # Anchoring these to home is what keeps a source file called `Cookies` in a
    # checkout from being permanently unreadable: a denial is not liftable.
    it "anchors the browser names under home, so a project file of the same name is ordinary" do
      expect(classify("app/models/Cookies")).to be_ordinary
      expect(classify("db/key4.db")).to be_ordinary
    end

    it "denies a home-relative path written with a tilde, without expanding it" do
      expect(classify("~/.ssh/id_ed25519")).to be_denied
      expect(classify("~/.aws/credentials")).to be_denied
    end

    # The home prefix is a whole path SEGMENT, not a string prefix: `/home/tester`
    # must not swallow `/home/tester2`. Nothing else in this file pins the `/` in
    # `descends?`, and dropping it makes these three denied -- an unliftable
    # denial reaching into a NEIGHBOUR's tree, which is the same over-reach the
    # anchoring above exists to prevent.
    it "does not let one home swallow a neighbour whose name merely starts the same" do
      expect(classify("/home/tester2/Cookies")).to be_ordinary
      expect(classify("/home/tester2/.config/google-chrome/Default/Login Data")).to be_ordinary
      expect(classify("/home/tester-old/key4.db")).to be_ordinary
    end

    it "applies that boundary to the gated half too, which shares the same test" do
      expect(classify("/home/tester2/Downloads/report.pdf")).to be_ordinary
      expect(classify("/home/tester2/.kube/config")).to be_ordinary
    end
  end

  # S1. A home-anchored table only ever saw ONE home, so an absolute path into
  # anybody else's -- `/root/.ssh/id_rsa`, `/home/other/.netrc` -- walked
  # straight through. The unambiguous names now match anywhere.
  describe "the unambiguous secrets match anywhere, not only under our home" do
    {
      "/root/.ssh/id_rsa" => "another user's ssh key by absolute path",
      "/home/other/.ssh/id_ed25519" => "a second human's ssh key",
      "/mnt/backup/home/tester/.ssh/id_rsa" => "an ssh key inside a mounted backup",
      "/root/.gnupg/pubring.kbx" => "another user's gnupg store",
      "/home/other/.netrc" => "another user's netrc",
      "/root/.aws/credentials" => "another user's aws credentials",
      "/home/other/.password-store/x.gpg" => "another user's password store",
      "/mnt/usb/vault.kdbx" => "a keepass database on removable media"
    }.each do |path, what|
      it "denies #{what}" do
        expect(classify(path)).to be_denied
      end
    end

    it "keeps the .pub exception everywhere the rule now reaches" do
      expect(classify("/root/.ssh/id_rsa.pub")).to be_ordinary
      expect(classify("/home/other/.ssh/id_ed25519.pub")).to be_ordinary
    end

    it "keeps the rule narrow: .ssh alone is not the secret, id_* is" do
      expect(classify("/root/.ssh/known_hosts")).to be_ordinary
      expect(classify("/root/.ssh/authorized_keys")).to be_ordinary
      expect(classify("#{home}/.ssh")).to be_ordinary
    end

    # A whole-subtree rule has to cover the subtree's ROOT, or T19 lists the
    # directory itself while withholding everything in it. Moving from a
    # home-anchored prefix to an ancestor-segment test lost this.
    it "denies the protected directory itself, not only what is under it" do
      expect(classify("#{home}/.gnupg")).to be_denied
      expect(classify("#{home}/.gnupg/")).to be_denied
      expect(classify("#{home}/.password-store")).to be_denied
      expect(classify("/root/.gnupg")).to be_denied
    end

    it "still requires a whole segment, so a neighbouring name is not the subtree" do
      expect(classify("#{home}/.gnupg-backup/x")).to be_ordinary
      expect(classify("#{home}/.password-store-old")).to be_ordinary
    end

    # The ruling drew this line explicitly: the argument for anchoring was about
    # AMBIGUOUS names, and it survives for them.
    it "leaves the ambiguous names anchored to our home, exactly as before" do
      expect(classify("/root/.config/google-chrome/Default/Cookies")).to be_ordinary
      expect(classify("/root/Downloads/report.pdf")).to be_ordinary
      expect(classify("/root/.kube/config")).to be_ordinary
      expect(classify("/root/.docker/config.json")).to be_ordinary
    end
  end

  describe "a tilde is honoured lexically, whoever it names" do
    it "denies another user's key written with a named tilde" do
      expect(classify("~someone/.ssh/id_rsa")).to be_denied
      expect(classify("~someone/.gnupg/secring.gpg")).to be_denied
    end

    # A named tilde is rewritten to the INJECTED home -- a pure string
    # substitution, never getpwnam -- so the home-anchored half sees it too.
    it "gates another user's personal directory, through the same rewrite" do
      expect(classify("~someone/Downloads/x.pdf")).to be_gated
      expect(classify("~someone/.config/gh/hosts.yml")).to be_denied
    end

    it "treats a bare tilde as the home directory itself" do
      expect(classify("~")).to be_ordinary
      expect(classify("~/.netrc")).to be_denied
    end

    it "leaves a tilde that is not the first segment alone" do
      expect(classify("/tmp/~someone/.ssh/id_rsa")).to be_denied
      expect(classify("/tmp/~backup/notes.md")).to be_ordinary
    end
  end

  describe "gated, credential-shaped" do
    %w[
      .env .env.local .env.production .envrc server.pem bundle.p12 credentials.json
      secrets.yml secrets.yaml .git-credentials .npmrc .pypirc .gitconfig
      terraform.tfstate prod.tfvars
    ].each do |name|
      it "gates #{name} for its credential shape" do
        verdict = classify("project/config/#{name}")

        expect(verdict).to be_gated
        expect(verdict.reason).to eq(:credential)
        expect(verdict).to be_credential
        expect(verdict.explanation).to include("credential")
      end
    end

    it "gates a dotenv variant wherever it sits, root or nested" do
      expect(classify(".env")).to be_gated
      expect(classify("services/api/.env.local")).to be_gated
    end

    it "does not gate a name that merely starts the same way" do
      expect(classify("lib/environment.rb")).to be_ordinary
      expect(classify("doc/envrc.md")).to be_ordinary
    end
  end

  describe "gated, out of scope" do
    %w[Downloads Documents Desktop Pictures].each do |dir|
      it "gates ~/#{dir} for a reason that is not credential shape" do
        verdict = classify("#{home}/#{dir}/report.pdf")

        expect(verdict).to be_gated
        expect(verdict.reason).to eq(:out_of_scope)
        expect(verdict).not_to be_credential
      end
    end

    it "gates the directory itself, not only what is under it" do
      expect(classify("#{home}/Downloads")).to be_gated
    end

    it "leaves a project directory of the same name ordinary, because the rule is anchored at home" do
      expect(classify("site/Documents/index.md")).to be_ordinary
    end
  end

  describe "ordinary paths" do
    it "classes a source file under a project root as ordinary" do
      verdict = classify("lib/lain/session.rb")

      expect(verdict).to be_ordinary
      expect(verdict.reason).to eq(:none)
      expect(verdict).not_to be_credential
    end

    it "classes an absolute source path as ordinary" do
      expect(classify("/srv/lain/lib/lain/session.rb")).to be_ordinary
    end
  end

  describe "config may widen and may never narrow" do
    let(:rules) do
      Lain::Sensitivity::Rules.from({ "denied" => ["*.secret"], "exempt" => ["~/.netrc"] })
    end
    let(:sensitivity) { described_class.new(home:, cwd:, rules:) }

    it "denies a pattern the config added" do
      verdict = classify("x.secret")

      expect(verdict).to be_denied
      expect(verdict.reason).to eq(:configured)
    end

    it "still denies a built-in denied path the config tried to exempt" do
      verdict = classify("#{home}/.netrc")

      expect(verdict).to be_denied
      expect(verdict.reason).to eq(:protected)
    end

    it "lets an exemption lift a GATED path, which is the whole use for the key" do
      rules = Lain::Sensitivity::Rules.from({ "exempt" => [".gitconfig"] })

      expect(described_class.new(home:, cwd:, rules:).classify("project/.gitconfig")).to be_ordinary
    end

    it "gates a pattern the config added at the gated strength" do
      rules = Lain::Sensitivity::Rules.from({ "gated" => ["*.private"] })
      verdict = described_class.new(home:, cwd:, rules:).classify("keys/team.private")

      expect(verdict).to be_gated
      expect(verdict.reason).to eq(:configured)
    end

    it "behaves identically to no config when the table is absent" do
      expect(described_class.new(home:, cwd:, rules: Lain::Sensitivity::Rules.from(nil)).classify(".env")).to be_gated
    end
  end

  # S5. Precedence is expressed as ONE ordered list rather than a check, so the
  # order is the whole rule and every step of it needs its own example. Reordering
  # any adjacent pair must turn exactly one of these red.
  describe "precedence, step by step" do
    def with(table) = described_class.new(home:, cwd:, rules: Lain::Sensitivity::Rules.from(table))

    it "does not let a config exemption lift a config denial" do
      expect(with({ "denied" => ["*.secret"], "exempt" => ["*.secret"] }).classify("x.secret")).to be_denied
    end

    it "does not let a config denial preempt the built-in denied reason" do
      verdict = with({ "denied" => ["~/.netrc"] }).classify("#{home}/.netrc")

      expect(verdict.reason).to eq(:protected)
    end

    it "does not let a config gate preempt the built-in gated reason" do
      verdict = with({ "gated" => [".env"] }).classify("project/.env")

      expect(verdict.reason).to eq(:credential)
    end

    it "does not let a config gate resurrect what an exemption lifted" do
      lifted = with({ "gated" => [".gitconfig"], "exempt" => [".gitconfig"] })

      expect(lifted.classify("project/.gitconfig")).to be_ordinary
    end

    # The one mechanism that makes "why is my file ordinary?" answerable. Without
    # this the reason could collapse to :none and nothing would notice.
    it "says an exemption is what made it ordinary, not that it was never gated" do
      verdict = with({ "exempt" => [".gitconfig"] }).classify("project/.gitconfig")

      expect(verdict.reason).to eq(:exempt)
      expect(verdict.explanation).to include("config")
      expect(classify("project/README.md").reason).to eq(:none)
    end
  end

  # S3. `exempt` is the one key that can subtract, so it is the one key where a
  # wildcard is not a widening. `exempt = ["*"]` silently turned the whole gated
  # half off.
  describe "an exemption may not turn the gated half off wholesale" do
    ["*", "**", "~", "~/"].each do |pattern|
      it "refuses #{pattern.inspect} as an exemption" do
        expect { Lain::Sensitivity::Rules.from({ "exempt" => [pattern] }) }
          .to raise_error(Lain::Sensitivity::Rules::MalformedPattern, /matches everything/)
      end
    end

    it "still accepts the same pattern where it can only widen" do
      expect { Lain::Sensitivity::Rules.from({ "gated" => ["*"], "denied" => ["**"] }) }.not_to raise_error
    end

    it "still accepts a specific exemption, which is the key's whole purpose" do
      expect { Lain::Sensitivity::Rules.from({ "exempt" => [".gitconfig", "~/.gitconfig"] }) }.not_to raise_error
    end
  end

  describe Lain::Sensitivity::Rules do
    it "refuses a table that is not a table" do
      expect { described_class.from("yes") }.to raise_error(described_class::NotATable, /must be a table/)
    end

    it "refuses a key it does not have, rather than dropping it silently" do
      expect { described_class.from({ "deneid" => ["x"] }) }
        .to raise_error(described_class::UnknownKeys, /deneid/)
    end

    it "refuses a strength given as one value instead of a list" do
      expect { described_class.from({ "denied" => "*.secret" }) }
        .to raise_error(described_class::NotAList, /denied/)
    end

    it "refuses a pattern that is not a string" do
      expect { described_class.from({ "denied" => [42] }) }
        .to raise_error(described_class::MalformedPattern, /string/)
    end

    it "refuses a blank pattern, which would match nothing and read as an entry" do
      expect { described_class.from({ "gated" => ["  "] }) }
        .to raise_error(described_class::MalformedPattern, /blank/)
    end

    # A path-shaped pattern that is not home-anchored has no defined meaning
    # here, and silently never matching is the failure Config::Answers exists to
    # refuse. Loud now, widenable later.
    it "refuses a path-shaped pattern that is not home-anchored" do
      expect { described_class.from({ "denied" => ["config/secrets/prod.key"] }) }
        .to raise_error(described_class::MalformedPattern, /home-anchored/)
    end

    it "names the config file in a refusal when it was given one" do
      expect { described_class.from({ "denied" => "x" }, path: "/etc/lain.toml") }
        .to raise_error(described_class::NotAList, %r{\A/etc/lain\.toml: })
    end

    it "reads an absent table as an empty one" do
      expect(described_class.from(nil)).to eq(described_class.empty)
    end
  end

  describe "the classifier makes no filesystem calls at all" do
    # Mechanical rather than argued: every door out of a lexical classifier into
    # the filesystem or the environment raises for the whole group.
    before do
      SensitivitySpecSupport::FORBIDDEN.each_key do |name|
        receiver = Object.const_get(name)
        SensitivitySpecSupport::FORBIDDEN.fetch(name).map(&:first).uniq.each do |call|
          allow(receiver).to receive(call).and_raise("#{SensitivitySpecSupport::REFUSAL} (#{name}.#{call})")
        end
      end
      # rubocop:disable RSpec/AnyInstance -- there is no injected Pathname to
      # double; the claim under test is that no Pathname ANYWHERE inside the
      # subject reaches the filesystem, which is what any_instance states.
      SensitivitySpecSupport::FORBIDDEN_PATHNAME.each do |call|
        allow_any_instance_of(Pathname).to receive(call)
                                       .and_raise("#{SensitivitySpecSupport::REFUSAL} (Pathname##{call})")
      end
      # rubocop:enable RSpec/AnyInstance
    end

    it "still denies a path under a home that does not exist" do
      absent = described_class.new(home: "/nonexistent/home/tester", cwd: "/nonexistent/work")

      expect(absent.classify("/nonexistent/home/tester/.ssh/id_ed25519")).to be_denied
    end

    it "still gates and still passes ordinary paths" do
      expect(classify(".env")).to be_gated
      expect(classify("lib/lain/session.rb")).to be_ordinary
    end

    it "still rewrites a named tilde without asking the system who that is" do
      expect(classify("~someone/.ssh/id_rsa")).to be_denied
    end

    # The canary, one assertion per stub. The earlier version proved two of
    # thirteen bit, which is exactly the shape of a green test that is not
    # testing its subject.
    SensitivitySpecSupport::FORBIDDEN.each do |name, calls|
      calls.each do |call, *args|
        it "has a stub that bites on #{name}.#{call}" do
          expect { Object.const_get(name).public_send(call, *args) }
            .to raise_error(/#{SensitivitySpecSupport::REFUSAL}/o)
        end
      end
    end

    SensitivitySpecSupport::FORBIDDEN_PATHNAME.each do |call|
      it "has a stub that bites on Pathname##{call}" do
        expect { Pathname.new("/tmp").public_send(call) }
          .to raise_error(/#{SensitivitySpecSupport::REFUSAL}/o)
      end
    end
  end

  # The stubs above prove the subject does not USE these doors on the paths the
  # examples happen to try. This proves it does not NAME them at all, on any
  # path, which is the claim the class comment actually makes. Ripper rather
  # than a text scan, per `output_discipline_spec.rb`: this file's comments
  # discuss `File.expand_path` and `Dir.home` at length, and neither is a call.
  describe "the source names no door to the filesystem" do
    let(:source) { File.read(File.expand_path("../../lib/lain/sensitivity.rb", __dir__)) }

    it "names no constant that could reach the filesystem, the environment or a subprocess" do
      named = SensitivitySpecSupport.constants_named_in(source)

      expect(named).not_to include(*SensitivitySpecSupport::BANNED_CONSTANTS)
    end

    it "calls only pure methods on File" do
      called = SensitivitySpecSupport.file_methods_called_in(source)

      expect(called).to match_array(SensitivitySpecSupport::PURE_FILE_METHODS)
    end

    it "spawns nothing" do
      expect(SensitivitySpecSupport.backticks_in?(source)).to be(false)
    end

    # The canary for the three above: the scanner must be able to SEE a door,
    # or all three pass on any file at all.
    it "has a scanner that finds what it is looking for" do
      planted = 'Dir.home; File.expand_path("~"); `id`'

      expect(SensitivitySpecSupport.constants_named_in(planted)).to include("Dir")
      expect(SensitivitySpecSupport.file_methods_called_in(planted)).to include("expand_path")
      expect(SensitivitySpecSupport.backticks_in?(planted)).to be(true)
    end
  end

  describe "classification is lexical, not resolved" do
    around do |example|
      Dir.mktmpdir("lain-sensitivity") do |dir|
        @dir = dir
        example.run
      end
    end

    it "reads the name it was given, so a symlink to a denied path is ordinary" do
      target = File.join(@dir, ".ssh", "id_ed25519")
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, "not a key")
      link = File.join(@dir, "notes.md")
      File.symlink(target, link)

      # The fixture cannot rot into a tautology: the link really does resolve to
      # a path this classifier denies.
      resolver = described_class.new(home: @dir, cwd: @dir)
      expect(resolver.classify(File.realpath(link))).to be_denied

      expect(resolver.classify(link)).to be_ordinary
    end
  end

  # B1. `Pathname#cleanpath` raises ArgumentError on a NUL byte, and
  # `File.fnmatch?` raises Encoding::CompatibilityError -- not an ArgumentError
  # -- on a string in an encoding it cannot compare. T11 calls this synchronously
  # inside a gate, so neither may escape.
  describe "a path it cannot read lexically" do
    it "gates a path holding a NUL byte instead of raising" do
      expect { classify("a\0b") }.not_to raise_error
      expect(classify("a\0b")).to be_gated
    end

    it "gates a path in an encoding it cannot match instead of raising" do
      wrong_encoding = +"\xFF\xFE/x"

      expect(classify(wrong_encoding.force_encoding("UTF-16LE"))).to be_gated
    end

    it "gates a path whose bytes are not valid in its own encoding" do
      invalid_bytes = +"caf\xE9.txt"

      expect(classify(invalid_bytes.force_encoding("UTF-8"))).to be_gated
    end

    # The guard and the rescue behind it are two mechanisms for one input class,
    # so "delete the guard" survives mutation -- a known equivalent mutant, kept
    # because T11 calls this inside a gate where an escaping exception is a fault
    # rather than a verdict. This pins the relationship instead of leaving it to
    # be rediscovered: `readable?` must refuse EXACTLY what `cleanpath` rejects.
    it "guards exactly the input class the rescue behind it exists to catch" do
      [+"a\0b", (+"caf\xE9.txt").force_encoding("UTF-8"), (+"\xFF\xFE/x").force_encoding("UTF-16LE")].each do |bad|
        raised = begin
          Pathname.new(bad).cleanpath.to_s
          nil
        rescue ArgumentError, EncodingError => e
          e
        end

        expect(described_class.readable?(bad)).to be(false)
        expect(raised).not_to be_nil
      end
    end

    it "lets an ordinary path through that guard" do
      expect(described_class.readable?("#{home}/.env")).to be(true)
    end

    # Gated and not ordinary is the whole point: gated reaches a human and is
    # liftable, ordinary is a silent pass.
    it "fails CLOSED, and says why in its own reason" do
      verdict = classify("a\0b")

      expect(verdict).not_to be_ordinary
      expect(verdict.reason).to eq(:malformed)
      expect(verdict).not_to be_credential
    end
  end

  # B2. A pattern that survives compilation and then raises inside
  # `File.fnmatch?` breaks every LATER call, not its own -- a config a project
  # committed once would crash the gate for good.
  describe "a config pattern it cannot read lexically" do
    it "refuses a pattern holding a NUL byte, at compile time" do
      expect { Lain::Sensitivity::Rules.from({ "denied" => ["a\0b"] }) }
        .to raise_error(Lain::Sensitivity::Rules::MalformedPattern)
    end

    it "refuses a pattern in an encoding it could never match against" do
      pattern = (+"\xFF\xFE").force_encoding("UTF-16LE")

      expect { Lain::Sensitivity::Rules.from({ "gated" => [pattern] }) }
        .to raise_error(Lain::Sensitivity::Rules::MalformedPattern)
    end

    # The regression itself: one poisoned pattern used to take out every path
    # classified after it, including the ones the config never mentioned.
    it "so an ordinary path still classifies when a config tried to smuggle one in" do
      expect { Lain::Sensitivity::Rules.from({ "denied" => ["*.secret", "a\0b"] }) }
        .to raise_error(Lain::Sensitivity::Rules::MalformedPattern)
    end
  end

  # B3. `HOME=/` is Docker's default when the uid has no /etc/passwd entry, and
  # `ENV["HOME"].to_s` is "" when it is unset. Either one silently disabled every
  # home-anchored rule in the table.
  describe "the home it is given" do
    it "refuses an empty home, which is what HOME unset looks like" do
      expect { described_class.new(home: "", cwd:) }.to raise_error(ArgumentError, /home/)
    end

    it "refuses the filesystem root, which is Docker's default HOME" do
      expect { described_class.new(home: "/", cwd:) }.to raise_error(ArgumentError, %r{"/"})
    end

    it "refuses a home that only looks like one after expansion" do
      expect { described_class.new(home: "~", cwd:) }.to raise_error(ArgumentError, /home/)
      expect { described_class.new(home: "home/tester", cwd:) }.to raise_error(ArgumentError, /home/)
    end

    it "refuses a home that is not a path at all" do
      expect { described_class.new(home: nil, cwd:) }.to raise_error(ArgumentError, /home/)
      expect { described_class.new(home: 42, cwd:) }.to raise_error(ArgumentError, /home/)
    end

    it "names the offending value, so the message is diagnostic" do
      expect { described_class.new(home: "/", cwd:) }.to raise_error(ArgumentError, %r{got "/"})
    end

    it "accepts a Pathname, because a caller holding one should not have to convert" do
      expect(described_class.new(home: Pathname.new(home), cwd:).classify("#{home}/.netrc")).to be_denied
    end
  end

  # S6. T20 classifies bash argv, where a relative path is the norm. Making each
  # caller normalize first would be three copies of one rule.
  describe "a relative path is resolved against the injected cwd" do
    it "climbs out of a project back into home, lexically" do
      nested = described_class.new(home:, cwd: SensitivitySpecSupport::NESTED_CWD)

      expect(nested.classify("../../.ssh/id_rsa")).to be_denied
      expect(nested.classify("../../Downloads/x.pdf")).to be_gated
    end

    it "leaves a relative path under a cwd outside home ordinary" do
      expect(classify("../sibling/notes.md")).to be_ordinary
    end

    it "requires a cwd rather than reaching for Dir.pwd" do
      expect { described_class.new(home:) }.to raise_error(ArgumentError, /cwd/)
    end

    it "refuses a cwd that is not absolute" do
      expect { described_class.new(home:, cwd: "relative/here") }.to raise_error(ArgumentError, /cwd/)
      expect { described_class.new(home:, cwd: "") }.to raise_error(ArgumentError, /cwd/)
    end

    # The asymmetry is deliberate: a process may legitimately sit at /, but a
    # HOME of / is a misconfiguration that disables the table.
    it "accepts / as a cwd, which home may not be" do
      expect(described_class.new(home:, cwd: "/").classify("etc/passwd")).to be_ordinary
    end
  end

  # N6. `path.to_s` turned every wrong type into "" and answered :ordinary.
  describe "a subject that is not a path at all" do
    it "raises on nil rather than answering ordinary" do
      expect { classify(nil) }.to raise_error(ArgumentError, /nil/)
    end

    it "raises on an object that is not path-shaped" do
      expect { classify(42) }.to raise_error(ArgumentError, /42/)
      expect { classify({ "path" => ".env" }) }.to raise_error(ArgumentError)
    end

    # The line between the two postures: a wrong TYPE is a caller's bug and is
    # loud; malformed path BYTES are hostile data and fail closed.
    it "accepts a Pathname, which is path-shaped" do
      expect(classify(Pathname.new("#{home}/.netrc"))).to be_denied
    end
  end

  describe "shape" do
    # `be_frozen` on the instance is SHALLOW and passed while `@home` held a
    # mutable String out of `Pathname#to_s`. `Ractor.shareable?` is the
    # mechanical statement CLAUDE.md's deep-freeze rule actually makes.
    it "is deeply frozen, which is Ractor.shareable? and not be_frozen" do
      expect(Ractor.shareable?(sensitivity)).to be(true)
      expect(Ractor.shareable?(classify("#{home}/.ssh/id_ed25519"))).to be(true)
    end

    # `+"..."` and the `~/` prefix are both deliberate. This file is
    # frozen_string_literal, so a plain literal would arrive already frozen and
    # the example would pass without the subject freezing anything -- and `~/`
    # is the branch that runs `delete_prefix`, which returns a fresh MUTABLE
    # String. A real config arrives from a TOML parse, mutable, either way.
    it "is deeply frozen with a config table too, where the patterns came from outside" do
      rules = Lain::Sensitivity::Rules.from({ "denied" => [+"*.secret"], "gated" => [+"*.private"],
                                              "exempt" => [+"~/.gitconfig"] })

      expect(Ractor.shareable?(rules)).to be(true)
      expect(Ractor.shareable?(described_class.new(home:, cwd:, rules:))).to be(true)
    end

    it "is deeply frozen when built with no config at all" do
      expect(Ractor.shareable?(Lain::Sensitivity::Rules.from(nil))).to be(true)
    end

    # The other half of freezing a copy: the caller keeps their String, and
    # mutating it afterwards must not move this boundary.
    it "does not retain the caller's strings" do
      mutable_home = +"/home/tester"
      built = described_class.new(home: mutable_home, cwd:)
      mutable_home << "/moved"

      expect(built.classify("/home/tester/.kube/config")).to be_denied
    end

    it "normalizes a path lexically, so . and .. segments do not dodge a rule" do
      expect(classify("#{home}/Downloads/../.ssh/id_ed25519")).to be_denied
      expect(classify("./lib//lain/session.rb")).to be_ordinary
    end

    it "answers the two convenience questions the handlers ask" do
      expect(sensitivity.denied?("#{home}/.netrc")).to be(true)
      expect(sensitivity.gated?(".env")).to be(true)
      expect(sensitivity.denied?(".env")).to be(false)
      expect(sensitivity.gated?("README.md")).to be(false)
    end

    it "refuses a verdict outside the closed sets, rather than answering in silence" do
      expect { Lain::Sensitivity::Verdict.new(level: :maybe, reason: :none) }
        .to raise_error(ArgumentError, /maybe/)
      expect { Lain::Sensitivity::Verdict.new(level: :gated, reason: :vibes) }
        .to raise_error(ArgumentError, /vibes/)
    end
  end
end
