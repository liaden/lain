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

    # `.ssh/config` names hosts, users and identity files, so it is asked about
    # -- but asked about is the gated tier, and nothing here makes it a denial.
    it "leaves the rest of ~/.ssh undenied, so the rule is id_* and not the directory" do
      expect(classify("#{home}/.ssh/known_hosts")).to be_ordinary
      expect(classify("#{home}/.ssh/config")).to be_gated
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

  # A home-anchored table only ever saw ONE home, so an absolute path into
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
      expect(classify("#{home}/.ssh")).to have_attributes(level: :gated, reason: :credential)
    end

    # A whole-subtree rule has to cover the subtree's ROOT, or a listing shows
    # the directory itself while withholding everything in it. Moving from a
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

    # `.gitconfig` was already gated for its credential shape while `.git/config`
    # -- which routinely carries a token in a remote URL -- was ordinary. An
    # asymmetry in the table, not a position anybody took.
    it "gates a repository's own .git/config, as it already gated .gitconfig" do
      expect(classify(".git/config")).to be_gated
      expect(classify("vendor/dep/.git/config").reason).to eq(:credential)
      expect(classify("#{home}/work/repo/.git/modules/x/config")).to be_gated
    end

    it "leaves an ordinary config outside a .git directory alone" do
      expect(classify("config")).to be_ordinary
      expect(classify("app/config")).to be_ordinary
      expect(classify(".git/HEAD")).to be_ordinary
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

  # The credential files an automatic reader released verbatim, because this
  # tier was sized for a world where a human is still asked. Widening costs a
  # prompt on `read_file` and a withheld listing row for each, which is this
  # half's stated bargain.
  describe "gated, the named credential files" do
    {
      "config/master.key" => "a Rails master key",
      "certs/server.key" => "any private key file",
      "config/credentials.yml.enc" => "Rails encrypted credentials",
      "#{SensitivitySpecSupport::HOME}/.pgpass" => "a postgres password file",
      "#{SensitivitySpecSupport::HOME}/.bash_history" => "a shell history",
      "#{SensitivitySpecSupport::HOME}/.zsh_history" => "another shell's history",
      "#{SensitivitySpecSupport::HOME}/.gem/credentials" => "a rubygems API key",
      "#{SensitivitySpecSupport::HOME}/.ssh/config" => "an ssh client config",
      "#{SensitivitySpecSupport::HOME}/.config/rclone/rclone.conf" => "an rclone remote config",
      "#{SensitivitySpecSupport::HOME}/.local/share/keyrings/login.keyring" => "a login keyring",
      "#{SensitivitySpecSupport::HOME}/.local/share/keyrings/user.keystore" => "anything under a keyrings directory"
    }.each do |path, what|
      it "gates #{what} for its credential shape" do
        expect(classify(path)).to have_attributes(level: :gated, reason: :credential)
      end
    end

    it "gates a bare private key anywhere, not only inside .ssh" do
      %w[id_rsa deploy/id_ed25519 backup/id_ecdsa id_rsa.old].each do |path|
        expect(classify(path)).to have_attributes(level: :gated, reason: :credential)
      end
    end

    it "leaves the public half ordinary, and keeps a key inside .ssh denied" do
      expect(classify("deploy/id_ed25519.pub")).to be_ordinary
      expect(classify("id_rsa.pub")).to be_ordinary
      expect(classify("#{home}/.ssh/id_rsa")).to be_denied
    end

    it "gates a DSA key outside .ssh too, the algorithm the first list forgot" do
      expect(classify("backup/id_dsa")).to have_attributes(level: :gated, reason: :credential)
      expect(classify("backup/id_dsa.pub")).to be_ordinary
    end

    it "offers, for every built-in gated entry, a sample the entry itself matches" do
      anchors = Lain::Sensitivity::Anchors.new(home:, root: cwd)

      unmatched = described_class::GATED.reject do |rule|
        rule.samples(anchors).all? { |path| rule.matches?(path, anchors) }
      end

      expect(unmatched).to be_empty
    end
  end

  # Credential stores an automatic reader could still reach by name, each with
  # the path its tool really writes.
  describe "gated, the credential stores the first table missed" do
    {
      "#{SensitivitySpecSupport::HOME}/.ssh/deploy" => "a key in ~/.ssh under a name that is not id_*",
      "#{SensitivitySpecSupport::HOME}/.ssh/keys/github" => "a key nested beneath ~/.ssh",
      "#{SensitivitySpecSupport::HOME}/.vault-token" => "a HashiCorp Vault token",
      "project/.vault-token" => "a Vault token wherever it sits",
      "#{SensitivitySpecSupport::HOME}/.cargo/credentials.toml" => "a crates.io token",
      "#{SensitivitySpecSupport::HOME}/.config/gcloud/application_default_credentials.json" =>
        "gcloud application default credentials",
      "#{SensitivitySpecSupport::HOME}/.terraform.d/credentials.tfrc.json" => "a Terraform Cloud token",
      "#{SensitivitySpecSupport::HOME}/.azure/msal_token_cache.json" => "anything under ~/.azure",
      "#{SensitivitySpecSupport::HOME}/.kube/config.bak" => "a kubeconfig backup",
      "#{SensitivitySpecSupport::HOME}/.kube/config-staging" => "a second kubeconfig"
    }.each do |path, what|
      it "gates #{what} for its credential shape" do
        expect(classify(path)).to have_attributes(level: :gated, reason: :credential)
      end
    end

    it "leaves the public keys and known hosts in ~/.ssh ordinary" do
      expect(classify("#{home}/.ssh/deploy.pub")).to be_ordinary
      expect(classify("#{home}/.ssh/known_hosts")).to be_ordinary
    end

    it "keeps the kubeconfig itself denied, and the rest of ~/.kube ordinary" do
      expect(classify("#{home}/.kube/config")).to be_denied
      expect(classify("#{home}/.kube/cache/discovery.json")).to be_ordinary
    end

    it "gates a kube config backup on the path read_file asks about" do
      policy = Lain::Sensitivity::Policy.new(sensitivity:)
      read = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "read_file",
                                        input: { "path" => "#{home}/.kube/config.bak" })

      expect(policy.gates?(read)).to be(true)
    end
  end

  # A live credential read, MEASURED rather than reasoned about: a child spawned
  # the way this codebase spawns one -- `Exec.child_env` over `WorkerEnv#env` --
  # inherits `ANTHROPIC_API_KEY`, because that scrub names only bundler and rspec
  # variables. A canary key set on the session was read straight back out of the
  # child's own `/proc/self/environ`. And `/proc/PID/cmdline` is mode 444 and
  # owned by the reader, so a same-user process invoked with `--api-key=...`
  # hands its argv to anything that opens it -- verified on this box.
  #
  # GATED and not DENIED on the tier's own stated criterion: someone debugging
  # their own process may legitimately read an environ, and being wrong here
  # costs one prompt. Nothing here claims all of `/proc` is off limits.
  describe "gated, the process filesystem" do
    %w[environ cmdline].each do |name|
      it "gates /proc/self/#{name}, which carries the session's own credentials" do
        verdict = classify("/proc/self/#{name}")

        expect(verdict).to be_gated
        expect(verdict.reason).to eq(:credential)
        expect(verdict).to be_credential
      end

      it "gates another process's /proc/PID/#{name} too, not only self's" do
        expect(classify("/proc/1/#{name}")).to be_gated
        expect(classify("/proc/12345/#{name}")).to be_gated
      end
    end

    # The rule is {Rule.within}, so it matches a `proc` SEGMENT anywhere rather
    # than an absolute prefix -- `./proc/environ` in a checkout is gated too.
    # Over-broad, failing closed, and costing one prompt, which is this tier's
    # whole bargain; contorting the pattern to dodge it would buy nothing.
    it "also gates a proc/environ that is not the real one, and that is the trade" do
      expect(classify("vendor/proc/environ")).to be_gated
    end

    # Deliberately UNCHANGED. `/proc/self/maps` leaks address-space layout, not
    # credentials, and no tier here moves on an argument nobody measured.
    it "leaves the rest of /proc ordinary, including maps" do
      expect(classify("/proc/self/maps")).to be_ordinary
      expect(classify("/proc/self/status")).to be_ordinary
      expect(classify("/proc/cpuinfo")).to be_ordinary
    end

    # The neighbouring name test, on `environment.rb`'s precedent: a whole
    # basename, never a prefix.
    it "does not gate a name that merely starts the same way" do
      expect(classify("/proc/self/environment")).to be_ordinary
      expect(classify("lib/cmdline_parser.rb")).to be_ordinary
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

  describe "credential file variants, recognised by name" do
    def levels(names) = names.to_h { |name| [name, classify("#{home}/#{name}").level] }

    it "keeps a variant of the netrc name denied" do
      expect(levels(%w[_netrc netrc .netrc.bak .netrc.old])).to eq(
        "_netrc" => :denied, "netrc" => :denied, ".netrc.bak" => :denied, ".netrc.old" => :denied
      )
    end

    it "keeps a variant of the pgpass name gated" do
      expect(levels(%w[.pgpass.bak pgpass .pgpass2]).values).to all(eq(:gated))
    end

    it "gates the named credential stores" do
      names = %w[.authinfo .msmtprc .fetchmailrc .htpasswd .vault_pass .vault-password passwords.txt]

      expect(levels(names).values).to all(eq(:gated))
    end

    it "keeps numbered and doubled backups denied or gated" do
      expect(levels(%w[.netrc.1 .netrc.~1~ .netrc.bak~]).values).to all(eq(:denied))
      expect(levels(%w[.pgpass.1 .pgpass.~2~ .pgpass.old~]).values).to all(eq(:gated))
    end

    it "refuses an exemption that would lift the backup spellings of several stores" do
      ["*~", "[!.]*rc"].each do |pattern|
        expect { Lain::Sensitivity::Rules.from({ "exempt" => [pattern] }) }
          .to raise_error(Lain::Config::Refusal, /lifts/)
      end
    end

    it "leaves ordinary names ordinary" do
      names = %w[Gemfile.lock notes.txt env gitconfig npmrc netrc_helper.rb pgpass.md]

      expect(levels(names).values).to all(eq(:ordinary))
    end
  end

  describe Lain::Sensitivity::Name do
    it "lists a basename, then its unsuffixed form, then its dotted form" do
      expect(described_class.stems("_netrc.bak")).to eq(%w[_netrc.bak _netrc .netrc])
    end

    it "strips one backup suffix or trailing digits" do
      expect(described_class.stems(".pgpass2")).to eq(%w[.pgpass2 .pgpass])
      expect(described_class.stems(".netrc.~1~")).to eq(%w[.netrc.~1~ .netrc])
      expect(described_class.stems("x~")).to eq(%w[x~ x .x])
    end

    it "lists a plain dotfile once" do
      expect(described_class.stems(".netrc")).to eq([".netrc"])
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

  # A home-anchored exemption names a PLACE. At that exact path it lifts
  # whatever is there; beneath it, it may lift a personal directory's gate but
  # never a credential's, so `exempt = ["~/src"]` cannot ungate every `.env` and
  # key in every project under it.
  describe "a home-anchored exemption, at its path and beneath it" do
    def with(*exempt) = described_class.new(home:, cwd:, rules: Lain::Sensitivity::Rules.from({ "exempt" => exempt }))

    it "keeps a credential-shaped name beneath an exempted directory gated" do
      src = with("~/src")

      expect(src.classify("#{home}/src/app/config/master.key")).to have_attributes(level: :gated, reason: :credential)
      expect(src.classify("#{home}/src/id_rsa")).to be_gated
      expect(src.classify("#{home}/src/app/.env")).to be_gated
      expect(src.classify("#{home}/src/app/README.md")).to be_ordinary
    end

    it "opens a personal directory without opening the credentials inside it" do
      downloads = with("~/Downloads")

      expect(downloads.classify("#{home}/Downloads")).to have_attributes(level: :ordinary, reason: :exempt)
      expect(downloads.classify("#{home}/Downloads/x.pdf")).to have_attributes(level: :ordinary, reason: :exempt)
      expect(downloads.classify("#{home}/Downloads/.env")).to be_gated
      expect(downloads.classify("#{home}/Downloads/x.key")).to be_gated
    end

    it "still lifts the one file it names exactly" do
      named = with("~/.gitconfig", "~/src/app/.env")

      expect(named.classify("#{home}/.gitconfig")).to have_attributes(level: :ordinary, reason: :exempt)
      expect(named.classify("#{home}/src/app/.env")).to have_attributes(level: :ordinary, reason: :exempt)
      expect(named.classify("#{home}/src/other/.env")).to be_gated
    end
  end

  # A leading `/` anchors a pattern at the project root, which a committed
  # config can name wherever the checkout lives. A trailing `/` is a directory
  # and everything beneath it, and only the keys that add may say that.
  describe "a project-anchored pattern" do
    let(:root) { "/srv/project" }

    def rooted(table, cwd: root) = described_class.new(home:, cwd:, root:, rules: Lain::Sensitivity::Rules.from(table))

    it "denies an anchored directory, everything beneath it, and nothing of the same name elsewhere" do
      vault = rooted({ "denied" => ["/vault/"] })

      expect(vault.classify("#{root}/vault")).to have_attributes(level: :denied, reason: :configured)
      expect(vault.classify("vault/a.txt")).to have_attributes(level: :denied, reason: :configured)
      expect(vault.classify("#{root}/vault/deep/b.txt")).to be_denied
      expect(vault.classify("#{root}/lib/vault/a.txt")).to be_ordinary
      expect(vault.classify("/srv/other/vault/a.txt")).to be_ordinary
      expect(vault.classify("#{root}/vaults/a.txt")).to be_ordinary
    end

    it "resolves a relative word from a cwd below the root against the root's anchor" do
      vault = rooted({ "denied" => ["/vault/"] }, cwd: "#{root}/lib")

      expect(vault.classify("../vault/a.txt")).to be_denied
      expect(vault.classify("vault/a.txt")).to be_ordinary
    end

    it "gates an anchored directory at the gated strength" do
      ops = rooted({ "gated" => ["/ops/"] })

      expect(ops.classify("ops/deploy.sh")).to have_attributes(level: :gated, reason: :configured)
    end

    # A key that restricts must fail closed on the spelling a person is most
    # likely to write, and a file has nothing beneath it to over-reach into.
    it "covers what lies beneath an anchored denied or gated path, with or without the trailing separator" do
      denied = rooted({ "denied" => ["/vault"] })
      gated = rooted({ "gated" => ["/ops"] })

      expect(denied.classify("vault")).to be_denied
      expect(denied.classify("vault/a.txt")).to have_attributes(level: :denied, reason: :configured)
      expect(denied.classify("vaults/a.txt")).to be_ordinary
      expect(gated.classify("ops/deploy.sh")).to have_attributes(level: :gated, reason: :configured)
    end

    it "lifts the one file an anchored exemption names, and no other file of that name" do
      fixture = rooted({ "exempt" => ["/fixtures/.env"] })

      expect(fixture.classify("fixtures/.env")).to have_attributes(level: :ordinary, reason: :exempt)
      expect(fixture.classify(".env")).to be_gated
      expect(fixture.classify("fixtures/deep/.env")).to be_gated
      expect(fixture.classify("/srv/other/fixtures/.env")).to be_gated
    end

    it "never lifts a built-in denial, however it is anchored" do
      verdict = rooted({ "exempt" => ["/.netrc"] }).classify(".netrc")

      expect(verdict).to have_attributes(level: :denied, reason: :protected)
    end

    it "refuses an anchored directory as an exemption, naming the pattern" do
      ["/fixtures/", "/"].each do |pattern|
        named = %r{\A/p/\.lain/config\.toml: .*exempt.*#{Regexp.escape(pattern.inspect)}}

        expect { Lain::Sensitivity::Rules.from({ "exempt" => [pattern] }, path: "/p/.lain/config.toml") }
          .to raise_error(Lain::Config::Refusal, named)
      end
    end

    # The table cannot look at the disk, so the loader that can says which
    # anchored paths are directories; a trailing separator needs no disk.
    it "refuses an anchored exemption the loader finds is a directory, naming the pattern and the file" do
      rules = Lain::Sensitivity::Rules.from({ "exempt" => ["/fixtures", "/fixtures/.env"] })
      directories = ->(anchored) { anchored == "fixtures" }

      expect { rules.exempting_files!(directories, path: "/p/.lain/config.toml") }
        .to raise_error(Lain::Config::Refusal, %r{\A/p/\.lain/config\.toml: .*exempt.*"/fixtures"})
      expect(rules.exempting_files!(->(_anchored) { false })).to equal(rules)
    end

    it "refuses an anchored pattern holding a glob or an unclean segment, which can never match" do
      ["/vault/*", "/*.env", "//vault", "/a/../b", "/./x", "/a//b"].each do |pattern|
        expect { Lain::Sensitivity::Rules.from({ "denied" => [pattern] }) }
          .to raise_error(Lain::Config::Refusal, /can never match/)
      end
    end

    it "refuses to build a classifier over anchored patterns when it was given no root to anchor them on" do
      rules = Lain::Sensitivity::Rules.from({ "denied" => ["/vault/"] })

      expect { described_class.new(home:, cwd:, rules:) }.to raise_error(ArgumentError, /root/)
      expect { described_class.new(home:, cwd:, rules:, root: "relative") }.to raise_error(ArgumentError, /root/)
    end

    it "needs no root for a table that anchors nothing there" do
      expect(described_class.new(home:, cwd:, rules: Lain::Sensitivity::Rules.from({ "denied" => ["*.secret"] }))
               .classify("a.secret")).to be_denied
    end

    it "compiles every shape of pattern to a rule its own sample matches, so the exemption probe means something" do
      anchors = Lain::Sensitivity::Anchors.new(home:, root:)
      table = { "denied" => ["/vault/", "/vault", "~/.secrets", "*.secret"], "exempt" => ["/fixtures/.env", "/.env"] }
      compiled = Lain::Sensitivity::Rules.from(table).then { |rules| [*rules.denied, *rules.exempt] }

      expect(compiled.reject { |rule| rule.samples(anchors).all? { |path| rule.matches?(path, anchors) } }).to be_empty
    end

    it "stays deeply frozen with a root" do
      expect(Ractor.shareable?(rooted({ "denied" => [+"/vault/"], "exempt" => [+"/fixtures/.env"] }))).to be(true)
    end
  end

  # Precedence is expressed as ONE ordered list rather than a check, so the
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

  # `exempt` is the one key that can subtract, so it is the one key where a
  # wildcard is not a widening. `exempt = ["*"]` silently turned the whole gated
  # half off.
  describe "an exemption may not turn the gated half off wholesale" do
    ["*", "**", "~", "~/"].each do |pattern|
      it "refuses #{pattern.inspect} as an exemption" do
        expect { Lain::Sensitivity::Rules.from({ "exempt" => [pattern] }) }
          .to raise_error(Lain::Config::Refusal, /matches everything/)
      end
    end

    it "still accepts the same pattern where it can only widen" do
      expect { Lain::Sensitivity::Rules.from({ "gated" => ["*"], "denied" => ["**"] }) }.not_to raise_error
    end

    it "still accepts a specific exemption, which is the key's whole purpose" do
      expect { Lain::Sensitivity::Rules.from({ "exempt" => [".gitconfig", "~/.gitconfig"] }) }.not_to raise_error
    end

    # `.*` is not in the unbounded list and turned off every dot-named
    # credential anyway. The line is drawn by what a pattern LIFTS: each
    # compiled exemption is probed against one sample per built-in gated entry,
    # and more than one lifted is a class rather than a file.
    it "refuses an exemption that lifts more than one built-in gated entry, naming them" do
      expect { Lain::Sensitivity::Rules.from({ "exempt" => [".*"] }, path: "/p/.lain/config.toml") }
        .to raise_error(Lain::Config::Refusal,
                        %r{\A/p/\.lain/config\.toml: .*exempt.*lifts.*"\.env".*"\.envrc".*"\.gitconfig"})
      expect { Lain::Sensitivity::Rules.from({ "exempt" => ["*.key*"] }) }
        .to raise_error(Lain::Config::Refusal, /\*\.key.*\*\.keyring/)
    end

    it "accepts an exemption that lifts exactly one entry, however it is spelled" do
      expect { Lain::Sensitivity::Rules.from({ "exempt" => ["*.pem", "~/Downloads", ".envrc"] }) }
        .not_to raise_error
    end

    # The probe's placeholder basename is a name no config would write, so an
    # exemption that happens to share it is not charged with lifting every
    # directory entry the placeholder stands in for.
    # A sample is only worth probing when it is a file somebody could really
    # exempt, judged by the entry that carries it rather than by a denial.
    it "probes every built-in gated entry with a sample that entry, and no denial, judges" do
      probe = Lain::Sensitivity::Rules::PROBE
      shadowed = described_class::GATED.select do |gated|
        gated.samples(probe).any? { |path| described_class::DENIED.any? { |denied| denied.matches?(path, probe) } }
      end

      expect(shadowed.map(&:label)).to be_empty
    end

    # One sample per key type the id_* rows already name, so a glob over any
    # of them is counted against the keys kept under other names in ~/.ssh.
    %w[rsa dsa ecdsa ed25519].each do |type|
      it "counts *_#{type} as lifting the ~/.ssh entry too, so the per-entry cap refuses it" do
        expect { Lain::Sensitivity::Rules.from({ "exempt" => ["*_#{type}"] }) }
          .to raise_error(Lain::Config::Refusal, %r{lifts 2 .*"id_#{type}\*".*"~/\.ssh"})
      end
    end

    it "counts *.bak against the kube backups entry and the backup spelling of each variant store" do
      expect { Lain::Sensitivity::Rules.from({ "exempt" => ["*.bak"] }) }
        .to raise_error(Lain::Config::Refusal, %r{lifts 8 .*"\.pgpass".*"~/\.kube/config\*"})
    end

    it "lifts exactly one entry with the obvious exemption for each credential store the first table missed" do
      probe = Lain::Sensitivity::Rules::PROBE
      %w[.vault-token ~/.cargo/credentials.toml application_default_credentials.json
         ~/.terraform.d/credentials.tfrc.json ~/.kube/config.bak ~/.ssh/github_ed25519
         ~/.azure/msal_token_cache.json].each do |pattern|
        exemption = Lain::Sensitivity::Rules.from({ "exempt" => [pattern] }).exempt.first

        expect(described_class::GATED.count { |gated| exemption.lifts?(gated, probe) }).to eq(1), pattern
      end
    end

    it "does not refuse an ordinary name for colliding with the probe's own placeholder" do
      expect { Lain::Sensitivity::Rules.from({ "exempt" => %w[sample file x] }) }.not_to raise_error
    end

    # A `.` or `..` segment never survives into a compiled home-anchored path,
    # so the entry reads as an exemption and lifts nothing.
    it "refuses a home-anchored pattern with a dot segment, which can never match" do
      ["~/.", "~/..", "~/../..", "~/./", "~/src/../.env"].each do |pattern|
        expect { Lain::Sensitivity::Rules.from({ "exempt" => [pattern] }) }
          .to raise_error(Lain::Config::Refusal, /can never match/)
      end
    end

    # A home-anchored pattern is a literal subtree, never a glob, so `~/**`
    # compiled to a directory literally named `**` and lifted nothing while
    # reading as though it lifted everything.
    it "refuses a home-anchored pattern holding a glob, which can never match" do
      ["~/**", "~/*.env", "~/.config/?"].each do |pattern|
        expect { Lain::Sensitivity::Rules.from({ "exempt" => [pattern] }) }
          .to raise_error(Lain::Config::Refusal, /can never match/)
        expect { Lain::Sensitivity::Rules.from({ "denied" => [pattern] }) }
          .to raise_error(Lain::Config::Refusal, /can never match/)
      end
    end
  end

  describe Lain::Sensitivity::Rules do
    it "refuses a table that is not a table" do
      expect { described_class.from("yes") }.to raise_error(Lain::Config::Refusal, /must be a table/)
    end

    # One refusal class across every config table, so a reader that degrades a
    # bad file names one class rather than seven.
    it "refuses a string entry as a config refusal, naming the file and the table" do
      expect { described_class.from("strict", path: "/p/.lain/config.toml") }
        .to raise_error(Lain::Config::Refusal,
                        %r{\A/p/\.lain/config\.toml: \[sensitivity\] must be a table})
    end

    it "refuses a key it does not have, rather than dropping it silently" do
      expect { described_class.from({ "deneid" => ["x"] }) }
        .to raise_error(Lain::Config::Refusal, /deneid/)
    end

    it "refuses a strength given as one value instead of a list" do
      expect { described_class.from({ "denied" => "*.secret" }) }
        .to raise_error(Lain::Config::Refusal, /denied/)
    end

    it "refuses a pattern that is not a string" do
      expect { described_class.from({ "denied" => [42] }) }
        .to raise_error(Lain::Config::Refusal, /string/)
    end

    it "refuses a blank pattern, which would match nothing and read as an entry" do
      expect { described_class.from({ "gated" => ["  "] }) }
        .to raise_error(Lain::Config::Refusal, /blank/)
    end

    # A path-shaped pattern that is not home-anchored has no defined meaning
    # here, and silently never matching is the failure Config::Answers exists to
    # refuse. Loud now, widenable later.
    it "refuses a path-shaped pattern that is not anchored" do
      expect { described_class.from({ "denied" => ["config/secrets/prod.key"] }) }
        .to raise_error(Lain::Config::Refusal, /home-anchored.*project-anchored/)
    end

    it "names the config file in a refusal when it was given one" do
      expect { described_class.from({ "denied" => "x" }, path: "/etc/lain.toml") }
        .to raise_error(Lain::Config::Refusal, %r{\A/etc/lain\.toml: })
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

  # `Pathname#cleanpath` raises ArgumentError on a NUL byte, and
  # `File.fnmatch?` raises Encoding::CompatibilityError -- not an ArgumentError
  # -- on a string in an encoding it cannot compare. The gate calls this
  # synchronously, so neither may escape.
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
    # because the gate calls this where an escaping exception is a fault rather
    # than a verdict. This pins the relationship instead of leaving it to be
    # rediscovered: `readable?` must refuse EXACTLY what `cleanpath` rejects.
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

  # A pattern that survives compilation and then raises inside
  # `File.fnmatch?` breaks every LATER call, not its own -- a config a project
  # committed once would crash the gate for good.
  describe "a config pattern it cannot read lexically" do
    it "refuses a pattern holding a NUL byte, at compile time" do
      expect { Lain::Sensitivity::Rules.from({ "denied" => ["a\0b"] }) }
        .to raise_error(Lain::Config::Refusal, /denied must be matchable text/)
    end

    it "refuses a pattern in an encoding it could never match against" do
      pattern = (+"\xFF\xFE").force_encoding("UTF-16LE")

      expect { Lain::Sensitivity::Rules.from({ "gated" => [pattern] }) }
        .to raise_error(Lain::Config::Refusal, /gated must be matchable text/)
    end

    # The regression itself: one poisoned pattern used to take out every path
    # classified after it, including the ones the config never mentioned.
    it "so an ordinary path still classifies when a config tried to smuggle one in" do
      expect { Lain::Sensitivity::Rules.from({ "denied" => ["*.secret", "a\0b"] }) }
        .to raise_error(Lain::Config::Refusal, /denied must be matchable text/)
    end
  end

  # `HOME=/` is Docker's default when the uid has no /etc/passwd entry, and
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

  # Bash argv gets classified here, where a relative path is the norm. Making
  # each caller normalize first would be three copies of one rule.
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

  # `path.to_s` turned every wrong type into "" and answered :ordinary.
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
