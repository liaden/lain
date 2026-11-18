# Running lain in a Lima VM

On macOS there is no bwrap and no Landlock, so lain's confinement runs degraded. The Lima template at
`lima/lain.yaml` starts an Ubuntu 24.04 VM where all of it works. Lain runs inside the VM against your
checkout.

You need [Lima](https://lima-vm.io) 1.1 or newer (`brew install lima`).

## Start the VM

The template mounts exactly 2 directories, both writable: your lain checkout at `/mnt/lain` and
`~/tmp/lain` at `/mnt/lain-tmp`, which the VM uses as `TMPDIR`. If your checkout is not at `~/dev/lain`,
edit the first `location` in the template. Create the second directory first:

```bash
mkdir -p ~/tmp/lain
limactl start lima/lain.yaml
```

The first boot installs the spec binaries, then mise, Ruby, Rust, clang and the bundle. It takes a few
minutes. Later boots run the same steps and skip what is installed. Open a shell with:

```bash
limactl shell lain
cd /mnt/lain
eval "$(mise env -s bash ruby@$(sed 's/^ruby-//' .ruby-version))"
```

## Build

`CARGO_TARGET_DIR` is `/var/lib/lain-target`, inside the VM, so the build never touches the `target/`
directory your Mac uses. The compiled extension is `lain.so` in the VM and `lain.bundle` on the Mac, so
both can sit in `lib/lain/`.

```bash
bundle exec rake compile
```

## Check that confinement is on

The fence reports the Landlock ABI it found:

```bash
"$CARGO_TARGET_DIR/release/lain-fence" --status
```

Then start a chat and make its first bash call. The session journal should hold no `CapabilityDegraded`
record. If it does, the guest kernel lacks Landlock or user namespaces.
