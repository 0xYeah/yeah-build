#!/bin/bash
set -e

DOWNLOAD_URL="https://raw.githubusercontent.com/0xYeah/yeah-build/main/yeeah-build"

# ===================== 基础兼容配置 =====================
# 解决Windows路径分隔符问题（/ 和 \ 互转）
convert_path() {
    local path="$1"
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$(uname -s)" == MINGW* ]]; then
        # Windows环境：将/转为\，同时处理绝对路径（如/c/ → C:\）
        path=$(echo "$path" | sed 's|^/c/|C:\\|g; s|/|\\|g')
    fi
    echo "$path"
}

# 颜色输出（兼容所有终端，Git Bash/CMD/PowerShell）
color_red() {
    if [[ "$TERM" == "xterm" || "$OSTYPE" == "msys" ]]; then
        echo -e "\033[0;31m$1\033[0m"
    else
        echo "[$(date +%H:%M:%S) ERROR] $1"
    fi
}
color_green() {
    if [[ "$TERM" == "xterm" || "$OSTYPE" == "msys" ]]; then
        echo -e "\033[0;32m$1\033[0m"
    else
        echo "[$(date +%H:%M:%S) INFO] $1"
    fi
}
color_yellow() {
    if [[ "$TERM" == "xterm" || "$OSTYPE" == "msys" ]]; then
        echo -e "\033[1;33m$1\033[0m"
    else
        echo "[$(date +%H:%M:%S) WARN] $1"
    fi
}

# 脚本结束自动删除
cleanup() {
    local script_path="$0"
    # 适配Windows路径，避免删除失败
    script_path=$(convert_path "$script_path")
    if [ -f "$script_path" ]; then
        rm -f "$script_path" >/dev/null 2>&1
        color_green "脚本已自动删除"
    fi
}
#trap cleanup EXIT

# ===================== 系统/终端识别 =====================
get_sys_and_terminal() {
    # 1. 识别终端类型
    if [[ -n "$PSModulePath" && -n "$PWSH_VERSION" ]]; then
        TERMINAL_TYPE="pwsh"
    elif [[ "$COMSPEC" == *"cmd.exe"* && -z "$BASH_VERSION" ]]; then
        TERMINAL_TYPE="cmd"
    else
        TERMINAL_TYPE="git-bash"
    fi
    color_green "检测到终端环境：$TERMINAL_TYPE"

    # 2. 识别系统类型
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$(uname -s)" == MINGW* ]]; then
        OS_TYPE="windows"
        # Windows系统可识别路径（适配PATH环境变量）
        SYS_PATH="$HOME/AppData/Local/Microsoft/WindowsApps"
        # 备用系统路径（更通用）
        if [ -d "C:\\Windows\\System32" ]; then
            SYS_PATH="C:\\Windows\\System32"
        fi
    elif [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_TYPE=$ID
        case "$OS_TYPE" in
            ubuntu|debian) SYS_PATH="/usr/bin" ;;
            centos|rhel) SYS_PATH="/usr/local/bin" ;;
            *) SYS_PATH="/usr/local/bin" ;;
        esac
    elif [ "$(uname -s)" = "Darwin" ]; then
        OS_TYPE="macos"
        SYS_PATH="/usr/local/bin"
        [ -d "/opt/homebrew/bin" ] && SYS_PATH="/opt/homebrew/bin"
    else
        OS_TYPE="linux"
        SYS_PATH="/usr/local/bin"
    fi
    # 统一路径格式（终端友好显示）
    SYS_PATH=$(convert_path "$SYS_PATH")
    color_green "检测到系统：$OS_TYPE，默认系统路径：$SYS_PATH"
}

# ===================== 安装路径选择 =====================
choose_install_path() {
    local current_path=$(pwd)
    current_path=$(convert_path "$current_path")

    color_yellow "\n【选择安装位置】"
    echo "1) 当前目录（默认）：$current_path"
    echo "2) 系统可识别路径：$SYS_PATH"

    # 适配不同终端的输入方式
    if [[ "$TERMINAL_TYPE" == "pwsh" ]]; then
        # PowerShell输入逻辑
        $CHOICE = Read-Host "输入1/2（回车默认1）"
        CHOICE=$(echo "$CHOICE" | tr -d '\r\n') # 去除换行符
    elif [[ "$TERMINAL_TYPE" == "cmd" ]]; then
        # CMD输入逻辑
        set /p CHOICE="输入1/2（回车默认1）："
        CHOICE=$(echo "$CHOICE" | tr -d '\r\n')
    else
        # Git Bash输入逻辑
        read -p "输入1/2（回车默认1）：" CHOICE
    fi

    # 确定安装路径
    if [[ "$CHOICE" == "2" ]]; then
        INSTALL_PATH="$SYS_PATH"
        # Windows无需sudo，Linux/macOS检查权限
        if [[ "$OS_TYPE" != "windows" && ! -w "$INSTALL_PATH" ]]; then
            SUDO="sudo"
            color_yellow "系统路径需要sudo权限"
        else
            SUDO=""
        fi
    else
        INSTALL_PATH="$current_path"
        SUDO=""
    fi
    color_green "最终安装路径：$INSTALL_PATH"
}

# ===================== 跨平台下载逻辑（增强版） =====================
download_file() {
    local url="$1"
    local output="$2"
    color_green "开始下载：$url → $output"

    # 适配Windows路径，避免下载路径错误
    output=$(convert_path "$output")

    # 前置检查：URL是否有效
    if ! curl -s --head "$url" | grep -q "200 OK" && ! wget --spider -q "$url"; then
        color_red "URL无效或无法访问：$url，请检查网络和地址！"
        exit 1
    fi

    # 方案1：优先用wget（Linux/macOS/Windows Git Bash 均可安装）
    if command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate --timeout=30 -O "$output" "$url"
        if [ $? -eq 0 ]; then
            color_green "wget 下载成功"
            return 0
        fi
        color_yellow "wget 下载失败，尝试 curl..."
    fi

    # 方案2：备用curl（比wget更通用，Linux/macOS默认有，Windows可安装）
    if command -v curl >/dev/null 2>&1; then
        curl -sSL --insecure --timeout=30 -o "$output" "$url"
        if [ $? -eq 0 ]; then
            color_green "curl 下载成功"
            return 0
        fi
        color_yellow "curl 下载失败，尝试 PowerShell（仅Windows）..."
    fi

    # 方案3：Windows兜底（PowerShell）
    if [[ "$OS_TYPE" == "windows" ]]; then
        powershell -Command "try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;
            Invoke-WebRequest -Uri '$url' -OutFile '$output' -UseBasicParsing -TimeoutSec 30;
        } catch {
            # 兼容旧版PowerShell（无TimeoutSec）
            Invoke-WebRequest -Uri '$url' -OutFile '$output' -UseBasicParsing;
        }"
        if [ $? -eq 0 ]; then
            color_green "PowerShell 下载成功"
            return 0
        fi
    fi

    # 所有方案失败
    color_red "下载失败！请检查：
    1. 网络是否能访问 $url；
    2. Windows：是否安装PowerShell ≥5.1，且无权限拦截；
    3. Linux/macOS：是否安装 wget/curl（sudo apt install wget curl）；
    4. 若需代理，先执行：export https_proxy=http://代理IP:端口"
    exit 1
}

# ===================== 脚本启动前：前置检查 =====================
pre_check() {
    color_green "========== 前置环境检查 =========="
    # 检查网络连通性
    if ! ping -c 1 raw.githubusercontent.com >/dev/null 2>&1; then
        color_yellow "警告：无法ping通 raw.githubusercontent.com，可能网络受限！
        若需代理，请先执行：export https_proxy=http://你的代理IP:端口"
    fi

    # 检查下载工具（至少有一个）
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        if [[ "$OS_TYPE" == "windows" ]]; then
            color_yellow "未检测到wget/curl，将使用PowerShell下载..."
        else
            color_red "Linux/macOS 未安装wget/curl，请先执行：
            Debian/Ubuntu: sudo apt install wget curl
            CentOS/RHEL: sudo yum install wget curl
            macOS: brew install wget curl"
            exit 1
        fi
    fi

    # 检查路径权限
    local test_file="$INSTALL_PATH/.test_write"
    touch "$test_file" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        color_red "安装路径无写入权限：$INSTALL_PATH，请切换路径或提升权限！"
        exit 1
    fi
    rm -f "$test_file" >/dev/null 2>&1
}

# 主流程中添加前置检查
main() {
    color_green "========== 开始安装 yeeah-build =========="
    get_sys_and_terminal
    choose_install_path
    pre_check  # 新增：前置检查
    install_main
    color_green "========== 安装流程结束 =========="
}

# ===================== 核心安装逻辑 =====================
install_main() {
    # 下载地址（替换为实际地址）
    # 目标文件路径
    TARGET_FILE="$INSTALL_PATH/yeeah-build"
    # 适配Windows后缀（可选，让文件可直接执行）
    if [[ "$OS_TYPE" == "windows" ]]; then
        TARGET_FILE="${TARGET_FILE}.exe"
    fi

    # 下载文件
    download_file "$DOWNLOAD_URL" "$TARGET_FILE"

    # 添加可执行权限（Windows无需chmod）
    if [[ "$OS_TYPE" != "windows" ]]; then
        $SUDO chmod +x "$TARGET_FILE"
    fi

    # 验证安装
    if [ -f "$TARGET_FILE" ]; then
        color_green "安装完成！"
        if [[ "$CHOICE" == "2" ]]; then
            color_green "可直接执行：yeeah-build（Linux/macOS）或 yeeah-build.exe（Windows）"
        else
            if [[ "$TERMINAL_TYPE" == "git-bash" ]]; then
                color_green "可执行：./yeeah-build"
            elif [[ "$TERMINAL_TYPE" == "cmd" ]]; then
                color_green "可执行：yeeah-build.exe"
            elif [[ "$TERMINAL_TYPE" == "pwsh" ]]; then
                color_green "可执行：.\yeeah-build.exe"
            fi
        fi
    else
        color_red "安装失败"
        exit 1
    fi
}

# ===================== 主流程 =====================
main() {
    color_green "========== 开始安装 yeeah-build =========="
    get_sys_and_terminal
    choose_install_path
    install_main
    color_green "========== 安装流程结束 =========="
}

# 适配不同终端的启动方式
if [[ "$TERMINAL_TYPE" == "pwsh" || "$TERMINAL_TYPE" == "cmd" ]]; then
    # PowerShell/CMD：通过Git Bash解释器执行
    if command -v bash.exe >/dev/null 2>&1; then
        bash.exe "$0" "$@"
        exit $?
    else
        color_red "未找到Git Bash（bash.exe），请先安装Git for Windows！"
        exit 1
    fi
else
    # Git Bash：原生执行
    main
fi