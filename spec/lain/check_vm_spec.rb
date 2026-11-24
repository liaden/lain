# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "tmpdir"

# The script runs inside a guest, so every command it asks is a fake here: a healthy world, then 1 fault per example.
RSpec.describe "bin/ci/check-vm", :seam do
  let(:source) { File.expand_path("../../bin/ci/check-vm", __dir__) }
  let(:resolver) { %w[/run/systemd/resolve/io.systemd.Resolve /run/systemd/resolve/io.systemd.Resolve.Monitor] }
  let(:status) do
    { abi: 8, private_net: false,
      rights: { connect_tcp: "enforced", resolve_unix: "dropped", abstract_unix_socket: "enforced" } }
  end
  let(:mac) { { "payload" => { "protocol" => "ip", "field" => "daddr" } } }
  let(:subnet) { { "prefix" => { "addr" => "192.168.5.0", "len" => 24 } } }
  # What nft 1.1.6 printed for the provisioned table, loaded in a private network namespace.
  let(:mac_rules) do
    [[match({ "ct" => { "key" => "state" } }, %w[established related], operator: "in"), accept],
     [match(mac, "192.168.5.2"), port("tcp", 11_434), accept],
     [match(mac, "192.168.5.2"), port("udp", 53), accept],
     [match(mac, "192.168.5.2"), port("tcp", 53), accept],
     [match(mac, "192.168.5.2"), port("udp", 67), accept],
     [match({ "fib" => { "result" => "type", "flags" => ["daddr"] } }, "local"), accept],
     [match({ "meta" => { "key" => "l4proto" } }, "tcp"), match(mac, subnet), { "counter" => "lain_mac_rejected" },
      { "reject" => { "type" => "tcp reset" } }],
     [match(mac, subnet), { "counter" => "lain_mac_rejected" },
      { "reject" => { "type" => "icmp", "expr" => "port-unreachable" } }]]
  end

  around do |example|
    Dir.mktmpdir("cvm") do |dir|
      @world = dir
      build_world
      example.run
    end
  end

  def match(left, right, operator: "==") = { "match" => { "op" => operator, "left" => left, "right" => right } }
  def port(protocol, number) = match({ "payload" => { "protocol" => protocol, "field" => "dport" } }, number)
  def accept = { "accept" => nil }

  def path(*parts) = File.join(@world, *parts)

  def write(relative, text, mode: nil)
    FileUtils.mkdir_p(File.dirname(path(relative)))
    File.write(path(relative), text)
    File.chmod(mode, path(relative)) if mode
  end

  def fake(name, body) = write("fakes/#{name}", "#!/bin/sh\n#{body}", mode: 0o755)

  def build_world
    FileUtils.mkdir_p(path("bin/ci"))
    FileUtils.cp(source, path("bin/ci/check-vm")) if File.exist?(source)
    write("target/release/lain-fence", "#!/bin/sh\n[ \"$1\" = --status ] || exit 64\ncat \"$FAKE/status.json\"\n",
          mode: 0o755)
    write_workspace_run
    write_fakes
    write_healthy_answers
    write_guest_root
    sweep(:nonet, netns: "net:[2]")
    sweep(:grant, netns: "net:[1]", reach: resolver)
  end

  def write_workspace_run
    write("bin/workspace-run", <<~SH, mode: 0o755)
      #!/bin/sh
      printf '%s|%s|%s\\n' "$*" "${LAIN_ENV_PASS:-}" "${GIT_SSH_COMMAND:-}" >>"$FAKE/calls"
      case " $* " in
        *" --grant "*) call=grant ;;
        *) call=nonet ;;
      esac
      if [ -f "$FAKE/real-$call" ]; then
        while [ "$1" != -- ]; do shift; done
        shift
        exec "$@"
      fi
      cat "$FAKE/$call.out" >&2
      exit "$(cat "$FAKE/$call.rc" 2>/dev/null || echo 0)"
    SH
  end

  # The fake timeout stands in for the probe to the Mac, and the table's reject is what moves the counter.
  def write_fakes
    fake("tmux", 'cat "$FAKE/tmux.out"')
    fake("ssh-add", 'exit "$(cat "$FAKE/ssh-add.rc")"')
    fake("timeout", <<~SH)
      printf '%s\\n' "$*" >>"$FAKE/probes"
      [ -f "$FAKE/rejects" ] && echo $(($(cat "$FAKE/rejected") + 1)) >"$FAKE/rejected"
      exit 1
    SH
    write_fake_nft
  end

  def write_fake_nft
    fake("sudo", <<~SH)
      printf '%s\\n' "$*" >>"$FAKE/sudo"
      [ "$1" = -n ] || exit 1
      case "$*" in
        "-n nft -j list table inet lain_mac") [ -f "$FAKE/table.json" ] && exec cat "$FAKE/table.json" ;;
        "-n nft -j list counter inet lain_mac lain_mac_rejected")
          [ -f "$FAKE/table.json" ] &&
            printf '{"nftables": [{"metainfo": {}}, {"counter": {"name": "lain_mac_rejected", "packets": %s}}]}\\n' \\
              "$(cat "$FAKE/rejected")" && exit 0 ;;
      esac
      exit 1
    SH
  end

  def write_healthy_answers
    write("tmux.out", "tmux 3.6\n")
    write("ssh-add.rc", "2")
    write("rejected", "7")
    write("rejects", "")
    write("status.json", JSON.generate(status))
    write_table(mac_rules)
  end

  def write_table(rules, **hook)
    chain = { "chain" => { "family" => "inet", "table" => "lain_mac", "name" => "out", "type" => "filter",
                           "hook" => "output", "prio" => 0, "policy" => "accept", **hook.transform_keys(&:to_s) } }
    items = rules.map { { "rule" => { "family" => "inet", "table" => "lain_mac", "chain" => "out", "expr" => _1 } } }
    write("table.json", JSON.generate("nftables" => [{ "metainfo" => {} }, chain, *items]))
  end

  def write_guest_root
    write("root/proc/self/mounts", "/dev/vda1 / ext4 rw 0 0\ntmpfs /run tmpfs rw 0 0\n")
    write("root/proc/sys/kernel/apparmor_restrict_unprivileged_userns", "1\n")
    write("root/usr/lib/sysctl.d/10-apparmor.conf", "kernel.apparmor_restrict_unprivileged_userns = 1\n")
    write_unix_table([*resolver, "/run/dbus/system_bus_socket", "/run/user/1000/bus"])
    FileUtils.ln_s("net:[1]", path("root/proc/self/ns/net").tap { FileUtils.mkdir_p(File.dirname(_1)) })
  end

  # /proc/net/unix as the kernel writes it: flags 00010000 mark a listener, type 0002 a datagram socket.
  def write_unix_table(listeners, extra: [])
    lines = listeners.each_with_index.map do |name, i|
      "0000000000000000: 00000002 00000000 00010000 0001 01 #{100 + i} #{name}"
    end
    write("root/proc/net/unix", ["Num       RefCount Protocol Flags    Type St Inode Path",
                                 "0000000000000000: 00000003 00000000 00000000 0001 03 55730",
                                 "0000000000000000: 00000002 00000000 00010000 0001 01 9 @/abstract/name",
                                 *lines, *extra].join("\n") << "\n")
  end

  def sweep(call, netns:, reach: [], swept: 4)
    write("#{call}.out", ["lain-check-vm netns #{netns}", *reach.map { "lain-check-vm reach #{_1}" },
                          "lain-check-vm swept #{swept}"].join("\n") << "\n")
  end

  def check(env = {})
    base = { "PATH" => "#{path("fakes")}:#{ENV.fetch("PATH")}", "FAKE" => @world,
             "SSH_AUTH_SOCK" => nil, "LAIN_ENV_PASS" => nil, "GIT_SSH_COMMAND" => nil }
    Open3.capture2e(base.merge(env), path("bin/ci/check-vm"), path("root"), chdir: @world, stdin_data: "")
  end

  def calls = File.exist?(path("calls")) ? File.readlines(path("calls"), chomp: true) : []

  it "reports every requirement of a healthy VM and passes" do
    out, result = check

    expect(result).to be_success, out
    expect(out).to include("tmux 3.6", "Landlock ABI 8", "abstract Unix sockets", "private network namespace",
                           "no host mount", "AppArmor", "inet lain_mac", "rejected a connect to 192.168.5.2:47321")
  end

  it "sweeps through a no-network call and a git grant call" do
    out, result = check

    expect(result).to be_success, out
    nonet, grant = calls
    expect(nonet).not_to include("--grant")
    expect(grant).to include("--grant git -- git ls-remote --quiet ssh:")
    expect(grant).to include("|GIT_SSH_COMMAND|")
  end

  it "runs from stdin with the current directory as the checkout, as bin/lain-vm sends it" do
    out, result = Open3.capture2e({ "PATH" => "#{path("fakes")}:#{ENV.fetch("PATH")}", "FAKE" => @world,
                                    "SSH_AUTH_SOCK" => nil }, "bash", "-s", "--", path("root"),
                                  chdir: @world, stdin_data: File.read(source))

    expect(result).to be_success, out
    expect(calls.size).to eq(2)
  end

  it "states the ABI gap when resolve_unix is dropped" do
    out, = check

    expect(out).to include("Landlock does not filter Unix connects on this kernel")
  end

  it "does not state the gap where Landlock filters Unix connects" do
    write("status.json", JSON.generate(status.merge(abi: 9, rights: status[:rights].merge(resolve_unix: "enforced"))))

    out, result = check

    expect(result).to be_success, out
    expect(out).not_to include("does not filter Unix connects")
  end

  it "fails a fence that leaves abstract sockets unscoped, since the sweep tries path sockets only" do
    write("status.json", JSON.generate(status.merge(rights: status[:rights].merge(abstract_unix_socket: "dropped"))))

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("abstract_unix_socket")
  end

  it "fails a no-network call that reaches a socket, and names it" do
    sweep(:nonet, netns: "net:[2]", reach: ["/run/dbus/system_bus_socket"])

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("/run/dbus/system_bus_socket")
  end

  it "fails a grant call that reaches a socket beyond the resolver, and names it" do
    sweep(:grant, netns: "net:[1]", reach: [*resolver, "/run/user/1000/bus"])

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("/run/user/1000/bus")
  end

  it "fails a grant call that cannot reach a resolver socket, and names it" do
    sweep(:grant, netns: "net:[1]", reach: resolver.take(1))

    out, result = check

    expect(result).not_to be_success
    expect(out).to include(resolver.last)
  end

  it "fails when a sweep did not run" do
    write("nonet.out", "workspace-run: this box cannot sandbox a call\n")
    write("nonet.rc", "69")

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("the no-network sweep did not run")
  end

  it "fails a no-network call that shares the VM's network namespace" do
    sweep(:nonet, netns: "net:[1]")

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("private network namespace")
  end

  it "fails a socket table line it cannot parse, rather than leave a socket unswept" do
    write_unix_table(resolver, extra: ["line"])

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("cannot parse")
    expect(calls).to be_empty
  end

  describe "with the real sweep" do
    around do |example|
      Dir.mktmpdir("s", ENV.fetch("TMPDIR", Dir.tmpdir)) do |dir|
        @dir = dir
        @socket = File.join(dir, "two  spaces ")
        UNIXServer.open(@socket) { example.run }
      end
    end

    it "names a live socket a no-network call can reach, keeping every space in its name" do
      write_unix_table([@socket, File.join(@dir, "gone.sock")])
      FileUtils.touch(path("real-nonet"))

      out, result = check

      expect(result).not_to be_success
      expect(out).to include("reached: #{@socket}\n")
      expect(out).not_to include("gone.sock")
    end

    it "reaches a datagram socket as a datagram socket" do
      dgram = File.join(@dir, "dgram")
      Socket.open(:UNIX, :DGRAM) do |socket|
        socket.bind(Socket.sockaddr_un(dgram))
        write_unix_table([], extra: ["0000000000000000: 00000002 00000000 00000000 0002 01 77 #{dgram}"])
        FileUtils.touch(path("real-nonet"))

        out, result = check

        expect(result).not_to be_success
        expect(out).to include("reached: #{dgram}")
      end
    end

    it "names a live socket the grant call's own child can reach" do
      write_unix_table([@socket])
      FileUtils.touch(path("real-grant"))

      out, result = check

      expect(result).not_to be_success
      expect(out).to include(@socket)
    end
  end

  it "fails a tmux older than 3.5 and names its version" do
    write("tmux.out", "tmux 3.4\n")

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("tmux 3.4")
    expect(calls).to be_empty
  end

  it "fails a Landlock ABI below 8" do
    write("status.json", JSON.generate(status.merge(abi: 7)))

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("Landlock ABI 7")
  end

  it "fails a mounted Mac folder and names the mount" do
    write("root/proc/self/mounts", "/dev/vda1 / ext4 rw 0 0\nmount0 /Users/joel virtiofs rw 0 0\n")

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("/Users/joel")
  end

  it "fails when SSH_AUTH_SOCK reaches a live agent" do
    write("ssh-add.rc", "1")

    out, result = check("SSH_AUTH_SOCK" => path("agent.sock"))

    expect(result).not_to be_success
    expect(out).to include("an SSH agent answers at #{path("agent.sock")}")
  end

  it "fails when no ssh-add can check SSH_AUTH_SOCK" do
    write("ssh-add.rc", "127")

    out, result = check("SSH_AUTH_SOCK" => path("agent.sock"))

    expect(result).not_to be_success
    expect(out).to include("ssh-add is not installed")
  end

  it "passes a SSH_AUTH_SOCK with no agent behind it" do
    out, result = check("SSH_AUTH_SOCK" => path("agent.sock"))

    expect(result).to be_success, out
  end

  it "fails when the AppArmor restriction is off" do
    write("root/proc/sys/kernel/apparmor_restrict_unprivileged_userns", "0\n")

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("apparmor_restrict_unprivileged_userns is 0")
  end

  { "/etc/sysctl.d/60-lain-userns.conf" => "kernel.apparmor_restrict_unprivileged_userns = 0",
    "/etc/sysctl.d/99-other.conf" => "kernel/apparmor_restrict_unprivileged_userns=0",
    "/etc/sysctl.conf" => "-kernel.apparmor_restrict_unprivileged_userns = 0",
    "/usr/lib/sysctl.d/99-late.conf" => "  kernel.apparmor_restrict_unprivileged_userns = 0" }.each do |file, line|
    it "fails when #{file} lifts the restriction on the next boot" do
      write("root#{file}", "# unrelated\n#{line}\n")

      out, result = check

      expect(result).not_to be_success
      expect(out).to include(file)
    end
  end

  it "fails when the lain_mac nftables table is not loaded, asking nft through sudo -n" do
    FileUtils.rm(path("table.json"))

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("lain_mac")
    expect(File.read(path("sudo"))).to include("-n nft -j list table inet lain_mac")
  end

  {
    "lacks the Ollama accept" => ->(rules) { rules.reject { _1.include?(rules[1][1]) } },
    "lacks the DHCP accept" => ->(rules) { rules.reject { _1.include?(rules[4][1]) } },
    "lacks the local-address accept" => ->(rules) { rules.reject.with_index { |_, i| i == 5 } },
    "rejects before it accepts Ollama" => ->(rules) { [rules[0], *rules.last(2), *rules[1..5]] },
    "accepts the whole subnet first" => ->(rules) { [rules[0], [rules[7][0], { "accept" => nil }], *rules[1..]] },
    "rejects with no counter" => ->(rules) { [*rules[0..6], rules[7].reject { _1.key?("counter") }] }
  }.each do |name, change|
    it "fails a lain_mac table that #{name}" do
      write_table(change.call(mac_rules))

      out, result = check

      expect(result).not_to be_success
      expect(out).to include("differs from the rules lain needs")
    end
  end

  { hook: "input", prio: 10, policy: "drop" }.each do |key, wrong|
    it "fails a lain_mac table with the right rules but a #{key} of #{wrong}" do
      write_table(mac_rules, key => wrong)

      out, result = check

      expect(result).not_to be_success
      expect(out).to include("differs from the rules lain needs")
    end
  end

  it "fails when a probe to the Mac does not reach the table's reject" do
    FileUtils.rm(path("rejects"))

    out, result = check

    expect(result).not_to be_success
    expect(out).to include("192.168.5.2:47321", "counter 7, then 7")
  end

  it "probes the Mac once, on a high port, through the counter's reads" do
    out, result = check

    expect(result).to be_success, out
    expect(File.readlines(path("probes"), chomp: true)).to eq([%(3 bash -c exec 3<>"/dev/tcp/$0/$1" 192.168.5.2 47321)])
    expect(File.read(path("sudo")).scan("list counter inet lain_mac lain_mac_rejected").size).to eq(2)
  end
end
