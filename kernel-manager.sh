#!/usr/bin/env bash
#
# 内核管理器 - 从 GitHub Release 下载、安装、切换、卸载自定义内核
# 注意：此脚本需要以 root 用户运行，仅支持 Debian/Ubuntu 系列发行版

set -euo pipefail

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    echo "错误：此脚本必须以 root 用户执行" >&2
    exit 1
fi

# 检查发行版（仅支持 Debian/Ubuntu）
if ! command -v dpkg &>/dev/null || ! command -v apt-get &>/dev/null; then
    echo "错误：此脚本仅支持 Debian/Ubuntu 系列发行版（需要 dpkg/apt-get）" >&2
    exit 1
fi

# ==================== 配置 ====================
GITHUB_REPO="${GITHUB_REPO:-hellooe/Latest-Kernel}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/.cache/kernel-manager}"
KEEP_DOWNLOADS="${KEEP_DOWNLOADS:-2}"
GH_API="https://api.github.com/repos"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== 辅助函数 ====================
info()    { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
ask()     { echo -en "${BLUE}[?]${NC} $1 " >&2; }

# 更新 GRUB（兼容 update-grub / update-grub2）
update_grub() {
    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v update-grub2 &>/dev/null; then
        update-grub2
    else
        error "未找到 update-grub 或 update-grub2，请手动更新引导配置"
    fi
}

# 清理旧的下载缓存（保留最近 KEEP_DOWNLOADS 个版本目录及对应 tar.gz）
cleanup_downloads() {
    if [[ -d "$DOWNLOAD_DIR" ]]; then
        (
            shopt -s nullglob
            cd "$DOWNLOAD_DIR"
            # 收集所有 kernel-* 目录，按修改时间排序（最旧的在前）
            local dirs=(kernel-*)
            if [[ ${#dirs[@]} -gt $KEEP_DOWNLOADS ]]; then
                local to_delete=$(( ${#dirs[@]} - KEEP_DOWNLOADS ))
                # 使用 find + stat 排序，避免 xargs 空格问题
                local del_dirs
                del_dirs=$(find . -maxdepth 1 -type d -name "kernel-*" -printf "%T@ %f\n" | sort -n | head -n "$to_delete" | cut -d' ' -f2-)
                while IFS= read -r d; do
                    [[ -z "$d" ]] && continue
                    rm -rf "$d"
                    local ver="${d#kernel-}"
                    if [[ -f "kernel-${ver}.tar.gz" ]]; then
                        rm -f "kernel-${ver}.tar.gz"
                    fi
                done <<< "$del_dirs"
            fi
        )
    fi
}

# GitHub API 请求（支持私有仓库 token，并添加缓存机制）
gh_api() {
    local endpoint="$1"
    local url="${GH_API}/${GITHUB_REPO}/${endpoint}"
    local token="${GITHUB_TOKEN:-}"
    local auth_header=()
    if [[ -n "$token" ]]; then
        auth_header=(-H "Authorization: token ${token}")
    fi
    local response_file
    response_file=$(mktemp)
    local http_code
    http_code=$(curl -sSL --connect-timeout 10 --max-time 30 -w "%{http_code}" -o "$response_file" "${auth_header[@]}" -H "Accept: application/vnd.github.v3+json" "$url")
    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        local err_msg
        err_msg=$(cat "$response_file" | jq -r '.message // "Unknown error"' 2>/dev/null || echo "HTTP $http_code")
        rm -f "$response_file"
        warn "GitHub API 请求失败 ($url): $err_msg"
        echo ""
        return 1
    fi
    cat "$response_file"
    rm -f "$response_file"
}

# 获取所有发布版本（带简单缓存）
_get_releases_cached() {
    local cache_file="${DOWNLOAD_DIR}/.release_cache"
    local cache_ttl=300  # 5 分钟
    mkdir -p "$DOWNLOAD_DIR"
    if [[ -f "$cache_file" ]] && [[ $(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0))) -lt $cache_ttl ]]; then
        cat "$cache_file"
        return
    fi
    local releases_json
    releases_json=$(gh_api "releases")
    if [[ -z "$releases_json" ]]; then
        # 如果 API 失败，尝试使用旧缓存（即使过期）
        if [[ -f "$cache_file" ]]; then
            warn "无法获取最新版本列表，使用缓存（可能已过期）"
            cat "$cache_file"
            return
        fi
        error "无法获取版本列表，请检查网络或 GitHub Token"
    fi
    local versions
    versions=$(echo "$releases_json" | jq -r '
        .[].assets[] | select(.name | test("^kernel-.+\\.tar\\.gz$")) | .name | sub("kernel-"; "") | sub("\\.tar\gz$"; "")
    ' 2>/dev/null | sort -V | uniq)
    if [[ -n "$versions" ]]; then
        echo "$versions" > "$cache_file"
        echo "$versions"
    else
        warn "未解析到任何有效版本"
        [[ -f "$cache_file" ]] && cat "$cache_file"
    fi
}
get_releases() { _get_releases_cached; }

# 根据版本号获取下载 URL
get_download_url() {
    local version="$1"
    local releases_json
    releases_json=$(gh_api "releases")
    if [[ -z "$releases_json" ]]; then
        error "无法获取 Release 信息"
    fi
    local url
    url=$(echo "$releases_json" | jq -r --arg ver "$version" '
        .[] | .assets[] | select(.name == "kernel-\($ver).tar.gz") | .browser_download_url
    ' 2>/dev/null | head -1)
    if [[ -z "$url" ]]; then
        echo ""
    else
        echo "$url"
    fi
}

# 下载并解压内核包（输出解压路径）
download_kernel() {
    local version="$1"
    local url
    url=$(get_download_url "$version")
    if [[ -z "$url" ]]; then
        error "未找到版本 ${version} 的内核包\n可用版本:\n$(get_releases | sed 's/^/  /')"
    fi

    mkdir -p "$DOWNLOAD_DIR"
    local archive="${DOWNLOAD_DIR}/kernel-${version}.tar.gz"
    local extract_dir="${DOWNLOAD_DIR}/kernel-${version}"

    # 检查已有文件是否完整（简单检查是否为 gzip）
    if [[ -f "$archive" ]] && ! gzip -t "$archive" 2>/dev/null; then
        warn "下载缓存文件损坏，将重新下载"
        rm -f "$archive"
    fi

    if [[ ! -f "$archive" ]]; then
        info "下载: $url"
        if ! curl -# -L --connect-timeout 10 --max-time 300 -o "$archive" "$url"; then
            rm -f "$archive"
            error "下载失败"
        fi
    else
        info "使用已缓存的下载: $archive"
    fi

    info "解压到: $extract_dir"
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xzf "$archive" -C "$extract_dir"

    # 检查是否包含 .deb 文件
    if ! find "$extract_dir" -maxdepth 1 -type f -name "*.deb" | grep -q .; then
        error "下载的压缩包中未找到任何 .deb 文件，可能 Release 资产格式错误"
    fi

    cleanup_downloads
    echo "$extract_dir"
}

# 检测虚拟化环境并返回需要的模块列表
detect_required_modules() {
    local modules=()
    # 方法1: systemd-detect-virt
    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt)
        case "$virt" in
            kvm|qemu)
                modules=(virtio_blk virtio_net virtio_scsi)
                ;;
            vmware)
                modules=(vmw_pvscsi vmxnet3)
                ;;
            xen)
                modules=(xen_blkfront xen_netfront)
                ;;
            microsoft)
                modules=(hv_storvsc hv_netvsc)
                ;;
        esac
    fi
    # 方法2: 通过 DMI 信息（如果上面的方法没有结果）
    if [[ ${#modules[@]} -eq 0 ]] && [[ -d /sys/devices/virtual/dmi/id ]]; then
        local product_name
        product_name=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo "")
        if [[ "$product_name" =~ KVM|QEMU ]]; then
            modules=(virtio_blk virtio_net virtio_scsi)
        elif [[ "$product_name" =~ VMware ]]; then
            modules=(vmw_pvscsi vmxnet3)
        elif [[ "$product_name" =~ Xen ]]; then
            modules=(xen_blkfront xen_netfront)
        fi
    fi
    # 方法3: 通过根设备名称补充判断
    local rootdev
    rootdev=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/[0-9]*$//')
    if [[ "$rootdev" == "/dev/vd"* ]]; then
        modules+=(virtio_blk virtio_scsi)
    elif [[ "$rootdev" == "/dev/xvd"* ]]; then
        modules+=(xen_blkfront)
    fi
    # 去重并输出
    printf '%s\n' "${modules[@]}" | sort -u
}

# 安装内核（安装 linux-image 和 linux-headers 包）
install_kernel() {
    local dir="$1"
    local version="$2"
    local deb_files=()

    while IFS= read -r -d '' file; do
        deb_files+=("$file")
    done < <(find "$dir" -maxdepth 1 -type f -name "*.deb" -print0 2>/dev/null)

    if [[ ${#deb_files[@]} -eq 0 ]]; then
        error "在 $dir 中未找到任何 .deb 文件"
    fi

    local image_debs=()
    local headers_debs=()
    for deb in "${deb_files[@]}"; do
        if [[ "$deb" =~ linux-image-.*\.deb$ ]]; then
            image_debs+=("$deb")
        elif [[ "$deb" =~ linux-headers-.*\.deb$ ]]; then
            headers_debs+=("$deb")
        fi
    done

    if [[ ${#image_debs[@]} -eq 0 ]]; then
        error "未找到 linux-image .deb 文件"
    fi

    local sample_deb="${image_debs[0]}"
    local pkg_arch
    pkg_arch=$(dpkg-deb -f "$sample_deb" Architecture)
    local sys_arch
    sys_arch=$(dpkg --print-architecture)
    if [[ "$pkg_arch" != "$sys_arch" ]]; then
        error "内核包架构为 $pkg_arch，当前系统为 $sys_arch，无法安装"
    fi

    # 检查是否已安装（使用传入的版本号作为包名后缀）
    local installed_pkg
    installed_pkg=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -Fx "linux-image-${version}" || true)
    local reinstall_flag=""
    if [[ -n "$installed_pkg" ]]; then
        warn "内核版本 $version 已安装 ($installed_pkg)"
        ask "是否重新安装? (y/N) "
        read -r answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "取消安装"
            return
        fi
        reinstall_flag="--reinstall"
    fi

    # 确保 initramfs 工具存在
    if ! command -v update-initramfs &>/dev/null && ! command -v dracut &>/dev/null; then
        warn "未检测到 initramfs 生成工具，将安装 initramfs-tools"
        apt-get update
        apt-get install -y initramfs-tools
    fi

    local install_packages=("${image_debs[@]}")
    if [[ ${#headers_debs[@]} -gt 0 ]]; then
        info "同时安装 linux-headers 包"
        install_packages+=("${headers_debs[@]}")
    fi

    info "安装以下 deb 包:"
    printf '  %s\n' "${install_packages[@]}"

    local apt_opts=()
    if [[ -n "$reinstall_flag" ]]; then
        apt_opts+=("$reinstall_flag")
    fi

    if ! apt-get install -y "${apt_opts[@]}" "${install_packages[@]}"; then
        warn "安装失败，尝试更新包索引并修复依赖..."
        apt-get update
        apt-get install -f -y
        apt-get install -y "${apt_opts[@]}" "${install_packages[@]}" || error "安装失败，请手动检查"
    fi

    # 获取实际内核版本（用于 initramfs 重建）
    local kernel_version="$version"

    # 重建 initramfs 并添加必要模块
    info "重建 initramfs 并添加虚拟化驱动..."
    local required_modules=()
    mapfile -t required_modules < <(detect_required_modules)

    if [[ ${#required_modules[@]} -gt 0 ]]; then
        info "检测到虚拟化环境，确保以下模块在 initramfs 中: ${required_modules[*]}"
        local modules_file="/etc/initramfs-tools/modules"
        mkdir -p "$(dirname "$modules_file")"
        if [[ ! -f "$modules_file" ]]; then
            touch "$modules_file"
        else
            cp "$modules_file" "${modules_file}.bak.$(date +%s)"
        fi
        for mod in "${required_modules[@]}"; do
            if ! grep -qxF "$mod" "$modules_file" 2>/dev/null; then
                echo "$mod" >> "$modules_file"
                info "已添加 $mod 到 $modules_file"
            fi
        done
    fi

    if command -v update-initramfs &>/dev/null; then
        if ! update-initramfs -u -k "$kernel_version"; then
            warn "update-initramfs 失败，请手动检查 /boot 空间及内核版本"
        fi
    elif command -v dracut &>/dev/null; then
        if ! dracut --force --kver "$kernel_version"; then
            warn "dracut 失败，请手动检查"
        fi
    else
        warn "未找到 initramfs 工具，系统可能无法启动"
    fi

    info "更新 GRUB 配置..."
    update_grub

    info "安装完成！"
}

# 列出已安装的自定义内核
list_installed() {
    dpkg-query -W -f='${Package}\n' 2>/dev/null | grep '^linux-image-' | sed 's/linux-image-//' | sort -V
}

# 卸载内核（支持 -y 选项自动确认）
uninstall_kernel() {
    local force=false
    if [[ "$1" == "-y" ]]; then
        force=true
        shift
    fi
    local version="$1"
    local current_pkg
    current_pkg=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -Fx "linux-image-$(uname -r)" || true)
    local target_pkg
    target_pkg=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -Fx "linux-image-${version}" || true)

    if [[ -z "$target_pkg" ]]; then
        error "未找到已安装的内核版本 ${version}\n已安装内核:\n$(list_installed | sed 's/^/  /')"
    fi

    if [[ "$target_pkg" == "$current_pkg" ]]; then
        error "不能卸载当前正在运行的内核 ($target_pkg)，请重启使用其他内核后再卸载"
    fi

    # 查找可能的相关包
    local related_packages=()
    mapfile -t related_packages < <(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E "^linux-(headers|modules|image)-${version}(-.*)?$" || true)

    echo -e "${YELLOW}将要卸载:${NC} $target_pkg"
    for pkg in "${related_packages[@]}"; do
        if [[ "$pkg" != "$target_pkg" ]]; then
            echo "          $pkg"
        fi
    done

    if [[ "$force" != true ]]; then
        ask "确认卸载? (y/N) "
        read -r answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            info "已取消"
            return
        fi
    fi

    dpkg --purge "$target_pkg" || warn "卸载 $target_pkg 失败"
    for pkg in "${related_packages[@]}"; do
        if [[ "$pkg" != "$target_pkg" ]]; then
            dpkg --purge "$pkg" 2>/dev/null || warn "无法卸载 $pkg (可能已不存在)"
        fi
    done
    info "卸载完成，更新 GRUB..."
    update_grub
}

# 切换内核（交互式选择，使用菜单编号）
switch_kernel() {
    if [[ ! -f /boot/grub/grub.cfg ]]; then
        error "未找到 /boot/grub/grub.cfg，请确认 GRUB 已正确安装"
    fi

    local titles=()
    local indices=()

    local idx=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^menuentry[[:space:]]+\'([^\']+)\' ]]; then
            titles+=("${BASH_REMATCH[1]}")
            indices+=("$idx")
            ((idx++))
        fi
    done < /boot/grub/grub.cfg

    if [[ ${#titles[@]} -eq 0 ]]; then
        error "未找到任何 GRUB 菜单项"
    fi

    echo "可用的启动项："
    for i in "${!titles[@]}"; do
        echo "  $((i+1))) ${titles[$i]}"
    done

    local choice
    read -p "请选择下次启动的内核编号 (1-${#titles[@]}): " choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#titles[@]} )); then
        error "无效选择"
    fi

    local selected_idx="${indices[$((choice-1))]}"
    local selected_title="${titles[$((choice-1))]}"
    info "设置下次启动使用: $selected_title (菜单索引 $selected_idx)"

    if ! command -v grub-reboot &>/dev/null; then
        error "grub-reboot 命令未找到，请安装 grub2-common"
    fi

    grub-reboot "$selected_idx"
    echo -e "${YELLOW}提示: 重启后将自动使用该内核。若要永久更改，请修改 /etc/default/grub 中的 GRUB_DEFAULT。${NC}" >&2
}

# 显示帮助
show_help() {
    cat <<EOF
内核管理器 - 管理从 GitHub Release 构建的自定义内核

用法:
    $0 list                     列出仓库中可用的内核版本
    $0 install <version>        下载并安装
    $0 uninstall [-y] <version> 卸载已安装的内核版本（-y 跳过确认）
    $0 switch                   交互式选择下次启动的内核

环境变量:
    GITHUB_REPO    GitHub 仓库 "owner/repo" (默认: ${GITHUB_REPO})
    GITHUB_TOKEN   GitHub 个人访问令牌 (访问私有仓库或提高 API 限流时需要)
    DOWNLOAD_DIR   下载目录 (默认: $HOME/.cache/kernel-manager)
    KEEP_DOWNLOADS 保留下载版本数 (默认: 2)

示例:
    export GITHUB_REPO="myuser/mykernel"
    $0 list
    $0 install 6.6.3-bbr
    $0 uninstall -y 6.6.3-bbr
    $0 switch
EOF
}

# ==================== 主入口 ====================
main() {
    if [[ $# -lt 1 ]]; then
        show_help
        exit 1
    fi

    # 检查必要命令
    for cmd in curl jq dpkg apt-get; do
        if ! command -v "$cmd" &>/dev/null; then
            error "缺少依赖命令: $cmd (请安装: apt install $cmd)"
        fi
    done
    if ! (command -v update-grub &>/dev/null || command -v update-grub2 &>/dev/null); then
        error "未找到 update-grub 或 update-grub2，请安装 grub2-common"
    fi

    case "$1" in
        list)
            info "从仓库 ${GITHUB_REPO} 获取版本列表..."
            get_releases | cat
            ;;
        install)
            [[ -z "${2:-}" ]] && error "请指定版本号"
            local dir
            dir=$(download_kernel "$2")
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
            switch_kernel
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
