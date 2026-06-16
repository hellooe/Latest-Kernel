# Linux Kernel Builder & Manager

Languages: English | [简体中文](README.zh-CN.md)

Build custom Linux kernel `.deb` packages with GitHub Actions, then install or remove them on Debian/Ubuntu with `kernel-manager.sh`.

## What It Does

- Builds Linux stable kernels from `linux-${kernel_version}.y`.
- Optionally applies the BBRv3 patch from a user‑specified URL.
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

For the standard stable kernel, set kernel_version only (e.g., 7.0).
For the BBRv3 kernel, you must provide two inputs:

- `kernel_version` – e.g., 6.12

- `bbr_patch_url` – the full URL to download the BBRv3 patch file

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
- For BBRv3 builds, the patch source must be provided by the user at build time.

## License

MIT. See [LICENSE](LICENSE).
