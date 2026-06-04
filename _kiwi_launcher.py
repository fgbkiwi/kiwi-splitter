"""Launcher resiliente para o instalador Pynsist."""

import os
import sys
import traceback
import importlib
import runpy
from pathlib import Path


APP_NAME = "Kiwi-Splitter"


def _set_qt_plugin_paths(base_dir: Path) -> None:
    """Ajusta caminhos de plugins Qt para ambientes empacotados."""
    candidates = [
        base_dir / "pkgs" / "PyQt6" / "Qt6" / "plugins",
        base_dir / "Lib" / "site-packages" / "PyQt6" / "Qt6" / "plugins",
        base_dir / "PyQt6" / "Qt6" / "plugins",
    ]
    plugin_root = next((p for p in candidates if p.exists()), None)
    if plugin_root is None:
        return

    os.environ.setdefault("QT_PLUGIN_PATH", str(plugin_root))
    platform_dir = plugin_root / "platforms"
    if platform_dir.exists():
        os.environ.setdefault("QT_QPA_PLATFORM_PLUGIN_PATH", str(platform_dir))


def _set_writable_workdir() -> Path:
    """Usa pasta do usuário para logs/cache em vez de Program Files."""
    local_appdata = Path(os.environ.get("LOCALAPPDATA", Path.home()))
    app_dir = local_appdata / APP_NAME
    app_dir.mkdir(parents=True, exist_ok=True)
    os.chdir(app_dir)
    return app_dir


def _show_error_dialog(message: str) -> None:
    try:
        import ctypes

        ctypes.windll.user32.MessageBoxW(0, message, APP_NAME, 0x10)
    except Exception:
        pass


def _resolve_app_main(base_dir: Path):
    """Resolve a funcao main do app em layouts diferentes do instalador."""
    search_paths = [base_dir, base_dir.parent]
    for path in search_paths:
        path_str = str(path)
        if path_str not in sys.path:
            sys.path.insert(0, path_str)

    try:
        module = importlib.import_module("kiwi_splitter")
        return module.main
    except ModuleNotFoundError:
        pass

    fallback_script = base_dir.parent / "kiwi_splitter.py"
    if fallback_script.exists():
        namespace = runpy.run_path(str(fallback_script), run_name="__kiwi_splitter__")
        if "main" in namespace and callable(namespace["main"]):
            return namespace["main"]

    raise ModuleNotFoundError("No module named 'kiwi_splitter'")


def main() -> None:
    base_dir = Path(__file__).resolve().parent
    _set_qt_plugin_paths(base_dir)
    log_dir = _set_writable_workdir()

    try:
        app_main = _resolve_app_main(base_dir)

        app_main()
    except Exception:
        err = traceback.format_exc()
        log_path = log_dir / "startup_error.log"
        log_path.write_text(err, encoding="utf-8")
        _show_error_dialog(
            "Falha ao iniciar o Kiwi-Splitter.\n\n"
            f"Detalhes salvos em:\n{log_path}"
        )
        raise


if __name__ == "__main__":
    main()
