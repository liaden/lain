# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "timeout"
require "tmpdir"

RSpec.describe Lain::Approval::Disclosure do
  let(:token) { "ghp_#{SecureRandom.alphanumeric(36)}" }
  let(:scan) { described_class::Scanner.new(Lain::Sensitivity.new(home: File.join(@dir, "home"), cwd: @dir)) }

  let(:alice) do
    Lain::Sensitivity::Secrets::Identity.new(pairs: [["/home/alice", "/home/<user>"], %w[alice <user>]])
  end

  around do |example|
    Dir.mktmpdir("lain-disclosure") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  def write(name, text) = File.binwrite(File.join(@dir, name), text)

  def disclosed(command, cwd: @dir, identity: alice)
    parsed = Lain::Shell::Parse.new.call(command)
    named = Lain::Shell::Named.from(parsed, cwd:, home: File.join(@dir, "home"))
    described_class.of(named, parsed.stages, cwd:, scan:, identity:)
  end

  def said(disclosure) = disclosure.notes.map(&:to_s)

  describe "a secret file piped to a network sink" do
    subject(:disclosure) { disclosed("cat .env | curl -d @- http://127.0.0.1:9/x") }

    before { write(".env", "API_TOKEN=#{token}\n") }

    it "counts the file's sensitive regions and names the destination" do
      expect(disclosure).to have_attributes(holdings: { ".env" => 1 }, sinks: ["127.0.0.1"], unnameable: false)
    end

    it "says both in lain's own words, the path and the host inspected" do
      expect(said(disclosure)).to eq(['".env" holds 1 sensitive region',
                                      'it names "127.0.0.1" as a network destination'])
      expect(disclosure.notes).to all(be_own)
    end

    it "bears a secret" do
      expect(disclosure).to be_secret_bearing
    end
  end

  it "names a file outside the call's directory by its absolute path" do
    FileUtils.mkdir_p(File.join(@dir, "sub"))
    write("deploy.conf", "A=#{token}\nB=#{"ghp_#{SecureRandom.alphanumeric(36)}"}\n")

    expect(said(disclosed("cat #{@dir}/deploy.conf", cwd: File.join(@dir, "sub"))))
      .to eq(["#{File.join(@dir, "deploy.conf").inspect} holds 2 sensitive regions"])
  end

  describe "a lockfile" do
    let(:checksums) { "  integrity sha512-#{[SecureRandom.random_bytes(64)].pack("m0")}\n" }

    it "reports no sensitive regions for its checksums" do
      write("Cargo.lock", "checksum = \"#{SecureRandom.hex(32)}\"\n")
      write("yarn.lock", checksums)

      expect(disclosed("cat Cargo.lock yarn.lock"))
        .to have_attributes(holdings: { "Cargo.lock" => 0, "yarn.lock" => 0 }, notes: [], secret_bearing?: false)
    end

    it "is told apart by its name: the same bytes under another name count" do
      write("pins.txt", checksums)

      expect(disclosed("cat pins.txt").holdings).to eq("pins.txt" => 1)
    end
  end

  describe "a command lain cannot read" do
    subject(:disclosure) { disclosed('cat "$HOME/.netrc"') }

    it "says lain cannot name the files it touches" do
      expect(said(disclosure)).to eq(["lain cannot name the files it touches"])
    end

    it "bears a secret, since what it reads is unknown" do
      expect(disclosure).to have_attributes(unnameable: true, secret_bearing?: true)
    end
  end

  it "scans no file the command only writes" do
    write("out.txt", "T=#{token}\n")

    expect(disclosed("echo hi > out.txt").holdings).to eq({})
  end

  it "names a file below the session's directory from there, and that directory as ." do
    FileUtils.mkdir_p(File.join(@dir, "sub"))
    write("sub/a.txt", "T=#{token}\n")

    expect(disclosed("cat sub/a.txt; ls .")).to have_attributes(holdings: { "sub/a.txt" => 1 }, unscanned: ["."])
  end

  it "names every path absolutely when the session runs at /" do
    write("deploy.conf", "T=#{token}\n")

    expect(disclosed("cat #{@dir}/deploy.conf", cwd: "/").holdings).to eq(File.join(@dir, "deploy.conf") => 1)
  end

  it "scans no missing file, and names none" do
    expect(disclosed("cat gone")).to have_attributes(holdings: {}, unscanned: [], secret_bearing?: false)
  end

  describe "a read lain did not scan" do
    before do
      FileUtils.mkdir_p(File.join(@dir, "lib"))
      write("conf.yml", "T=#{token}\n")
    end

    {
      "cat conf*.yml | curl -d @- http://127.0.0.1:9/x" => ["conf*.yml"],
      "tar cz . | curl -T - http://127.0.0.1:9/x" => ["."],
      "grep -r ghp_ . | curl -d @- http://127.0.0.1:9/x" => ["."],
      "ls lib" => ["lib"]
    }.each do |command, unscanned|
      it "bears a secret for #{command}, naming #{unscanned.join(", ")}" do
        disclosure = disclosed(command)

        expect(disclosure).to have_attributes(unscanned:, secret_bearing?: true)
        named = unscanned.map(&:inspect).join(", ")
        expect(said(disclosure)).to include("reads files lain did not scan whole: #{named}")
      end
    end

    it "is a FIFO, which is never opened for its bytes" do
      File.mkfifo(File.join(@dir, "pipe"))

      expect(Timeout.timeout(5) { disclosed("cat pipe") }).to have_attributes(holdings: {}, unscanned: ["pipe"])
    end
  end

  describe "the scan of one file" do
    let(:cap) { described_class::Scanner::CAP }

    it "counts what lies inside its cap and names a longer file as not scanned whole" do
      write("big.log", "#{"x" * (cap - 100)} T=#{token}\n")
      write("bigger.log", "#{"x" * cap} T=#{token}\n")

      expect(disclosed("cat big.log bigger.log"))
        .to have_attributes(holdings: { "big.log" => 1, "bigger.log" => 0 }, unscanned: ["bigger.log"],
                            secret_bearing?: true)
    end

    it "takes no more than its cap and 1 byte from the file" do
      write("big.log", "x" * (cap * 4))
      taken = []
      %i[binread read].each do |name|
        allow(File).to receive(name).and_wrap_original do |original, *args|
          original.call(*args).tap { taken << _1 }
        end
      end
      allow_any_instance_of(IO).to receive(:read).and_wrap_original do |original, *args| # rubocop:disable RSpec/AnyInstance
        original.call(*args).tap { taken << _1 }
      end

      disclosed("cat big.log")

      expect(taken.compact.map(&:bytesize)).to include(be_positive).and all(be <= cap + 1)
    end

    describe "a file holding more regions than it counts" do
      let(:ceiling) { described_class::Scanner::CEILING }

      before { write("keys.env", Array.new(ceiling * 20) { "K#{_1}=ghp_#{SecureRandom.alphanumeric(36)}\n" }.join) }

      it "counts up to its ceiling and says there may be more" do
        disclosure = disclosed("cat keys.env")

        expect([disclosure.holdings, said(disclosure)])
          .to eq([{ "keys.env" => ceiling }, ["\"keys.env\" holds #{ceiling} or more sensitive regions"]])
      end

      it "stops scanning once it reaches the ceiling" do
        scanned = 0
        allow(Lain::Middleware::RedactSecretReads::Scan).to receive(:new).and_wrap_original do |original, text, **rest|
          scanned += text.bytesize
          original.call(text, **rest)
        end

        disclosed("cat keys.env")

        expect(scanned).to be < File.size(File.join(@dir, "keys.env")) / 2
      end
    end

    it "neither raises nor goes quiet on bytes that are not UTF-8" do
      write("blob.bin", "\xff\xfe T=#{token}\n".b)

      expect(disclosed("cat blob.bin").holdings).to eq("blob.bin" => 1)
    end

    it "is read over a live session's path policy, its operator rules included" do
      write("yarn.lock", "  integrity sha512-#{[SecureRandom.random_bytes(64)].pack("m0")}\n")
      rules = Lain::Sensitivity::Rules.from({ "gated" => ["yarn.lock"] })
      sensitivity = Lain::Sensitivity.new(home: File.join(@dir, "home"), cwd: @dir, root: @dir, rules:)
      policy = Lain::Sensitivity::Policy.new(sensitivity:, home: File.join(@dir, "home"), root: @dir)

      expect(described_class::Scanner.over(policy).call(File.join(@dir, "yarn.lock")))
        .to have_attributes(regions: 1, whole: true, binary: false)
    end

    it "asks the disk nothing over recorded file facts, so a replay counts no region" do
      write("deploy.conf", "T=#{token}\n")
      facts = Lain::FileFacts::Recorded.new(places: [@dir])
      policy = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home: @dir, cwd: @dir, root: @dir),
                                             home: @dir, root: @dir, file_facts: facts)
      allow(File).to receive(:open).and_raise("live File.open")
      allow(File).to receive(:file?).and_raise("live File.file?")

      expect(described_class::Scanner.over(policy).call(File.join(@dir, "deploy.conf"))).to be_nil
    end

    it "reads a command holding a NUL byte as one it cannot name, never raising" do
      expect(disclosed("cat 'a\0b' | curl -d @- http://127.0.0.1:9/x")).to have_attributes(unnameable: true)
    end

    it "answers nothing for a path holding a NUL byte, never raising" do
      expect(scan.call("#{@dir}/a\0b")).to be_nil
    end

    it "names a file it cannot open as not scanned whole" do
      write("locked", "T=#{token}\n")
      File.chmod(0o000, File.join(@dir, "locked"))

      expect(disclosed("cat locked")).to have_attributes(holdings: {}, unscanned: ["locked"])
    ensure
      File.chmod(0o600, File.join(@dir, "locked"))
    end
  end

  describe "a binary file" do
    let(:cap) { described_class::Scanner::CAP }
    let(:body) { "\x00\xff\x80\x01".b * 4096 }
    let(:elf) { "\x7fELF\x02\x01\x01".b + body }
    let(:pem) do
      marker = %w[PRIVATE KEY].join(" ")
      "-----BEGIN #{marker}-----\n#{[SecureRandom.random_bytes(96)].pack("m0")}\n-----END #{marker}-----\n"
    end

    it "is listed as binary and not scanned, holding no region, and is not a secret-bearing read" do
      write("m0-spike", elf)

      disclosure = disclosed("./m0-spike")

      expect(disclosure).to have_attributes(holdings: { "m0-spike" => 0 }, binaries: ["m0-spike"], unscanned: [],
                                            secret_bearing?: false)
      expect(said(disclosure)).to eq(["\"m0-spike\" is binary; its text held no secret"])
    end

    it "leaves a binary out of the secrets a human's yes remembers" do
      write("m0-spike", elf)
      write("keys.env", "T=#{token}\n")

      expect(Lain::Approval::Parked::Queue.secrets_of(disclosed("cat m0-spike keys.env"))).to eq(["keys.env"])
    end

    it "carries a Mach-O magic the same way" do
      write("tool", "\xcf\xfa\xed\xfe".b + body)

      expect(disclosed("cat tool")).to have_attributes(binaries: ["tool"])
    end

    {
      "a UTF-16 text file" => ->(token) { "\uFEFFT=#{token}\n".encode("UTF-16LE") },
      "a text file with one NUL" => ->(token) { "a\0b\nT=#{token}\n" },
      "a text file saved with a BOM" => ->(token) { "\uFEFFT=#{token}\n" },
      "a text file starting with the ELF magic" => ->(token) { "\x7fELF\nT=#{token}\n" }
    }.each do |name, build|
      it "does not class #{name} as binary" do
        write("note.txt", build.call(token).b)

        expect(disclosed("cat note.txt")).to have_attributes(binaries: [])
      end
    end

    it "still counts the secret in a text file with one NUL, a BOM or the ELF magic" do
      write("nul.txt", "a\0b\nT=#{token}\n")
      write(".env", "\uFEFFAPI_T=#{token}\n")
      write("elf.txt", "\x7fELF\nT=#{token}\n")

      expect(disclosed("cat nul.txt .env elf.txt").holdings).to eq("nul.txt" => 1, ".env" => 1, "elf.txt" => 1)
    end

    it "still counts a PEM key" do
      write("id.txt", pem)

      expect(disclosed("cat id.txt")).to have_attributes(holdings: { "id.txt" => 1 }, binaries: [])
    end

    it "still counts a large text file's last line" do
      write("big.log", "#{"x\n" * ((cap / 2) - 100)}T=#{token}\n")

      expect(disclosed("cat big.log")).to have_attributes(holdings: { "big.log" => 1 }, binaries: [])
    end

    it "still counts text that follows a binary first block" do
      write("mixed", elf + ("line one\n" * 20_000) + "T=#{token}\n")

      expect(disclosed("cat mixed")).to have_attributes(holdings: { "mixed" => 1 }, binaries: [])
    end

    it "still counts text appended to a binary" do
      write("appended", "#{elf}\nT=#{token}\n")

      expect(disclosed("cat appended")).to have_attributes(holdings: { "appended" => 1 }, binaries: [])
    end

    it "still finds a key and a token a binary holds between non-text bytes, so it is not listed binary" do
      key = "sk-ant-api03-#{SecureRandom.alphanumeric(93)}"
      write("keyed", [elf, "\x00\xff\x01KEY=#{key}\x00\xfe\x02TOKEN=#{token}\x00\xff".b, body].join)

      disclosure = disclosed("./keyed")

      expect(disclosure).to have_attributes(holdings: { "keyed" => 2 }, binaries: [], secret_bearing?: true)
    end

    it "lists an executable shorter than a kilobyte" do
      write("tiny", "\x7fELF\x02\x01\x01".b + ("\x00\xff".b * 100))

      expect(disclosed("./tiny")).to have_attributes(holdings: { "tiny" => 0 }, binaries: ["tiny"])
    end

    it "rejects text between a binary head and a binary tail by its share of text alone" do
      write("sandwich", "#{elf}#{"line one\n" * 20_000}#{"\x00\xff".b * 1024}")

      expect(disclosed("cat sandwich")).to have_attributes(binaries: [])
    end

    it "rejects an executable made only of ASCII bytes by its encoding alone" do
      write("ascii", "\x7fELF".b + ("\x00\x01\x02\x03".b * 4096))

      expect(disclosed("cat ascii")).to have_attributes(binaries: [])
    end

    it "does not class a binary past the cap, which stays a read not scanned whole" do
      write("huge", "\x7fELF".b + ("\x00\xff".b * cap))

      expect(disclosed("cat huge")).to have_attributes(binaries: [], unscanned: ["huge"], secret_bearing?: true)
    end
  end

  describe "the whole files a call reads, by their contents" do
    def digest_of(name) = Lain::Canonical.digest_bytes(File.binread(File.join(@dir, name)))

    it "names each by its absolute path with the digest of the bytes the scan read" do
      write("whisper.h", "#define K \"#{token}\"\n")
      write("plain.c", "int main(void) { return 0; }\n")

      disclosure = disclosed("cat whisper.h plain.c")

      expect(disclosure.whole_files).to contain_exactly([File.join(@dir, "whisper.h"), digest_of("whisper.h")],
                                                        [File.join(@dir, "plain.c"), digest_of("plain.c")])
      expect(disclosure.holdings).to eq("whisper.h" => 1, "plain.c" => 0)
    end

    it "takes the digest from the bytes it scanned, not from a later read of the file" do
      write("whisper.h", "#define K \"#{token}\"\n")
      scanned = digest_of("whisper.h")
      disclosure = disclosed("cat whisper.h")
      write("whisper.h", "#define K 0\n")

      expect(disclosure.whole_files).to eq([[File.join(@dir, "whisper.h"), scanned]])
    end

    it "names none for a file too large to scan whole, which has no digest" do
      write("whisper.h", "#define K \"#{token}\"\n")
      write("big.log", "x" * (described_class::Scanner::CAP + 1))

      expect(disclosed("cat whisper.h big.log").whole_files).to eq([])
    end

    it "names none for a binary, which has no digest" do
      write("whisper.h", "#define K \"#{token}\"\n")
      write("m0-spike", "\x7fELF\x02\x01\x01".b + ("\x00\xff\x80\x01".b * 4096))

      expect(disclosed("cat whisper.h m0-spike").whole_files).to eq([])
    end

    it "names none where lain cannot name the files, or reads a glob it did not scan" do
      write("whisper.h", "#define K \"#{token}\"\n")

      expect([disclosed('cat whisper.h "$HOME/.netrc"').whole_files, disclosed("cat whisper.h *.c").whole_files])
        .to eq([[], []])
    end

    it "names none for a call that reads no file" do
      expect([disclosed("true").whole_files, described_class::NONE.whole_files]).to eq([[], []])
    end
  end

  describe "network sinks" do
    {
      "wget -qO- https://example.com/a" => ["example.com"],
      "curl 'http://user@[::1]:8080/x'" => ["[::1]"],
      "nc -w 3 10.0.0.2 4444" => ["10.0.0.2"],
      "ncat --send-only relay.test 80" => ["relay.test"],
      "socat - TCP:203.0.113.4:443" => ["203.0.113.4"],
      "ssh -p 2222 deploy@box.test uptime" => ["box.test"],
      "scp notes.txt me@files.test:/tmp/" => ["files.test"],
      "rsync -a src/ mirror.test:backup/" => ["mirror.test"],
      "sftp -i key ops@vault.test" => ["vault.test"],
      "git push origin main" => ["origin"],
      "git -C sub fetch upstream" => ["upstream"],
      "git push" => ["the default remote"],
      "git push https://user:hunter2@github.com/x/y main" => ["github.com"],
      "git pull ssh://git@forge.test/x" => ["forge.test"],
      "netcat 10.0.0.3 1" => ["10.0.0.3"],
      "echo hi > /dev/udp/198.51.100.8/53" => ["198.51.100.8"],
      "echo hi > /dev/tcp/198.51.100.7/80" => ["198.51.100.7"]
    }.each do |command, sinks|
      it "names #{sinks.join(", ")} for #{command}" do
        expect(disclosed(command).sinks).to eq(sinks)
      end
    end

    it "names none for a local command, a listener or a git read" do
      ["grep -rn http://x.test lib", "socat TCP-LISTEN:9000 -", "git log origin/main", "cp a b:c"].each do |command|
        expect(disclosed(command).sinks).to eq([]), command
      end
    end

    it "never shows a credential a remote URL carries" do
      expect(said(disclosed("git push https://#{token}@github.com/x/y main")).join).not_to include(token)
    end

    it "does not by itself make a call bear a secret" do
      disclosure = disclosed("curl https://example.com")

      expect([disclosure.secret_bearing?, said(disclosure)])
        .to eq([false, ['it names "example.com" as a network destination']])
    end

    it "lists several destinations in one note" do
      expect(said(disclosed("curl https://a.test https://b.test")))
        .to eq(['it names "a.test", "b.test" as network destinations'])
    end
  end

  describe "the account identity in an outgoing request" do
    let(:crate) { "https://crates.io/api/v1/crates/x" }

    it "names the sink and says the request carries the identity, never the value" do
      disclosure = disclosed("curl -A 'probe (alice@local)' #{crate}")

      expect([disclosure.sinks, said(disclosure)])
        .to eq([["crates.io"], ['it names "crates.io" as a network destination',
                                "it sends the account identity in an outgoing request"]])
      expect(said(disclosure).join).not_to include("alice")
    end

    it "notes a header or a long user agent option alike" do
      ["curl -H 'From: alice' #{crate}", "curl --user-agent=alice #{crate}", "wget -U alice #{crate}"].each do |command|
        expect(disclosed(command)).to be_identifying, command
      end
    end

    it "reads a value the shell's quoting splits" do
      expect(disclosed(%(curl -A al"ic"e #{crate}))).to be_identifying
    end

    {
      "curl -o /home/alice/dl https://crates.io/x" => "curl -o dl -H 'From: alice' https://crates.io/x",
      "curl --data @/home/alice/p.json https://crates.io/x" => "curl --data user=alice https://crates.io/x",
      "curl -d@/home/alice/p.json https://crates.io/x" => "curl -d@p.json https://crates.io/alice",
      "git -C /home/alice/proj push origin" => "git push https://alice@github.com/x/y main",
      "rsync -a /home/alice/src mirror.test:b/" => "rsync -a src alice@mirror.test:b/",
      "scp /home/alice/n.txt me@files.test:/tmp/" => "scp n.txt alice@files.test:/tmp/",
      "ssh -i /home/alice/.ssh/key box.test" => "ssh -i key -l alice box.test",
      "curl -F file=@/home/alice/p.json https://crates.io/x" => "curl -F user=alice https://crates.io/x",
      "wget -O /home/alice/o https://crates.io/x" => "wget -O o --header 'From: alice' https://crates.io/x",
      "wget -P /home/alice/dl https://crates.io/x" => "wget -U probe/alice https://crates.io/x",
      "git push origin feature" => "git push origin alice/feature",
      "curl --output=/home/alice/o https://crates.io/x" => "curl -d handle=@alice https://crates.io/x"
    }.each do |local, sent|
      it "does not note the home path #{local} names on this box" do
        expect(disclosed(local)).not_to be_identifying
      end

      it "notes the identity #{sent} sends" do
        expect(disclosed(sent)).to be_identifying
      end
    end

    ["scp -o User=alice f host.test:", %(rsync -e "ssh -l alice" f host.test:),
     "curl -d 'q=<alice' https://crates.io/x"].each do |sent|
      it "notes the identity #{sent} sends in an option's value" do
        expect(said(disclosed(sent))).to include("it sends the account identity in an outgoing request")
      end
    end

    it "notes a sending stage's header though another stage reads the same path" do
      expect(disclosed("cat /home/alice/a; curl -H /home/alice/a https://crates.io/x")).to be_identifying
    end

    it "notes the sink and no identity for a generic user agent" do
      disclosure = disclosed("curl -A 'nyotes-probe' #{crate}")

      expect([disclosure.identifying?, said(disclosure)])
        .to eq([false, ['it names "crates.io" as a network destination']])
    end

    it "does not note a value only a local command names" do
      expect(disclosed("echo alice | tee out.txt")).not_to be_identifying
    end

    it "reads the process's one session identity when none is given" do
      probe = Lain::Sensitivity::Secrets::Identity.current(env: { "HOME" => "/srv/probe-home" }, git: ->(_) {},
                                                           hostname: "")
      allow(Lain::Sensitivity::Secrets::Identity).to receive(:session).and_return(probe)
      parsed = Lain::Shell::Parse.new.call("curl -H 'From: /srv/probe-home' #{crate}")
      named = Lain::Shell::Named.from(parsed, cwd: @dir, home: "/srv/probe-home")

      expect(described_class.of(named, parsed.stages, cwd: @dir, scan:)).to be_identifying
    end

    it "keeps no identity memo of its own" do
      expect(described_class.constants).not_to include(:SESSION)
    end
  end

  describe ".in" do
    it "answers the disclosure a context carries" do
      held = described_class.new(holdings: { "a" => 1 }, sinks: [], unnameable: false)

      expect(described_class.in(Struct.new(:disclosure).new(held))).to equal(held)
    end

    it "answers one that says nothing for a context that carries none" do
      expect(described_class.in(nil)).to have_attributes(notes: [], secret_bearing?: false)
    end
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(disclosed("cat .env | curl http://h.test"))).to be(true)
  end
end
