package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/gdamore/tcell/v2"
	"github.com/rivo/tview"
	"gopkg.in/yaml.v3"
)

// Config 配置结构
type Config struct {
	Interactive bool       `yaml:"interactive"`
	Projects    []Project  `yaml:"projects"`
	Global      GlobalConf `yaml:"global"`
}

type GlobalConf struct {
	Parallel    bool   `yaml:"parallel"`
	StopOnError bool   `yaml:"stop_on_error"`
	LogFile     string `yaml:"log_file"`
	Timeout     int    `yaml:"timeout"` // 秒
}

type Project struct {
	Name     string            `yaml:"name"`
	Path     string            `yaml:"path"`
	Type     string            `yaml:"type"` // java, go, node, rust, etc
	Git      GitConf           `yaml:"git"`
	Build    BuildConf         `yaml:"build"`
	Env      map[string]string `yaml:"env"`
	Disabled bool              `yaml:"disabled"`
}

type GitConf struct {
	Pull   bool   `yaml:"pull"`
	Branch string `yaml:"branch"`
	Reset  bool   `yaml:"reset"`
}

type BuildConf struct {
	Commands []string `yaml:"commands"`
	Clean    bool     `yaml:"clean"`
	Test     bool     `yaml:"test"`
}

// BuildResult 构建结果
type BuildResult struct {
	Project  string
	Success  bool
	Output   string
	Error    string
	Duration time.Duration
}

// App 应用结构
type App struct {
	config   *Config
	app      *tview.Application
	list     *tview.List
	textView *tview.TextView
	pages    *tview.Pages
	results  []BuildResult
	mu       sync.Mutex
}

func main() {
	configPath := "./yeah-build.yaml"

	// 解析命令行参数
	for i, arg := range os.Args[1:] {
		if arg == "-c" || arg == "--config" {
			if i+1 < len(os.Args[1:]) {
				configPath = os.Args[i+2]
			}
		}
		if arg == "--no-interactive" {
			runNonInteractive(configPath)
			return
		}
		if arg == "-h" || arg == "--help" {
			printHelp()
			return
		}
	}

	// 加载配置
	config, err := loadConfig(configPath)
	if err != nil {
		fmt.Printf("加载配置文件失败: %v\n", err)
		fmt.Println("创建默认配置文件...")
		createDefaultConfig(configPath)
		os.Exit(1)
	}

	// 根据配置决定是否使用交互模式
	if !config.Interactive {
		runNonInteractive(configPath)
		return
	}

	// 启动交互式界面
	app := &App{config: config, results: []BuildResult{}}
	app.runInteractive()
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var config Config
	if err := yaml.Unmarshal(data, &config); err != nil {
		return nil, err
	}

	// 设置默认值
	if config.Global.Timeout == 0 {
		config.Global.Timeout = 600
	}

	return &config, nil
}

func createDefaultConfig(path string) {
	defaultConfig := `interactive: true

global:
  parallel: false
  stop_on_error: true
  log_file: "build.log"
  timeout: 600

projects:
  - name: "backend-api"
    path: "./backend"
    type: "java"
    git:
      pull: true
      branch: "main"
      reset: false
    build:
      clean: true
      test: false
      commands:
        - "mvn clean package -DskipTests"
    env:
      JAVA_HOME: "/usr/lib/jvm/java-17"

  - name: "frontend-service"
    path: "./frontend"
    type: "go"
    git:
      pull: true
      branch: "main"
    build:
      clean: true
      commands:
        - "go mod download"
        - "go build -o bin/app ./cmd/main.go"
    env:
      CGO_ENABLED: "0"

  - name: "admin-dashboard"
    path: "./admin"
    type: "node"
    disabled: false
    git:
      pull: true
    build:
      commands:
        - "npm install"
        - "npm run build"
`
	os.WriteFile(path, []byte(defaultConfig), 0644)
	fmt.Printf("已创建默认配置文件: %s\n", path)
}

func (a *App) runInteractive() {
	a.app = tview.NewApplication()

	// 创建项目列表
	a.list = tview.NewList().
		ShowSecondaryText(true)
	a.list.SetBorder(true).
		SetTitle(" 项目列表 (Space:选择 Enter:构建 Ctrl+A:全选 Ctrl+D:取消) ").
		SetTitleAlign(tview.AlignLeft)

	for i, proj := range a.config.Projects {
		if proj.Disabled {
			continue
		}
		status := "[ ]"
		a.list.AddItem(
			fmt.Sprintf("%s %s (%s)", status, proj.Name, proj.Type),
			proj.Path,
			rune('0'+i%10),
			nil,
		)
	}

	// 创建输出窗口
	a.textView = tview.NewTextView().
		SetDynamicColors(true).
		SetScrollable(true).
		SetWordWrap(false).
		SetChangedFunc(func() {
			a.app.Draw()
		})
	a.textView.SetBorder(true).
		SetTitle(" 构建输出 ").
		SetTitleAlign(tview.AlignLeft)

	// 创建帮助文本
	helpText := tview.NewTextView().
		SetDynamicColors(true).
		SetText("[yellow]Space[white]:选择  [yellow]Enter[white]:构建  [yellow]Ctrl+A[white]:全选  [yellow]Ctrl+D[white]:取消  [yellow]Ctrl+C[white]:退出").
		SetTextAlign(tview.AlignCenter)

	// 按键处理 - 使用最新 API
	a.list.SetInputCapture(func(event *tcell.EventKey) *tcell.EventKey {
		switch event.Key() {
		case tcell.KeyEnter:
			a.startBuild()
			return nil
		case tcell.KeyCtrlA:
			a.selectAll()
			return nil
		case tcell.KeyCtrlD:
			a.deselectAll()
			return nil
		case tcell.KeyCtrlC:
			a.app.Stop()
			return nil
		case tcell.KeyRune:
			if event.Rune() == ' ' {
				a.toggleSelection()
				return nil
			}
		}
		return event
	})

	// 布局 - 使用 Flex 进行垂直和水平布局
	mainFlex := tview.NewFlex().
		SetDirection(tview.FlexRow).
		AddItem(
			tview.NewFlex().
				AddItem(a.list, 0, 1, true).
				AddItem(a.textView, 0, 2, false),
			0, 1, true,
		).
		AddItem(helpText, 1, 0, false)

	// 创建 Pages 用于可能的未来扩展
	a.pages = tview.NewPages().
		AddPage("main", mainFlex, true, true)

	if err := a.app.SetRoot(a.pages, true).
		EnableMouse(true).
		SetFocus(a.list).
		Run(); err != nil {
		panic(err)
	}
}

func (a *App) toggleSelection() {
	idx := a.list.GetCurrentItem()
	if idx < 0 {
		return
	}
	main, sec := a.list.GetItemText(idx)

	if strings.HasPrefix(main, "[X]") {
		main = "[ ]" + main[3:]
	} else {
		main = "[X]" + main[3:]
	}
	a.list.SetItemText(idx, main, sec)
}

func (a *App) selectAll() {
	count := a.list.GetItemCount()
	for i := 0; i < count; i++ {
		main, sec := a.list.GetItemText(i)
		if strings.HasPrefix(main, "[ ]") {
			main = "[X]" + main[3:]
			a.list.SetItemText(i, main, sec)
		}
	}
}

func (a *App) deselectAll() {
	count := a.list.GetItemCount()
	for i := 0; i < count; i++ {
		main, sec := a.list.GetItemText(i)
		if strings.HasPrefix(main, "[X]") {
			main = "[ ]" + main[3:]
			a.list.SetItemText(i, main, sec)
		}
	}
}

func (a *App) startBuild() {
	// 获取选中的项目
	var selectedProjects []Project
	projectIdx := 0
	for i := 0; i < a.list.GetItemCount(); i++ {
		main, _ := a.list.GetItemText(i)
		if strings.HasPrefix(main, "[X]") {
			// 找到对应的未禁用项目
			enabledIdx := 0
			for _, proj := range a.config.Projects {
				if !proj.Disabled {
					if enabledIdx == i {
						selectedProjects = append(selectedProjects, proj)
						break
					}
					enabledIdx++
				}
			}
		}
		projectIdx++
	}

	if len(selectedProjects) == 0 {
		a.log("[yellow]请至少选择一个项目[-]")
		return
	}

	a.textView.Clear()
	a.log("[green]开始构建...[-]")
	a.results = []BuildResult{}

	// 并行或串行构建
	if a.config.Global.Parallel {
		a.buildParallel(selectedProjects)
	} else {
		a.buildSequential(selectedProjects)
	}
}

func (a *App) buildSequential(projects []Project) {
	go func() {
		for _, proj := range projects {
			result := a.buildProject(proj)
			a.mu.Lock()
			a.results = append(a.results, result)
			a.mu.Unlock()

			if !result.Success && a.config.Global.StopOnError {
				a.log(fmt.Sprintf("[red]构建失败,停止后续构建[-]"))
				break
			}
		}
		a.showSummary()
	}()
}

func (a *App) buildParallel(projects []Project) {
	go func() {
		var wg sync.WaitGroup
		for _, proj := range projects {
			wg.Add(1)
			go func(p Project) {
				defer wg.Done()
				result := a.buildProject(p)
				a.mu.Lock()
				a.results = append(a.results, result)
				a.mu.Unlock()
			}(proj)
		}
		wg.Wait()
		a.showSummary()
	}()
}

func (a *App) buildProject(proj Project) BuildResult {
	start := time.Now()
	result := BuildResult{Project: proj.Name}

	a.log(fmt.Sprintf("\n[cyan]>>> 构建项目: %s (%s)[-]", proj.Name, proj.Type))

	// Git 操作
	if proj.Git.Pull {
		if err := a.gitPull(proj); err != nil {
			result.Success = false
			result.Error = err.Error()
			a.log(fmt.Sprintf("[red]Git 操作失败: %v[-]", err))
			result.Duration = time.Since(start)
			return result
		}
	}

	// 执行构建命令
	for _, cmd := range proj.Build.Commands {
		a.log(fmt.Sprintf("[yellow]$ %s[-]", cmd))

		output, err := a.executeCommand(cmd, proj)
		result.Output += output

		if err != nil {
			result.Success = false
			result.Error = err.Error()
			a.log(fmt.Sprintf("[red]✗ 命令执行失败: %v[-]", err))
			result.Duration = time.Since(start)
			return result
		}
	}

	result.Success = true
	result.Duration = time.Since(start)
	a.log(fmt.Sprintf("[green]✓ %s 构建成功 (耗时: %v)[-]", proj.Name, result.Duration))

	return result
}

func (a *App) gitPull(proj Project) error {
	absPath, _ := filepath.Abs(proj.Path)

	if _, err := os.Stat(filepath.Join(absPath, ".git")); os.IsNotExist(err) {
		a.log(fmt.Sprintf("[yellow]跳过 Git 操作 (非 Git 仓库)[-]"))
		return nil
	}

	if proj.Git.Branch != "" {
		cmd := a.createCommand("git", []string{"checkout", proj.Git.Branch}, absPath, proj.Env)
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("切换分支失败: %v", err)
		}
		a.log(fmt.Sprintf("[blue]切换到分支: %s[-]", proj.Git.Branch))
	}

	if proj.Git.Reset {
		cmd := a.createCommand("git", []string{"reset", "--hard", "HEAD"}, absPath, proj.Env)
		cmd.Run()
	}

	cmd := a.createCommand("git", []string{"pull"}, absPath, proj.Env)
	output, err := cmd.CombinedOutput()

	if err != nil {
		return fmt.Errorf("git pull 失败: %v", err)
	}

	a.log(fmt.Sprintf("[blue]Git: %s[-]", strings.TrimSpace(string(output))))
	return nil
}

func (a *App) executeCommand(cmdStr string, proj Project) (string, error) {
	absPath, _ := filepath.Abs(proj.Path)

	// 跨平台命令解析
	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		// Windows 使用 cmd.exe 或 PowerShell
		if strings.HasPrefix(cmdStr, "powershell") || strings.HasPrefix(cmdStr, "pwsh") {
			parts := strings.Fields(cmdStr)
			cmd = exec.Command(parts[0], parts[1:]...)
		} else {
			cmd = exec.Command("cmd", "/C", cmdStr)
		}
	} else {
		// Unix-like 系统使用 sh
		parts := strings.Fields(cmdStr)
		cmd = exec.Command(parts[0], parts[1:]...)
	}

	cmd.Dir = absPath

	// 设置环境变量
	cmd.Env = os.Environ()
	for k, v := range proj.Env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}

	output, err := cmd.CombinedOutput()
	outputStr := string(output)

	// 显示输出(限制行数)
	lines := strings.Split(outputStr, "\n")
	displayLines := 10
	if len(lines) > displayLines {
		a.log(strings.Join(lines[len(lines)-displayLines:], "\n"))
	} else {
		a.log(outputStr)
	}

	return outputStr, err
}

// createCommand 跨平台创建命令
func (a *App) createCommand(name string, args []string, dir string, env map[string]string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Env = os.Environ()
	for k, v := range env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
	}
	return cmd
}

func (a *App) log(text string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	fmt.Fprintf(a.textView, "%s\n", text)
	a.textView.ScrollToEnd()
}

func (a *App) showSummary() {
	a.log("\n[green]========== 构建汇总 ==========[-]")

	success, failed := 0, 0
	for _, r := range a.results {
		if r.Success {
			success++
			a.log(fmt.Sprintf("[green]✓ %s - 成功 (%v)[-]", r.Project, r.Duration))
		} else {
			failed++
			a.log(fmt.Sprintf("[red]✗ %s - 失败: %s[-]", r.Project, r.Error))
		}
	}

	a.log(fmt.Sprintf("\n总计: %d 成功, %d 失败", success, failed))
	a.log(fmt.Sprintf("平台: %s/%s", runtime.GOOS, runtime.GOARCH))
	a.log("[yellow]按 Ctrl+C 退出[-]")
}

// 非交互模式
func runNonInteractive(configPath string) {
	config, err := loadConfig(configPath)
	if err != nil {
		fmt.Printf("错误: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("=== Yeah-Build 非交互模式 ===\n")
	fmt.Printf("平台: %s/%s\n\n", runtime.GOOS, runtime.GOARCH)

	for _, proj := range config.Projects {
		if proj.Disabled {
			continue
		}

		fmt.Printf("\n>>> 构建: %s\n", proj.Name)

		// 简化版构建逻辑
		for _, cmdStr := range proj.Build.Commands {
			fmt.Printf("$ %s\n", cmdStr)

			var cmd *exec.Cmd
			if runtime.GOOS == "windows" {
				cmd = exec.Command("cmd", "/C", cmdStr)
			} else {
				parts := strings.Fields(cmdStr)
				cmd = exec.Command(parts[0], parts[1:]...)
			}

			absPath, _ := filepath.Abs(proj.Path)
			cmd.Dir = absPath

			// 环境变量
			cmd.Env = os.Environ()
			for k, v := range proj.Env {
				cmd.Env = append(cmd.Env, fmt.Sprintf("%s=%s", k, v))
			}

			output, err := cmd.CombinedOutput()
			fmt.Print(string(output))

			if err != nil {
				fmt.Printf("✗ 失败: %v\n", err)
				if config.Global.StopOnError {
					os.Exit(1)
				}
			} else {
				fmt.Println("✓ 成功")
			}
		}
	}

	fmt.Printf("\n构建完成!\n")
}

func printHelp() {
	help := `Yeah-Build - 多语言项目构建工具 (跨平台支持)

用法:
  yeah-build [选项]

选项:
  -c, --config <file>    指定配置文件 (默认: ./yeah-build.yaml)
  --no-interactive       非交互模式运行
  -h, --help            显示帮助信息

交互模式快捷键:
  Space      选择/取消选择项目
  Enter      开始构建选中的项目
  Ctrl+A     全选
  Ctrl+D     取消全选
  Ctrl+C     退出

支持平台:
  - Linux (x86_64, ARM, ARM64)
  - macOS (x86_64, ARM64/Apple Silicon)
  - Windows (x86_64)
  - FreeBSD, OpenBSD

配置文件示例:
  查看自动生成的 yeah-build.yaml 文件

环境要求:
  - 终端支持 ANSI 颜色 (Windows 10+ 原生支持)
  - UTF-8 编码支持
`
	fmt.Println(help)
}
