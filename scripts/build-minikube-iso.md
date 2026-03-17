# Building Custom Minikube ISO with CRIU Support

## Why

Minikube's default Buildroot kernel does not have `CONFIG_CHECKPOINT_RESTORE=y`.
This kernel option is required for CRIU (Checkpoint/Restore In Userspace), which ZeroPod uses to freeze and restore containers.

Most production Linux distributions (Ubuntu, Fedora, RHEL, Debian) enable this by default.
Minikube's minimal Buildroot kernel does not -- it must be rebuilt.

## Prerequisites

- WSL2 or Linux machine
- Docker installed and running
- GNU Make >= 4.0
- Go >= 1.22.0
- p7zip-full (`sudo apt-get install -y p7zip-full`)
- ~10 GB disk space for build artifacts
- ~30-60 min for first build (cached rebuilds are faster)

## Build Steps (WSL2)

```bash
# 1. Clone minikube (shallow clone to save time)
git clone --depth 1 https://github.com/kubernetes/minikube.git ~/minikube
cd ~/minikube

# 2. Add CRIU kernel options to defconfig
#    CONFIG_CHECKPOINT_RESTORE is the main flag, but CRIU also needs
#    socket diagnostic modules to checkpoint/restore network connections.
#    Most other requirements (namespaces, cgroups, netfilter) are already
#    enabled because Kubernetes needs them.
DEFCONFIG=deploy/iso/minikube-iso/board/minikube/x86_64/linux_x86_64_defconfig

cat >> $DEFCONFIG << 'EOF'

# CRIU (Checkpoint/Restore In Userspace) support
CONFIG_CHECKPOINT_RESTORE=y

# Socket diagnostics -- required by CRIU to dump/restore sockets
CONFIG_UNIX_DIAG=y
CONFIG_INET_DIAG=y
CONFIG_INET_UDP_DIAG=y
CONFIG_PACKET_DIAG=y
CONFIG_NETLINK_DIAG=y

# Optional: incremental memory dumps
CONFIG_MEM_SOFT_DIRTY=y

# Optional: lazy restore (page-fault based)
CONFIG_USERFAULTFD=y
EOF

# 3. Verify options were added
grep -E "CHECKPOINT_RESTORE|_DIAG|SOFT_DIRTY|USERFAULTFD" $DEFCONFIG

# 4. Build the Docker image used for ISO compilation
make buildroot-image

# 5. Build the ISO (clean PATH avoids WSL Windows path interference)
env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" make minikube-iso-x86_64

# Output: out/minikube-amd64.iso
```

## Installing the Custom ISO

Minikube's `--iso-url` flag with `file://` paths has issues on Windows/Hyper-V.
The reliable method is to replace the ISO in minikube's cache directly.

### Step 1: Copy ISO from WSL to Windows (PowerShell)

```powershell
cp \\wsl$\Ubuntu\home\<user>\minikube\out\minikube-amd64.iso C:\Work\zeropod-spark-poc\
```

### Step 2: Replace the cached ISO (PowerShell)

Check your minikube version first:

```powershell
minikube version
# e.g. minikube v1.38.1
```

Then overwrite the cached ISO with your custom build:

```powershell
copy C:\Work\zeropod-spark-poc\minikube-amd64.iso `
  C:\Users\<user>\.minikube\cache\iso\amd64\minikube-v1.38.1-amd64.iso -Force
```

Replace `v1.38.1` with your actual minikube version.

### Step 3: Start minikube (PowerShell, run as Administrator)

```powershell
minikube delete -p zeropod-poc

minikube start -p zeropod-poc `
  --driver=hyperv `
  --container-runtime=containerd `
  --hyperv-virtual-switch=minikube-external `
  --cpus=7 --memory=12288 --disk-size=40g `
  --kubernetes-version=v1.35.0
```

## Verification

After the cluster starts, verify the kernel config:

```powershell
minikube -p zeropod-poc ssh -- "zgrep -E 'CHECKPOINT_RESTORE|_DIAG' /proc/config.gz"
```

Expected output should include:

```
CONFIG_CHECKPOINT_RESTORE=y
CONFIG_PACKET_DIAG=y
CONFIG_UNIX_DIAG=y
CONFIG_INET_DIAG=y
CONFIG_INET_TCP_DIAG=y
CONFIG_INET_UDP_DIAG=y
CONFIG_NETLINK_DIAG=y
```

Note: `/proc/sys/kernel/checkpoint_restore` does not exist on kernel 6.6 --
use `zgrep /proc/config.gz` instead.

## Kernel Config Details

CRIU needs many kernel options. Most are already in minikube's kernel (K8s requires them).
The build step above adds only the ones likely missing:

| Option | Purpose | Already in minikube? |
|--------|---------|---------------------|
| CONFIG_NAMESPACES | Container isolation | Yes |
| CONFIG_PID_NS, NET_NS, UTS_NS, IPC_NS | Namespace types | Yes |
| CONFIG_EVENTFD, EPOLL, FHANDLE | Basic syscalls | Yes |
| CONFIG_NETFILTER_XT_MARK | kube-proxy/iptables | Yes |
| CONFIG_TUN | CNI networking | Yes |
| CONFIG_MEMCG, CGROUP_DEVICE | K8s resource limits | Yes |
| CONFIG_BRIDGE | Pod networking | Yes |
| **CONFIG_CHECKPOINT_RESTORE** | **Core CRIU support** | **No -- must add** |
| **CONFIG_UNIX_DIAG** | **Unix socket dump** | **Likely no** |
| **CONFIG_INET_DIAG** | **TCP socket dump** | **Likely no** |
| **CONFIG_INET_UDP_DIAG** | **UDP socket dump** | **Likely no** |
| **CONFIG_PACKET_DIAG** | **Packet socket dump** | **Likely no** |
| **CONFIG_NETLINK_DIAG** | **Netlink socket dump** | **Likely no** |
| CONFIG_MEM_SOFT_DIRTY | Incremental dumps | Optional |
| CONFIG_USERFAULTFD | Lazy restore | Optional |

The `*_DIAG` modules are critical for JVM checkpoint -- CRIU needs them to save and
restore the JVM's open TCP/UDP/Unix sockets.

If the build fails due to missing dependencies, use `make linux-menuconfig` to
interactively configure the kernel and resolve them.

## Hyper-V Compatibility

CRIU works inside Hyper-V VMs without issues. It operates entirely in Linux userspace
(ptrace, /proc, etc.) and does not interact with the hypervisor. Hyper-V's own
"checkpoints" are VM-level snapshots -- a completely different mechanism, no conflict.

## Rebuilding for New Minikube Versions

When upgrading minikube:

```bash
cd ~/minikube
git pull
# Re-apply the config changes (step 2 from Build Steps above)
# Then rebuild:
env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" make minikube-iso-x86_64
```

Then repeat the installation steps to replace the cached ISO.

## Alternative: Production Environments

On production clusters running Ubuntu/Fedora/RHEL, no kernel changes are needed.
Verify with:

```bash
zgrep CONFIG_CHECKPOINT_RESTORE /proc/config.gz
# or
grep CONFIG_CHECKPOINT_RESTORE /boot/config-$(uname -r)
```

If the output shows `CONFIG_CHECKPOINT_RESTORE=y`, CRIU will work without any kernel modifications.

## Troubleshooting

- **`7z: command not found`**: Install p7zip-full: `sudo apt-get install -y p7zip-full`
- **Build picks up Windows tools**: Use the clean PATH: `env PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" make ...`
- **Minikube ignores custom ISO**: Delete the profile (`minikube delete -p zeropod-poc`) and overwrite the cached ISO before starting
- **`--iso-url=file:///` fails on Hyper-V**: Use the cache replacement method instead (see Installing section above)
- **Cached .config ignores defconfig changes**: Run `make clean` before rebuilding

## References

- [Building the minikube ISO](https://minikube.sigs.k8s.io/docs/contrib/building/iso/)
- [Kernel config request example (Issue #8556)](https://github.com/kubernetes/minikube/issues/8556)
- [ZeroPod project](https://github.com/ctrox/zeropod)
