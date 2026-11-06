# Bridge Control

**Run programs that normally need a black terminal window open all the time, without the window.**

Some tools (order-checker bridges, mail bridges, bots, local servers…) only work while their terminal window stays
open. Close the window and the program stops. Bridge Control runs them **hidden in the background** instead, and
gives you one small window to see and control them:

| | Program | Status | |
|---|---|---|---|
| 🟢 | OrderChecker | Online · up 5h 12m | `Stop` |
| 🟠 | OrderScrapeBridge | Restarting · back in 8s | `Stop` |
| ⚪ | Order Tracker | Offline · not running | `Start` |

- Each program gets a dark card with **its own logo**, a status dot and one button.
- 🟢 **Green** = running (and for how long). 🟠 **Orange** = being started again. ⚪ **Grey** = not running.
- **Start** starts the program (hidden). **Stop** closes it. **Start all** starts every program that isn't running.
- Bridge Control can start your programs by itself every time you turn on your PC.
- It can also **keep them running**: if one closes by itself, or updates itself and comes back in a black window,
  Bridge Control starts it again, hidden.
- It sits quietly next to the clock (in the hidden icons) until you need it.

**What you need:** a Windows 10 or Windows 11 PC and the program(s) you want to control. Nothing else to install,
no administrator rights, and it doesn't connect to the internet.

---

## Set it up (about 5 minutes)

### Step 1 – Download it

1. At the top of this page, click the green **`<> Code`** button, then **Download ZIP**.
2. Open your **Downloads** folder. Right-click **bridge-control-main.zip** → **Extract All…** → **Extract**.
3. A folder called **bridge-control-main** opens. Move it somewhere it can stay forever, for example
   **`C:\Tools`**, and rename it to **Bridge Control** if you like.

   > Don't leave it in Downloads: things in Downloads get deleted by accident. And try not to move it later.

**Tip:** do the same for the programs you want to control. Keep each in its own folder in a place like
`C:\Tools`, not in Downloads or on the Desktop.

### Step 2 – Run the installer once

1. Open the **Bridge Control** folder.
2. Right-click **Install** (it may show as `Install.ps1`) → **Run with PowerShell**.
3. The first time, it makes your program list and opens it in **Notepad** for you. Leave Notepad open for
   step 3. You can close the blue window.

> **The blue window flashes and disappears, or says "running scripts is disabled"?**
> In the Bridge Control folder, click the address bar at the top, type `powershell` and press **Enter**.
> In the blue window that opens, paste this line and press **Enter**:
>
> ```
> powershell -ExecutionPolicy Bypass -File .\Install.ps1
> ```
>
> This only lets that one script run once. It doesn't change any Windows settings.

### Step 3 – Tell it which programs to control

Notepad now shows a list like this. Each `{ … }` block is **one program**:

```json
[
  {
    "name": "OrderChecker",
    "path": "C:\\Tools\\OrderChecker\\OrderChecker-MCP.exe",
    "startAtLogin": true,
    "keepRunning": true
  },
  {
    "name": "OrderScrapeBridge",
    "path": "C:\\Tools\\OrderScrapeBridge\\OrderScrapeBridge.exe",
    "startAtLogin": false,
    "keepRunning": false
  }
]
```

Change each block to one of **your** programs:

| Line | What to put there |
|---|---|
| `"name"` | Any name you like. It's what the panel shows. |
| `"path"` | Where the program's `.exe` file is (see below). |
| `"startAtLogin"` | `true` = start it by itself every time you log in to Windows.<br>`false` = only when you press Start. |
| `"icon"` *(optional)* | A picture to show as the program's logo, e.g. `"icons\\mybridge.png"` (a path inside the Bridge Control folder, or a full path). Without it, the program's own icon is used. |
| `"keepRunning"` | `true` = if it closes by itself, start it again (hidden). Good for programs that update themselves. See [Keep running](#keep-running).<br>`false` = leave it closed. |

Watch the commas: every line inside a block ends with a comma, **except the last one** before the `}`.

**How to get the path, without typing it:**

1. Find your program's `.exe` file in File Explorer.
2. Right-click it → **Copy as path** (on Windows 10: hold **Shift** while right-clicking).
3. In Notepad, select the old path **including its quotes** and paste over it.
4. Now change every single `\` into two: `\\`.

   ✅ Right: `"C:\\Tools\\MyBridge\\MyBridge.exe"`  ❌ Wrong: `"C:\Tools\MyBridge\MyBridge.exe"`

   (This is just how this kind of file works: one `\` on its own means something else to it.)

**Only one program?** Delete the second block, including the comma before it, so it ends like this:

```json
[
  {
    "name": "MyBridge",
    "path": "C:\\Tools\\MyBridge\\MyBridge.exe",
    "startAtLogin": true,
    "keepRunning": true
  }
]
```

**More than two?** Copy a whole block, from `{` to `}`, and paste it after the last one. Every block needs a
comma after its `}`, **except the last one**.

When you're done, press **Ctrl + S** to save, and close Notepad.

### Step 4 – Run the installer again

Right-click **Install** → **Run with PowerShell** again. This time it:

- checks each program: **OK** means it was found. **MISSING** means the path is wrong (go back to step 3).
- puts a **Bridge Control** shortcut on your desktop.
- if any program has `"startAtLogin": true`, sets Bridge Control to start when you log in.

Press **Enter** to close the window. **You're done!** 🎉

---

## Using it every day

| I want to… | Do this |
|---|---|
| Open Bridge Control | Double-click **Bridge Control** on your desktop, or click its dot by the clock. |
| Start a program | Press **Start** next to it. Its dot turns green in a second or two. |
| Stop a program | Press **Stop** next to it. Its dot turns grey. |
| Close the window | Click **✕**. Bridge Control keeps running next to the clock. |
| Close Bridge Control completely | Right-click its dot by the clock → **Quit Bridge Control**. |
| Check if everything is running, without opening it | Hover over its dot by the clock. It says e.g. *"3 of 3 online"*. |

**Closing or quitting Bridge Control never stops your programs.** It's only a remote control. To stop a
program, press its **Stop** button.

### The dot next to the clock

Bridge Control lives in the **hidden icons**, the little **`^`** arrow next to the clock:

- 🟢 **green**: all your programs are running
- 🟠 **orange**: some are running
- ⚪ **grey**: none are running

**Want the dot always visible?** Click the `^` arrow, then drag the dot down onto the taskbar next to the clock.

### When you turn on your PC

Programs set to `"startAtLogin": true` start by themselves after you log in. Bridge Control waits next to the
clock, and no window pops up.

### Keep running

Some programs update themselves. After an update they often restart **in a normal black window**, and if you close
that window, the program stops. With `"keepRunning": true`, Bridge Control looks after the program while Bridge
Control is running:

- **It closed by itself** (an update, a crash, its window was closed): about 10 seconds later Bridge Control starts
  it again, hidden. Meanwhile its dot is 🟠 orange and says *Restarting · back in 8s*.
- **It came back in a black window** (a copy Bridge Control didn't start): Bridge Control gives it about 20 seconds to
  finish updating, then closes that window and starts the program again, hidden. Meanwhile it says *Switching to
  hidden*. The program is offline for a second or two while it swaps.
- **You pressed Stop**: it stays stopped. Bridge Control won't start it again until you press **Start**.
- If a program keeps closing, Bridge Control waits longer each time (up to 5 minutes), so it doesn't restart it
  over and over.

Every restart is written down in **bridge-control.log** in the Bridge Control folder, with the time and the reason.

> Don't use `keepRunning` for a program you sometimes start by hand in its own window on purpose. Bridge Control
> would swap it for a hidden one.

### Changing your programs later

1. Right-click the dot by the clock → **Quit Bridge Control**.
2. In the Bridge Control folder, right-click **apps** (or `apps.json`) → **Open with** → **Notepad**.
3. Make your changes (same rules as step 3), then save.
4. Run **Install** again (right-click → **Run with PowerShell**).
5. Double-click **Bridge Control** on your desktop. Your new list shows up.

---

## Something not working?

**"apps.json could not be read"**
There's a small mistake in your program list, usually one of these:
- a missing comma between two blocks (`},` is needed between blocks),
- an extra comma after the last block,
- a path with single `\` instead of `\\`,
- a missing quote `"`.

Tip: paste the whole list into a free website like **jsonlint.com** and it shows you the exact line.

**A program shows "MISSING" or "file not found"**
The path is wrong, or the program was moved. Copy its path again (step 3).

**I press Start but the dot goes back to grey**
The program starts and then closes by itself, usually because it needs a login, a setting or a licence first.
Run the program once the normal way (double-click its `.exe`) to read its error message, fix that, then try again.

**A black window for my program popped up by itself (often after the program updated)**
Don't close it if you want the program to keep working. Set `"keepRunning": true` for that program (see
[Changing your programs later](#changing-your-programs-later)) and Bridge Control will swap that window for a hidden
copy by itself from then on.

**The program needs me to type something when it starts**
Then it can't run hidden. It needs its own window. Use it the normal way instead.

**I closed the window. Where did it go?**
It's next to the clock: click the **`^`** arrow and click the dot. Or double-click the desktop shortcut again.

**I can't find the dot by the clock**
Bridge Control isn't running. Double-click the **Bridge Control** shortcut on your desktop.

**A program won't stop**
It may need administrator rights to be stopped. Open **Task Manager** (Ctrl + Shift + Esc) → **Details** →
find the program → **End task**.

**Windows shows a blue "Windows protected your PC" box**
That's Windows asking about your program, not about Bridge Control. Only run programs you trust.

---

## Remove it

1. Open Bridge Control and **Stop** any programs you want stopped.
2. Right-click its dot by the clock → **Quit Bridge Control**.
3. In the Bridge Control folder, right-click **Uninstall** → **Run with PowerShell**. This removes the desktop
   shortcut and stops it from starting with Windows.
4. Delete the Bridge Control folder.

Your programs are never changed or deleted.

---

<details>
<summary><b>How it works (for the curious)</b></summary>

| File | What it does |
|---|---|
| `BridgeControl.ps1` | The window and the dot by the clock. With `-Autostart` it starts the `startAtLogin` programs and waits by the clock. Only one copy runs; opening it again shows the running one. |
| `BridgeControl.vbs` | Opens the script above without a black window flashing up. |
| `apps.example.json` | The example program list. Your own `apps.json` stays on your PC (it is never uploaded). |
| `Install.ps1` | Makes `apps.json` the first time, creates the desktop shortcut and the login entry. |
| `Uninstall.ps1` | Removes the desktop shortcut and the login entry. |
| `icons\` | Optional: your own logo pictures for the `"icon"` line. Stays on your PC (it is never uploaded), so logos of other companies' programs don't end up online. |
| `state.json` | Made while it runs: which running copies Bridge Control started itself (process id + start time), so `keepRunning` can tell them apart from copies it didn't start. |
| `bridge-control.log` | Made while it runs: every automatic restart, with the time and the reason. |

- Programs are started hidden (`Start-Process -WindowStyle Hidden`), from their own folder.
- "Online" means a program with that `.exe` file is running (matched on the full path where Windows allows it).
- The login entry is a normal shortcut in your Startup folder (`Win + R` → `shell:startup`), called
  *Bridge Control (autostart)*. No services, scheduled tasks or registry changes.
- An optional `"args"` line passes command-line options to a program, e.g. `"args": "--port 8080"`.
- Put an `icon.ico` in the folder and run `Install.ps1` again to give the shortcuts your own icon.
- Everything runs as you. Nothing needs administrator rights and nothing connects to the internet.

</details>

## License

MIT: free to use, change and share. See [LICENSE](LICENSE).
