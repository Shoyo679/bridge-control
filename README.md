# Bridge Control

A tiny Windows control panel for programs that normally need a terminal window open all the time
(order-checker bridges, MCP bridges, local servers, bots…).

Bridge Control runs them **hidden in the background** (no terminal, nothing on the taskbar) and gives you one
small window to manage them:

| | Program | Status | |
|---|---|---|---|
| 🟢 | OrderChecker | Online | `Start` `Stop` |
| ⚪ | OrderScrapeBridge | Offline | `Start` `Stop` |

- **Green dot** = running, **grey dot** = not running (checked every 2 seconds).
- **Start** runs the program hidden. **Stop** closes it.
- Optional: start chosen programs automatically when you log in to Windows.
- Closing the panel does **not** stop your programs. It's only a remote control.

No install, no admin rights, nothing to download besides this folder. It's plain PowerShell + VBScript that
come with Windows 10 and 11.

---

## Setup guide

### 1. Download

1. On this page, click the green **Code** button → **Download ZIP**.
2. Open your Downloads folder, right-click the ZIP → **Extract All…**
3. Move the extracted folder somewhere permanent, for example:

   ```
   C:\Tools\Bridge Control
   ```

   Don't leave it in Downloads (it tends to get cleaned up) and avoid moving it later. If you do move it,
   just run `Install.ps1` again.

> Tip: put the programs you want to control somewhere permanent too, e.g. `C:\Tools\OrderChecker\`.

### 2. Tell it which programs to control

1. In the folder, make a copy of **`apps.example.json`** and name the copy **`apps.json`**.
   (If you skip this, step 3 does it for you and opens it in Notepad.)
2. Open `apps.json` with Notepad (right-click → **Open with** → **Notepad**).
3. Put in your own programs. One block per program:

   ```json
   [
     {
       "name": "OrderChecker",
       "path": "C:\\Tools\\OrderChecker\\OrderChecker-MCP.exe",
       "startAtLogin": true
     },
     {
       "name": "OrderScrapeBridge",
       "path": "C:\\Tools\\OrderScrapeBridge\\OrderScrapeBridge.exe",
       "startAtLogin": false
     }
   ]
   ```

   | Field | What it means |
   |---|---|
   | `name` | Any label you like; shown in the panel. |
   | `path` | Full path to the `.exe`. **Write every `\` twice** (`C:\\Tools\\...`). |
   | `startAtLogin` | `true` = start it hidden every time you log in to Windows. `false` = only when you press Start. |
   | `args` *(optional)* | Command-line arguments, e.g. `"args": "--port 8080"`. |

   **Getting the path:** find the `.exe` in File Explorer, hold **Shift**, right-click it →
   **Copy as path**, and paste it after `"path": `. It comes with quotes already; keep them and just change
   each `\` into `\\`.

   **Adding a third program:** copy a whole `{ ... }` block, put a comma between blocks, no comma after the
   last one.

4. Save the file.

### 3. Install the shortcuts

1. In the folder, right-click **`Install.ps1`** → **Run with PowerShell**.
2. A blue window lists each program as **OK** (found) or **MISSING** (check that path), then:
   - creates a **Bridge Control** shortcut on your desktop,
   - adds a login entry if any program has `"startAtLogin": true`.
3. Press **Enter** to close the window.

If Windows says *"running scripts is disabled on this system"* or the window flashes and closes, open the
folder, click the address bar, type `powershell` and press Enter, then run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1
```

This only applies to that one run; it doesn't change any Windows setting.

### 4. Use it

- Double-click **Bridge Control** on your desktop → the panel opens.
- Press **Start** next to a program → its dot turns green within a second or two.
- Press **Stop** → the dot turns grey.
- Programs with `startAtLogin: true` start on their own after you log in. Open the panel any time to check them.

**Changed `apps.json`?** Close the panel and open it again. If you changed `startAtLogin`, also run
`Install.ps1` again.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| "apps.json was not found" | Copy `apps.example.json` to `apps.json` (step 2). |
| "apps.json could not be read" | Usually a missing comma between blocks, an extra comma after the last block, or a single `\` in a path. Paste the file into any online JSON checker to find the line. |
| Program shows **MISSING** / "file not found" | The `path` is wrong or the `.exe` was moved. Use Shift + right-click → Copy as path again. |
| I press Start but the dot stays grey | The program starts and then exits right away (missing login, config, licence…). Run the `.exe` normally once, in its own window, to see its error message. |
| The program needs me to type something on start | It can't run hidden; it needs a visible window. |
| The program opens its own normal window | Bridge Control hides console/terminal windows. Programs with a real app window might stay hidden too; use them normally instead. |
| Nothing happens when I double-click the shortcut | The panel may already be open behind other windows (only one can be open). Check the taskbar for "Bridge Control". |
| Windows shows a blue "Windows protected your PC" box for my program | That's about your program, not Bridge Control. Only run programs you trust. |
| Program won't stop | It may need administrator rights to stop. Use Task Manager → Details → End task. |

---

## Uninstall

1. Open the panel and **Stop** anything you want stopped.
2. Right-click **`Uninstall.ps1`** → **Run with PowerShell**. This removes the desktop shortcut and the login entry.
3. Delete the Bridge Control folder.

Your programs themselves are never touched or deleted.

---

## How it works (for the curious)

| File | Role |
|---|---|
| `BridgeControl.ps1` | The panel (Windows Forms). With `-Autostart` it just starts the `startAtLogin` programs and exits. |
| `BridgeControl.vbs` | Launches the PowerShell script with no console window flashing up. |
| `apps.example.json` | Example program list. Your own `apps.json` is never uploaded (it's in `.gitignore`). |
| `Install.ps1` | Creates the desktop shortcut and the Startup-folder entry `Bridge Control (autostart)`. |
| `Uninstall.ps1` | Removes those two shortcuts. |

- Programs are started with a hidden window (`Start-Process -WindowStyle Hidden`), in their own folder.
- "Online" means a process with that `.exe` name (and, where Windows allows reading it, that exact path) is running.
- The login entry is a normal shortcut in your Startup folder (`Win + R` → `shell:startup`). No services,
  scheduled tasks or registry changes.
- Everything runs as your own user. Nothing needs admin rights and nothing connects to the internet.

**Custom icon:** put an `icon.ico` in the folder and run `Install.ps1` again.

## License

MIT. Free to use, change and share. See [LICENSE](LICENSE).
