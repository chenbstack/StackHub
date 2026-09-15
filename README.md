# StackHub

> 把本地开发服务和 CI 流水线集中到 macOS 菜单栏。

StackHub 是一款原生 SwiftUI 菜单栏应用：在一个小面板中管理本地项目的启动、停止、重启和日志，同时查看 GitHub Actions 与 GitLab CI 的流水线状态。

## 界面预览

### 本地项目与服务

![项目服务总览（示例数据）](docs/screenshots/projects-sanitized.png)

### 全屏运行日志

![运行日志（示例数据）](docs/screenshots/logs-sanitized.png)

以上截图均使用虚构的项目名、目录、端口和地址，不包含 Token、真实路径或生产日志。

## 功能

- 菜单栏原生面板，支持拖动调整高度并记住尺寸。
- 为每个本地项目配置工作目录、服务、启动命令、访问地址和一个或多个 TCP 端口。
- 启动前只释放明确配置的端口；支持以英文逗号分隔多个端口，例如 `3000, 5173`。
- 服务启停、重启、自动读取 stdout/stderr；检测到错误日志时标记为警告而非“健康”。
- ANSI 彩色日志、全屏日志页面、`Esc` 或“返回”关闭日志／编辑页面。
- 项目页直接添加、编辑和移除本地项目；CI 页直接管理 GitHub 授权和 GitLab 实例，无独立设置页。
- GitHub Actions 支持浏览器 Device Flow OAuth 和增量仓库同步；GitLab 支持多个实例及完整发现。
- CI 凭据保存在 macOS 钥匙串的单一加密凭据包中；旧版独立条目在首次实际使用时按需迁移。

## 运行

要求 macOS 14 或更高版本，以及 Swift 5.9 或更高版本。

```bash
cd swift-prototype
swift build
swift run StackHub
```

也可以用 Xcode 打开 [swift-prototype/Package.swift](swift-prototype/Package.swift)。

## 使用方式

1. 点击菜单栏的 StackHub 图标，进入“项目”页。
2. 点击“添加项目”，填写项目工作目录、服务命令和可选端口。
3. 在项目卡片中启动、停止或重启服务；点击文档图标进入日志。
4. 切换至“CI”，连接 GitHub 或添加 GitLab 实例，然后查看、关注和刷新流水线。

### 端口处理

端口字段留空时，StackHub 不会检查或终止任何进程。填写端口后，启动服务前会确认监听进程并先尝试正常终止；仍被占用时才强制结束。请只填写属于该服务的端口。

### 凭据与授权

StackHub 不将 Token 写进项目配置、日志或 `UserDefaults`。GitHub access/refresh token 与 GitLab Token 统一保存在钥匙串的 `ci.credentials.v1` 条目中。

从旧版本升级后，已有的独立凭据会在对应 GitHub 或 GitLab 账号首次刷新时迁入该条目；迁移完成后不再读取旧项。

## 项目结构

```text
swift-prototype/
├── Sources/                  # SwiftUI 应用与 CI、本地服务逻辑
├── Tests/                    # 单元测试
├── Package.swift             # Swift Package Manager 清单
└── dist/StackHub.app         # 本地构建的应用包（不提交）
docs/
└── screenshots/              # README 脱敏示例图
```

## 构建发布包

```bash
cd swift-prototype
swift build -c release
```

发布可执行文件位于 `.build/release/StackHub`。若需要 macOS `.app` 包，请以 `dist/StackHub.app/Contents/MacOS/StackHub` 为目标替换该可执行文件后进行代码签名。
