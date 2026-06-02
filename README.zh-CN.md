# Linux Kernel Builder & Manager

语言：[English](README.md) | 简体中文

使用 GitHub Actions 构建自定义 Linux 内核 `.deb` 包，并通过 `kernel-manager.sh` 在 Debian/Ubuntu 上安装或卸载。

## 功能

- 从 `linux-${kernel_version}.y` 构建 Linux stable 内核。
- 可选应用 CachyOS BBRv3 patch。
- 发布 Release 资源：
  - `kernel-<version>.tar.gz`
  - `config-<version>.tar.gz`
- 支持列出、安装、卸载和清理内核包。

## 文件

```text
.github/workflows/build-kernel.yml    可复用构建 workflow
.github/workflows/trigger-stable.yml  构建普通 stable 内核
.github/workflows/trigger-bbrv3.yml   构建 BBRv3 内核
config                                内核 .config
kernel-manager.sh                     安装/卸载脚本
```

## 构建

在 GitHub Actions 中运行：

- `Build Latest Stable Kernel`
- `Build BBRv3 Kernel`

填写 `kernel_version`，例如：

```text
7.0
```

构建完成后会创建 GitHub Release，并上传内核包。

## 安装

在目标 Debian/Ubuntu 主机上：

```bash
curl -O https://raw.githubusercontent.com/hellooe/Latest-Kernel/main/kernel-manager.sh
chmod +x kernel-manager.sh
```

如果使用自己的仓库：

```bash
export GITHUB_REPO="owner/repo"
```

列出版本：

```bash
./kernel-manager.sh list
```

安装：

```bash
./kernel-manager.sh install <version>
```

卸载：

```bash
./kernel-manager.sh uninstall <version>
```

清理缓存：

```bash
./kernel-manager.sh clean
```

## 依赖

脚本必须以 `root` 运行，并依赖 `dpkg`、`apt-get`、`tar`、`find`、`curl`、`jq`、`update-grub`。

## 环境变量

| 变量 | 默认值 |
| --- | --- |
| `GITHUB_REPO` | `hellooe/Latest-Kernel` |
| `DOWNLOAD_DIR` | `/root/.cache/kernel-manager` |

## 注意

- 保留至少一个可正常启动的旧内核。
- 安装新内核后需要重启。
- 脚本不会卸载当前正在运行的内核。
- BBRv3 patch 是否可用取决于 CachyOS。

## 许可证

MIT，见 [LICENSE](LICENSE)。
