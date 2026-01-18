#!/bin/bash
set -euo pipefail  # 增强错误处理

# ======================== 基础配置 ========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
BUILD_PATH="${SCRIPT_DIR}/build"
RUN_MODE="release"
UPLOAD_TMP_DIR="${BUILD_PATH}/upload_tmp_dir"
PRODUCT_NAME=""
CURRENT_VERSION=""
PROJECT_VERSION_KEY="ProjectVersion"
PROJECT_NAME_KEY="ProjectName"
CONFIG_FILE="${SCRIPT_DIR}/config/config.go"

# 定义支持的编译目标（可扩展）
SUPPORTED_TARGETS=(
    "linux/amd64"
    "linux/arm64"
    "darwin/amd64"
    "darwin/arm64"
    "darwin/universal"  # macOS通用二进制（依赖amd64+arm64）
    "windows/amd64"
)

# 当前系统类型（初始化）
OS_TYPE="Unknown"
# Windows环境标记
IS_WINDOWS=0

# ======================== 工具函数 ========================

# 1. 打印帮助信息
PrintHelp() {
    echo "使用方法: $0 [选项] [目标平台] [目标架构]"
    echo "选项:"
    echo "  -h/--help           显示帮助信息"
    echo "  -m/--mode <mode>    指定构建模式 (release/test/debug，默认release)"
    echo ""
    echo "目标平台/架构（支持的组合）:"
    for target in "${SUPPORTED_TARGETS[@]}"; do
        echo "  $target"
    done
    echo "  all                 编译所有支持的平台/架构"
    echo ""
    echo "示例:"
    echo "  $0 all                      # 编译所有平台（release模式）"
    echo "  $0 linux arm64              # 编译Linux ARM64（release模式）"
    echo "  $0 -m debug darwin universal # debug模式编译macOS通用二进制"
    echo "  $0 windows amd64            # 编译Windows AMD64（release模式）"
}

# 2. 获取操作系统类型
GetOSType() {
    local uname_s
    uname_s=$(uname -s)
    case "${uname_s}" in
        Darwin*)
            OS_TYPE="Darwin"
            IS_WINDOWS=0
            ;;
        Linux*)
            OS_TYPE="Linux"
            IS_WINDOWS=0
            ;;
        MINGW*)
            OS_TYPE="Windows"
            IS_WINDOWS=1
            ;;
        MSYS*)
            OS_TYPE="Windows"
            IS_WINDOWS=1
            ;;
        *)
            OS_TYPE="Unknown"
            IS_WINDOWS=0
            ;;
    esac
    echo "[INFO] 当前宿主系统: ${OS_TYPE}"
    echo "[INFO] Windows环境标记: ${IS_WINDOWS}"
}

# 3. 从配置文件读取产品名称和版本
LoadProjectInfo() {
    if [ ! -f "${CONFIG_FILE}" ]; then
        echo "[ERROR] 配置文件不存在: ${CONFIG_FILE}"
        exit 1
    fi

    # 读取产品名称
    PRODUCT_NAME=$(grep "${PROJECT_NAME_KEY}" "${CONFIG_FILE}" | awk -F '"' '{print $2}' | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')
    if [ -z "${PRODUCT_NAME}" ]; then
        echo "[ERROR] 无法从配置文件读取 ProjectName"
        exit 1
    fi

    # 读取版本号
    CURRENT_VERSION=$(grep "${PROJECT_VERSION_KEY}" "${CONFIG_FILE}" | awk -F '"' '{print $2}' | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')
    if [ -z "${CURRENT_VERSION}" ]; then
        echo "[ERROR] 无法从配置文件读取 ProjectVersion"
        exit 1
    fi

    echo "[INFO] 产品名称: ${PRODUCT_NAME}"
    echo "[INFO] 产品版本: ${CURRENT_VERSION}"
}

# 4. 验证目标平台/架构是否支持
ValidateTarget() {
    local target_os=$1
    local target_arch=$2
    local target="${target_os}/${target_arch}"

    # 特殊处理universal（需要先编译amd64+arm64）
    if [ "${target_arch}" = "universal" ] && [ "${target_os}" != "darwin" ]; then
        echo "[ERROR] universal仅支持darwin平台"
        exit 1
    fi

    # 检查是否在支持列表中
    local supported=0
    for t in "${SUPPORTED_TARGETS[@]}"; do
        if [ "${t}" = "${target}" ]; then
            supported=1
            break
        fi
    done

    if [ ${supported} -eq 0 ]; then
        echo "[ERROR] 不支持的目标: ${target}"
        echo "支持的目标列表:"
        for t in "${SUPPORTED_TARGETS[@]}"; do
            echo "  - $t"
        done
        exit 1
    fi
}

# 5. 生成编译参数（注入版本、构建信息）- 修复Windows下的ldflags格式
GetBuildLdflags() {
    local go_version commit_hash build_time ldflags

    # 获取基础信息
    go_version=$(go version | awk '{print $3}')
    commit_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    build_time=$(date -u +"%Y-%m-%d %H:%M:%S")

    # 修复：Windows下使用单行格式，避免换行符解析错误
    if [ ${IS_WINDOWS} -eq 1 ]; then
        ldflags="-X main.buildVersion=${CURRENT_VERSION} -X main.buildCommit=${commit_hash} -X main.buildTime=${build_time} -X main.buildGoVersion=${go_version} -X main.buildMode=${RUN_MODE}"
    else
        ldflags="\
            -X main.buildVersion=${CURRENT_VERSION} \
            -X main.buildCommit=${commit_hash} \
            -X main.buildTime=${build_time} \
            -X main.buildGoVersion=${go_version} \
            -X main.buildMode=${RUN_MODE}"
    fi

    # 非debug模式开启优化，减小体积
    if [ "${RUN_MODE}" != "debug" ]; then
        ldflags="${ldflags} -w -s"
    fi

    # 输出ldflags用于调试
    echo "[DEBUG] 生成的ldflags: ${ldflags}"
    echo "${ldflags}"
}

# ======================== 核心功能函数 ========================

# 6. 编译指定平台/架构的二进制
BuildBinary() {
    local target_os=$1
    local target_arch=$2
    local output_dir="${BUILD_PATH}/${RUN_MODE}/${target_os}/${target_arch}"
    local output_name="${PRODUCT_NAME}"
    local ldflags=$(GetBuildLdflags)

    # Windows平台添加.exe后缀
    if [ "${target_os}" = "windows" ]; then
        output_name="${output_name}.exe"
    fi

    # 跳过universal（它是合并产物，不是直接编译的）
    if [ "${target_arch}" = "universal" ]; then
        return 0
    fi

    # 创建输出目录
    rm -rf ${output_dir}
    mkdir -p "${output_dir}"
    echo "[INFO] clear: ${output_dir}/${output_name}"
    echo "[INFO] start build: ${target_os}/${target_arch} -> ${output_dir}/${output_name}"

    # 修复：Windows下跨平台编译的环境变量传递方式
    if [ ${IS_WINDOWS} -eq 1 ]; then
        # Windows Git Bash下需要显式导出环境变量
        export CGO_ENABLED=0
        export GOOS="${target_os}"
        export GOARCH="${target_arch}"

        go build -trimpath \
                 -ldflags "${ldflags}" \
                 -o "${output_dir}/${output_name}" \
                 "${SCRIPT_DIR}/main.go"

        # 清理环境变量
        unset CGO_ENABLED
        unset GOOS
        unset GOARCH
    else
        # Linux/macOS直接传递环境变量
        CGO_ENABLED=0 \
        GOOS="${target_os}" \
        GOARCH="${target_arch}" \
        go build -trimpath \
                 -ldflags "${ldflags}" \
                 -o "${output_dir}/${output_name}" \
                 "${SCRIPT_DIR}/main.go"
    fi

    # 添加可执行权限
    chmod +x "${output_dir}/${output_name}"
    echo "[SUCCESS] 编译完成: ${output_dir}/${output_name}"
}

# 7. 打包二进制文件
PackageBinary() {
    local target_os=$1
    local target_arch=$2
    local source_dir="${BUILD_PATH}/${RUN_MODE}/${target_os}/${target_arch}"
    local package_name="${PRODUCT_NAME}_${RUN_MODE}_${CURRENT_VERSION}_${target_os}_${target_arch}.zip"
    local package_path="${UPLOAD_TMP_DIR}/${package_name}"

    if [ ! -d "${source_dir}" ]; then
        echo "[WARN] 打包目录不存在: ${source_dir}，跳过打包"
        return
    fi

    # 创建打包目录
    rm -rf ${package_path}
    echo "clear old package ${package_path}"
    mkdir -p "${UPLOAD_TMP_DIR}"

    # 进入源目录打包
    cd "${source_dir}"
    echo "[INFO] 开始打包: ${package_name}"

    # 优先使用zip，fallback到7z/powershell
    if command -v zip >/dev/null 2>&1; then
        zip -qr "${package_path}" ./*
    elif command -v 7z >/dev/null 2>&1; then
        7z a -tzip -r "${package_path}" ./* >/dev/null
    elif [ ${IS_WINDOWS} -eq 1 ]; then
        # Windows下使用PowerShell打包（修复路径格式）
        local ps_source_dir=$(cygpath -w "${source_dir}")
        local ps_package_path=$(cygpath -w "${package_path}")
        powershell.exe -NoProfile -NonInteractive -Command "
            \$ErrorActionPreference = 'Stop'
            Compress-Archive -Path '${ps_source_dir}\*' -DestinationPath '${ps_package_path}' -Force
        "
    else
        echo "[ERROR] 未找到打包工具（zip/7z）"
        exit 1
    fi

    # 返回脚本目录
    cd "${SCRIPT_DIR}"
    echo "[SUCCESS] 打包完成: ${package_path}"
}

# 8. 构建macOS通用二进制（amd64+arm64合并）
BuildDarwinUniversal() {
    # Windows下不支持lipo命令，跳过通用二进制构建
    if [ ${IS_WINDOWS} -eq 1 ]; then
        echo "[WARN] Windows系统不支持lipo命令，跳过darwin universal构建"
        return 0
    fi

    local amd64_bin="${BUILD_PATH}/${RUN_MODE}/darwin/amd64/${PRODUCT_NAME}"
    local arm64_bin="${BUILD_PATH}/${RUN_MODE}/darwin/arm64/${PRODUCT_NAME}"
    local universal_dir="${BUILD_PATH}/${RUN_MODE}/darwin/universal"
    local universal_bin="${universal_dir}/${PRODUCT_NAME}"

    # 先编译amd64和arm64
    BuildBinary "darwin" "amd64"
    BuildBinary "darwin" "arm64"

    if [ ! -f "${amd64_bin}" ] || [ ! -f "${arm64_bin}" ]; then
        echo "[ERROR] macOS二进制文件缺失，无法合并通用二进制"
        return 1
    fi

    # 创建通用二进制目录
    mkdir -p "${universal_dir}"

    # 合并二进制
    echo "[INFO] 合并macOS通用二进制（amd64+arm64）"
    lipo -create -output "${universal_bin}" "${amd64_bin}" "${arm64_bin}"
    chmod +x "${universal_bin}"

    # 打包通用二进制
    PackageBinary "darwin" "universal"

    # 清理临时文件（可选）
    rm -rf "${BUILD_PATH}/${RUN_MODE}/darwin/amd64"
    rm -rf "${BUILD_PATH}/${RUN_MODE}/darwin/arm64"
    echo "[SUCCESS] macOS通用二进制构建完成: ${universal_bin}"
}

# 9. 编译单个目标
BuildSingleTarget() {
    local target_os=$1
    local target_arch=$2

    # 验证目标
    ValidateTarget "${target_os}" "${target_arch}"

    # 特殊处理universal
    if [ "${target_arch}" = "universal" ]; then
        BuildDarwinUniversal
        return
    fi

    # 编译普通目标
    BuildBinary "${target_os}" "${target_arch}"
    # 打包
    PackageBinary "${target_os}" "${target_arch}"
}

# 10. 编译所有目标（适配Windows）
BuildAllTargets() {
    echo "[INFO] 开始编译所有支持的平台/架构"

    # 编译Linux系列
    BuildSingleTarget "linux" "amd64"
    BuildSingleTarget "linux" "arm64"

    # 编译macOS系列（Windows下跳过universal）
    if [ ${IS_WINDOWS} -eq 1 ]; then
        BuildSingleTarget "darwin" "amd64"
        BuildSingleTarget "darwin" "arm64"
    else
        BuildSingleTarget "darwin" "universal"
    fi

    # 编译Windows系列
    BuildSingleTarget "windows" "amd64"

    echo "[SUCCESS] 所有平台编译完成"
}

# ======================== 主流程 ========================
echo "========================================"
echo "          ${PRODUCT_NAME} 构建脚本          "
echo "========================================"

# 初始化
GetOSType
LoadProjectInfo

# 解析命令行参数
TARGET_OS=""
TARGET_ARCH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            PrintHelp
            exit 0
            ;;
        -m|--mode)
            RUN_MODE="$2"
            shift 2
            # 验证构建模式
            if [[ ! "${RUN_MODE}" =~ ^(release|test|debug)$ ]]; then
                echo "[ERROR] 无效的构建模式: ${RUN_MODE}"
                PrintHelp
                exit 1
            fi
            ;;
        all)
            TARGET_OS="all"
            TARGET_ARCH="all"
            shift
            ;;
        linux|darwin|windows)
            TARGET_OS="$1"
            TARGET_ARCH="$2"
            shift 2
            ;;
        *)
            echo "[ERROR] 无效的参数: $1"
            PrintHelp
            exit 1
            ;;
    esac
done

# 默认编译所有（如果未指定目标）
if [ -z "${TARGET_OS}" ] && [ -z "${TARGET_ARCH}" ]; then
    TARGET_OS="all"
    TARGET_ARCH="all"
fi

# 打印构建模式
echo "[INFO] 构建模式: ${RUN_MODE}"

# 执行编译
if [ "${TARGET_OS}" = "all" ]; then
    BuildAllTargets
else
    BuildSingleTarget "${TARGET_OS}" "${TARGET_ARCH}"
fi

# 最终提示
echo "[INFO] 构建完成！打包文件位置: ${UPLOAD_TMP_DIR}"