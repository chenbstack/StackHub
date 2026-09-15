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
- 支持简体中文与英文，可在主面板右上角随时切换；语言偏好保存在本机。
- 项目页直接添加、编辑和移除本地项目；CI 页直接管理 GitHub 授权和 GitLab 实例，无独立设置页。
- GitHub Actions 支持浏览器 Device Flow OAuth 和增量仓库同步；GitLab 支持多个实例及完整发现。
- GitHub 与各 GitLab 实例独立刷新，结果完成即显示；离线实例保留缓存，不阻塞其他实例。请求超时为 3 秒，首次连接失败后停止本轮后续请求，自动重试间隔从 1 分钟逐步延长至最多 5 分钟；点击刷新可立即重试。
- CI 凭据保存在 macOS 钥匙串的单一加密凭据包中；旧版独立条目在首次实际使用时按需迁移。
- 使用 Sparkle 检查 GitHub Release：启动时及每小时检查一次；发现新版仅在右上角显示小蓝色下载按钮，点击后下载、校验、安装并重启。

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

应用包还需要嵌入 Sparkle.framework 及其安装辅助程序。请在仓库根目录使用统一打包脚本，输出目录应为空：

```bash
bash scripts/package-app.sh 1.0.3 /tmp/stackhub-release-1.0.3
```

命令行工具链缺少 SwiftUI 插件时，在命令前加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

### 自动更新发布

- [Sparkle 2.10.0](https://sparkle-project.org/documentation/) 已锁定在 `Package.resolved`；应用使用自定义用户界面，仅显示面板按钮，不弹出后台更新通知。
- 语言和下载按钮默认透明，悬停或按下时显示底色。下载过程中显示进度，失败后可重试。
- 更新源为 [GitHub Release 的 appcast.xml](https://github.com/chenbstack/StackHub/releases/latest/download/appcast.xml)。没有更新或索引暂不可用时，不显示按钮。
- `SUEnableAutomaticChecks=true`、`SUScheduledCheckInterval=3600`；禁止后台自动下载，不发送系统配置统计。
- 更新包和索引使用 Ed25519 签名，公钥嵌入 `Packaging/Info.plist`。本机私钥由 Sparkle 保存在钥匙串账号 `com.stackhub.prototype.updates` 中，私钥不能提交到仓库。
- GitHub Actions 需要仓库 Secret `SPARKLE_PRIVATE_KEY`。发布流程打包框架、使用版本号设置 `CFBundleVersion`、签名 ZIP 与 appcast，然后将两者上传至同一 Release。预发布使用 beta channel，不进入默认稳定版更新源。
- 旧 Release 没有更新索引；首次发布包含上述流程的新版后，GitHub 更新源才会可用。尚未内置 Sparkle 的旧应用需要手动安装一次新版。
- 点击更新后的重启会经过应用正常退出流程，停止 StackHub 管理的本地服务；重新打开后不会自动启动这些服务。

本机生成更新索引时，可直接使用钥匙串签名，无需导出私钥：

```bash
ditto -c -k --sequesterRsrc --keepParent /tmp/stackhub-release-1.0.3/StackHub.app /tmp/stackhub-release-1.0.3/StackHub-1.0.3-macos-arm64.zip
bash scripts/generate-update-feed.sh 1.0.3 /tmp/stackhub-release-1.0.3
```
