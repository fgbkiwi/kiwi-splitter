import os
import sys
import re
import time
import json
import gc
import subprocess
import tempfile
import urllib.error
import urllib.request
from datetime import date
from typing import List, Dict, Any, Optional, Tuple

import pymupdf as fitz
import tiktoken

from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QLineEdit, QPushButton, QFileDialog, QProgressBar,
    QCheckBox, QTableWidget, QTableWidgetItem, QHeaderView, QTextEdit,
    QMessageBox, QFrame, QScrollArea, QProgressDialog
)
from PyQt6.QtCore import Qt, QThread, QTimer, pyqtSignal
from PyQt6.QtGui import QIcon, QPixmap

APP_NAME = "Kiwi-Splitter"
APP_VERSION = "1.1.6"
GITHUB_OWNER = "fgbkiwi"
GITHUB_REPO = "kiwi-splitter"
GITHUB_RELEASES_API = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/releases/latest"
GITHUB_RELEASES_PAGE = f"https://github.com/{GITHUB_OWNER}/{GITHUB_REPO}/releases/latest"
UPDATE_STATE_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"),
    APP_NAME,
)
UPDATE_CHECK_FILE = os.path.join(UPDATE_STATE_DIR, "update_check.json")

def ts() -> str:
    return time.strftime("[%Y-%m-%d %H:%M:%S]")

def parse_version(version: str) -> Tuple[int, ...]:
    cleaned = (version or "").strip().lstrip("vV")
    parts: List[int] = []
    for chunk in cleaned.split("."):
        digits = ""
        for ch in chunk:
            if ch.isdigit():
                digits += ch
            else:
                break
        parts.append(int(digits) if digits else 0)
    return tuple(parts) if parts else (0,)

def version_is_newer(remote: str, local: str) -> bool:
    return parse_version(remote) > parse_version(local)

def load_update_check_state() -> Dict[str, Any]:
    try:
        if os.path.exists(UPDATE_CHECK_FILE):
            with open(UPDATE_CHECK_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                return data if isinstance(data, dict) else {}
    except Exception:
        pass
    return {}

def save_update_check_state(state: Dict[str, Any]) -> None:
    try:
        os.makedirs(UPDATE_STATE_DIR, exist_ok=True)
        with open(UPDATE_CHECK_FILE, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)
    except Exception:
        pass

def should_check_for_updates_today() -> bool:
    state = load_update_check_state()
    return state.get("last_check_date") != date.today().isoformat()

def mark_update_checked() -> None:
    state = load_update_check_state()
    state["last_check_date"] = date.today().isoformat()
    save_update_check_state(state)

def pick_installer_asset(assets: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    candidates = []
    for asset in assets or []:
        name = str(asset.get("name") or "")
        url = asset.get("browser_download_url")
        if not url:
            continue
        lower = name.lower()
        if lower.endswith(".exe") and ("kiwi-splitter" in lower or "kiwi_splitter" in lower):
            candidates.append(asset)
    if not candidates:
        for asset in assets or []:
            name = str(asset.get("name") or "")
            if name.lower().endswith(".exe") and asset.get("browser_download_url"):
                candidates.append(asset)
                break
    if not candidates:
        return None
    candidates.sort(key=lambda a: (0 if "setup" in str(a.get("name", "")).lower() or "_" in str(a.get("name", "")) else 1, str(a.get("name", ""))))
    return candidates[0]

def normalize_desc(s: str) -> str:
    if not s: return ""
    s = s.replace("\u00A0", " ")
    s = re.sub(r"[\u2000-\u200B]+", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s

def estimate_tokens(text: str) -> int:
    if not text:
        return 0
    try:
        enc = tiktoken.get_encoding("cl100k_base")
        return len(enc.encode(text))
    except Exception:
        clean = re.sub(r"\s+", " ", text).strip()
        if not clean:
            return 0
        words = len(re.findall(r"\S+", clean))
        chars = len(clean)
        return max(int(words * 1.3), int(chars / 4))

def resource_path(filename: str) -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), filename)

class AppState:
    def __init__(self):
        self.pdf_path: str = ""
        self.output_dir: str = ""
        self.documents: List[Dict[str, Any]] = []
        self.log_lines: List[str] = []
        self.selections_cache: Dict[str, Dict[str, bool]] = {}
        self.load_selections()
        
    def load_selections(self):
        try:
            if os.path.exists("selections_kiwi_splitter.json"):
                with open("selections_kiwi_splitter.json", "r", encoding="utf-8") as f:
                    self.selections_cache = json.load(f)
        except Exception:
            self.selections_cache = {}

    def save_selections(self):
        try:
            data = {}
            if os.path.exists("selections_kiwi_splitter.json"):
                with open("selections_kiwi_splitter.json", "r", encoding="utf-8") as f:
                    data = json.load(f)
            data.update(self.selections_cache)
            with open("selections_kiwi_splitter.json", "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
        except Exception:
            pass

class SumarioParser:
    def __init__(self, pdf_path: str, logger_signal=None):
        self.pdf_path = pdf_path
        self.id_regex = re.compile(r'(?:ID\.?|Id\.?|Num\.?|Doc\.?)\s*([a-f0-9]{7})\b|(?:-\s+)([a-f0-9]{7})\s*$', re.IGNORECASE | re.MULTILINE)
        self.events: List[str] = []
        self._page_text_cache = {}
        self.logger_signal = logger_signal

    def _log(self, msg):
        self.events.append(f"{ts()} {msg}")
        if self.logger_signal:
            self.logger_signal.emit(msg)

    def parse(self) -> List[Dict[str, Any]]:
        self._log("Sumário: tentando PyMuPDF nas últimas páginas.")
        docs = self._parse_with_pymupdf()
        final = self._finalize_ranges(docs)
        self._log(f"Sumário: peças identificadas={len(final)}.")
        return final

    def _parse_with_pymupdf(self) -> List[Dict[str, Any]]:
        out: List[Dict[str, Any]] = []
        with fitz.open(self.pdf_path) as doc:
            start_search = max(0, len(doc) - 20)
            for i in range(start_search, len(doc)):
                page = doc[i]
                links = []
                try:
                    links = page.get_links()
                except Exception:
                    links = []
                tf = None
                try:
                    tf = page.find_tables()
                except Exception:
                    tf = None
                if not tf or not getattr(tf, "tables", None):
                    continue
                for tab in tf.tables:
                    header_names = [str(n).strip().lower() for n in (tab.header.names if getattr(tab, "header", None) else [])]
                    data_rows: List[List[str]] = []
                    try:
                        extract_fn = getattr(tab, "extract", None)
                        if callable(extract_fn):
                            data_rows = extract_fn()
                        else:
                            data_rows = []
                    except Exception:
                        data_rows = []
                    if not data_rows:
                        continue
                        
                    header_row_idx = -1
                    for idx, row in enumerate(data_rows[:5]):
                        row_join = " ".join([str(x) for x in row if x is not None]).lower()
                        if "documento" in row_join and ("id" in row_join or "id." in row_join):
                            header_row_idx = idx
                            break
                    id_idx = -1
                    doc_idx = -1
                    type_idx = -1
                    if header_row_idx != -1:
                        hdr_cells = data_rows[header_row_idx]
                        for idx, name in enumerate(hdr_cells):
                            nm = str(name or "").replace(":", "").strip().lower()
                            if id_idx == -1 and nm.startswith("id"): id_idx = idx
                            if doc_idx == -1 and "documento" in nm: doc_idx = idx
                            if type_idx == -1 and "tipo" in nm: type_idx = idx
                    elif header_names:
                        normalized = [str(n or "").replace(":", "").strip().lower() for n in header_names]
                        valid_exact = any(h in normalized for h in ["id", "id.", "documento", "tipo"])
                        has_idlike = any(re.fullmatch(r'[a-f0-9]{7}', s) for s in normalized)
                        has_datelike = any(re.search(r'\d{2}/\d{2}/\d{4}', s) for s in normalized)
                        if valid_exact and not has_idlike and not has_datelike:
                            for idx, name in enumerate(normalized):
                                if id_idx == -1 and name in ["id", "id."]: id_idx = idx
                                if doc_idx == -1 and name == "documento": doc_idx = idx
                                if type_idx == -1 and name == "tipo": type_idx = idx
                    else:
                        if data_rows and len(data_rows[0]) >= 4:
                            first_row = [str(x or "") for x in data_rows[0]]
                            if re.search(r'^[a-f0-9]{7}$', first_row[0], re.IGNORECASE):
                                id_idx, doc_idx, type_idx = 0, 2, 3

                    if id_idx == -1 or doc_idx == -1:
                        id_idx = 0 if id_idx == -1 else id_idx
                        doc_idx = 2 if doc_idx == -1 else doc_idx
                        type_idx = 3 if type_idx == -1 else type_idx
                        
                    row_objs = getattr(tab, "rows", [])
                    rows_offset = header_row_idx + 1 if header_row_idx != -1 else 0
                    
                    for r in range(rows_offset, len(data_rows)):
                        row = data_rows[r]
                        raw_id = (str(row[id_idx]).strip() if len(row) > id_idx and row[id_idx] is not None else "")
                        raw_doc = (str(row[doc_idx]).strip() if len(row) > doc_idx and row[doc_idx] is not None else "")
                        raw_type = (str(row[type_idx]).strip() if len(row) > type_idx and row[type_idx] is not None else "")
                        
                        m_id = re.search(r'([a-f0-9]{7})', raw_id, re.IGNORECASE)
                        doc_id = (m_id.group(1) if m_id else None)
                        if not doc_id:
                            m2 = re.search(r'([a-f0-9]{7})', raw_doc, re.IGNORECASE)
                            doc_id = (m2.group(1) if m2 else None)
                        if not doc_id:
                            continue
                        doc_id = doc_id.lower()
                        doc_desc = normalize_desc(raw_doc or "")
                        doc_type = normalize_desc(raw_type or "")
                        if (not doc_desc or (doc_type and doc_desc.lower() == doc_type.lower())) and len(row) >= 4:
                            raw_doc2 = str(row[-2] or "").strip()
                            raw_type2 = str(row[-1] or "").strip()
                            if raw_doc2: doc_desc = normalize_desc(raw_doc2)
                            if raw_type2: doc_type = normalize_desc(raw_type2)
                            
                        dest_page = -1
                        try:
                            tbl_row_idx = r if header_row_idx != -1 else r
                            if 0 <= tbl_row_idx < len(row_objs):
                                cells = getattr(row_objs[tbl_row_idx], "cells", [])
                                doc_cell_rect = None
                                if 0 <= doc_idx < len(cells):
                                    try: doc_cell_rect = fitz.Rect(cells[doc_idx])
                                    except Exception: doc_cell_rect = None
                                    for link in links:
                                        if link.get("kind") == 1:
                                            lrect = fitz.Rect(link["from"])
                                            if doc_cell_rect and lrect.intersects(doc_cell_rect):
                                                dest_page = int(link["page"])
                                                break
                        except Exception:
                            dest_page = -1
                            
                        if dest_page == -1:
                            for pnum in range(0, len(doc)):
                                if pnum not in self._page_text_cache:
                                    self._page_text_cache[pnum] = doc[pnum].get_text("text")
                                pg_txt = self._page_text_cache[pnum].lower()
                                if doc_id in pg_txt:
                                    dest_page = pnum
                                    break
                                    
                        if dest_page != -1:
                            out.append({
                                "id": doc_id,
                                "start_page": dest_page,
                                "type": (doc_type or "Desconhecido"),
                                "display_name": f"{doc_desc} (ID: {doc_id})",
                                "description": doc_desc,
                                "token_est": 0
                            })
                            
        unique: Dict[str, Dict[str, Any]] = {}
        for d in out:
            if d["id"] not in unique:
                unique[d["id"]] = d
        final = list(unique.values())
        final.sort(key=lambda x: x["start_page"])
        return final

    def _finalize_ranges(self, docs: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        if not docs:
            return docs
        with fitz.open(self.pdf_path) as doc:
            total_pages = len(doc)
            docs.sort(key=lambda x: x["start_page"])
            for i in range(len(docs) - 1):
                docs[i]["end_page"] = docs[i+1]["start_page"] - 1
            docs[-1]["end_page"] = total_pages - 1
            if docs and docs[0]["start_page"] > 0:
                capa_end = docs[0]["start_page"] - 1
                if capa_end >= 0:
                    capa_doc = {
                        "id": "capa",
                        "start_page": 0, "end_page": capa_end,
                        "type": "CAPA",
                        "display_name": "Capa / Termos Iniciais",
                        "description": "Capa / Termos Iniciais",
                        "token_est": 0,
                        "selected": True
                    }
                    docs.insert(0, capa_doc)
            
            for d in docs:
                try:
                    sp = int(d.get("start_page", 0))
                    ep = int(d.get("end_page", sp))
                    if ep < sp: ep = sp; d["end_page"] = sp
                    combined_text = []
                    for p in range(sp, ep + 1):
                        if p not in self._page_text_cache:
                            self._page_text_cache[p] = doc[p].get_text("text")
                        combined_text.append(self._page_text_cache[p])
                    d["token_est"] = estimate_tokens("\n".join(combined_text))
                except Exception:
                    pass
        return docs

def split_pdf_files(pdf_path: str, output_dir: str, selected_pages: List[int], max_mb: int, log_cb):
    max_bytes = max_mb * 1024 * 1024
    base_name = os.path.basename(pdf_path).replace(".pdf", "")
    
    full_sanitized_name = f"{base_name}_full_sanitized.pdf"
    full_sanitized_path = os.path.join(output_dir, full_sanitized_name)
    
    log_cb(f"Gerando arquivo consolidado sanitizado...")
    doc_full = fitz.open(pdf_path)
    doc_full.select(selected_pages)
    doc_full.save(full_sanitized_path, garbage=4, deflate=True)
    full_size = os.path.getsize(full_sanitized_path)
    doc_full.close()
    
    if full_size <= max_bytes:
        log_cb(f"  Salvo arquivo unico: {full_sanitized_name} ({full_size / (1024*1024):.2f} MB)")
        log_cb("O arquivo consolidado cabe no limite estabelecido. Fracionamento ignorado.")
        log_cb("Processo finalizado com sucesso!")
        return
        
    log_cb(f"  Salvo arquivo unico: {full_sanitized_name} ({full_size / (1024*1024):.2f} MB)")
    log_cb(f"O arquivo excede o limite de {max_mb}MB. Iniciando particionamento adicional...")
    
    part_number = 1
    remaining_pages = selected_pages[:]
    
    while remaining_pages:
        chunk_to_test = remaining_pages[:1000]
        doc = fitz.open(pdf_path)
        doc.select(chunk_to_test)
        total_size = len(doc.tobytes(garbage=3))
        doc.close()
        
        if total_size <= max_bytes:
            doc = fitz.open(pdf_path)
            doc.select(chunk_to_test)
            out_name = f"{base_name}_part{part_number}.pdf"
            out_path = os.path.join(output_dir, out_name)
            doc.save(out_path, garbage=4, deflate=True)
            final_size = os.path.getsize(out_path)
            doc.close()
            log_cb(f"  Salva particao: {out_name} ({final_size / (1024*1024):.2f} MB, {len(chunk_to_test)} págs)")
            
            remaining_pages = remaining_pages[len(chunk_to_test):]
            part_number += 1
            continue
            
        low = 1
        high = len(chunk_to_test) - 1
        best_split = 1
        
        while low <= high:
            mid = (low + high) // 2
            doc = fitz.open(pdf_path)
            doc.select(chunk_to_test[:mid])
            size = len(doc.tobytes(garbage=3))
            doc.close()
            
            if size <= max_bytes:
                best_split = mid
                low = mid + 1 
            else:
                high = mid - 1
                
        doc = fitz.open(pdf_path)
        doc.select(chunk_to_test[:best_split])
        out_name = f"{base_name}_part{part_number}.pdf"
        out_path = os.path.join(output_dir, out_name)
        
        doc.save(out_path, garbage=4, deflate=True)
        final_size = os.path.getsize(out_path)
        doc.close()
        
        if best_split == 1 and final_size > max_bytes:
            log_cb(f"  Salva particao: {out_name} ({final_size / (1024*1024):.2f} MB, 1 pág) [Aviso: Página excede {max_mb}MB]")
        else:
            log_cb(f"  Salva particao: {out_name} ({final_size / (1024*1024):.2f} MB, {best_split} págs)")
            
        remaining_pages = remaining_pages[best_split:]
        part_number += 1
            
    log_cb("Processo de divisao finalizado com sucesso!")

# Threads PyQt
class AnalyzeThread(QThread):
    log_signal = pyqtSignal(str)
    done_signal = pyqtSignal(list)
    error_signal = pyqtSignal(str)

    def __init__(self, pdf_path):
        super().__init__()
        self.pdf_path = pdf_path

    def run(self):
        try:
            self.log_signal.emit("Analisando estrutura (PyMuPDF)...")
            parser = SumarioParser(self.pdf_path, logger_signal=self.log_signal)
            docs = parser.parse()
            self.log_signal.emit(f"Análise concluída. {len(docs)} documentos encontrados.")
            self.done_signal.emit(docs)
        except Exception as e:
            self.error_signal.emit(f"Erro na análise: {str(e)}")

class SplitThread(QThread):
    log_signal = pyqtSignal(str)
    done_signal = pyqtSignal()
    error_signal = pyqtSignal(str)

    def __init__(self, pdf_path, output_dir, selected_pages):
        super().__init__()
        self.pdf_path = pdf_path
        self.output_dir = output_dir
        self.selected_pages = selected_pages

    def run(self):
        try:
            orig_size_mb = os.path.getsize(self.pdf_path) / (1024 * 1024)
            self.log_signal.emit(f"  Tamanho do PDF original: {orig_size_mb:.2f} MB")
            if orig_size_mb > 50:
                self.log_signal.emit("  O arquivo tem mais de 50 MB, aplicando divisão em partes de 45 MB.")
            else:
                self.log_signal.emit("  O arquivo tem menos de 50 MB, mas a verificação de 45 MB continuará ativa.")
                
            split_pdf_files(
                pdf_path=self.pdf_path, 
                output_dir=self.output_dir, 
                selected_pages=self.selected_pages, 
                max_mb=45, 
                log_cb=self.log_signal.emit
            )
            self.done_signal.emit()
        except Exception as e:
            import traceback
            print(traceback.format_exc())
            self.error_signal.emit(f"Erro fatal na divisão: {str(e)}")

class UpdateCheckThread(QThread):
    update_available = pyqtSignal(str, str, str)  # version, filename, download_url
    check_failed = pyqtSignal(str)
    check_finished = pyqtSignal()

    def run(self):
        checked_ok = False
        try:
            req = urllib.request.Request(
                GITHUB_RELEASES_API,
                headers={
                    "Accept": "application/vnd.github+json",
                    "User-Agent": f"{APP_NAME}/{APP_VERSION}",
                    "X-GitHub-Api-Version": "2022-11-28",
                },
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            checked_ok = True

            remote_version = str(payload.get("tag_name") or payload.get("name") or "").strip()
            if not remote_version:
                return

            asset = pick_installer_asset(payload.get("assets") or [])
            if not asset:
                return

            download_url = str(asset.get("browser_download_url") or "")
            filename = str(asset.get("name") or f"{APP_NAME}_{remote_version}.exe")
            if download_url and version_is_newer(remote_version, APP_VERSION):
                self.update_available.emit(remote_version.lstrip("vV"), filename, download_url)
        except urllib.error.HTTPError as exc:
            # 404 = ainda nao ha releases publicadas; conta como verificacao ok
            if exc.code == 404:
                checked_ok = True
            else:
                self.check_failed.emit(f"Falha ao verificar atualizações (HTTP {exc.code}).")
        except Exception as exc:
            self.check_failed.emit(f"Falha ao verificar atualizações: {exc}")
        finally:
            if checked_ok:
                mark_update_checked()
            self.check_finished.emit()

class InstallerDownloadThread(QThread):
    progress = pyqtSignal(int)
    finished_ok = pyqtSignal(str)
    failed = pyqtSignal(str)

    def __init__(self, download_url: str, filename: str):
        super().__init__()
        self.download_url = download_url
        self.filename = filename

    def run(self):
        dest_path = ""
        try:
            safe_name = os.path.basename(self.filename) or f"{APP_NAME}-update.exe"
            dest_path = os.path.join(tempfile.gettempdir(), safe_name)
            req = urllib.request.Request(
                self.download_url,
                headers={"User-Agent": f"{APP_NAME}/{APP_VERSION}"},
            )
            with urllib.request.urlopen(req, timeout=60) as resp, open(dest_path, "wb") as out:
                total = int(resp.headers.get("Content-Length") or 0)
                downloaded = 0
                chunk_size = 1024 * 256
                while True:
                    chunk = resp.read(chunk_size)
                    if not chunk:
                        break
                    out.write(chunk)
                    downloaded += len(chunk)
                    if total > 0:
                        self.progress.emit(min(100, int(downloaded * 100 / total)))
                    else:
                        self.progress.emit(-1)
            self.progress.emit(100)
            self.finished_ok.emit(dest_path)
        except Exception as exc:
            try:
                if dest_path and os.path.exists(dest_path):
                    os.remove(dest_path)
            except Exception:
                pass
            self.failed.emit(str(exc))

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle(f"Fracionador e Sanitizador de PDF (PJe) para LLMs — {APP_NAME} {APP_VERSION}")
        self.resize(1000, 800)
        self.state = AppState()
        self.update_thread = None
        self.download_thread = None
        self.download_progress = None
        app_icon_path = resource_path("kiwi-splitter.ico")
        if os.path.exists(app_icon_path):
            self.setWindowIcon(QIcon(app_icon_path))
        
        main_widget = QWidget()
        self.setCentralWidget(main_widget)
        layout = QVBoxLayout(main_widget)
        
        # Sec 0: Application VISUAL Title
        header_row = QHBoxLayout()
        header_row.setContentsMargins(0, 0, 0, 0)
        header_row.setSpacing(12)

        lbl_title = QLabel(
            "<b>Fracionador e Sanitizador de PDF (PJe) para LLMs</b>"
            f"<br><span style='font-size:10pt;font-weight:normal;'>Versão {APP_VERSION}</span>"
        )
        font = lbl_title.font()
        font.setPointSize(font.pointSize() + 2)
        lbl_title.setFont(font)
        lbl_title.setAlignment(Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft)

        lbl_logo = QLabel()
        lbl_logo.setAlignment(Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignRight)
        logo_pixmap = QPixmap(resource_path("KiwiSplitterSquared.png"))
        if not logo_pixmap.isNull():
            lbl_logo.setPixmap(logo_pixmap.scaledToHeight(56, Qt.TransformationMode.SmoothTransformation))

        header_row.addStretch(1)
        header_row.addWidget(lbl_title)
        header_row.addStretch(1)
        header_row.addWidget(lbl_logo)
        layout.addLayout(header_row)

        line_title = QFrame()
        line_title.setFrameShape(QFrame.Shape.HLine)
        line_title.setFrameShadow(QFrame.Shadow.Sunken)
        layout.addWidget(line_title)
        
        # Sec 1: File Selection
        layout.addWidget(QLabel("<b>Seleção de Arquivos para Divisão/Extração</b>"))
        
        row_pdf = QHBoxLayout()
        self.pdf_input = QLineEdit()
        self.pdf_input.setReadOnly(True)
        btn_pdf = QPushButton("Selecionar PDF")
        btn_pdf.clicked.connect(self.select_pdf)
        row_pdf.addWidget(self.pdf_input)
        row_pdf.addWidget(btn_pdf)
        layout.addLayout(row_pdf)
        
        row_dest = QHBoxLayout()
        self.dest_input = QLineEdit()
        self.dest_input.setReadOnly(True)
        btn_dest = QPushButton("Selecionar Pasta")
        btn_dest.clicked.connect(self.select_dest)
        row_dest.addWidget(self.dest_input)
        row_dest.addWidget(btn_dest)
        layout.addLayout(row_dest)
        
        # Sec 2: Buttons
        line = QFrame()
        line.setFrameShape(QFrame.Shape.HLine)
        line.setFrameShadow(QFrame.Shadow.Sunken)
        layout.addWidget(line)
        
        row_btns = QHBoxLayout()
        self.btn_analyze = QPushButton("Analisar Estrutura")
        self.btn_analyze.setStyleSheet("background-color: #2196F3; color: white;")
        self.btn_analyze.clicked.connect(self.on_analyze)
        
        self.btn_split = QPushButton("Extrair e Dividir Selecionados")
        self.btn_split.setStyleSheet("background-color: #4CAF50; color: white;")
        self.btn_split.clicked.connect(self.on_split)
        
        btn_save_log = QPushButton("Salvar Log")
        btn_save_log.setStyleSheet("background-color: #FF5722; color: white;")
        btn_save_log.clicked.connect(self.save_log)
        
        row_btns.addWidget(self.btn_analyze)
        row_btns.addWidget(self.btn_split)
        row_btns.addWidget(btn_save_log)
        layout.addLayout(row_btns)
        
        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 0) # Indeterminate
        self.progress_bar.setVisible(False)
        layout.addWidget(self.progress_bar)
        
        # Sec 3: Documents Table
        layout.addWidget(QLabel("<b>Documentos Identificados:</b>"))
        self.chk_select_all = QCheckBox("Marcar Todos / Desmarcar Todos")
        self.chk_select_all.setChecked(True)
        self.chk_select_all.stateChanged.connect(self.on_select_all)
        layout.addWidget(self.chk_select_all)
        
        self.table = QTableWidget()
        self.table.setColumnCount(6)
        self.table.setHorizontalHeaderLabels(["Incluir", "ID PJe", "Documento", "Tipo", "Páginas", "Tokens Est."])
        self.table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        self.table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeMode.Stretch)
        layout.addWidget(self.table)
        
        self.lbl_totals = QLabel("Selecionados: 0 documentos | Total Estimado: ~0 tokens")
        layout.addWidget(self.lbl_totals)
        
        # Sec 4: Logs
        layout.addWidget(QLabel("<b>Log de Execução:</b>"))
        self.log_area = QTextEdit()
        self.log_area.setReadOnly(True)
        layout.addWidget(self.log_area)
        
        self.analyze_thread = None
        self.split_thread = None

    def schedule_update_check(self):
        if not should_check_for_updates_today():
            return
        self.update_thread = UpdateCheckThread()
        self.update_thread.update_available.connect(self.on_update_available)
        self.update_thread.check_failed.connect(self.on_update_check_failed)
        self.update_thread.start()

    def on_update_check_failed(self, message: str):
        self.log(message)

    def on_update_available(self, remote_version: str, filename: str, download_url: str):
        self.log(f"Nova versão disponível: {remote_version} (atual: {APP_VERSION}).")
        reply = QMessageBox.question(
            self,
            "Atualização disponível",
            (
                f"Há uma nova versão do {APP_NAME}.\n\n"
                f"Versão instalada: {APP_VERSION}\n"
                f"Versão disponível: {remote_version}\n\n"
                "Deseja baixar e executar o instalador agora?\n"
                f"(Também disponível em {GITHUB_RELEASES_PAGE})"
            ),
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.Yes,
        )
        if reply != QMessageBox.StandardButton.Yes:
            self.log("Atualização adiada pelo usuário.")
            return

        self.download_progress = QProgressDialog(
            f"Baixando {filename}...",
            "Cancelar",
            0,
            100,
            self,
        )
        self.download_progress.setWindowTitle("Download do instalador")
        self.download_progress.setWindowModality(Qt.WindowModality.WindowModal)
        self.download_progress.setMinimumDuration(0)
        self.download_progress.setValue(0)
        self.download_progress.canceled.connect(self.on_download_canceled)

        self.download_thread = InstallerDownloadThread(download_url, filename)
        self.download_thread.progress.connect(self.on_download_progress)
        self.download_thread.finished_ok.connect(self.on_download_finished)
        self.download_thread.failed.connect(self.on_download_failed)
        self.download_thread.start()

    def on_download_progress(self, percent: int):
        if not self.download_progress:
            return
        if percent < 0:
            self.download_progress.setRange(0, 0)
        else:
            if self.download_progress.maximum() == 0:
                self.download_progress.setRange(0, 100)
            self.download_progress.setValue(percent)

    def on_download_canceled(self):
        if self.download_thread and self.download_thread.isRunning():
            self.download_thread.terminate()
            self.download_thread.wait(2000)
        self.log("Download do instalador cancelado.")

    def on_download_failed(self, message: str):
        if self.download_progress:
            self.download_progress.close()
            self.download_progress = None
        self.log(f"Falha no download do instalador: {message}")
        QMessageBox.warning(
            self,
            "Falha no download",
            (
                f"Não foi possível baixar o instalador:\n{message}\n\n"
                f"Baixe manualmente em:\n{GITHUB_RELEASES_PAGE}"
            ),
        )

    def on_download_finished(self, installer_path: str):
        if self.download_progress:
            self.download_progress.close()
            self.download_progress = None
        self.log(f"Instalador baixado em: {installer_path}")
        try:
            subprocess.Popen([installer_path], shell=False)
        except Exception as exc:
            QMessageBox.warning(
                self,
                "Falha ao abrir instalador",
                (
                    f"O arquivo foi baixado, mas não foi possível abri-lo:\n{exc}\n\n"
                    f"Abra manualmente:\n{installer_path}"
                ),
            )
            return

        quit_reply = QMessageBox.question(
            self,
            "Instalador iniciado",
            (
                "O instalador foi iniciado.\n\n"
                "Recomenda-se fechar o Kiwi-Splitter antes de concluir a instalação.\n"
                "Deseja fechar o aplicativo agora?"
            ),
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.Yes,
        )
        if quit_reply == QMessageBox.StandardButton.Yes:
            self.close()

    def log(self, msg: str):
        line = f"{ts()} {msg}"
        self.state.log_lines.append(line)
        self.log_area.append(line)

    def select_pdf(self):
        path, _ = QFileDialog.getOpenFileName(self, "Selecionar PDF", "", "PDF Files (*.pdf)")
        if path:
            # Prepara a UI para uma nova sessão de fracionamento do Zero
            prev_dest = self.state.output_dir
            
            self.state.documents.clear()
            self.state.log_lines.clear()
            self.log_area.clear()
            
            self.table.setRowCount(0)
            self.lbl_totals.setText("Selecionados: 0 documentos | Total Estimado: ~0 tokens")
            
            self.chk_select_all.blockSignals(True)
            self.chk_select_all.setChecked(True)
            self.chk_select_all.blockSignals(False)
            self.progress_bar.setVisible(False)
            
            self.state.pdf_path = path
            self.pdf_input.setText(path)
            
            if not prev_dest:
                self.state.output_dir = os.path.dirname(path)
                self.dest_input.setText(self.state.output_dir)
            else:
                self.state.output_dir = prev_dest
                
            # Limpa lixo residual do PyMuPDF na RAM (C variables e arrays isolados de pdfs antigos)
            gc.collect()

            self.log(f"Pronto para novo processamento. PDF Selecionado: {path}")

    def select_dest(self):
        path = QFileDialog.getExistingDirectory(self, "Selecionar Pasta de Destino")
        if path:
            self.state.output_dir = path
            self.dest_input.setText(path)
            self.log(f"Destino: {path}")

    def on_analyze(self):
        if not self.state.pdf_path:
            self.log("Selecione um PDF primeiro.")
            return
            
        self.progress_bar.setVisible(True)
        self.btn_analyze.setEnabled(False)
        self.btn_split.setEnabled(False)
        
        self.analyze_thread = AnalyzeThread(self.state.pdf_path)
        self.analyze_thread.log_signal.connect(self.log)
        self.analyze_thread.error_signal.connect(self.log)
        self.analyze_thread.done_signal.connect(self.on_analyze_done)
        self.analyze_thread.start()

    def on_analyze_done(self, docs):
        self.state.documents = docs
        prev_selections = self.state.selections_cache.get(self.state.pdf_path, {})
        
        # Block signals briefly to prevent spamming updates
        self.table.blockSignals(True)
        self.table.setRowCount(0)
        
        for d in docs:
            d["selected"] = prev_selections.get(d["id"], True)
            row_idx = self.table.rowCount()
            self.table.insertRow(row_idx)
            
            chk_widget = QWidget()
            chk_layout = QHBoxLayout(chk_widget)
            chk_layout.setContentsMargins(0, 0, 0, 0)
            chk_layout.setAlignment(Qt.AlignmentFlag.AlignCenter)
            chk = QCheckBox()
            chk.setChecked(d["selected"])
            
            # Use lambda with default arg to bind scope correctly
            chk.stateChanged.connect(lambda state, doc=d: self.on_doc_toggled(doc, state))
            chk_layout.addWidget(chk)
            self.table.setCellWidget(row_idx, 0, chk_widget)
            
            self.table.setItem(row_idx, 1, QTableWidgetItem(d.get("id", "")))
            desc = normalize_desc(d.get("description", d.get("display_name",""))).replace(f"(ID: {d.get('id','')})","").strip()
            self.table.setItem(row_idx, 2, QTableWidgetItem(desc))
            self.table.setItem(row_idx, 3, QTableWidgetItem(d.get("type", "Desconhecido")))
            
            p_label = "-" if d.get("id") == "capa" else f"{d.get('start_page',0)+1} a {d.get('end_page',0)+1}" if d.get("end_page", d.get("start_page",0)) != d.get("start_page",0) else f"{d.get('start_page',0)+1}"
            self.table.setItem(row_idx, 4, QTableWidgetItem(p_label))
            self.table.setItem(row_idx, 5, QTableWidgetItem(str(d.get("token_est", 0))))

        self.table.blockSignals(False)
        self.update_totals()
        
        self.progress_bar.setVisible(False)
        self.btn_analyze.setEnabled(True)
        self.btn_split.setEnabled(True)

    def on_doc_toggled(self, doc, state):
        doc["selected"] = bool(state)
        self.update_totals()

    def update_totals(self):
        selected_count = sum(1 for d in self.state.documents if d.get("selected"))
        toks = sum(int(d.get("token_est", 0)) for d in self.state.documents if d.get("selected"))
        all_checked = (selected_count == len(self.state.documents)) if self.state.documents else False
        
        self.lbl_totals.setText(f"Selecionados: {selected_count} documentos | Total Estimado: ~{toks} tokens")
        
        self.chk_select_all.blockSignals(True)
        self.chk_select_all.setChecked(all_checked)
        self.chk_select_all.blockSignals(False)
        
        if self.state.pdf_path:
            self.state.selections_cache[self.state.pdf_path] = {d["id"]: d.get("selected", True) for d in self.state.documents}
            self.state.save_selections()

    def on_select_all(self, state):
        is_checked = bool(state)
        self.table.blockSignals(True)
        for i, d in enumerate(self.state.documents):
            d["selected"] = is_checked
            widget = self.table.cellWidget(i, 0)
            if widget:
                chk = widget.layout().itemAt(0).widget()
                chk.setChecked(is_checked)
        self.table.blockSignals(False)
        self.update_totals()

    def on_split(self):
        if not self.state.documents:
            self.log("Analise a estrutura primeiro.")
            return
            
        selected_docs = [d for d in self.state.documents if d.get('selected', True)]
        if not selected_docs:
            self.log("Nenhum documento selecionado.")
            return

        self.log("Iniciando divisão e extração dos documentos...")
        
        selected_pages = []
        for d in selected_docs:
            for p in range(d['start_page'], d['end_page'] + 1):
                if p not in selected_pages:
                    selected_pages.append(p)
        selected_pages.sort()
        
        self.progress_bar.setVisible(True)
        self.btn_analyze.setEnabled(False)
        self.btn_split.setEnabled(False)
        
        self.split_thread = SplitThread(self.state.pdf_path, self.state.output_dir, selected_pages)
        self.split_thread.log_signal.connect(self.log)
        self.split_thread.error_signal.connect(self.log)
        self.split_thread.done_signal.connect(self.on_split_done)
        self.split_thread.start()

    def on_split_done(self):
        self.progress_bar.setVisible(False)
        self.btn_analyze.setEnabled(True)
        self.btn_split.setEnabled(True)

    def save_log(self):
        try:
            pdf_stem = os.path.splitext(os.path.basename(self.state.pdf_path))[0] if self.state.pdf_path else "log"
            fname = f"{pdf_stem}_log_split_{int(time.time())}.txt"
            path = os.path.join(self.state.output_dir, fname)
            with open(path, "w", encoding="utf-8") as f:
                f.write("\n".join(self.state.log_lines))
            self.log(f"Log salvo em: {path}")
        except Exception as ex:
            self.log(f"Erro ao salvar log: {ex}")

    def closeEvent(self, event):
        """Disparado quando a janela é fechada (X, Alt+F4 ou Gerenciador)"""
        try:
            # Encerramento preventivo de Threads longas ainda rodando órfãs
            if getattr(self, 'analyze_thread', None) and self.analyze_thread.isRunning():
                self.analyze_thread.terminate()
                self.analyze_thread.wait()
            
            if getattr(self, 'split_thread', None) and self.split_thread.isRunning():
                self.split_thread.terminate()
                self.split_thread.wait()

            if getattr(self, 'update_thread', None) and self.update_thread.isRunning():
                self.update_thread.terminate()
                self.update_thread.wait(1000)

            if getattr(self, 'download_thread', None) and self.download_thread.isRunning():
                self.download_thread.terminate()
                self.download_thread.wait(1000)
                
            # Limpa todos os arrays que poderiam reter caches binários na memória do PyMuPDF
            self.state.documents.clear()
            self.state.log_lines.clear()
            
            # Invoca explicitamente a coleção de todas as C-Bindings em memória RAM
            import gc
            gc.collect()
        except:
            pass
            
        # Confirma e fecha a janela para o Windows
        event.accept()

def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app_icon_path = resource_path("kiwi-splitter.ico")
    if os.path.exists(app_icon_path):
        app.setWindowIcon(QIcon(app_icon_path))
    win = MainWindow()
    win.show()
    QTimer.singleShot(1200, win.schedule_update_check)
    sys.exit(app.exec())

if __name__ == "__main__":
    main()
