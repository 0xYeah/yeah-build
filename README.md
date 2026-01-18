# Yeah-Build - 多语言项目构建工具
* Quickly build complex multi-project applications developed in languages ​​such as Java and Go in a single step.
* zh-CN：一次性快速构建 Java、Go等语言开发的复杂的多个工程项目 ,依赖git 以及 dev lang 开发环境。

一个基于 Go 和 tview 开发的交互式多项目构建工具,支持 Java、Go、Node.js 等多种语言项目的一键构建。

## ✨ 特性

- 🎨 **交互式 TUI 界面** - 基于 tview 的美观终端界面
- 🚀 **多语言支持** - Java (Maven/Gradle)、Go、Node.js、Rust 等
- 📦 **批量构建** - 支持选择多个项目同时构建
- 🔄 **Git 集成** - 自动 pull、切换分支、reset
- ⚡ **并行/串行** - 可配置并行或串行构建
- 📝 **配置驱动** - 通过 YAML 配置文件管理所有项目
- 🎯 **灵活模式** - 支持交互模式和非交互模式
- 🌍 **跨平台** - 完美支持 Linux、macOS、Windows、BSD

## 🚀 快速开始

### 安装

```bash
# 克隆或下载代码
git clone <your-repo>
cd yeah-build

# 安装依赖
go mod download

# 编译
go build -o yeah-build

# 可选: 安装到系统路径
sudo cp yeah-build /usr/local/bin/
```

### 初次使用

```bash
# 在项目根目录执行(会自动生成配置文件)
./yeah-build

# 或使用全局安装的版本
yeah-build
```

首次运行会自动生成 `yeah-build.yaml` 配置文件模板。

## 📖 使用方法

### 交互模式 (默认)

```bash
# 直接运行
./yeah-build

# 指定配置文件
./yeah-build -c /path/to/config.yaml
```

**交互模式快捷键:**
- `Space` - 选择/取消选择项目
- `Enter` - 开始构建选中的项目
- `Ctrl+A` - 全选所有项目
- `Ctrl+D` - 取消全选
- `Ctrl+C` - 退出程序

### 非交互模式

```bash
# 直接执行所有启用的项目构建
./yeah-build --no-interactive
```

## ⚙️ 配置文件

`yeah-build.yaml` 配置示例:

```yaml
# 是否启用交互模式 (false 则直接执行构建)
interactive: true

# 全局配置
global:
  parallel: false        # 是否并行构建
  stop_on_error: true   # 遇到错误是否停止
  log_file: "build.log" # 日志文件
  timeout: 600          # 超时时间(秒)

# 项目列表
projects:
  # Java 项目示例
  - name: "backend-api"
    path: "./backend"
    type: "java"
    disabled: false      # 是否禁用此项目
    git:
      pull: true         # 构建前是否 git pull
      branch: "main"     # 切换到指定分支
      reset: false       # 是否 reset --hard
    build:
      clean: true        # 是否清理
      test: false        # 是否运行测试
      commands:
        - "mvn clean package -DskipTests"
    env:
      JAVA_HOME: "/usr/lib/jvm/java-17"
      MAVEN_OPTS: "-Xmx2048m"

  # Go 项目示例
  - name: "user-service"
    path: "./services/user"
    type: "go"
    git:
      pull: true
      branch: "develop"
    build:
      commands:
        - "go mod download"
        - "go build -o bin/user-service ./cmd/main.go"
    env:
      CGO_ENABLED: "0"
      GOOS: "linux"
      GOARCH: "amd64"

  # Node.js 项目示例
  - name: "admin-dashboard"
    path: "./frontend/admin"
    type: "node"
    git:
      pull: true
    build:
      commands:
        - "npm install"
        - "npm run build"
    env:
      NODE_ENV: "production"

  # Gradle 项目示例
  - name: "payment-service"
    path: "./services/payment"
    type: "java"
    git:
      pull: true
    build:
      commands:
        - "./gradlew clean build -x test"

  # Rust 项目示例
  - name: "data-processor"
    path: "./processor"
    type: "rust"
    disabled: true  # 暂时禁用
    build:
      commands:
        - "cargo build --release"
```

## 🎯 使用场景

### 场景 1: 微服务项目一键构建

```yaml
projects:
  - name: "gateway"
    path: "./gateway"
    type: "go"
    build:
      commands: ["go build -o bin/gateway"]
  
  - name: "auth-service"
    path: "./services/auth"
    type: "java"
    build:
      commands: ["mvn clean package"]
  
  - name: "user-service"
    path: "./services/user"
    type: "go"
    build:
      commands: ["go build -o bin/user-service"]
```

### 场景 2: 前后端分离项目

```yaml
projects:
  - name: "backend-api"
    path: "./server"
    type: "java"
    build:
      commands: ["mvn clean package"]
  
  - name: "web-frontend"
    path: "./web"
    type: "node"
    build:
      commands: 
        - "npm install"
        - "npm run build"
  
  - name: "mobile-app"
    path: "./mobile"
    type: "node"
    build:
      commands:
        - "npm install"
        - "npm run build:android"
```

### 场景 3: CI/CD 流程

```bash
# 非交互模式用于 CI/CD
yeah-build --no-interactive

# 在 Dockerfile 中
RUN yeah-build --no-interactive
```

## 🔧 高级用法

### 环境变量覆盖

项目级环境变量会覆盖系统环境变量:

```yaml
projects:
  - name: "my-app"
    env:
      JAVA_HOME: "/custom/java"
      PATH: "/custom/bin:$PATH"
```

### 条件构建

使用 `disabled` 字段控制项目是否参与构建:

```yaml
projects:
  - name: "experimental-feature"
    disabled: true  # 临时禁用
```

### 多阶段构建

```yaml
projects:
  - name: "data-layer"
    path: "./database"
    build:
      commands:
        - "liquibase update"
  
  - name: "backend"
    path: "./api"
    build:
      commands:
        - "mvn clean package"
  
  - name: "frontend"
    path: "./web"
    build:
      commands:
        - "npm run build"
```

## 📝 注意事项

1. **路径问题**: 所有 `path` 都相对于 `yeah-build.yaml` 所在目录
2. **Git 仓库**: Git 操作仅在存在 `.git` 目录时执行
3. **依赖工具**: 确保系统已安装对应的构建工具(mvn, go, npm 等)
4. **权限问题**: 某些命令可能需要特定权限
5. **超时控制**: 长时间构建可调整 `global.timeout` 值

## 🐛 故障排查

### 构建失败

1. 检查构建工具是否已安装: `mvn -v`, `go version`, `npm -v`
2. 检查项目路径是否正确
3. 检查环境变量配置
4. 查看详细错误输出

### Git 操作失败

1. 检查网络连接
2. 检查 Git 凭证配置
3. 确认分支名称正确

### 界面显示异常

1. 确保终端支持 UTF-8
2. 调整终端窗口大小
3. 检查 `TERM` 环境变量

## 🤝 贡献

欢迎提交 Issue 和 Pull Request!

## 📄 License

MIT License
