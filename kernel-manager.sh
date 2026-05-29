#!/usr/bin/env bash
#
# 内核管理器 - 从 GitHub Release 下载、安装、切换、卸载自定义内核
# 注意：此脚本需要以 root 用户运行

set -euo pipefail

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    echo "错误：此脚本必须以 root 用户执行" >&2
    exit 1
fi

# ==================== 配置 ====================
GITHUB_REPO="${GITHUB_REPO:-}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/.cache/kernel-manager}"
KEEP_DOWNLOADS="${KEEP_DOWNLOADS:-2}"          # 保留最近几个下载版本
GH_API="https://api.github.com/repos"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 辅助函数（所有输出重定向到 stderr） ====================
info()    { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
ask()     { echo -en "${BLUE}[?]${NC} $1 " >&2; }

# 通用：更新 GRUB（兼容 update-grub / update-grub2）
update_grub() {
    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v update-grub2 &>/dev/null; then
        update-grub2
    else
        warn "未找到 update-grub/update-grub2，请手动更新引导配置"
    fi
}

# 清理旧的下载缓存
cleanup_downloads() {
    if [[ -d "$DOWNLOAD_DIR" ]]; then
        (
            shopt -s nullglob
            cd "$DOWNLOAD_DIR"
            dirs=(kernel-*)
            if [[ ${#dirs[@]} -gt $KEEP_DOWNLOADS ]]; then
                printf '%s\n' "${dirs[@]}" | sort -V | head -n -${KEEP_DOWNLOADS} | xargs -r rm -rf
            fi
        )
    fi
}

# 检测 GitHub 仓库（owner/repo）
detect_repo() {
    if [[ -n "$GITHUB_REPO" ]]; then
        echo "$GITHUB_REPO"
        return
    fi
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local remote_url=$(git config --get remote.origin.url 2>/dev/null || echo "")
        if [[ -n "$remote_url" ]]; then
            local repo=$(echo "$remote_url" | sed -E 's#.*github.com[:/](.*)\.git#\1#')
            echo "$repo"
            return
        fi
    fi
    error "无法自动检测 GitHub 仓库，请设置环境变量 GITHUB_REPO (格式: 'owner/repo')"
}

# GitHub API 请求（支持私有仓库 token）
gh_api() {
    local endpoint="$1"
    local url="${GH_API}/$(detect_repo)/${endpoint}"
    local token="${GITHUB_TOKEN:-}"
    local auth_header=()
    if [[ -n "$token" ]]; then
        auth_header=(-H "Authorization: token ${token}")
    fi
    curl -sSL "${auth_header[@]}" -H "Accept: application/vnd.github.v3+json" "$url"
}

# 获取所有发布版本（宽松匹配 kernel-*.tar.gz），增加容错
get_releases() {
    gh_api "releases" | jq -r '
        .[].assets[] | select(.name | test("^kernel-[A-Za-z0-9._-]+\\.tar\\.gz$")) | .name | sub("kernel-"; "") | sub("\\.tar\\.gz$"; "")
    ' 2>/dev/null | sort -V | uniq || true
}

# 根据版本号获取下载 URL
get_download_url() {
    local version="$1"
    gh_api "releases" | jq -r --arg ver "$version" '
        .[].assets[] | select(.name == "kernel-\($ver).tar.gz") | .browser_download_url
    ' 2>/dev/null | head -1 || true
}

# 下载并解压内核包（仅输出解压路径到 stdout）
download_kernel() {
    local version="$1"
    local url=$(get_download_url "$version")
    if [[ -z "$url" ]]; then
        error "未找到版本 ${version} 的内核包\n可用版本:\n$(get_releases | sed 's/^/  /')"
    fi

    mkdir -p "$DOWNLOAD_DIR"
    local archive="${DOWNLOAD_DIR}/kernel-${version}.tar.gz"
    local extract_dir="${DOWNLOAD_DIR}/kernel-${version}"

    info "下载: $url"
    if ! curl -# -L -o "$archive" "$url"; then
        rm -f "$archive"
        error "下载失败"
    fi
    
    info "解压到: $extract_dir"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$archive" -C "$extract_dir"
    
    cleanup_downloads
    echo "$extract_dir"
}

# 安装内核（使用 apt-get 自动处理依赖）
install_kernel() {
    local dir="$1"
    local version="$2"
    local deb_files=()
    while IFS= read -r -d '' file; do
        deb_files+=("$file")
    done < <(find "$dir" -maxdepth 1 -type f -name "*.deb" -print0 2>/dev/null)
    
    if [[ ${#deb_files[@]} -eq 0 ]]; then
        error "在 $dir 中未找到 .deb 文件"
    fi

    # 检查是否已安装相同版本（使用包名中的版本字符串）
    local installed=$(dpkg -l | awk -v ver="$version" '$2 ~ "^linux-image-" ver "[+-]" || $2 == "linux-image-" ver {print $2}' | head -1 || true)
    if [[ -n "$installed" ]]; then
        warn "内核版本 $version 已安装 ($installed)"
        ask "是否重新安装? (y/N) "
        read -r answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "取消安装"
            return
        fi
    fi

    info "安装以下 deb 包:"
    printf '  %s\n' "${deb_files[@]}"
    
    if ! apt-get install -y "${deb_files[@]}"; then
        error "安装失败，请检查依赖或手动执行: apt-get install -f"
    fi
    
    info "更新 GRUB 配置..."
    update_grub
    info "安装完成！可使用 '$0 switch $version' 切换至此内核（重启后生效）。"
}

# 列出已安装的自定义内核
list_installed() {
    dpkg -l | awk '/^ii  linux-image-/ {print $2}' | sed 's/linux-image-//' | sort -V
}

# 卸载内核（支持 -y 选项自动确认）
uninstall_kernel() {
    local force=false
    if [[ "$1" == "-y" ]]; then
        force=true
        shift
    fi
    local version="$1"
    local current_pkg=$(dpkg -l | awk -v kernel="$(uname -r)" '$2 == "linux-image-" kernel {print $2}' | head -1 || true)
    local target_pkg=$(dpkg -l | awk -v ver="$version" '$2 ~ "^linux-image-" ver "[+-]" || $2 == "linux-image-" ver {print $2}' | head -1 || true)
    
    if [[ -z "$target_pkg" ]]; then
        error "未找到已安装的内核版本 ${version}\n已安装内核:\n$(list_installed | sed 's/^/  /')"
    fi
    
    if [[ "$target_pkg" == "$current_pkg" ]]; then
        error "不能卸载当前正在运行的内核 ($target_pkg)，请重启使用其他内核后再卸载"
    fi

    # 改进的 headers 包匹配（支持多种变体）
    local headers_pkg=$(dpkg -l | awk -v ver="$version" '
        $2 ~ "^linux-headers-" ver && $1=="ii" {print $2; exit}
    ' || true)

    echo -e "${YELLOW}将要卸载:${NC} $target_pkg"
    [[ -n "$headers_pkg" ]] && echo "          $headers_pkg"
    
    if [[ "$force" != true ]]; then
        ask "确认卸载? (y/N) "
        read -r answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "已取消"
            return
        fi
    fi

    dpkg --purge "$target_pkg"
    [[ -n "$headers_pkg" ]] && dpkg --purge "$headers_pkg"
    info "卸载完成，更新 GRUB..."
    update_grub
}

# 切换内核（下次启动）- 使用包含匹配，不再依赖正则转义
switch_kernel() {
    local version="$1"
    local entries=()
    
    # 收集所有菜单项标题中包含指定版本字符串的项
    while IFS= read -r line; do
        if [[ "$line" =~ menuentry\ [\"\']([^\"\']+)[\"\'] ]]; then
            local title="${BASH_REMATCH[1]}"
            if [[ "$title" == *"$version"* ]]; then
                entries+=("$title")
            fi
        fi
    done < <(grep -E "^menuentry" /boot/grub/grub.cfg)

    if [[ ${#entries[@]} -eq 0 ]]; then
        error "未在 GRUB 中找到包含版本 ${version} 的启动项"
    fi

    local selected
    if [[ ${#entries[@]} -eq 1 ]]; then
        selected="${entries[0]}"
    else
        echo "找到多个匹配项，请选择:" >&2
        for i in "${!entries[@]}"; do
            echo "  $((i+1))) ${entries[$i]}" >&2
        done
        read -p "请输入编号 (1-${#entries[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#entries[@]} )); then
            selected="${entries[$((choice-1))]}"
        else
            error "无效选择"
        fi
    fi

    info "设置下次启动使用: $selected"
    if ! command -v grub-reboot &>/dev/null; then
        error "grub-reboot 命令未找到，请安装 grub2-common (Ubuntu) 或相应包"
    fi
    grub-reboot "$selected"
    echo -e "${YELLOW}提示: 重启后将自动使用该内核。若要永久更改，请修改 /etc/default/grub 中的 GRUB_DEFAULT。${NC}" >&2
}

# 显示当前内核
current_kernel() {
    local cur=$(uname -r)
    info "当前运行的内核: $cur"
    if dpkg -l | grep -q "linux-image-${cur}"; then
        echo "   (已通过 dpkg 安装)" >&2
    else
        echo "   (可能是系统自带或手动编译)" >&2
    fi
}

# 显示帮助
show_help() {
    cat <<EOF
内核管理器 - 管理从 GitHub Release 构建的自定义内核

用法:
    $0 list                     列出仓库中可用的内核版本
    $0 download <version>       仅下载指定版本 (不安装)
    $0 install <version>        下载并安装
    $0 uninstall [-y] <version> 卸载已安装的内核版本（-y 跳过确认）
    $0 switch <version>         设置下次启动时使用该内核
    $0 current                  显示当前运行的内核
    $0 clean-downloads          清理旧的下载缓存 (保留最近 ${KEEP_DOWNLOADS} 个)

环境变量:
    GITHUB_REPO    GitHub 仓库 "owner/repo" (若不设置则自动检测)
    GITHUB_TOKEN   GitHub 个人访问令牌 (访问私有仓库或提高 API 限流时需要)
    DOWNLOAD_DIR   下载目录 (默认: ~/.cache/kernel-manager)
    KEEP_DOWNLOADS 保留下载版本数 (默认: 2)

示例:
    export GITHUB_REPO="myuser/mykernel"
    $0 list
    $0 install 6.6.3-bbr
    $0 uninstall -y 6.6.3-bbr
    $0 switch 6.6.3-bbr
EOF
}

# ==================== 主入口 ====================
main() {
    if [[ $# -lt 1 ]]; then
        show_help
        exit 1
    fi

    # 检查必要命令
    for cmd in curl jq dpkg apt-get update-grub; do
        if ! command -v "$cmd" &>/dev/null; then
            error "缺少依赖命令: $cmd (请安装: apt install $cmd)"
        fi
    done

    case "$1" in
        list)
            info "从仓库 $(detect_repo) 获取版本列表..."
            get_releases | cat
            ;;
        download)
            [[ -z "${2:-}" ]] && error "请指定版本号"
            download_kernel "$2" >/dev/null
            info "下载完成，目录: $DOWNLOAD_DIR/kernel-$2"
            ;;
        install)
            [[ -z "${2:-}" ]] && error "请指定版本号"
            local dir=$(download_kernel "$2")
            install_kernel "$dir" "$2"
            ;;
        uninstall)
            [[ -z "${2:-}" ]] && error "请指定版本号"
            if [[ "$2" == "-y" ]]; then
                [[ -z "${3:-}" ]] && error "请指定版本号"
                uninstall_kernel -y "$3"
            else
                uninstall_kernel "$2"
            fi
            ;;
        switch)
            [[ -z "${2:-}" ]] && error "请指定版本号"
            switch_kernel "$2"
            ;;
        current)
            current_kernel
            ;;
        clean-downloads)
            cleanup_downloads
            info "已清理旧下载，保留最近 ${KEEP_DOWNLOADS} 个版本"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "未知命令: $1\n查看帮助: $0 help"
            ;;
    esac
}

main "$@"
