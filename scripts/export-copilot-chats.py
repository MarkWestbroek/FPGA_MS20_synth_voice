#!/usr/bin/env python3
from __future__ import annotations

"""
Export VS Code Copilot Chat sessies naar leesbare Markdown bestanden.

Zoekt de JSONL chat-sessiebestanden in VS Code's workspace storage
en converteert ze naar Markdown in doc/copilot-chats/exports/.

Gebruik:
    python3 scripts/export-copilot-chats.py

Draait vanuit de root van MusicBrain/.
"""

import json
import os
import sys
import glob
import re
import unicodedata
from datetime import datetime
from pathlib import Path
from urllib.parse import unquote, urlparse


def decode_file_uri(value: str) -> str:
    """Zet een file:// URI om naar een lokaal pad als dat nodig is."""
    if not isinstance(value, str):
        return ""
    if not value.startswith("file://"):
        return value

    parsed = urlparse(value)
    path = unquote(parsed.path or "")
    if re.match(r"^/[A-Za-z]:", path):
        path = path[1:]
    return path.replace("/", os.sep)


def workspace_contains_project(workspace_meta: dict, project_path: str) -> bool:
    """Check of een workspace naar dit project verwijst, ook bij multi-root workspaces."""
    needle = project_path.replace("\\", "/").lower().rstrip("/")
    candidate_paths = []

    for key in ("folder", "workspace"):
        value = workspace_meta.get(key)
        if isinstance(value, str):
            candidate_paths.append(decode_file_uri(value))

    for folder in workspace_meta.get("folders", []):
        if isinstance(folder, dict) and isinstance(folder.get("path"), str):
            candidate_paths.append(decode_file_uri(folder["path"]))

    workspace_ref = workspace_meta.get("workspace")
    workspace_file = decode_file_uri(workspace_ref) if isinstance(workspace_ref, str) else ""
    if workspace_file and os.path.isfile(workspace_file):
        try:
            with open(workspace_file, "r", encoding="utf-8") as wf:
                nested_workspace = json.load(wf)
            for folder in nested_workspace.get("folders", []):
                if isinstance(folder, dict) and isinstance(folder.get("path"), str):
                    candidate_paths.append(decode_file_uri(folder["path"]))
        except (json.JSONDecodeError, IOError):
            pass

    for candidate in candidate_paths:
        normalized = candidate.replace("\\", "/").lower().rstrip("/")
        if needle and needle in normalized:
            return True
    return False


def find_workspace_storage_dirs(project_path: str) -> list[str]:
    """Vind VS Code workspace storage directories voor dit project."""
    vscode_storage = os.path.expanduser(
        "~/Library/Application Support/Code/User/workspaceStorage"
    )
    if not os.path.isdir(vscode_storage):
        # Windows pad
        appdata = os.environ.get("APPDATA", "")
        vscode_storage = os.path.join(appdata, "Code", "User", "workspaceStorage")
    if not os.path.isdir(vscode_storage):
        # Linux pad
        vscode_storage = os.path.expanduser(
            "~/.config/Code/User/workspaceStorage"
        )
    if not os.path.isdir(vscode_storage):
        print("Kan VS Code workspace storage niet vinden.")
        return []

    matches = []
    for entry in os.listdir(vscode_storage):
        ws_json = os.path.join(vscode_storage, entry, "workspace.json")
        if os.path.isfile(ws_json):
            try:
                with open(ws_json, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if workspace_contains_project(data, project_path):
                    matches.append(os.path.join(vscode_storage, entry))
            except (json.JSONDecodeError, IOError):
                continue
    return sorted(set(matches))


# Response item kinds to skip entirely when extracting readable text.
# Note: toolInvocationSerialized and inlineReference are handled explicitly below.
_RESPONSE_SKIP_KINDS = frozenset({
    "thinking",
    "textEditGroup",
    "codeblockUri",
    "undoStop",
    "mcpServersStarting",
    "treeData",
})


def _clean_file_uri_in_text(text: str) -> str:
    """Zet '[](file:///d%3A/.../foo.md)' om naar 'foo.md' in een tekst."""
    def _replace(m: re.Match) -> str:
        uri = unquote(m.group(1)).split("#")[0]
        path = uri.replace("file:///", "").replace("/", os.sep)
        if path.startswith(os.sep) and len(path) > 2 and path[2] == ":":
            path = path[1:]
        return os.path.basename(path.rstrip("/\\")) or path
    return re.sub(r"\[\]\(([^)]+)\)", _replace, text)


_EMPTY_FENCE_RE = re.compile(r"\n```\n(?:\s*\n```\n)+")


def _remove_empty_fences(text: str) -> str:
    """Verwijder lege code-blocks (artefacten van overgeslagen textEditGroup-items)."""
    # Collapse een reeks van bare ``` fences (zonder inhoud ertussen) naar \n
    return _EMPTY_FENCE_RE.sub("\n", text)


def _extract_text_from_response_list(response_list: list) -> list[str]:
    """Extraheer tekst-items en tool-statusregels uit een response-lijst.

    Verwerkt items in volgorde:
    - toolInvocationSerialized (isComplete=True): cursieve statusregel
    - inlineReference: bestandsnaam als inline code
    - markdownContent / kindloze items met value: tekst-inhoud
    """
    parts: list[str] = []
    pending_tools: list[str] = []

    def flush_tools() -> None:
        if not pending_tools:
            return
        if len(pending_tools) <= 4:
            line = "*" + " \u00b7 ".join(pending_tools) + "*"
        else:
            first = pending_tools[0]
            count = len(pending_tools) - 1
            items_md = "\n".join(f"- {t}" for t in pending_tools)
            line = (
                f"<details>\n<summary><em>{first}</em>"
                f" (+{count} meer)</summary>\n\n{items_md}\n</details>"
            )
        parts.append(f"\n\n{line}\n\n")
        pending_tools.clear()

    for r in response_list:
        if not isinstance(r, dict):
            continue
        r_kind = r.get("kind")          # None voor null, str voor de rest

        if r_kind in _RESPONSE_SKIP_KINDS:
            continue

        # Tool-statusregels: alleen afgeronde aanroepen meenemen
        if r_kind == "toolInvocationSerialized":
            if r.get("isComplete"):
                past = r.get("pastTenseMessage", {})
                pastval = past.get("value", "") if isinstance(past, dict) else ""
                if pastval:
                    pending_tools.append(_clean_file_uri_in_text(pastval))
            continue

        # Inline bestandsreferenties
        if r_kind == "inlineReference":
            ref = r.get("inlineReference", {})
            if isinstance(ref, dict):
                name = ref.get("name", "")
                if not name:
                    fspath = ref.get("fsPath", "")
                    if fspath:
                        name = os.path.basename(fspath.rstrip("/\\")) or fspath
                if name:
                    flush_tools()
                    parts.append(f"`{name}`")
            continue

        # Tekst-inhoud: kind=None, kind="", kind="markdownContent", of supportThemeIcons
        if r_kind in (None, "", "markdownContent") or "supportThemeIcons" in r:
            r_val = r.get("value", "")
            if isinstance(r_val, str) and r_val.strip():
                flush_tools()
                parts.append(r_val)

    flush_tools()
    return parts


def replay_jsonl_state(filepath: str) -> dict:
    """
    Replay een JSONL state-journal naar bruikbare conversatie-data.

    VS Code gebruikt twee JSONL-formaten:

    **Compact-snapshot formaat** (nieuw, na compactie door VS Code):
    - Regel 0: kind=null, v = volledig sessie-object incl. alle requests
    - Volgende regels: kind=path (list) voor incrementele patches
      - kind=['requests'] / k=['requests']: nieuw request toegevoegd
      - kind=['requests',N,'response']: streaming response-update voor request N
      - kind=['customTitle'] etc.: metadatawijziging

    **Incrementeel formaat** (oud, bij verse/ongecomprimeerde sessies):
    - kind=0: initieel snapshot (requests meestal leeg)
    - kind=1: scalar patch (k=pad, v=waarde)
    - kind=2: list patch (request markers, streaming chunks)
    """
    session_header = None
    messages = []
    current_response_parts = []      # streaming chunks (fallback, oud formaat)
    current_consolidated = []        # geconsolideerde response (oud formaat)
    _cons_has_text = [False]          # True als consolidated echte tekst bevat (niet alleen tool-status)
    latest_generated_title = ""
    first_message_timestamp = 0

    # --- helpers ---

    def _update_title(key: str, value: str) -> None:
        nonlocal latest_generated_title
        cleaned = " ".join(value.split()).strip()
        if cleaned:
            nonlocal session_header
            if session_header is None:
                session_header = {}
            session_header[key] = cleaned
            if key == "generatedTitle":
                latest_generated_title = cleaned

    def _track_timestamp(ts: object) -> None:
        nonlocal first_message_timestamp
        if isinstance(ts, (int, float)) and ts > 0:
            if not first_message_timestamp:
                first_message_timestamp = ts
            else:
                first_message_timestamp = min(first_message_timestamp, ts)

    def _process_request(req: dict) -> None:
        """Verwerk één request-object (compact-snapshot of ['requests']-patch)."""
        _track_timestamp(req.get("timestamp"))

        gen_title = req.get("generatedTitle", "")
        if isinstance(gen_title, str) and gen_title.strip():
            nonlocal latest_generated_title
            latest_generated_title = " ".join(gen_title.split()).strip()

        msg_data = req.get("message", {})
        if isinstance(msg_data, dict):
            user_text = msg_data.get("text", "")
        elif isinstance(msg_data, str):
            user_text = msg_data
        else:
            user_text = ""
        if user_text.strip():
            messages.append({"role": "user", "text": user_text.strip()})

        resp_texts = _extract_text_from_response_list(req.get("response", []))
        if resp_texts:
            messages.append(
                {"role": "assistant", "text": _remove_empty_fences("" .join(resp_texts))}
            )

    def flush_pending_response() -> None:
        """Voeg lopende assistent-response toe (oud formaat)."""
        if current_response_parts:
            # Streaming-resultaat heeft de meest complete response (tools + tekst)
            resp_parts = current_response_parts
        elif current_consolidated:
            # Geen streaming: gebruik de embedded response als fallback
            resp_parts = current_consolidated
        else:
            resp_parts = []
        if resp_parts:
            messages.append(
                {"role": "assistant", "text": _remove_empty_fences("".join(resp_parts))}
            )
        current_consolidated.clear()
        current_response_parts.clear()
        _cons_has_text[0] = False

    # --- main parse loop ---

    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            kind = obj.get("kind")   # None / int / list
            v = obj.get("v")
            k = obj.get("k")         # path key (list or None)

            # ── COMPACT-SNAPSHOT FORMAAT ───────────────────────────────────────

            if kind is None and isinstance(v, dict) and "requests" in v:
                # Volledige sessie-snapshot (compact formaat)
                session_header = {key: val for key, val in v.items() if key != "requests"}
                for title_key in ("customTitle", "sessionTitle", "generatedTitle", "title"):
                    val = session_header.get(title_key, "")
                    if isinstance(val, str) and val.strip():
                        cleaned = " ".join(val.split()).strip()
                        session_header[title_key] = cleaned
                        if title_key == "generatedTitle":
                            latest_generated_title = cleaned
                        break
                _track_timestamp(session_header.get("creationDate"))
                for req in v.get("requests", []):
                    if isinstance(req, dict):
                        _process_request(req)
                continue

            if isinstance(kind, list):
                # kind is het pad (== k in dit formaat)
                path = kind  # kind en k zijn hetzelfde

                # ['requests'] → nieuw request appended
                if path == ["requests"] and isinstance(v, list):
                    for req in v:
                        if isinstance(req, dict):
                            _process_request(req)
                    continue

                # ['requests', N, 'response'] → streaming response-update
                if (
                    len(path) == 3
                    and path[0] == "requests"
                    and isinstance(path[1], int)
                    and path[2] == "response"
                    and isinstance(v, list)
                ):
                    resp_texts = _extract_text_from_response_list(v)
                    if resp_texts:
                        new_text = "".join(resp_texts)
                        if messages and messages[-1]["role"] == "assistant":
                            if len(new_text) > len(messages[-1]["text"]):
                                messages[-1]["text"] = new_text
                        else:
                            messages.append({"role": "assistant", "text": new_text})
                    continue

                # Titelwijziging
                if path and path[-1] in ("customTitle", "sessionTitle", "generatedTitle", "title"):
                    if isinstance(v, str) and v.strip():
                        _update_title(path[-1], v)
                continue

            # ── OUD INCREMENTEEL FORMAAT (kind = int) ──────────────────────────

            if kind == 0:
                snapshot = v or {}
                session_header = {key: val for key, val in snapshot.items() if key != "requests"}
                for key in ("customTitle", "sessionTitle", "generatedTitle", "title"):
                    value = session_header.get(key, "")
                    if isinstance(value, str) and value.strip():
                        cleaned = " ".join(value.split()).strip()
                        session_header[key] = cleaned
                        if key == "generatedTitle":
                            latest_generated_title = cleaned
                        break
                _track_timestamp(session_header.get("creationDate"))
                # Process any requests already present in the snapshot
                for req in snapshot.get("requests", []):
                    if isinstance(req, dict):
                        _process_request(req)
                continue

            if kind == 1:
                patch_path = k if isinstance(k, list) else obj.get("k", [])
                if isinstance(patch_path, list) and patch_path:
                    patch_key = patch_path[-1]
                    if patch_key in ("customTitle", "sessionTitle", "generatedTitle", "title"):
                        if isinstance(v, str) and v.strip():
                            _update_title(patch_key, v)
                continue

            if kind == 2 and isinstance(v, list):
                patch_key = k if isinstance(k, list) else obj.get("k", [])

                # Live streaming patches: k=['requests', N, 'response']
                if (
                    isinstance(patch_key, list)
                    and len(patch_key) == 3
                    and patch_key[0] == "requests"
                    and isinstance(patch_key[1], int)
                    and patch_key[2] == "response"
                ):
                    if not _cons_has_text[0]:
                        # Accumuleer delta-patches; flush_pending_response
                        # gebruikt streaming boven consolidated om dubbeling te voorkomen
                        current_response_parts.extend(
                            _extract_text_from_response_list(v)
                        )
                    continue

                for item in v:
                    if not isinstance(item, dict):
                        continue

                    _track_timestamp(item.get("timestamp"))

                    generated_title = item.get("generatedTitle", "")
                    if isinstance(generated_title, str) and generated_title.strip():
                        latest_generated_title = " ".join(generated_title.split()).strip()

                    if "requestId" in item:
                        flush_pending_response()

                        msg_data = item.get("message", {})
                        if isinstance(msg_data, dict):
                            user_text = msg_data.get("text", "")
                        elif isinstance(msg_data, str):
                            user_text = msg_data
                        else:
                            user_text = ""
                        if user_text.strip():
                            messages.append({"role": "user", "text": user_text.strip()})

                        consolidated = _extract_text_from_response_list(
                            item.get("response", [])
                        )
                        if consolidated:
                            current_response_parts.clear()
                            current_consolidated.extend(consolidated)
                            # Echte tekst aanwezig? Dan blokkeren we streaming chunks
                            _cons_has_text[0] = any(
                                r.get("kind") in (None, "", "markdownContent")
                                or "supportThemeIcons" in r
                                for r in item.get("response", [])
                                if isinstance(r, dict)
                                and r.get("kind") not in _RESPONSE_SKIP_KINDS
                                and r.get("kind") not in ("toolInvocationSerialized", "inlineReference")
                                and isinstance(r.get("value", ""), str)
                                and r.get("value", "").strip()
                            )

                    elif "value" in item and isinstance(item["value"], str):
                        if item.get("kind") not in _RESPONSE_SKIP_KINDS:
                            if not _cons_has_text[0]:
                                current_response_parts.append(item["value"])

    flush_pending_response()

    if not session_header:
        session_header = {}

    if latest_generated_title and not session_header.get("generatedTitle"):
        session_header["generatedTitle"] = latest_generated_title

    if first_message_timestamp:
        session_header["_first_timestamp"] = first_message_timestamp

    session_header["_extracted_messages"] = messages
    return session_header


def extract_messages(session: dict) -> list[dict]:
    """
    Extraheer user/assistant berichten uit een chat-sessie.

    Returns: lijst van {"role": "user"|"assistant", "text": str}
    """
    return session.get("_extracted_messages", [])


def resolve_session_datetime(session: dict, filepath: str | None = None) -> datetime | None:
    """Bepaal een bruikbare sessiedatum, met fallback op bericht-timestamps en bestandstijd."""
    for key in ("creationDate", "lastUpdatedDate", "_first_timestamp"):
        value = session.get(key, 0)
        if isinstance(value, (int, float)) and value > 0:
            timestamp = value / 1000 if value > 10_000_000_000 else value
            try:
                return datetime.fromtimestamp(timestamp)
            except (ValueError, OSError, OverflowError):
                continue

    if filepath and os.path.exists(filepath):
        try:
            return datetime.fromtimestamp(os.path.getmtime(filepath))
        except (ValueError, OSError, OverflowError):
            return None

    return None


def build_session_title(session: dict, messages: list[dict], session_id: str) -> str:
    """Gebruik bij voorkeur de echte sessietitel uit VS Code, met fallback naar het eerste user-bericht."""
    for key in ("customTitle", "sessionTitle", "generatedTitle", "title"):
        value = session.get(key, "")
        if isinstance(value, str):
            cleaned = " ".join(value.split()).strip()
            if cleaned:
                if len(cleaned) > 80:
                    return cleaned[:80].rstrip() + "..."
                return cleaned

    first_user = next((m["text"] for m in messages if m["role"] == "user"), "")
    title = first_user[:80].replace("\n", " ").strip()
    if len(first_user) > 80:
        title += "..."
    if title:
        return title
    return session_id[:8]


def slugify_title(title: str, max_length: int = 60) -> str:
    """Normaliseer een titel naar een nette bestandsnaam-slug, inclusief accenten zoals é -> e."""
    if not isinstance(title, str):
        return ""

    normalized = unicodedata.normalize("NFKD", title)
    ascii_title = normalized.encode("ascii", "ignore").decode("ascii")
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_title.lower()).strip("-")
    slug = re.sub(r"-{2,}", "-", slug)

    if max_length > 0 and len(slug) > max_length:
        truncated = slug[:max_length].rstrip("-")
        word_boundary = truncated.rfind("-")
        if word_boundary >= max(8, max_length // 2):
            truncated = truncated[:word_boundary]
        slug = truncated.rstrip("-")

    return slug


def session_to_markdown(session: dict, session_id: str, source_path: str | None = None) -> str:
    """Converteer een chat-sessie naar leesbaar Markdown."""
    created_dt = resolve_session_datetime(session, source_path)
    if created_dt:
        date_str = created_dt.strftime("%Y-%m-%d %H:%M")
    else:
        date_str = "onbekend"

    messages = extract_messages(session)
    if not messages:
        return ""

    title = build_session_title(session, messages, session_id)

    lines = [
        f"# Chat: {title}",
        f"",
        f"- **Datum**: {date_str}",
        f"- **Sessie-ID**: `{session_id}`",
        f"- **Berichten**: {len(messages)}",
        f"",
        f"---",
        f"",
    ]

    for msg in messages:
        if msg["role"] == "user":
            lines.append(f"## 🧑 User\n")
        else:
            lines.append(f"## 🤖 Assistant\n")
        lines.append(msg["text"])
        lines.append("")
        lines.append("---")
        lines.append("")

    return "\n".join(lines)


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Exporteer VS Code Copilot chatsessies naar Markdown.")
    parser.add_argument(
        "--force", "-f",
        action="store_true",
        help="Exporteer alle sessies opnieuw, ook als ze al up-to-date lijken.",
    )
    args = parser.parse_args()
    force = args.force

    # Bepaal project root (één niveau boven scripts/)
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    project_name = os.path.basename(project_root)

    export_dir = os.path.join(project_root, "doc", "copilot-chats", "exports")
    os.makedirs(export_dir, exist_ok=True)

    # Zoek workspace storage dirs op basis van project_root (zelfconfigurerend)
    ws_dirs = find_workspace_storage_dirs(project_root)
    if not ws_dirs:
        print(f"Geen VS Code workspace storage gevonden voor {project_name}.")
        sys.exit(1)

    print(f"Gevonden workspace storage directories: {len(ws_dirs)}")
    if force:
        print("  (--force actief: alle sessies worden opnieuw geëxporteerd)")

    exported = 0
    skipped = 0

    for ws_dir in ws_dirs:
        chat_dir = os.path.join(ws_dir, "chatSessions")
        if not os.path.isdir(chat_dir):
            continue

        for jsonl_file in glob.glob(os.path.join(chat_dir, "*.jsonl")):
            session_id = os.path.basename(jsonl_file).replace(".jsonl", "")

            session = replay_jsonl_state(jsonl_file)
            if not session:
                print(f"  Overgeslagen (leeg): {session_id[:8]}")
                skipped += 1
                continue

            messages = extract_messages(session)
            if not messages:
                print(f"  Overgeslagen (geen berichten): {session_id[:8]}")
                skipped += 1
                continue

            created_dt = resolve_session_datetime(session, jsonl_file)
            if created_dt:
                date_prefix = created_dt.strftime("%Y-%m-%d")
            else:
                date_prefix = "onbekend"

            title_for_filename = build_session_title(session, messages, session_id)
            slug = slugify_title(title_for_filename, max_length=60)
            if not slug:
                slug = session_id[:8]

            filename = f"{date_prefix}-{slug}.md"
            filepath = os.path.join(export_dir, filename)

            existing_files = glob.glob(os.path.join(export_dir, "*.md"))
            existing_filepath = None
            existing_msg_count = 0
            for ef in existing_files:
                try:
                    with open(ef, "r", encoding="utf-8", errors="replace") as f:
                        content = f.read(600)
                    if session_id in content:
                        existing_filepath = ef
                        m = re.search(r"\*\*Berichten\*\*:\s*(\d+)", content)
                        if m:
                            existing_msg_count = int(m.group(1))
                        break
                except IOError:
                    continue

            current_msg_count = len(messages)
            needs_filename_update = bool(
                existing_filepath and os.path.basename(existing_filepath) != filename
            )

            jsonl_mtime = os.path.getmtime(jsonl_file)
            export_mtime = os.path.getmtime(existing_filepath) if existing_filepath else 0.0
            jsonl_is_newer = jsonl_mtime > export_mtime

            if (not force
                    and existing_filepath
                    and current_msg_count <= existing_msg_count
                    and not needs_filename_update
                    and not jsonl_is_newer):
                print(f"  Ongewijzigd ({current_msg_count} berichten): {session_id[:8]} -> {os.path.basename(existing_filepath)}")
                skipped += 1
                continue

            if existing_filepath:
                if needs_filename_update:
                    filepath = os.path.join(export_dir, filename)
                    counter = 1
                    base_filepath = filepath
                    while os.path.exists(filepath) and os.path.abspath(filepath) != os.path.abspath(existing_filepath):
                        name, ext = os.path.splitext(base_filepath)
                        filepath = f"{name}-{counter}{ext}"
                        counter += 1
                    if current_msg_count > existing_msg_count:
                        action = f"Hernoemd en bijgewerkt ({existing_msg_count}->{current_msg_count} berichten)"
                    else:
                        action = "Hernoemd"
                else:
                    filepath = existing_filepath
                    if current_msg_count > existing_msg_count:
                        action = f"Bijgewerkt ({existing_msg_count}->{current_msg_count} berichten)"
                    elif jsonl_is_newer or force:
                        action = f"Ververst ({current_msg_count} berichten, JSONL bijgewerkt)"
                    else:
                        action = f"Bijgewerkt ({existing_msg_count}->{current_msg_count} berichten)"
            else:
                counter = 1
                base_filepath = filepath
                while os.path.exists(filepath):
                    name, ext = os.path.splitext(base_filepath)
                    filepath = f"{name}-{counter}{ext}"
                    counter += 1
                action = "Geëxporteerd"

            md = session_to_markdown(session, session_id, jsonl_file)
            if md:
                with open(filepath, "w", encoding="utf-8", newline="\n") as f:
                    f.write(md)
                if existing_filepath and os.path.abspath(existing_filepath) != os.path.abspath(filepath):
                    try:
                        os.remove(existing_filepath)
                    except OSError:
                        pass
                print(f"  {action}: {session_id[:8]} -> {os.path.basename(filepath)}")
                exported += 1

    export_dir_display = os.path.relpath(export_dir, project_root)
    print(f"\nKlaar: {exported} geëxporteerd/bijgewerkt, {skipped} overgeslagen.")
    print(f"Map:   {export_dir}")


if __name__ == "__main__":
    main()
