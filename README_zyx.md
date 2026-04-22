# Hermes Agent Windows 使用说明

这份文档面向原生 Windows 使用场景，重点说明：

- 如何安装并启动 Hermes
- 如何在 Windows 下手动运行 gateway
- 如何用“任务计划程序”实现登录后自动启动 gateway
- Windows 下 profile 的推荐用法

本文不讨论 Windows Service。  
在原生 Windows 上，`hermes gateway install` 目前也不受支持。

## 1. 快速开始

### 安装

前提：

- Windows PowerShell 可用
- 已安装 Python，建议 3.11
- 当前目录是仓库根目录

推荐直接执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

如果你已经自己准备好了虚拟环境，也可以手动安装：

```powershell
uv pip install -e ".[all]"
```

### 启动

仓库根目录提供了一个 Windows 启动脚本：

```text
start-hermes.bat
```

直接双击它，或者在 `cmd` / PowerShell 中运行：

```bat
start-hermes.bat
```

默认会：

- 启动 Hermes CLI 聊天界面
- 调用 `scripts/start-windows.ps1`
- 自动设置 `HERMES_HOME`
- 自动补齐 `%LOCALAPPDATA%\hermes` 下的常用目录和基础配置文件
- 在仓库没有可用 Python 环境时自动创建 `.venv`
- 在依赖缺失时优先尝试自动安装，然后继续启动

首次运行可能会比较慢，因为可能会自动建虚拟环境并安装依赖。

## 2. 常用命令

最常用的 Windows 命令如下：

```bat
start-hermes.bat
start-hermes.bat gateway
start-hermes.bat gateway setup
start-hermes.bat gateway status
start-hermes.bat dashboard
start-hermes.bat dashboard --no-open
start-hermes.bat setup
start-hermes.bat doctor
start-hermes.bat model
start-hermes.bat custom config edit
start-hermes.bat custom profile list
```

说明：

- `start-hermes.bat`：启动聊天界面
- `start-hermes.bat gateway`：前台运行 gateway，等价于 `hermes gateway run`
- `start-hermes.bat gateway setup/status`：直接执行对应的 gateway 子命令
- `start-hermes.bat dashboard`：启动 Web UI，默认打开 `http://127.0.0.1:9119`
- `start-hermes.bat dashboard --no-open`：启动 Web UI，但不自动打开浏览器
- `start-hermes.bat custom ...`：透传任意 Hermes 原生命令

## 3. Gateway 在 Windows 上怎么用

### 可以用的命令

原生 Windows 下，下面这些 gateway 命令是可以正常使用的：

```bat
start-hermes.bat gateway
start-hermes.bat gateway setup
start-hermes.bat gateway status
```

推荐的运行方式仍然是前台启动：

```bat
start-hermes.bat gateway
```

### 不能用的命令

原生 Windows 下执行：

```bat
start-hermes.bat gateway install
```

Hermes 会返回：

```text
Service installation not supported on this platform.
```

也就是说：

- `gateway run/setup`：推荐
- `gateway status`：可用于排查，但在老的 GBK `cmd` 里可能因为 Unicode 输出报错
- `gateway install/start/stop/restart`：不适合作为原生 Windows 的常规方案

如果你在 `cmd` 里执行 `gateway status` 时遇到 `UnicodeEncodeError`，建议改用 PowerShell / Windows Terminal，或者先切到 UTF-8 代码页：

```bat
chcp 65001
```

## 4. 不做 Windows Service，如何自动启动 gateway

如果你不想手动每次启动 gateway，但又不想做 Windows Service，推荐直接使用 Windows 自带的“任务计划程序”。

仓库里已经准备好了两个相关文件：

- `gateway-task.bat`
- `scripts/gateway-task.ps1`

它们会为当前登录用户注册一个计划任务，在登录 Windows 后自动执行：

```bat
start-hermes.bat gateway
```

### 最简单的用法

```bat
gateway-task.bat install
```

### 常用管理命令

```bat
gateway-task.bat status
gateway-task.bat run
gateway-task.bat stop
gateway-task.bat uninstall
```

说明：

- `install`：注册计划任务
- `status`：查看任务是否已安装、最近运行时间、上次退出码
- `run`：立刻手动触发一次计划任务
- `stop`：停止当前由计划任务启动的那次运行
- `uninstall`：删除计划任务

### 可选参数

自定义任务名：

```bat
gateway-task.bat install -TaskName HermesGatewayCoder
```

绑定指定的 `HERMES_HOME`：

```bat
gateway-task.bat install -TaskName HermesGatewayCoder -HermesHome D:\hermes-coder
```

指定 Python：

```bat
gateway-task.bat install -PythonPath C:\Python313\python.exe
```

补充说明：

- 这个方案本质上是“登录后自动拉起前台 gateway”
- 它不是 Windows Service
- 真要排查问题，建议仍然先手动执行 `start-hermes.bat gateway`

## 5. Windows 下如何使用 Profile

`profile create` 在 Windows 上可以正常使用，但原生 PowerShell / `cmd` 下，不建议依赖 Unix 风格的 profile alias。

原因是当前上游生成的 alias 仍然是 `sh` wrapper，更适合 Git Bash / WSL。

Windows 原生环境里，推荐这样用：

```powershell
start-hermes.bat custom profile create coder --no-alias
start-hermes.bat custom -p coder setup
start-hermes.bat custom -p coder chat
start-hermes.bat custom -p coder gateway run
```

如果你的环境里已经有可直接调用的 `hermes` 命令，也可以写成：

```powershell
hermes profile create coder --no-alias
hermes -p coder setup
hermes -p coder chat
hermes -p coder gateway run
```

如果你想把某个 profile 设为默认：

```powershell
start-hermes.bat custom profile use coder
```

或者：

```powershell
hermes profile use coder
```

设置后，后续可以直接运行：

```powershell
start-hermes.bat
start-hermes.bat gateway
```

不需要每次都显式写 `-p coder`。

官方文档：

- https://hermes-agent.nousresearch.com/docs/user-guide/profiles

补充说明：

- 上面这份官方文档的 profile 思路是对的
- 但其中很多示例偏向 Unix/macOS
- Windows 下请优先使用 `hermes -p <profile> ...` 或 `start-hermes.bat custom -p <profile> ...`

## 6. 配置文件与启动器

### 默认配置目录

默认 `HERMES_HOME`：

```text
%LOCALAPPDATA%\hermes
```

常用文件：

- `%LOCALAPPDATA%\hermes\.env`
- `%LOCALAPPDATA%\hermes\config.yaml`
- `%LOCALAPPDATA%\hermes\SOUL.md`
- `%LOCALAPPDATA%\hermes\logs\`

### PowerShell 启动器

真正执行 Windows 启动逻辑的是：

```text
scripts/start-windows.ps1
```

如果你想直接调用它，可以这样用：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1 -Mode gateway
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1 -Mode dashboard
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1 -Mode custom gateway status
```

如果你想自定义 `HERMES_HOME`：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1 -HermesHome D:\hermes-data
```

## 7. 常见问题

### 1）提示缺少依赖

例如缺少 `yaml`、`prompt_toolkit`、`dotenv`，说明当前 Python 还不是 Hermes 可用环境。  
如果启动 Web UI 时提示缺少 `fastapi` 或 `uvicorn`，也属于同类问题。

默认情况下，下面这些入口都会优先尝试自动创建 `.venv` 并补安装依赖：

- `start-hermes.bat`
- `start-hermes.bat dashboard`
- `scripts/start-windows.ps1`

如果想手动先安装一遍，执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

或者：

```powershell
uv pip install -e ".[all]"
```

如果你不想自动补环境，只想看原始报错：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1 -NoBootstrap
```

### 2）能启动，但终端工具不好用

Hermes 在 Windows 下的部分终端能力依赖 Git Bash。  
如果没有安装 Git for Windows，聊天界面可能能启动，但终端相关工具可能不可用。

## 8. 推荐用法

如果你只是想快速稳定地用起来，按下面这几条记就够了：

- 日常聊天：`start-hermes.bat`
- 手动跑 gateway：`start-hermes.bat gateway`
- 登录后自动启动 gateway：`gateway-task.bat install`
- 打开 Web UI：`start-hermes.bat dashboard`
- 检查环境：`start-hermes.bat doctor`

## 附录：自定义模型配置示例

如果你使用自定义 OpenAI 兼容代理，并且它支持 `codex_responses`，可以在 `%LOCALAPPDATA%\hermes\config.yaml` 中参考下面的写法：

```yaml
model:
  default: gpt-5.4
  provider: custom
  base_url: https://gpt-proxy-usa-pub.singularity-ai.com/gpt-proxy/api
  api_key: <your key>
  api_mode: codex_responses

custom_providers:
  - name: kunlun-sky
    base_url: https://gpt-proxy-usa-pub.singularity-ai.com/gpt-proxy/api
    api_key: <your key>
    model: gpt-5.4
    api_mode: codex_responses
```
