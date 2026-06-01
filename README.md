# Linux Kernel Builder & Manager

通过 GitHub Actions 构建自定义内核（.deb），支持开启 BBRv3 (apply bbr3.patch from CachyOS)，并提供脚本方便安装/卸载内核。

## 快速开始

### 1. 构建内核

将下列文件放入你的仓库：

- `.github/workflows/build-kernel.yml` – 可重用构建工作流
- `.github/workflows/trigger-bbrv3.yml` – 示例：构建 BBRv3 内核
- `config` – 内核配置文件（放在仓库根目录）

在 GitHub 仓库中手动触发 Action → 完成后 Release 会生成 `*.tar.gz`。

### 2. 安装/管理内核

在目标 Ubuntu/Debian 主机上（root 用户）：

```bash
curl -O https://raw.githubusercontent.com/hellooe/Latest-Kernel/main/kernel-manager.sh && chmod +x kernel-manager.sh

# 设置仓库（默认或手动指定）
export GITHUB_REPO="你的用户名/仓库名"

# 列出可用版本
./kernel-manager.sh list

# 安装指定版本
./kernel-manager.sh install 7.0.10

# 安全卸载指定版本
./kernel-manager.sh uninstall 7.0.10
```

## 命令一览

| 命令 | 说明 |
|------|------|
| `list` | 查看可下载的内核版本 |
| `install <版本>` | 下载并安装内核 |
| `uninstall <版本>` | 卸载已安装内核 |
| `clean` | 清理缓存文件 |

## 环境变量

- `GITHUB_REPO` – GitHub 仓库 `owner/repo`
- `DOWNLOAD_DIR` – 缓存目录，默认 `~/.cache/kernel-manager`

## 文件说明

- `build-kernel.yml` – 可复用工作流（下载、编译kernel.org官方源码）
- `trigger-bbrv3.yml` – 手动触发，构建带BBRv3的内核
- `trigger-stable.yml` – 手动触发，构建最新稳定内核
- `kernel-manager.sh` – 内核下载/安装/卸载脚本


