# Linux Kernel Builder & Manager

Languages: English | [简体中文](README.zh-CN.md)

Build custom Linux kernel `.deb` packages with GitHub Actions, then install or remove them on Debian/Ubuntu with `kernel-manager.sh`.

## What It Does

- Builds Linux stable kernels from `linux-${kernel_version}.y`.
- Optionally applies the CachyOS BBRv3 patch.
- Publishes Release assets:
  - `kernel-<version>.tar.gz`
  - `config-<version>.tar.gz`
- Installs, uninstalls, lists, and cleans downloaded kernels.

## Files

```text
.github/workflows/build-kernel.yml    Reusable build workflow
.github/workflows/trigger-stable.yml  Build a standard stable kernel
.github/workflows/trigger-bbrv3.yml   Build a BBRv3 kernel
config                                Kernel .config
kernel-manager.sh                     Install/uninstall helper
```

## Build

Run one of these workflows from GitHub Actions:

- `Build Latest Stable Kernel`
- `Build BBRv3 Kernel`

Set `kernel_version`, for example:

```text
7.0
```

The workflow creates a GitHub Release containing the built kernel packages.

## Install

On the target Debian/Ubuntu host:

```bash
curl -O https://raw.githubusercontent.com/hellooe/Latest-Kernel/main/kernel-manager.sh
chmod +x kernel-manager.sh
```

If using your own repository:

```bash
export GITHUB_REPO="owner/repo"
```

List versions:

```bash
./kernel-manager.sh list
```

Install:

```bash
./kernel-manager.sh install <version>
```

Uninstall:

```bash
./kernel-manager.sh uninstall <version>
```

Clean cache:

```bash
./kernel-manager.sh clean
```

## Requirements

The script must run as `root` and requires `dpkg`, `apt-get`, `tar`, `find`, `curl`, `jq` and `update-grub`.

## Environment

| Variable | Default |
| --- | --- |
| `GITHUB_REPO` | `hellooe/Latest-Kernel` |
| `DOWNLOAD_DIR` | `/root/.cache/kernel-manager` |

## Notes

- Keep at least one known-good old kernel installed.
- Reboot after installing a new kernel.
- The script refuses to uninstall the currently running kernel.
- BBRv3 patch availability depends on CachyOS.

## License

MIT. See [LICENSE](LICENSE).
