#!/bin/bash
# 核心修复：所有日志输出到stderr，确保变量只保留纯数据

# ===================== 核心配置 =====================
GITHUB_REPO="0xYeah/yeah-build"
ASSET_BASE_NAME="yeah-build_release"

# ===================== 基础配置（日志输出到stderr） =====================
# 颜色输出（所有日志输出到stderr，避免污染stdout）
color_red() {
    if [[ "$TERM" == "xterm" || "$OSTYPE" == "msys" ]]; then
        echo -e "\033[0;31m$1\033[0m" >&2
    else
        echo "[$(date +%H:%M:%S) ERROR] $1" >&2
    fi
}
color_green() {
    if [[ "$TERM" == "xterm" || "$OSTYPE" == "msys" ]]; then
        echo -e "\033[0;32m$1\033[0m" >&2
    else
        echo "[$(date +%H:%M:%S) INFO] $1" >&2
    fi
}
color_yellow() {
    if [[ "$TERM" == "xterm" || "$OSTYPE" == "msys" ]]; then
        echo -e "\033[1;33m$1\033[0m" >&2
    else
        echo "[$(date +%H:%M:%S) WARN] $1" >&2
    fi
}

# 路径转换（修复换行/转义问题）
convert_path() {
    local input_path="$1"
    # 移除所有换行符和多余空格
    input_path=$(echo "$input_path" | tr -d '\n' | tr -d '\r' | sed 's/[[:space:]]*$//')

    if [[ -z "$input_path" ]]; then
        echo ""
        return 0
    fi

    # POSIX → Windows
    if [[ "$input_path" =~ ^/[a-zA-Z]/ ]]; then
        local drive=$(echo "$input_path" | cut -c2 | tr 'a-z' 'A-Z')
        local win_path="${drive}:${input_path#/[a-zA-Z]}"
        win_path=${win_path//\//\\}
        echo "$win_path"
        return 0
    fi

    # Windows → POSIX
    if [[ "$input_path" =~ ^[a-zA-Z]:\\ ]]; then
        local drive=$(echo "$input_path" | cut -c1 | tr 'A-Z' 'a-z')
        local posix_path="/${drive}/${input_path#*:\\}"
        posix_path=${posix_path//\\/\/}
        echo "$posix_path"
        return 0
    fi

    echo "$input_path"
}

# ===================== 系统/架构识别 =====================
get_sys_arch_terminal() {
    color_green "【步骤1/6】识别运行环境..."
    if [[ -n "$PSModulePath" && -n "$PWSH_VERSION" ]]; then
        TERMINAL_TYPE="pwsh"
    elif [[ "$COMSPEC" == *"cmd.exe"* && -z "$BASH_VERSION" ]]; then
        TERMINAL_TYPE="cmd"
    else
        TERMINAL_TYPE="git-bash"
    fi
    color_green "检测到终端环境：$TERMINAL_TYPE"

    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$(uname -s)" == MINGW* ]]; then
        OS_TYPE="windows"
        if [[ "$(uname -m)" == "x86_64" || "$PROCESSOR_ARCHITECTURE" == "AMD64" ]]; then
            ARCH_TYPE="x86_64"
            ARCH_ALIAS="amd64"
        else
            ARCH_TYPE="x86_64"
            ARCH_ALIAS="amd64"
        fi
        SYS_PATH="/c/Windows/System32"
        USER_BIN_PATH="$HOME/AppData/Local/bin"
    else
        OS_TYPE="linux"
        ARCH_TYPE="x86_64"
        ARCH_ALIAS="amd64"
        SYS_PATH="/usr/local/bin"
        USER_BIN_PATH="$SYS_PATH"
    fi

    # 构建匹配关键词
    if [[ "$OS_TYPE" == "windows" ]]; then
        MATCH_KEYWORDS=("windows_${ARCH_ALIAS}" "windows_${ARCH_TYPE}")
    else
        MATCH_KEYWORDS=("linux_${ARCH_ALIAS}" "linux_${ARCH_TYPE}")
    fi

    color_green "检测到系统：$OS_TYPE | 架构：$ARCH_TYPE（别名：$ARCH_ALIAS） | 系统二进制路径：$SYS_PATH"
    color_green "资产匹配关键词：${MATCH_KEYWORDS[*]}"
    color_green "✅ 环境识别完成"
}

# ===================== 安装路径选择 =====================
choose_install_path() {
    color_green "【步骤2/6】选择安装路径..."
    CURRENT_DIR=$(pwd)
    CURRENT_DIR=$(convert_path "$CURRENT_DIR")

    color_yellow "请选择安装路径：
1. 当前脚本执行目录（推荐，默认）：$CURRENT_DIR
2. 自定义路径
3. 系统用户级二进制目录：$USER_BIN_PATH"
    read -p "输入1/2/3（回车默认1）：" input
    input=${input:-1}

    case "$input" in
        "1") INSTALL_PATH="$CURRENT_DIR" ;;
        "2")
            read -p "请输入自定义安装路径：" custom_path
            INSTALL_PATH=$(convert_path "$custom_path") ;;
        "3") INSTALL_PATH="$USER_BIN_PATH" ;;
        *)
            color_red "输入无效，使用默认路径：$CURRENT_DIR"
            INSTALL_PATH="$CURRENT_DIR" ;;
    esac

    mkdir -p "$INSTALL_PATH" || { color_red "创建路径失败：$INSTALL_PATH"; exit 1; }
    # 最终清理路径
    INSTALL_PATH=$(convert_path "$INSTALL_PATH")
    color_green "最终安装路径：$INSTALL_PATH"
    color_green "✅ 路径选择完成"
}

# ===================== 前置检查 =====================
pre_check() {
    color_green "【步骤3/6】前置环境检查..."
    color_green "1/3 跳过网络连通性检查"

    color_green "2/3 检查下载工具..."
    if [[ "$OS_TYPE" != "windows" ]]; then
        if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
            color_red "❌ 未安装wget/curl"
            exit 1
        fi
        color_green "✅ 下载工具检查通过"
    else
        color_green "✅ Windows系统跳过下载工具检查"
    fi

    color_green "3/3 检查安装路径写入权限..."
    local test_file="$INSTALL_PATH/.yeah_test_$(date +%s)"
    if touch "$test_file" >/dev/null 2>&1; then
        rm -f "$test_file" >/dev/null 2>&1
        color_green "✅ 安装路径写入权限检查通过"
    else
        color_red "❌ 安装路径无写入权限：$INSTALL_PATH"
        exit 1
    fi

    # 检查jq
    color_green "【额外检查】验证jq工具..."
    if [[ "$OS_TYPE" == "windows" ]]; then
        JQ_PATHS=(
            "$HOME/AppData/Local/Microsoft/WinGet/Packages/JQLang.jq_Microsoft.Winget.Source_8wekyb3d8bbwe/jq.exe"
        )
        for jq_path in "${JQ_PATHS[@]}"; do
            if [ -f "$jq_path" ]; then
                export PATH="$PATH:$(dirname "$jq_path")"
                color_green "✅ 找到winget安装的jq：$jq_path"
                break
            fi
        done
    fi

    if ! command -v jq >/dev/null 2>&1; then
        color_red "❌ 未检测到jq工具"
        exit 1
    else
        color_green "✅ jq工具检查通过（版本：$(jq --version)）"
    fi

    color_green "✅ 前置环境检查全部完成"
}

# ===================== 获取资产链接（关键修复：只返回纯URL） =====================
get_matched_asset_url() {
    color_green "【步骤4/6】获取最新Release资产..."
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

    # 只获取纯API响应，日志输出到stderr
    color_green "正在查询最新Release：$api_url"
    local api_response=$(curl -s -L "$api_url")
    if [[ -z "$api_response" ]]; then
        color_red "❌ GitHub API返回空内容"
        exit 1
    fi

    # 获取纯资产列表（无日志）
    local all_assets=$(echo "$api_response" | jq -r '.assets[] | .name + "|" + .browser_download_url')
    if [[ -z "$all_assets" ]]; then
        color_red "❌ 未找到任何Release资产"
        exit 1
    fi

    # 匹配资产
    local matched_url=""
    for keyword in "${MATCH_KEYWORDS[@]}"; do
        color_green "尝试匹配资产关键词：$ASSET_BASE_NAME + $keyword"
        matched_url=$(echo "$all_assets" | grep -i "${ASSET_BASE_NAME}.*${keyword}" | cut -d'|' -f2 | head -1)
        if [[ -n "$matched_url" ]]; then
            break
        fi
    done

    if [[ -z "$matched_url" ]]; then
        color_red "❌ 未找到匹配的资产！
可用资产列表：
$(echo "$all_assets" | cut -d'|' -f1)"
        exit 1
    fi

    # 只输出纯URL到stdout，其他日志到stderr
    local matched_filename=$(basename "$matched_url")
    color_green "✅ 匹配到资产：$matched_filename"
    color_green "✅ 下载链接：$matched_url"
    color_green "✅ 资产匹配完成"

    # 关键：只返回纯URL，无任何其他输出
    echo "$matched_url"
}

# ===================== 下载文件（修复URI和路径） =====================
download_file() {
    local url="$1"
    local output="$2"
    color_green "【步骤5/6】下载文件..."

    # 强制清理URL和路径（移除所有非必要字符）
    url=$(echo "$url" | tr -d '\n' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    output=$(convert_path "$output")
    local output_win=$(convert_path "$output")

    color_green "下载地址：$url"
    color_green "保存路径：$output_win"

    # Windows PowerShell下载（修复URI）
    if [[ "$OS_TYPE" == "windows" ]]; then
        color_green "使用PowerShell下载..."
        # 构建纯PowerShell命令，无转义错误
        powershell -Command "
            \$ErrorActionPreference = 'Stop'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri '$url' -OutFile '$output_win' -UseBasicParsing
            Write-Host '✅ PowerShell 下载成功'
        " 2>&1
        if [ $? -eq 0 ]; then
            color_green "✅ PowerShell 下载成功"
            return 0
        fi
        color_yellow "⚠️ PowerShell 下载失败，尝试curl..."
    fi

    # curl下载
    if command -v curl >/dev/null 2>&1; then
        color_green "使用curl下载..."
        if curl -sL --insecure -o "$output" "$url"; then
            color_green "✅ curl 下载成功"
            return 0
        fi
        color_red "❌ curl 下载失败"
    fi

    color_red "❌ 下载失败！请手动下载：
下载地址：$url
保存路径：$output_win"
    exit 1
}

# ===================== 核心安装逻辑 =====================
install_main() {
    # 关键：只捕获纯URL，排除所有日志
    DOWNLOAD_URL=$(get_matched_asset_url)
    # 强制清理下载链接
    DOWNLOAD_URL=$(echo "$DOWNLOAD_URL" | tr -d '\n' | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ -z "$DOWNLOAD_URL" || ! "$DOWNLOAD_URL" =~ ^https:// ]]; then
        color_red "❌ 无效的下载链接：$DOWNLOAD_URL"
        exit 1
    fi

    # 生成目标文件路径
    ORIGINAL_FILENAME=$(basename "$DOWNLOAD_URL")
    TARGET_FILE="$INSTALL_PATH/$ORIGINAL_FILENAME"
    TARGET_FILE=$(convert_path "$TARGET_FILE")

    # 检查文件是否存在
    if [ -f "$TARGET_FILE" ]; then
        color_yellow "⚠️ 目标文件已存在：$TARGET_FILE
1. 覆盖安装
2. 退出"
        read -p "输入1/2（回车默认1）：" cover_choice
        cover_choice=${cover_choice:-1}
        if [[ "$cover_choice" == "2" ]]; then
            color_green "ℹ️ 用户选择退出"
            exit 0
        fi
    fi

    # 下载文件
    download_file "$DOWNLOAD_URL" "$TARGET_FILE"

    # 完成安装
    color_green "【步骤6/6】完成安装..."
    if [ -f "$TARGET_FILE" ]; then
        color_green "✅ yeah-build 安装完成！"
        if [[ "$ORIGINAL_FILENAME" == *.zip ]]; then
            unzip -o $TARGET_FILE -d $INSTALL_PATH
            rm -rf $TARGET_FILE
        fi
    else
        color_red "❌ 安装失败：文件不存在"
        exit 1
    fi
}

# ===================== 主流程 =====================
main() {
    color_green "========== 开始安装 yeah-build 最新版本 =========="
    get_sys_arch_terminal
    choose_install_path
    pre_check
    color_green "========== 前置流程完成，开始资产获取 =========="
    install_main
    color_green "========== 安装流程全部结束 =========="
}

# ===================== 启动 =====================
if [[ "$TERM" == "pwsh" || "$TERM" == "cmd" ]]; then
    color_red "❌ 不支持PowerShell/CMD，请使用Git Bash"
    exit 1
else
    color_green "✅ 终端验证通过，启动安装..."
    main
fi