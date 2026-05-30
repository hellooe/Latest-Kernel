# Linux Kernel Builder & Manager

通过 GitHub Actions 自动构建自定义内核（.deb），并使用管理脚本一键安装/切换。

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
./kernel-manager.sh install 6.6.0-bbrv3

# 下次启动切换到此内核
./kernel-manager.sh switch

# 重启
reboot
```

## 命令一览

| 命令 | 说明 |
|------|------|
| `list` | 查看可下载的内核版本 |
| `install <版本>` | 下载并安装内核 |
| `uninstall <版本>` | 卸载已安装内核 |
| `switch` | 下次启动使用该内核 |

## 环境变量

- `GITHUB_REPO` – GitHub 仓库 `owner/repo`
- `GITHUB_TOKEN` – 私有仓库或提高 API 限流时需要
- `DOWNLOAD_DIR` – 缓存目录，默认 `~/.cache/kernel-manager`

## 文件说明

- `build-kernel.yml` – 通用内核构建工作流（支持 Git 仓库或 kernel.org 最新稳定版）
- `trigger-bbrv3.yml` – 调用工作流，构建 Google BBRv3 内核
- `trigger-stable.yml` – 调用工作流，构建最新稳定内核
- `kernel-manager.sh` – 内核下载/安装/切换脚本


