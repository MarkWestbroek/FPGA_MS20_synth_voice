# Copilot Chat Export — installatie

Exporteert VS Code Copilot chatsessies naar leesbare Markdown bestanden
(`doc/copilot-chats/exports/`). Werkt automatisch als git pre-commit hook.

## Bestanden (vanuit bronproject)

```
scripts/
  export-copilot-chats.py   ← hoofdscript (zelfconfigurerend, geen aanpassing nodig)
  run-chat-backup.ps1       ← PowerShell wrapper met -Force / -OpenExports
  install-chat-hook.ps1     ← installeert de git pre-commit hook
  pre-commit-chat-export    ← de hook zelf
```

## Kopiëren naar een nieuw project

```powershell
cd D:\Git\Muziek\MusicBrain
python scripts/update-chat-export.py D:\Git\<doelproject>
```

Kopieert de 4 bestanden, maakt `doc/copilot-chats/exports/` aan en
mergt de VS Code taken in `.vscode/tasks.json` van het doelproject.

## Daarna in het doelproject

```powershell
# Export testen
python scripts/export-copilot-chats.py

# Git hook installeren (optioneel — exporteert automatisch bij elke commit)
powershell scripts/install-chat-hook.ps1
```

## VS Code taken (globaal beschikbaar in elk project)

Via **Terminal → Run Task**:

| Taak | Actie |
|---|---|
| Export Copilot Chats | Exporteer nieuwe/gewijzigde sessies |
| Export Copilot Chats (force) | Exporteer alles opnieuw |
| Install Copilot Chat Hook | Installeer git pre-commit hook |

De taken staan in `%APPDATA%\Code\User\tasks.json` en werken
in elk project dat de scripts heeft.
