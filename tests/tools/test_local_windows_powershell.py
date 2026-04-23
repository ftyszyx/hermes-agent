from unittest.mock import MagicMock, patch

from tools.environments.local import LocalEnvironment


class TestWindowsLocalEnvironment:
    def test_init_session_skips_bash_snapshot_on_windows(self):
        with patch("tools.environments.local._IS_WINDOWS", True):
            with patch.object(LocalEnvironment, "_run_bash", autospec=True) as mock_run:
                env = LocalEnvironment(cwd=r"C:\work", timeout=10)

        assert env._snapshot_ready is False
        mock_run.assert_not_called()

    def test_run_bash_uses_powershell_on_windows(self):
        captured = {}

        def fake_popen(cmd, **kwargs):
            captured["cmd"] = cmd
            proc = MagicMock()
            proc.stdout = MagicMock()
            proc.stdin = MagicMock()
            return proc

        with patch("tools.environments.local._IS_WINDOWS", True), \
             patch("tools.environments.local._find_powershell", return_value="powershell.exe"), \
             patch.object(LocalEnvironment, "init_session", autospec=True, return_value=None), \
             patch("subprocess.Popen", side_effect=fake_popen):
            env = LocalEnvironment(cwd=r"C:\work", timeout=10)
            env._run_bash("Write-Output test")

        assert captured["cmd"][:5] == [
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
        ]
        assert captured["cmd"][5] == "-Command"
        assert captured["cmd"][6] == "Write-Output test"

    def test_wrap_windows_command_uses_powershell_location_and_marker(self):
        with patch("tools.environments.local._IS_WINDOWS", True), \
             patch.object(LocalEnvironment, "init_session", autospec=True, return_value=None):
            env = LocalEnvironment(cwd=r"C:\repo", timeout=10)

        wrapped = env._wrap_windows_command("Write-Output hello", r"C:\repo")

        assert "Set-Location -LiteralPath" in wrapped
        assert "Write-Output hello" in wrapped
        assert "$__hermesMarker" in wrapped
        assert "Set-Content -LiteralPath" in wrapped
