"""Exporta kiwi-splitter.ico para PNGs do tema hicolor.

Uso:
    QT_QPA_PLATFORM=offscreen python export_icons.py ICONE.ico DESTINO
"""
import sys
from pathlib import Path

from PyQt6.QtGui import QIcon
from PyQt6.QtWidgets import QApplication

SIZES = (16, 24, 32, 48, 64, 128, 256)


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write("uso: export_icons.py ICONE.ico DESTINO\n")
        return 2

    app = QApplication([])
    icon = QIcon(sys.argv[1])
    if icon.isNull():
        sys.stderr.write(f"nao foi possivel ler o icone: {sys.argv[1]}\n")
        return 1

    dest = Path(sys.argv[2])
    dest.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        pixmap = icon.pixmap(size, size)
        if pixmap.isNull():
            sys.stderr.write(f"icone vazio no tamanho {size}\n")
            return 1
        out = dest / f"{size}.png"
        if not pixmap.save(str(out), "PNG"):
            sys.stderr.write(f"falha ao salvar {out}\n")
            return 1
    app.quit()
    return 0


if __name__ == "__main__":
    sys.exit(main())
