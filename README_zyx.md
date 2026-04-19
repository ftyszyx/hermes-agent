# Hermes Agent Windows 使用说明

这个文档只说明“在原生 Windows 下手动启动”的最小用法，不涉及 Windows 服务化。

## 1. 准备条件

- Windows PowerShell 可用
- Python 已安装，建议 3.11
- 已在仓库根目录执行过安装

推荐安装方式：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

如果你已经自己建好了虚拟环境，也可以直接安装依赖：

```powershell
# uv pip install -e ".[all]"
uv sync --extra web
```

## 2. 一键启动

仓库根目录新增了一个批处理脚本：

```text
start-hermes.bat
```

双击它，或在 `cmd` / PowerShell 里运行：

```bat
start-hermes.bat
```

默认行为：

- 启动 Hermes CLI 聊天界面
- 自动调用 `scripts/start-windows.ps1`
- 自动设置 `HERMES_HOME`
- 自动补齐 `%LOCALAPPDATA%\hermes` 下的常用目录和基础配置文件
- 如果仓库里还没有可用的 Python 环境，会自动创建 `.venv`
- 会优先尝试自动安装依赖，成功后直接继续启动

首次运行可能会比较慢，因为需要自动创建虚拟环境并安装依赖。

## 3. 常用启动方式

### 启动聊天界面

```bat
start-hermes.bat
```

### 启动网关前台运行

```bat
start-hermes.bat gateway
```

### 启动 Web UI 控制台

```bat
start-hermes.bat dashboard
```

默认会打开本地地址 `http://127.0.0.1:9119`。如果你不想自动打开浏览器，可以这样运行：

```bat
start-hermes.bat dashboard --no-open
```

### 打开初始化向导

```bat
start-hermes.bat setup
```

### 检查环境

```bat
start-hermes.bat doctor
```

### 进入模型选择

```bat
start-hermes.bat model
```

### 执行自定义 Hermes 命令

```bat
start-hermes.bat custom gateway status
start-hermes.bat custom config edit
```

## 4. PowerShell 启动器

真正执行启动逻辑的是：

```text
scripts/start-windows.ps1
```

如果你想手动指定参数，也可以直接运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1 -Mode gateway
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1 -Mode dashboard
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1 -Mode custom gateway status
```

## 5. 配置文件位置

默认 `HERMES_HOME`：

```text
%LOCALAPPDATA%\hermes
```

常用文件：

- `%LOCALAPPDATA%\hermes\.env`
- `%LOCALAPPDATA%\hermes\config.yaml`
- `%LOCALAPPDATA%\hermes\SOUL.md`
- `%LOCALAPPDATA%\hermes\logs\`

## 6. 常见问题

### 1）提示缺少依赖

比如缺少 `yaml`、`prompt_toolkit`、`dotenv`，说明当前 Python 不是 Hermes 的可用环境。

如果是启动 Web UI 时提示缺少 `fastapi` 或 `uvicorn`，也属于同一类问题。

现在默认行为是：

- `start-hermes.bat`
- `start-hermes.bat dashboard`
- `scripts/start-windows.ps1`

都会优先尝试自动创建 `.venv` 并安装依赖。

先执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

或者在你的虚拟环境里执行：

```powershell
uv pip install -e ".[all]"
```

如果你不想自动补环境，只想看原始报错，可以直接运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1 -NoBootstrap
```

### 2）能启动但终端工具不好用

Hermes 在 Windows 下的部分终端能力依赖 Git Bash。  
如果没有安装 Git for Windows，聊天本身可能能启动，但终端相关工具可能不可用。

### 3）想自定义 `HERMES_HOME`

可以直接调用 PowerShell 启动器：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows.ps1 -HermesHome D:\hermes-data
```

## 7. 当前建议

- 日常聊天：直接双击 `start-hermes.bat`
- 手动跑 gateway：`start-hermes.bat gateway`
- 打开 Web UI：`start-hermes.bat dashboard`
- 要查问题：`start-hermes.bat doctor`

如果后面还需要，我可以继续补：

- 一个单独的 `start-gateway.bat`
- 自动优先使用 `venv` 的安装/修复脚本
- Windows 下更完整的原生兼容说明

配置
model:
default: gpt-5.4
provider: custom
base_url: https://gpt-proxy-usa-pub.singularity-ai.com/gpt-proxy/api
api_key: 你的key
api_mode: codex_responses

custom_providers:

- name: kunlun-sky
  base_url: https://gpt-proxy-usa-pub.singularity-ai.com/gpt-proxy/api
  api_key: 你的key
  model: gpt-5.4
  api_mode: codex_responses
