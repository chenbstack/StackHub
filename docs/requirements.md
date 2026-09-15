# StackHub 项目需求文档

> **产品名称**：StackHub  
> **产品标语**：Your Development Stack, One Click Away  
> **文档状态**：初版需求

## 1. 产品定位

StackHub 是一个 macOS 菜单栏开发工作台，用于集中管理本地开发项目、服务依赖以及远程 CI/CD 状态。

它将项目启动、服务监控、访问地址、GitHub Actions 和 GitLab CI 状态聚合到一个轻量入口中。

## 2. 核心目标

- 一键启动、停止、重启一个项目及其多个服务。
- 展示每个服务的运行状态、端口、健康状态和访问地址。
- 聚合 GitHub Actions 与 GitLab CI 的运行状态、结果和跳转链接。
- 减少开发者在终端、浏览器和 CI 页面之间切换的成本。
- 保持 macOS 原生、轻量、可配置，并支持后续灵动岛展示。

## 3. 功能范围

### 3.1 项目与服务管理

- 创建、编辑、删除项目，配置名称、图标、工作目录和分组。
- 每个项目支持多个服务，例如 frontend、backend、worker、redis。
- 每个服务支持多个启动命令、环境变量、启动参数和工作目录。
- 支持项目级和服务级启动、停止、重启。
- 支持依赖顺序，例如数据库 → 后端 → 前端。
- 支持 Node.js、Python、Ruby、Go、Shell、Docker 等常见服务。

### 3.2 进程、日志与健康状态

- 展示 stopped、starting、running、unhealthy、crashed 等状态。
- 支持优雅停止，必要时终止整个进程树。
- 捕获 stdout/stderr，提供最近日志查看。
- 记录启动时间、运行时长、退出码和最近错误。
- 支持端口占用检查。
- 支持 HTTP、TCP 和 Shell 健康检查。
- 检测服务异常退出、端口冲突和健康检查失败。
- 支持 macOS 通知和菜单栏状态摘要。

### 3.3 访问地址

- 为服务配置一个或多个访问地址。
- 支持 localhost、局域网地址、自定义 URL。
- 点击地址打开默认浏览器，支持复制地址。
- 支持项目主页、Swagger、管理后台等快捷链接。

### 3.4 GitHub Actions

- 添加 GitHub 账号或 Personal Access Token。
- 支持在设置中查看、编辑和断开 GitHub 认证，凭据仅保存到 macOS Keychain。
- 选择仓库和 workflow。
- 展示 queued、in progress、success、failure、cancelled 等状态。
- 展示分支、提交、触发者、开始时间和耗时。
- 按 workflow 的 job/stage 分组展示执行阶段，支持展开单个阶段查看实时/历史日志。
- 跳转到 Actions 运行详情。
- 按仓库权限支持手动触发 workflow。
- 支持完成或失败通知。

### 3.5 GitLab CI/CD

- 支持 GitLab.com 和自建 GitLab。
- 支持在设置中绑定多个 GitLab 实例，每个实例独立配置实例地址、访问令牌、默认项目和权限。
- 支持新增、编辑、移除 GitLab 实例，并在 CI 页面按实例切换。
- 选择项目和 pipeline。
- 展示 pipeline 状态、分支、提交、触发者、阶段和耗时。
- 按 stage/job 分组展示多阶段流水线，支持展开阶段查看日志、错误上下文和退出码。
- 跳转到 pipeline 详情。
- 按权限支持重试、取消和触发 pipeline。

### 3.6 菜单栏体验

- 常驻 macOS 菜单栏，不占用 Dock 主窗口位置。
- 点击菜单栏图标打开/收起主面板；无独立主窗口时仍可完成核心操作。
- 按项目分组、收藏和搜索。
- 项目行提供启动、停止、重启、打开地址、查看日志等操作。
- 支持打开项目目录、终端和关联的 Glint workspace。
- 支持启动时自动运行指定项目。
- 后续支持全局快捷键。

### 3.7 Glint 与灵动岛

- 可选关联 Glint workspace，并通过 Glint 本地控制协议进行聚焦和查询。
- StackHub 的服务生命周期不依赖 Glint workspace 生命周期。
- 通过适配层在支持的灵动岛工具中展示项目摘要和 CI 状态。
- 首期不绑定某一个灵动岛应用的私有插件协议。

## 4. 初步配置模型

```json
{
  "projects": [
    {
      "id": "demo",
      "name": "Demo Project",
      "directory": "~/Code/demo",
      "services": [
        {
          "id": "backend",
          "name": "Backend",
          "commands": ["pnpm install", "pnpm dev"],
          "port": 3001,
          "healthCheck": "http://localhost:3001/health",
          "urls": ["http://localhost:3001"]
        }
      ]
    }
  ]
}
```

## 5. 非功能需求

- macOS 14 Sonoma 及以上，优先支持 Apple Silicon，同时提供 Intel 构建。
- 优先使用 Swift/SwiftUI/AppKit，保持轻量。
- 凭据使用 macOS Keychain 保存，不写入普通配置文件。
- 默认仅访问本机服务和用户明确授权的 GitHub/GitLab API。
- 进程管理、网络轮询和 UI 展示解耦。
- 配置支持导入、导出和备份。
- 日志具备大小限制和轮转策略。

## 6. 版本规划

### V0.1：本地服务核心

项目/服务配置、多命令启动、启停重启、端口检测、访问地址、菜单栏界面、日志和进程状态。

### V0.2：健康检查与体验

HTTP/TCP/Shell 健康检查、依赖启动顺序、崩溃通知、收藏分组搜索、Docker 支持。

### V0.3：CI/CD 聚合

GitHub Actions、GitLab CI/CD、状态通知、详情跳转、触发/重试/取消操作。

### V0.4：Glint 与灵动岛

Glint workspace 关联和聚焦、灵动岛适配层、项目与 CI 状态的紧凑展示。

## 7. 暂不纳入范围

- 完整 IDE 功能。
- Issue、看板和完整项目管理系统。
- 远程服务器进程编排。
- 替代 GitHub/GitLab 的完整 CI/CD 平台。
- 强绑定某一个灵动岛应用的私有插件协议。

## 8. 待确认问题

- 首版是否支持 Docker Compose。
- 多个启动命令默认串行，还是支持并行与依赖配置。
- 服务停止采用进程组终止、端口终止，还是两者结合。
- GitHub/GitLab 凭据是否支持 OAuth。
- 首版是否支持非刘海 Mac 的浮动面板。
