# StackHub

Your Development Stack, One Click Away

## Swift 原生 macOS 应用

原生版本位于 [swift-prototype](/Users/chen/work/private/StackHub/swift-prototype)：

- 用 \`MenuBarExtra\` 提供菜单栏图标和弹出面板
- SwiftUI 实现 Projects、CI、Settings 页面，全部在菜单栏面板内完成
- 支持 GitHub Actions、多个 GitLab 实例、流水线阶段和作业日志详情
- GitHub 支持浏览器 Device Flow OAuth；GitLab 支持多个实例独立授权
- 设置页内联管理本地项目、GitHub 授权和 GitLab 多实例；凭据写入 macOS 钥匙串
- 每个服务可单独选择启动目录，留空时使用项目工作目录；支持绝对路径、`~` 和相对项目目录的路径（如 `backend`、`frontend`），保存后在下次启动服务时生效
- GitHub 仅同步最近更新的 8 个自有仓库，缓存优先刷新并限制流水线请求并发
- 主菜单栏面板支持底部拖动调整高度，并记住上次尺寸

使用 Xcode 打开 \`swift-prototype/Package.swift\`，或在项目目录执行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

GitHub OAuth App 已创建并开启 Device Flow，应用内置其公开 Client ID；如需替换 OAuth App，可在设置页修改 Client ID。Client Secret 不会写入应用。
