#!/usr/bin/env bash
#
# 内核管理器 - 从 GitHub Release 下载/安装/卸载自定义内核
# 仅支持 Debian/Ubuntu，需以 root 运行

set -euo pipefail

# 全局缓存：GitHub API 原始响应
CACHED_RELEASES_DATA=""

info() {
    echo "[INFO] $*" >&2
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

if [[ $EUID -ne 0 ]]; then
    error "此脚本必须以 root 用户执行"
fi

for cmd in curl jq dpkg apt-get update-grub; do
    if ! command -v "$cmd" &>/dev/null; then
        error "缺少命令 $cmd"
    fi
done

# 配置（可通过环境变量覆盖）
GITHUB_REPO="${GITHUB_REPO:-hellooe/Latest-Kernel}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/root/.cache/kernel-manager}"

escape_regex() {
    echo "$1" | sed 's/[.[\^$*+?{|}]/\\&/g'
}

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

get_versions() {
    fetch_releases_data
    local versions
    versions=$(jq -r '
        .[].assets[] | select(.name | test("^kernel-[0-9].+\\.tar\\.gz$")) |
        .name | sub("kernel-"; "") | sub("\\.tar\\.gz$"; "")
    ' <<<"$CACHED_RELEASES_DATA" | sort -V | uniq)
    if [[ -z "$versions" ]]; then
        echo "警告：没有找到任何内核版本" >&2
    else
        echo "$versions"
    fi
}

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

download_kernel() {
    local version="$1"
    local url
    url=$(get_download_url "$version")

    mkdir -p "$DOWNLOAD_DIR"
    local archive="${DOWNLOAD_DIR}/kernel-${version}.tar.gz"
    local extract_dir="${DOWNLOAD_DIR}/kernel-${version}"

    if [[ -f "$archive" ]]; then
        info "发现已缓存文件: $archive"
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

    local deb_files=()
    while IFS= read -r -d '' f; do
        deb_files+=("$f")
    done < <(find "$extract_dir" -type f -name "*.deb" -print0)

    if [[ ${#deb_files[@]} -eq 0 ]]; then
        error "压缩包中没有 .deb 文件"
    fi

    DEB_FILES=("${deb_files[@]}")
}

install_kernel() {
    local version="$1"
    local escaped_version
    escaped_version=$(escape_regex "$version")
    if dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -qE "^linux-image-${escaped_version}(-|$)"; then
        error "内核版本 ${version} 已安装，请先卸载或使用其他版本"
    fi

    unset DEB_FILES
    download_kernel "$version"
    local deb_files=("${DEB_FILES[@]}")

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

    local selected_image_deb=""
    if [[ ${#image_debs[@]} -eq 1 ]]; then
        selected_image_deb="${image_debs[0]}"
    else
        echo "发现多个内核镜像包：" >&2
        for i in "${!image_debs[@]}"; do
            local pkg_name_i
            pkg_name_i=$(dpkg-deb -f "${image_debs[$i]}" Package)
            echo "  $((i+1)). $pkg_name_i (${image_debs[$i]})" >&2
        done
        local choice=""
        while true; do
            read -p "请选择要安装的内核镜像 (1-${#image_debs[@]}): " choice
            if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ || $choice -lt 1 || $choice -gt ${#image_debs[@]} ]]; then
                echo "无效输入，请输入 1-${#image_debs[@]} 之间的数字" >&2
                continue
            fi
            break
        done
        selected_image_deb="${image_debs[$((choice-1))]}"
    fi

    local pkg_arch
    pkg_arch=$(dpkg-deb -f "$selected_image_deb" Architecture)
    local sys_arch
    sys_arch=$(dpkg --print-architecture)
    if [[ "$pkg_arch" != "all" && "$pkg_arch" != "$sys_arch" ]]; then
        error "内核架构 $pkg_arch 与系统架构 $sys_arch 不匹配"
    fi

    local selected_pkg_name
    selected_pkg_name=$(dpkg-deb -f "$selected_image_deb" Package)
    local kernel_ver="${selected_pkg_name#linux-image-}"

    local matched_headers_debs=()
    for deb in "${headers_debs[@]}"; do
        local header_pkg
        header_pkg=$(dpkg-deb -f "$deb" Package)
        if [[ "$header_pkg" =~ ^linux-headers-"${kernel_ver}"(-|$) ]]; then
            matched_headers_debs+=("$deb")
        fi
    done

    if [[ ${#matched_headers_debs[@]} -eq 0 ]]; then
        echo "警告：未找到与内核 ${selected_pkg_name} 匹配的 headers 包，将仅安装内核镜像" >&2
    fi

    local all_pkgs=("$selected_pkg_name")
    for deb in "${matched_headers_debs[@]}"; do
        all_pkgs+=("$(dpkg-deb -f "$deb" Package)")
    done

    echo "将要安装以下内核相关包：" >&2
    printf "  %s\n" "${all_pkgs[@]}" >&2
    read -p "确认安装？(y/N) " -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消安装" >&2
        exit 0
    fi

    apt-get update || error "apt-get update 失败，请检查网络或源配置"

    apt-get install -y "$selected_image_deb" "${matched_headers_debs[@]}"

    update-grub

    local extract_dir="${DOWNLOAD_DIR}/kernel-${version}"
    rm -rf "$extract_dir"
    info "已清理临时解压目录"

    echo "安装完成。请重启系统以加载新内核。" >&2
}

uninstall_kernel() {
    local version="$1"
    local escaped_version
    escaped_version=$(escape_regex "$version")
    local image_pkgs=()
    local header_pkgs=()
    local installed_pkgs
    installed_pkgs=$(dpkg-query -W -f='${Package}\n' 2>/dev/null)

    while IFS= read -r pkg; do
        if [[ "$pkg" =~ ^linux-image-${escaped_version}(-|$) ]] && [[ ! "$pkg" =~ -common$ ]]; then
            image_pkgs+=("$pkg")
        elif [[ "$pkg" =~ ^linux-headers-${escaped_version}(-|$) ]] && [[ ! "$pkg" =~ -common$ ]]; then
            header_pkgs+=("$pkg")
        fi
    done <<< "$installed_pkgs"

    if [[ ${#image_pkgs[@]} -eq 0 ]]; then
        error "未安装匹配版本 $version 的内核包"
    fi

    local selected_image_pkg=""
    if [[ ${#image_pkgs[@]} -eq 1 ]]; then
        selected_image_pkg="${image_pkgs[0]}"
    else
        echo "发现多个匹配的内核包：" >&2
        for i in "${!image_pkgs[@]}"; do
            echo "  $((i+1)). ${image_pkgs[$i]}" >&2
        done
        local choice=""
        while true; do
            read -p "请选择要卸载的内核包 (1-${#image_pkgs[@]}): " choice
            if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ || $choice -lt 1 || $choice -gt ${#image_pkgs[@]} ]]; then
                echo "无效输入，请输入 1-${#image_pkgs[@]} 之间的数字" >&2
                continue
            fi
            break
        done
        selected_image_pkg="${image_pkgs[$((choice-1))]}"
    fi

    local current_version
    current_version=$(uname -r)
    local escaped_current
    escaped_current=$(escape_regex "$current_version")
    local running_pkg
    running_pkg=$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E "^linux-image-${escaped_current}(-|$)" | head -1 || true)

    if [[ "$selected_image_pkg" == "$running_pkg" ]]; then
        error "不能卸载当前正在运行的内核 ($current_version, 包名: $running_pkg)"
    fi

    local kernel_ver="${selected_image_pkg#linux-image-}"
    local matched_headers=()
    for hp in "${header_pkgs[@]}"; do
        if [[ "$hp" =~ ^linux-headers-"${kernel_ver}"(-|$) ]]; then
            matched_headers+=("$hp")
        fi
    done

    echo "将要卸载以下包：" >&2
    echo "  $selected_image_pkg" >&2
    for hp in "${matched_headers[@]}"; do
        echo "  $hp" >&2
    done
    read -p "确认卸载？(y/N) " -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "取消卸载" >&2
        exit 0
    fi

    apt-get purge -y "$selected_image_pkg"
    for hp in "${matched_headers[@]}"; do
        apt-get purge -y "$hp"
    done

    update-grub
    echo "卸载完成" >&2
}

clean_cache() {
    if [[ -d "$DOWNLOAD_DIR" ]]; then
        echo "将要删除缓存目录: $DOWNLOAD_DIR" >&2
        read -p "确认清理？(y/N) " -r confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$DOWNLOAD_DIR"
            info "已清理缓存"
        else
            echo "取消清理" >&2
        fi
    else
        info "缓存目录不存在，无需清理"
    fi
}

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
