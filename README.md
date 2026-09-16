# StackHub

**English** | [简体中文](README.zh-CN.md)

StackHub is a native macOS menu bar app built with SwiftUI. Run commands and shell scripts, manage local services, and monitor GitHub Actions and GitLab CI from one panel.

## Screenshots

<table>
  <tr>
    <th>Local projects and services</th>
    <th>CI activity</th>
    <th>Full-panel service logs</th>
  </tr>
  <tr>
    <td width="33%" valign="top"><img src="docs/screenshots/projects-sanitized.png" alt="Project and service overview with sample data" width="100%"></td>
    <td width="33%" valign="top"><img src="docs/screenshots/ci-sanitized.png" alt="GitHub Actions and GitLab CI activity with sample data" width="100%"></td>
    <td width="33%" valign="top"><img src="docs/screenshots/logs-sanitized.png" alt="Service logs with sample data" width="100%"></td>
  </tr>
</table>

*English interface with sample data.*

## Features

- **Local services** — Start, stop, and restart project services with custom commands, working directories, and ports. Commands load your `.zshrc` so tools such as jenv and nvm can configure the environment.
- **Per-service runtimes** — Select an installed JDK or Node.js version, or specify a custom path. No version manager required.
- **Live logs** — View service output with ANSI colors in a dedicated log view.
- **CI monitoring** — Follow GitHub Actions and multiple GitLab instances. Each refreshes independently and keeps cached results when offline.
- **Secure credentials** — Store GitHub and GitLab tokens in macOS Keychain.
- **In-app updates** — Check for updates hourly. Click the blue download icon when an update is available to install and restart.
- **Bilingual interface** — Switch between English and Simplified Chinese.

## Install

Requires **macOS 14 or later**. Release downloads are for **Apple Silicon**.

1. Download the ZIP from [GitHub Releases](https://github.com/chenbstack/StackHub/releases/latest).
2. Extract it and move `StackHub.app` to Applications.
3. Launch StackHub and click its menu bar icon. Add local services in **Projects**, or connect GitHub and GitLab in **CI**.

Configured ports are freed before a service starts; use only ports belonging to that service. Quitting or installing an update stops managed services; start them again when needed.

### JDK and Node.js

Expand **Runtime environment** when editing a service. Automatic mode reads the nearest `.java-version`, `.nvmrc`, or `.node-version` from the service directory upward, then uses your shell default if no version file exists. A manual selection takes priority. The panel shows the resolved version, path, and source.

JDKs, Homebrew Node.js, and installed jenv/nvm versions are detected locally; custom paths work too. Numeric versions can be matched without a manager; manager aliases such as `lts/*` require an installed version resolvable by that manager. Missing requested versions prevent startup, without downloading or silently choosing another version. Changes apply after restarting the service and do not change other services or your terminal environment.

## Build from source

Requires Xcode and Swift 5.9 or later.

```bash
cd swift-prototype
swift run StackHub
```

To build an app bundle, use [scripts/package-app.sh](scripts/package-app.sh).
