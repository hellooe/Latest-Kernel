#!/usr/bin/env bash
#
# 内核管理器 - 从 GitHub Release 下载/安装/卸载自定义内核
# 仅支持 Debian/Ubuntu，需以 root 运行

set -euo pipefail

# 全局缓存：GitHub API 原始响应
CACHED_RELEASES_DATA=""

# 辅助函数
info() {
    echo "[INFO] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# 检查执行权限
if [[ $EUID -ne 0 ]]; then
    error "此脚本必须以 root 用户执行"
fi

# 依赖检查
for cmd in curl jq dpkg apt-get update-grub; do
    if ! command -v "$cmd" &>/dev/null; then
        error "缺少命令 $cmd"
    fi
done

# 配置（可通过环境变量覆盖）
GITHUB_REPO="${GITHUB_REPO:-hellooe/Latest-Kernel}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/root/.cache/kernel-manager}"

# 获取并缓存 GitHub API 数据（仅第一次调用时获取）
fetch_releases_data() {
    if [[ -n "$CACHED_RELEASES_DATA" ]]; then
        return
    fi
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases"
    info "获取版本列表..."
    CACHED_RELEASES_DATA=$(curl -sSL --fail --connect-timeout 10 --retry 3 "$api_url") \
        || error "GitHub API 请求失败"
    if ! jq -e . >/dev/null 2>&1 <<<"$CACHED_RELEASES_DATA"; then
        error "GitHub API 返回的数据不是有效 JSON"
    fi
}

# 获取版本列表
get_versions() {
    fetch_releases_data
    local versions
    versions=$(jq -r '
        .[].assets[] | select(.name | test("^kernel-.+\\.tar\\.gz$")) |
        .name | sub("kernel-"; "") | sub("\\.tar\\.gz$"; "")
    ' <<<"$CACHED_RELEASES_DATA" | sort -V | uniq)
    if [[ -z "$versions" ]]; then
        echo "警告：没有找到任何内核版本" >&2
    else
        echo "$versions"
    fi
}

# 获取指定版本的下载 URL
get_download_url() {
    local version="$1"
    fetch_releases_data
    local url
    url=$(jq -r --arg ver "$version" '
        .[].assets[] | select(.name == "kernel-\($ver).tar.gz") | .browser_download_url
    ' <<<"$CACHED_RELEASES_DATA" | head -1)
    if [[ -z "$url" ]]; then
        error "未找到版本 ${version} 的下载 URL"
    fi
    echo "$url"
}

# 下载并解压内核包（设置全局数组 DEB_FILES）
download_kernel() {
    local version="$1"
    local url
    url=$(get_download_url "$version")

    mkdir -p "$DOWNLOAD_DIR"
    local archive="${DOWNLOAD_DIR}/kernel-${version}.tar.gz"
    local extract_dir="${DOWNLOAD_DIR}/kernel-${version}"

    # 下载或验证缓存
    if [[ -f "$archive" ]]; then
        info "发现已缓存文件: $archive"
        # 验证压缩包完整性
        if ! tar -tzf "$archive" &>/dev/null; then
            info "缓存文件损坏，重新下载"
            rm -f "$archive"
        fi
    fi

    if [[ ! -f "$archive" ]]; then
        info "下载: $url"
        curl -# -L --fail --connect-timeout 10 --retry 3 -o "$archive" "$url" || {
            rm -f "$archive"
            error "下载失败"
        }
        if ! tar -tzf "$archive" &>/dev/null; then
            rm -f "$archive"
            error "下载的文件不是有效的 tar.gz 压缩包"
        fi
    fi

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    info "解压到 $extract_dir"
    tar -xzf "$archive" -C "$extract_dir"

    # 查找所有 .deb 文件（支持子目录）
    local deb_files=()
    while IFS= read -r -d '' f; do
        deb_files+=("$f")
    done < <(find "$extract_dir" -type f -name "*.deb" -print0)

    if [[ ${#deb_files[@]} -eq 0 ]]; then
        error "压缩包中没有 .deb 文件"
    fi

    # 通过全局数组返回结果
    DEB_FILES=("${deb_files[@]}")
}

# 安装内核（同时安装 image 和 headers）
install_kernel() {
    local version="$1"

    # 安装前检查：是否已安装
    if dpkg-query -W -f='${Package}\n' | grep -qE "^linux-image-${version}(-|$)"; then
        error "内核版本 ${version} 已安装，请先卸载或使用其他版本"
    fi

    unset DEB_FILES
    download_kernel "$version"
    local deb_files=("${DEB_FILES[@]}")

    # 分类：image deb 和 headers deb
    local image_debs=()
    local headers_debs=()
    for deb in "${deb_files[@]}"; do
        local pkg_name
        pkg_name=$(dpkg-deb -f "$deb" Package)
        if [[ "$pkg_name" =~ linux-image ]]; then
            image_debs+=("$deb")
        elif [[ "$pkg_name" =~ linux-headers ]]; then
            headers_debs+=("$deb")
        fi
    done

    if [[ ${#image_debs[@]} -eq 0 ]]; then
        error "未找到任何 linux-image .deb 文件"
    fi

    # 架构检查
    local pkg_arch
    pkg_arch=$(dpkg-deb -f "${image_debs[0]}" Architecture)
    local sys_arch
    sys_arch=$(dpkg --print-architecture)
    if [[ "$pkg_arch" != "all" && "$pkg_arch" != "$sys_arch" ]]; then
        error "内核架构 $pkg_arch 与系统架构 $sys_arch 不匹配"
    fi

    # 收集所有要安装的包名
    local all_pkgs=()
    for deb in "${image_debs[@]}" "${headers_debs[@]}"; do
        all_pkgs+=("$(dpkg-deb -f "$deb" Package)")
    done

    echo "将要安装以下内核相关包："
    printf "  %s\n" "${all_pkgs[@]}"
    read -p "确认安装？(y/N) " -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消安装"
        exit 0
    fi

    apt-get install -y "${image_debs[@]}" "${headers_debs[@]}"

    info "更新 GRUB 配置..."
    update-grub

    # 安装成功后清理解压目录（保留 .tar.gz 缓存）
    local extract_dir="${DOWNLOAD_DIR}/kernel-${version}"
    rm -rf "$extract_dir"
    info "已清理临时解压目录"

    echo "安装完成。"
}

# 卸载内核（同时卸载 image 和 headers，但保留 -common 包）
uninstall_kernel() {
    local version="$1"
    local image_pkg=""
    local header_pkgs=()
    local installed_pkgs
    installed_pkgs=$(dpkg-query -W -f='${Package}\n' 2>/dev/null)

    # 转义点号用于精确匹配
    local escaped_version
    escaped_version=$(printf '%s' "$version" | sed 's/\./\\./g')
    for pkg in $installed_pkgs; do
        if [[ "$pkg" =~ ^linux-image-${escaped_version}(-|$) ]] && [[ ! "$pkg" =~ -common$ ]]; then
            image_pkg="$pkg"
        elif [[ "$pkg" =~ ^linux-headers-${escaped_version}(-|$) ]] && [[ ! "$pkg" =~ -common$ ]]; then
            header_pkgs+=("$pkg")
        fi
    done

    if [[ -z "$image_pkg" ]]; then
        error "未安装匹配版本 $version 的内核包"
    fi

    # 检查是否正在运行
    local running_pkg=$(dpkg-query -W -f='${Package}\n' | grep -E "^linux-image-$(uname -r)(-|$)" | head -1)
    if [[ "$image_pkg" == "$running_pkg" ]]; then
        error "不能卸载当前正在运行的内核 ($running_kernel_version, 包名: $running_pkg)"
    fi

    echo "将要卸载以下包："
    echo "  $image_pkg"
    for hp in "${header_pkgs[@]}"; do
        echo "  $hp"
    done
    read -p "确认卸载？(y/N) " -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消卸载"
        exit 0
    fi

    apt-get purge -y "$image_pkg"
    for hp in "${header_pkgs[@]}"; do
        apt-get purge -y "$hp"
    done

    info "更新 GRUB 配置..."
    update-grub
    echo "卸载完成"
}

# 清理缓存
clean_cache() {
    if [[ -d "$DOWNLOAD_DIR" ]]; then
        echo "将要删除缓存目录: $DOWNLOAD_DIR"
        read -p "确认清理？(y/N) " -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$DOWNLOAD_DIR"
            info "已清理缓存"
        else
            echo "取消清理"
        fi
    else
        info "缓存目录不存在，无需清理"
    fi
}

# 主命令处理
case "${1:-}" in
    list)
        echo "从 ${GITHUB_REPO} 获取可用内核版本："
        get_versions
        ;;
    install)
        if [[ -z "${2:-}" ]]; then
            echo "用法：$0 install <版本号>" >&2
            exit 1
        fi
        install_kernel "$2"
        ;;
    uninstall)
        if [[ -z "${2:-}" ]]; then
            echo "用法：$0 uninstall <版本号>" >&2
            exit 1
        fi
        uninstall_kernel "$2"
        ;;
    clean)
        clean_cache
        ;;
    *)
        cat <<EOF
用法：
    $0 list                      列出可用内核版本
    $0 install <版本号>          下载并安装指定版本（包含 image 和 headers）
    $0 uninstall <版本号>        卸载已安装的内核及对应 headers（不能卸载当前运行内核）
    $0 clean                     清理所有缓存文件（.tar.gz 和解压目录）
EOF
        exit 1
        ;;
esac
