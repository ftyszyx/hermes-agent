"""Local execution environment — spawn-per-call with session snapshot."""

import json
import logging
import os
import platform
import re
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path

from tools.environments.base import BaseEnvironment, _pipe_stdin

_IS_WINDOWS = platform.system() == "Windows"
logger = logging.getLogger(__name__)


# Hermes-internal env vars that should NOT leak into terminal subprocesses.
_HERMES_PROVIDER_ENV_FORCE_PREFIX = "_HERMES_FORCE_"
_POWERSHELL_PREFERENCE = ("pwsh", "powershell")
_POWERSHELL_ENV_PAT = re.compile(r"^\s*(?:\$env:([A-Za-z_][A-Za-z0-9_]*)\s*=|Remove-Item\s+Env:([A-Za-z_][A-Za-z0-9_]*))")


def _build_provider_env_blocklist() -> frozenset:
    """Derive the blocklist from provider, tool, and gateway config."""
    blocked: set[str] = set()

    try:
        from hermes_cli.auth import PROVIDER_REGISTRY
        for pconfig in PROVIDER_REGISTRY.values():
            blocked.update(pconfig.api_key_env_vars)
            if pconfig.base_url_env_var:
                blocked.add(pconfig.base_url_env_var)
    except ImportError:
        pass

    try:
        from hermes_cli.config import OPTIONAL_ENV_VARS
        for name, metadata in OPTIONAL_ENV_VARS.items():
            category = metadata.get("category")
            if category in {"tool", "messaging"}:
                blocked.add(name)
            elif category == "setting" and metadata.get("password"):
                blocked.add(name)
    except ImportError:
        pass

    blocked.update({
        "OPENAI_BASE_URL",
        "OPENAI_API_KEY",
        "OPENAI_API_BASE",
        "OPENAI_ORG_ID",
        "OPENAI_ORGANIZATION",
        "OPENROUTER_API_KEY",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "LLM_MODEL",
        "GOOGLE_API_KEY",
        "DEEPSEEK_API_KEY",
        "MISTRAL_API_KEY",
        "GROQ_API_KEY",
        "TOGETHER_API_KEY",
        "PERPLEXITY_API_KEY",
        "COHERE_API_KEY",
        "FIREWORKS_API_KEY",
        "XAI_API_KEY",
        "HELICONE_API_KEY",
        "PARALLEL_API_KEY",
        "FIRECRAWL_API_KEY",
        "FIRECRAWL_API_URL",
        "TELEGRAM_HOME_CHANNEL",
        "TELEGRAM_HOME_CHANNEL_NAME",
        "DISCORD_HOME_CHANNEL",
        "DISCORD_HOME_CHANNEL_NAME",
        "DISCORD_REQUIRE_MENTION",
        "DISCORD_FREE_RESPONSE_CHANNELS",
        "DISCORD_AUTO_THREAD",
        "SLACK_HOME_CHANNEL",
        "SLACK_HOME_CHANNEL_NAME",
        "SLACK_ALLOWED_USERS",
        "WHATSAPP_ENABLED",
        "WHATSAPP_MODE",
        "WHATSAPP_ALLOWED_USERS",
        "SIGNAL_HTTP_URL",
        "SIGNAL_ACCOUNT",
        "SIGNAL_ALLOWED_USERS",
        "SIGNAL_GROUP_ALLOWED_USERS",
        "SIGNAL_HOME_CHANNEL",
        "SIGNAL_HOME_CHANNEL_NAME",
        "SIGNAL_IGNORE_STORIES",
        "HASS_TOKEN",
        "HASS_URL",
        "EMAIL_ADDRESS",
        "EMAIL_PASSWORD",
        "EMAIL_IMAP_HOST",
        "EMAIL_SMTP_HOST",
        "EMAIL_HOME_ADDRESS",
        "EMAIL_HOME_ADDRESS_NAME",
        "GATEWAY_ALLOWED_USERS",
        "GH_TOKEN",
        "GITHUB_APP_ID",
        "GITHUB_APP_PRIVATE_KEY_PATH",
        "GITHUB_APP_INSTALLATION_ID",
        "MODAL_TOKEN_ID",
        "MODAL_TOKEN_SECRET",
        "DAYTONA_API_KEY",
    })
    return frozenset(blocked)


_HERMES_PROVIDER_ENV_BLOCKLIST = _build_provider_env_blocklist()


def _sanitize_subprocess_env(base_env: dict | None, extra_env: dict | None = None) -> dict:
    """Filter Hermes-managed secrets from a subprocess environment."""
    try:
        from tools.env_passthrough import is_env_passthrough as _is_passthrough
    except Exception:
        _is_passthrough = lambda _: False  # noqa: E731

    sanitized: dict[str, str] = {}

    for key, value in (base_env or {}).items():
        if key.startswith(_HERMES_PROVIDER_ENV_FORCE_PREFIX):
            continue
        if key not in _HERMES_PROVIDER_ENV_BLOCKLIST or _is_passthrough(key):
            sanitized[key] = value

    for key, value in (extra_env or {}).items():
        if key.startswith(_HERMES_PROVIDER_ENV_FORCE_PREFIX):
            real_key = key[len(_HERMES_PROVIDER_ENV_FORCE_PREFIX):]
            sanitized[real_key] = value
        elif key not in _HERMES_PROVIDER_ENV_BLOCKLIST or _is_passthrough(key):
            sanitized[key] = value

    # Per-profile HOME isolation for background processes (same as _make_run_env).
    from hermes_constants import get_subprocess_home
    _profile_home = get_subprocess_home()
    if _profile_home:
        sanitized["HOME"] = _profile_home

    return sanitized


def _find_powershell() -> str:
    """Find PowerShell for command execution on Windows."""
    for name in _POWERSHELL_PREFERENCE:
        found = shutil.which(name)
        if found:
            return found

    system_root = os.environ.get("SystemRoot", r"C:\Windows")
    candidates = (
        os.path.join(system_root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe"),
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "PowerShell", "7", "pwsh.exe"),
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "PowerShell", "6", "pwsh.exe"),
    )
    for candidate in candidates:
        if candidate and os.path.isfile(candidate):
            return candidate

    raise RuntimeError(
        "PowerShell not found. Hermes Agent requires PowerShell on Windows.\n"
        "Install PowerShell 7+ from: https://aka.ms/powershell-release?tag=stable\n"
        "Or ensure Windows PowerShell is available on PATH."
    )


def _find_bash() -> str:
    """Find bash for command execution."""
    if not _IS_WINDOWS:
        return (
            shutil.which("bash")
            or ("/usr/bin/bash" if os.path.isfile("/usr/bin/bash") else None)
            or ("/bin/bash" if os.path.isfile("/bin/bash") else None)
            or os.environ.get("SHELL")
            or "/bin/sh"
        )

    custom = os.environ.get("HERMES_GIT_BASH_PATH")
    if custom and os.path.isfile(custom):
        return custom

    found = shutil.which("bash")
    if found:
        return found

    for candidate in (
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "Git", "bin", "bash.exe"),
        os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"), "Git", "bin", "bash.exe"),
        os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Git", "bin", "bash.exe"),
    ):
        if candidate and os.path.isfile(candidate):
            return candidate

    raise RuntimeError(
        "Git Bash not found. Hermes Agent requires Git for Windows on Windows.\n"
        "Install it from: https://git-scm.com/download/win\n"
        "Or set HERMES_GIT_BASH_PATH to your bash.exe location."
    )


def _find_shell() -> str:
    """Return the preferred interactive shell for the current platform."""
    if _IS_WINDOWS:
        return _find_powershell()
    return _find_bash()


def _powershell_flag(exe: str) -> str:
    """Return the command flag accepted by the resolved PowerShell binary."""
    return "-Command"


def _to_windows_pwd(path: str) -> str:
    """Convert a POSIX-ish cwd from agent state into a Windows path when possible."""
    if not path:
        return path
    if path == "~" or path.startswith("~/"):
        home = str(Path.home())
        if path == "~":
            return home
        return os.path.join(home, path[2:].replace("/", os.sep))
    if path.startswith("/"):
        drive_match = re.match(r"^/([a-zA-Z])(?:/(.*))?$", path)
        if drive_match:
            drive = drive_match.group(1).upper() + ":"
            rest = drive_match.group(2) or ""
            rest = rest.replace("/", os.sep)
            return os.path.join(drive + os.sep, rest) if rest else drive + os.sep
    return path


def _render_env_delta_powershell(env_vars: dict[str, str]) -> str:
    """Translate backend env overrides into PowerShell assignments."""
    lines: list[str] = []
    for key, value in env_vars.items():
        if key.startswith(_HERMES_PROVIDER_ENV_FORCE_PREFIX):
            key = key[len(_HERMES_PROVIDER_ENV_FORCE_PREFIX):]
        if value is None:
            lines.append(f"Remove-Item Env:{key} -ErrorAction SilentlyContinue")
            continue
        value_json = json.dumps(str(value))
        lines.append(f"$env:{key} = {value_json}")
    return "\n".join(lines)


def _command_mutates_environment(command: str) -> bool:
    """Best-effort detection of PowerShell commands that alter env vars."""
    for line in command.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if _POWERSHELL_ENV_PAT.match(stripped):
            return True
    return False


# Standard PATH entries for environments with minimal PATH.
_SANE_PATH = (
    "/opt/homebrew/bin:/opt/homebrew/sbin:"
    "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
)


def _make_run_env(env: dict) -> dict:
    """Build a run environment with a sane PATH and provider-var stripping."""
    try:
        from tools.env_passthrough import is_env_passthrough as _is_passthrough
    except Exception:
        _is_passthrough = lambda _: False  # noqa: E731

    merged = dict(os.environ | env)
    run_env = {}
    for k, v in merged.items():
        if k.startswith(_HERMES_PROVIDER_ENV_FORCE_PREFIX):
            real_key = k[len(_HERMES_PROVIDER_ENV_FORCE_PREFIX):]
            run_env[real_key] = v
        elif k not in _HERMES_PROVIDER_ENV_BLOCKLIST or _is_passthrough(k):
            run_env[k] = v
    existing_path = run_env.get("PATH", "")
    if not _IS_WINDOWS:
        if "/usr/bin" not in existing_path.split(":"):
            run_env["PATH"] = f"{existing_path}:{_SANE_PATH}" if existing_path else _SANE_PATH

    # Per-profile HOME isolation: redirect system tool configs (git, ssh, gh,
    # npm …) into {HERMES_HOME}/home/ when that directory exists.  Only the
    # subprocess sees the override — the Python process keeps the real HOME.
    from hermes_constants import get_subprocess_home
    _profile_home = get_subprocess_home()
    if _profile_home:
        run_env["HOME"] = _profile_home

    return run_env


def _read_terminal_shell_init_config() -> tuple[list[str], bool]:
    """Return (shell_init_files, auto_source_bashrc) from config.yaml.

    Best-effort — returns sensible defaults on any failure so terminal
    execution never breaks because the config file is unreadable.
    """
    try:
        from hermes_cli.config import load_config

        cfg = load_config() or {}
        terminal_cfg = cfg.get("terminal") or {}
        files = terminal_cfg.get("shell_init_files") or []
        if not isinstance(files, list):
            files = []
        auto_bashrc = bool(terminal_cfg.get("auto_source_bashrc", True))
        return [str(f) for f in files if f], auto_bashrc
    except Exception:
        return [], True


def _resolve_shell_init_files() -> list[str]:
    """Resolve the list of files to source before the login-shell snapshot.

    Expands ``~`` and ``${VAR}`` references and drops anything that doesn't
    exist on disk, so a missing ``~/.bashrc`` never breaks the snapshot.
    The ``auto_source_bashrc`` path runs only when the user hasn't supplied
    an explicit list — once they have, Hermes trusts them.
    """
    explicit, auto_bashrc = _read_terminal_shell_init_config()

    candidates: list[str] = []
    if explicit:
        candidates.extend(explicit)
    elif auto_bashrc and not _IS_WINDOWS:
        # Bash's login-shell invocation does NOT source ~/.bashrc by default,
        # so tools like nvm / asdf / pyenv that self-install there stay
        # invisible to the snapshot without this nudge.
        candidates.append("~/.bashrc")

    resolved: list[str] = []
    for raw in candidates:
        try:
            path = os.path.expandvars(os.path.expanduser(raw))
        except Exception:
            continue
        if path and os.path.isfile(path):
            resolved.append(path)
    return resolved


def _prepend_shell_init(cmd_string: str, files: list[str]) -> str:
    """Prepend ``source <file>`` lines (guarded + silent) to a bash script.

    Each file is wrapped so a failing rc file doesn't abort the whole
    bootstrap: ``set +e`` keeps going on errors, ``2>/dev/null`` hides
    noisy prompts, and ``|| true`` neutralises the exit status.
    """
    if not files:
        return cmd_string

    prelude_parts = ["set +e"]
    for path in files:
        # shlex.quote isn't available here without an import; the files list
        # comes from os.path.expanduser output so it's a concrete absolute
        # path.  Escape single quotes defensively anyway.
        safe = path.replace("'", "'\\''")
        prelude_parts.append(f"[ -r '{safe}' ] && . '{safe}' 2>/dev/null || true")
    prelude = "\n".join(prelude_parts) + "\n"
    return prelude + cmd_string


class LocalEnvironment(BaseEnvironment):
    """Run commands directly on the host machine.

    Spawn-per-call: every execute() spawns a fresh bash process.
    Session snapshot preserves env vars across calls.
    CWD persists via file-based read after each command.
    """

    def __init__(self, cwd: str = "", timeout: int = 60, env: dict = None):
        super().__init__(cwd=cwd or os.getcwd(), timeout=timeout, env=env)
        self.init_session()

    def get_temp_dir(self) -> str:
        """Return a shell-safe writable temp dir for local execution.

        Termux does not provide /tmp by default, but exposes a POSIX TMPDIR.
        Prefer POSIX-style env vars when available, keep using /tmp on regular
        Unix systems, and only fall back to tempfile.gettempdir() when it also
        resolves to a POSIX path.

        Check the environment configured for this backend first so callers can
        override the temp root explicitly (for example via terminal.env or a
        custom TMPDIR), then fall back to the host process environment.
        """
        for env_var in ("TMPDIR", "TMP", "TEMP"):
            candidate = self.env.get(env_var) or os.environ.get(env_var)
            if candidate:
                candidate = candidate.rstrip("/\\")
                if candidate:
                    return candidate

        if not _IS_WINDOWS and os.path.isdir("/tmp") and os.access("/tmp", os.W_OK | os.X_OK):
            return "/tmp"

        candidate = tempfile.gettempdir()
        if candidate:
            candidate = candidate.rstrip("/\\")
            if candidate:
                return candidate

        return tempfile.gettempdir()

    def init_session(self):
        """Capture initial shell state.

        Windows uses PowerShell directly per command, so we don't create a
        bash-style snapshot script there.
        """
        if _IS_WINDOWS:
            self._snapshot_ready = False
            self.cwd = _to_windows_pwd(self.cwd)
            logger.info(
                "Windows local session initialized without shell snapshot (session=%s, cwd=%s)",
                self._session_id,
                self.cwd,
            )
            return
        super().init_session()

    def _wrap_windows_command(self, command: str, cwd: str) -> str:
        """Build the PowerShell script for one Windows command execution."""
        resolved_cwd = _to_windows_pwd(cwd)
        marker = self._cwd_marker
        env_prelude = _render_env_delta_powershell(self.env)
        parts = [
            "$ErrorActionPreference = 'Continue'",
            "$ProgressPreference = 'SilentlyContinue'",
        ]
        if env_prelude:
            parts.append(env_prelude)
        parts.extend(
            [
                f"$__hermesMarker = {json.dumps(marker)}",
                f"$__hermesCwdFile = {json.dumps(self._cwd_file)}",
                f"$__hermesRequestedCwd = {json.dumps(resolved_cwd)}",
                r"if ($__hermesRequestedCwd) { try { Set-Location -LiteralPath $__hermesRequestedCwd -ErrorAction Stop } catch { exit 126 } }",
                r"& {",
                command,
                r"}",
                r"$__hermes_ec = $LASTEXITCODE",
                r'if ($null -eq $__hermes_ec) { $__hermes_ec = 0 }',
                r"$__hermesPwd = (Get-Location).ProviderPath",
                r"Set-Content -LiteralPath $__hermesCwdFile -Value $__hermesPwd -NoNewline",
                r'Write-Output ""',
                r'Write-Output ($__hermesMarker + $__hermesPwd + $__hermesMarker)',
                r"exit $__hermes_ec",
            ]
        )
        return "\n".join(parts)

    def _run_bash(self, cmd_string: str, *, login: bool = False,
                  timeout: int = 120,
                  stdin_data: str | None = None) -> subprocess.Popen:
        if _IS_WINDOWS:
            shell = _find_powershell()
            args = [shell, "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", _powershell_flag(shell), cmd_string]
            run_env = _make_run_env(self.env)
            proc = subprocess.Popen(
                args,
                text=True,
                env=run_env,
                encoding="utf-8",
                errors="replace",
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
                preexec_fn=None,
            )
            if stdin_data is not None:
                _pipe_stdin(proc, stdin_data)
            return proc

        bash = _find_bash()
        # For login-shell invocations (used by init_session to build the
        # environment snapshot), prepend sources for the user's bashrc /
        # custom init files so tools registered outside bash_profile
        # (nvm, asdf, pyenv, …) end up on PATH in the captured snapshot.
        # Non-login invocations are already sourcing the snapshot and
        # don't need this.
        if login:
            init_files = _resolve_shell_init_files()
            if init_files:
                cmd_string = _prepend_shell_init(cmd_string, init_files)
        args = [bash, "-l", "-c", cmd_string] if login else [bash, "-c", cmd_string]
        run_env = _make_run_env(self.env)

        proc = subprocess.Popen(
            args,
            text=True,
            env=run_env,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            preexec_fn=None if _IS_WINDOWS else os.setsid,
        )

        if stdin_data is not None:
            _pipe_stdin(proc, stdin_data)

        return proc

    def execute(
        self,
        command: str,
        cwd: str = "",
        *,
        timeout: int | None = None,
        stdin_data: str | None = None,
    ) -> dict:
        if not _IS_WINDOWS:
            return super().execute(command, cwd, timeout=timeout, stdin_data=stdin_data)

        self._before_execute()
        exec_command, sudo_stdin = self._prepare_command(command)
        effective_timeout = timeout or self.timeout
        effective_cwd = cwd or self.cwd

        if sudo_stdin is not None and stdin_data is not None:
            effective_stdin = sudo_stdin + stdin_data
        elif sudo_stdin is not None:
            effective_stdin = sudo_stdin
        else:
            effective_stdin = stdin_data

        wrapped = self._wrap_windows_command(exec_command, effective_cwd)
        proc = self._run_bash(
            wrapped,
            login=False,
            timeout=effective_timeout,
            stdin_data=effective_stdin,
        )
        result = self._wait_for_process(proc, timeout=effective_timeout)
        self._update_cwd(result)

        if _command_mutates_environment(exec_command):
            self._snapshot_ready = False

        return result

    def _kill_process(self, proc):
        """Kill the entire process group (all children)."""
        try:
            if _IS_WINDOWS:
                proc.terminate()
            else:
                pgid = os.getpgid(proc.pid)
                os.killpg(pgid, signal.SIGTERM)
                try:
                    proc.wait(timeout=1.0)
                except subprocess.TimeoutExpired:
                    os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            try:
                proc.kill()
            except Exception:
                pass

    def _update_cwd(self, result: dict):
        """Read CWD from temp file (local-only, no round-trip needed)."""
        try:
            cwd_path = open(self._cwd_file).read().strip()
            if cwd_path:
                self.cwd = cwd_path
        except (OSError, FileNotFoundError):
            pass

        # Still strip the marker from output so it's not visible
        self._extract_cwd_from_output(result)

    def cleanup(self):
        """Clean up temp files."""
        for f in (self._snapshot_path, self._cwd_file):
            try:
                os.unlink(f)
            except OSError:
                pass
