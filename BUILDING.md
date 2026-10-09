# Building and installing ProTrack on Windows 10

This guide takes you from a Windows 10 PC with only Planet Coaster 2 and your current mods installed to a freshly built ProTrack copied into the game's `ovldata` folder.
You install everything once (Part 1). After that, each rebuild takes one command (Part 4).

---

## What the build does

ProTrack's source is plain files: Lua scripts, text files, and an HTML/JS user interface.
The game only loads them when they are packed into **OVL archives**.
The build script that ships with ProTrack (`Build\build.py`) does this in three steps:

1. **Packs the UI.** Everything in `Main\ProTrackUI\` becomes one file, `Main\ProTrackUI.ppuipkg`.
2. **Creates the OVLs.** It runs **cobra-tools** on the `Main` folder to produce `Main.ovl`, then on the `Init` folder to produce `Init.ovl`.
   Lua scripts must be stored under **dotted names** (`protrack/modes/fvdmode.lua` → `protrack.modes.fvdmode.lua`), because that's how the game finds them. cobra-tools only does this when its **Lua flattening** setting is on (Step 3b).
3. You then copy `Manifest.xml`, `Main.ovl` and `Init.ovl` into `...\Win64\ovldata\Mod_ProTrack\`.

```
Mod_ProTrack\ (source)           build.py + cobra-tools              ovldata\Mod_ProTrack\ (installed)
  Manifest.xml  ─────────────────────────────────────────────────▶  Manifest.xml
  Main\  (lua, txt, ProTrackUI\)  ──▶ ProTrackUI.ppuipkg ──▶ Main.ovl ──▶ Main.ovl
  Init\  (pscollection)           ─────────────────────────▶ Init.ovl ──▶ Init.ovl
```

## What you need

| Tool | Why | Where |
|---|---|---|
| **Python 3.11** (cobra-tools is made for 3.11 only) | Runs the build script and cobra-tools | python.org |
| **4 Python packages**: numpy, imageio, pillow, bitarray | Required by cobra-tools | Installed with `pip` (Step 2) |
| **cobra-tools** | Creates the OVL files | GitHub ZIP, or the copy you already have on your Mac |
| **The ProTrack source** | What you build | The `mod_protrack-main` folder from your Mac |

You **don't** need Git, Lua, Visual Studio, Blender or admin rights for any of this.
cobra-tools ships its own `luacheck.exe`, which it uses to check Lua syntax.

The guide uses `C:\Modding` as the working folder. Use another folder if you prefer, but **avoid OneDrive-synced folders** such as `Documents` or `Desktop`, because syncing can lock files during a build.

Final layout of the working folder:

```
C:\Modding\
├─ cobra-tools\          ← contains ovl_tool_cmd.py
└─ Mod_ProTrack\         ← the ProTrack source (renamed!)
   ├─ Manifest.xml
   ├─ .ovlpaths
   ├─ Build\  (build.py, ui_package.py, package.py)
   ├─ Main\
   └─ Init\
```

---

## Part 1 — One-time setup

### Step 1 — Install Python 3.11

1. Go to <https://www.python.org/downloads/release/python-3119/>.
   Python **3.11.9** is the last 3.11 release with a Windows installer.
2. Scroll to **Files** and download **Windows installer (64-bit)**.
3. Run the installer. On the first screen:
   - ✅ Tick **"Add python.exe to PATH"** at the bottom. *This matters: the build script calls `python` by name.*
   - Click **Install Now**.
4. When it finishes, click **"Disable path length limit"** if it is offered (harmless, and avoids long-path errors), then **Close**.

**Check it:** open a **new** Command Prompt (Start menu → type `cmd` → Enter) and run:

```bat
python --version
python -m pip --version
```

You should see `Python 3.11.9`, followed by a `pip ... (python 3.11)` line.

> **`python` opens the Microsoft Store, or says "not recognized"?**
> Windows ships placeholder `python` shortcuts that point at the Store. Turn them off:
> **Settings → Apps → Apps & features → App execution aliases**, then switch **off** both *App Installer python.exe* and *python3.exe*.
> Then close and reopen Command Prompt. If it still fails, re-run the Python installer, choose **Modify**, and make sure "Add Python to environment variables" is ticked.

### Step 2 — Install the Python packages cobra-tools needs

In Command Prompt:

```bat
python -m pip install --upgrade pip
python -m pip install "numpy>=1.26.4,<2.0.0" "imageio>=2.26.0" "pillow>=10.0.1" "bitarray~=2.9.2"
```

Keep the quotes: without them, Command Prompt treats `<` and `>` as file redirections.

These are the exact requirements from cobra-tools' `pyproject.toml`. numpy must stay **below 2.0**.

### Step 3 — Get cobra-tools

**Option A — reuse the copy from your Mac (recommended).**
Copy the `cobra-tools-master` folder to `C:\Modding\` and rename it to `cobra-tools`. That copy is version 2026.09.28, which already has the command-line tool ProTrack's build needs.

**Option B — download it fresh.**
1. Go to <https://github.com/OpenNaja/cobra-tools>, then click **Code → Download ZIP**.
2. **Before extracting**, right-click the ZIP → **Properties**, tick **Unblock** at the bottom, then click **OK**.
   This stops Windows from blocking the `.exe` helpers inside, such as `luacheck.exe`.
3. Extract it to `C:\Modding\`. The ZIP contains a `cobra-tools-master` folder; rename it to `cobra-tools`.

**Check it:** the file `C:\Modding\cobra-tools\ovl_tool_cmd.py` must exist. Watch out for a doubled folder such as `cobra-tools\cobra-tools-master\ovl_tool_cmd.py`. Then run:

```bat
python C:\Modding\cobra-tools\ovl_tool_cmd.py --help
```

You should see a usage text listing `new`, `extract` and `inject`.
If you get `ModuleNotFoundError: No module named '...'`, go back to Step 2.

### Step 3b — Turn on Lua flattening (required)

ProTrack's scripts live in subfolders (`managers\mod_protrack.lua`, `protrack\modes\fvdmode.lua`, …).
The game looks scripts up by dotted name (`require("managers.mod_protrack")`), so inside the OVL they must be stored as `managers.mod_protrack.lua`, `protrack.modes.fvdmode.lua`, and so on.
cobra-tools only renames them when its **Flatten LUA subfolders** setting is on, and it is **off by default**.

> **If you skip this step**, the build succeeds but the game can't find any ProTrack script. The game runs normally, but ProTrack doesn't load at all: no panel, no tools.

The setting is read from a `config.json` file in the cobra-tools folder. Create it in Command Prompt:

```bat
echo {"lua_flatten": true}> C:\Modding\cobra-tools\config.json
type C:\Modding\cobra-tools\config.json
```

The second line should print `{"lua_flatten": true}`.

- This replaces any existing `config.json`; cobra-tools rebuilds its other settings from defaults.
- If you prefer to edit an existing `config.json` (created by the cobra-tools GUI), open it in Notepad, set `"lua_flatten": true`, and save.
- **Don't create the file with PowerShell's `Set-Content` / `Out-File`.** Windows PowerShell 5.1 adds an invisible marker (BOM) at the start of the file. cobra-tools then treats the file as broken and silently falls back to defaults, which turns flattening off again.
- If you use the cobra-tools GUI, keep **Flatten LUA subfolders** ticked in its settings, since it saves back to this same file.

### Step 4 — Put the ProTrack source in place

1. Copy the `mod_protrack-main` folder from your Mac to `C:\Modding\`.
2. **Rename it to exactly `Mod_ProTrack`.**

   > **Why the name matters:** the UI packer writes the path `<source folder name>/Main` into `ProTrackUI.ppuipkg`. The installed mod folder is `ovldata\Mod_ProTrack`, the name taken from `Manifest.xml`. If you build from `mod_protrack-main`, the panel's UI path won't match the installed folder, and the ProTrack panel may not load.

3. **Remove macOS leftovers.** Copying from a Mac, especially through a USB stick, can add hidden `._something` and `.DS_Store` files. cobra-tools would try to pack a `._profilemode.lua` as if it were a real script. In Command Prompt:

   ```bat
   del /s /q /a "C:\Modding\Mod_ProTrack\._*"
   del /s /q /a "C:\Modding\Mod_ProTrack\.DS_Store"
   ```

   "Could Not Find" means there was nothing to delete, which is fine.

**Check it:** `C:\Modding\Mod_ProTrack\Manifest.xml` and `C:\Modding\Mod_ProTrack\.ovlpaths` both exist.

---

## Part 2 — Build

### Step 5 — Run the build

In Command Prompt:

```bat
cd /d C:\Modding\Mod_ProTrack
python Build\build.py C:\Modding\cobra-tools Manifest.xml
```

If a path contains spaces, wrap it in quotes, and **don't end a quoted path with a backslash**: write `"C:\My Tools\cobra-tools"`, not `"C:\My Tools\cobra-tools\"`.

Expected output, which takes a few seconds:

```
Processing .ovlpaths from: C:\Modding\Mod_ProTrack\.ovlpaths
Manifest directory: C:\Modding\Mod_ProTrack
Cobra tools path: C:\Modding\cobra-tools
------------------------------------------------------------

[1] Processing: ./Main
  Input:  C:\Modding\Mod_ProTrack\Main
  Output: C:\Modding\Mod_ProTrack\Main.ovl
  Found .uipackages file
  Building UI packages...
     Building UI package: ./ProTrackUI
  Finished building UI packages...
  Packaging OVL...
  Finished.

[2] Processing: ./Init
  Input:  C:\Modding\Mod_ProTrack\Init
  Output: C:\Modding\Mod_ProTrack\Init.ovl
  Packaging OVL...
  Finished.

============================================================
Processing complete: 2 succeeded, 0 failed
```

You should now have these new files:

- `C:\Modding\Mod_ProTrack\Main.ovl`
- `C:\Modding\Mod_ProTrack\Init.ovl`
- `C:\Modding\Mod_ProTrack\Main\ProTrackUI.ppuipkg`: an intermediate file, already inside `Main.ovl`

### Step 6 — Check that every file made it in (recommended)

`build.py` only prints cobra-tools' output when the whole command **fails**.
But if a single file can't be packed, for example because a Lua script has a syntax error, cobra-tools **leaves that file out and still reports success**.
The mod then breaks in-game with no clue why.

To see the full output, run the `Main` packing step by hand. It rebuilds `Main.ovl` exactly as `build.py` does, reusing the UI package from Step 5:

```bat
cd /d C:\Modding\Mod_ProTrack
python C:\Modding\cobra-tools\ovl_tool_cmd.py new -i Main -g "Planet Coaster 2" -o Main.ovl --force
```

Scroll through the output:

- ✅ Lines containing `Creating protrack.modes.profilemode.lua in ...` (**dots**) are normal. There is one per packed file, including all the `Loc_ProTrack_*.txt` files and `ProTrackUI.ppuipkg`.
- ❌ If script names show **slashes** instead, such as `Creating protrack/modes/profilemode.lua` or `Creating managers/mod_protrack.lua`, Lua flattening is off. The mod won't load: go back to Step 3b, then rebuild.
- ❌ Any line containing `Could not create: <file>` (logged as an error) means that file is **not** in the OVL. The message below it says why, usually `SyntaxError: <file>: line N, column M: ...` for a Lua script. Fix it, then build again from Step 5.
- `WARNING` lines from luacheck (unused variables, globals, …) are harmless; the original ProTrack files produce them too.

Optional deeper check: open `Main.ovl` in the cobra-tools GUI and browse the file list (see *Extras*).

### Step 7 (optional) — Make a shareable ZIP

```bat
cd /d C:\Modding\Mod_ProTrack
python Build\package.py . Mod_ProTrack.zip
```

This creates `Mod_ProTrack.zip`, containing a `Mod_ProTrack\` folder with `Manifest.xml`, the `.ovl` files (plus any `.ovs` files) and any readme or license.
You can extract it straight into `ovldata`. Step 8 does the same thing by hand.

---

## Part 3 — Install

### Step 8 — Copy into the game's `ovldata` folder

1. **Close Planet Coaster 2.** Files can't be replaced while the game runs.
2. **Find `ovldata`.** In Steam, right-click **Planet Coaster 2 → Manage → Browse local files**, then open `Win64\ovldata`.
   The default location is:

   ```
   C:\Program Files (x86)\Steam\steamapps\common\Planet Coaster 2\Win64\ovldata
   ```

   Your ACSE and ForgeUtils folders, and your current ProTrack, are in here.
3. **Back up the ProTrack you have now.** Move the existing `Mod_ProTrack` folder **out of `ovldata`**, for example to `C:\Modding\Backup\Mod_ProTrack`.

   > Don't just rename it inside `ovldata`. The game would still load the renamed copy as a second ProTrack, with the same content ID as your build, and the two would conflict.

4. Create a new, empty `ovldata\Mod_ProTrack` folder. The name must be exactly this, matching `<Name>` in `Manifest.xml` and the build folder name.
5. Copy these three files from `C:\Modding\Mod_ProTrack\` into it:
   - `Manifest.xml`
   - `Main.ovl`
   - `Init.ovl`
   - (also any `.ovs` file, if the build created one)

   Do **not** copy the `Main`, `Init` or `Build` source folders, or the `.ppuipkg` file.

If Windows says *Access denied* when writing into `Program Files (x86)`, confirm the admin prompt, or copy from an Explorer window started as administrator.

Result:

```
...\Win64\ovldata\
├─ (ACSE, ForgeUtils and your other mods — unchanged)
└─ Mod_ProTrack\
   ├─ Manifest.xml
   ├─ Main.ovl
   └─ Init.ovl
```

**Keep ACSE and ForgeUtils installed.** ProTrack needs both: it checks for ACSE ≥ 0.7, and it registers itself with ForgeUtils.

### Step 9 — Check in game

1. Start Planet Coaster 2. If ForgeUtils shows a version warning at the main menu, update ForgeUtils.
2. Load a park, then build or edit a coaster's track. The ProTrack panel should appear as usual.
3. In the panel: **Track Tools** tab → the mode selector now has a 4th entry, **Profile**.
4. Select **Profile**: the section controls appear. To use it, anchor the train as you would for ForceLock: a train on the track, TrackViz data reaching the track end.

What you might see, and what it means:

| What you see | Meaning |
|---|---|
| "Profile" is missing; only Normal / ForceLock / Gizmo | The game is still loading the old ProTrack. Check that the backup was moved **out of** `ovldata` and that `Main.ovl` was replaced. |
| Labels show raw keys such as `[Loc_ProTrack_TM_Profile]` | The localisation `.txt` files weren't packed. Run Step 6 and look for errors. |
| No ProTrack panel at all | Most likely Lua flattening was off, so the game can't find ProTrack's scripts. Check Step 6 for script names with slashes, fix with Step 3b, then rebuild and reinstall. Otherwise it's a folder-name mismatch: the source wasn't named `Mod_ProTrack` when built, or the `ovldata` folder isn't named `Mod_ProTrack`. |
| Panel appears but Profile does nothing / editor misbehaves | A Lua file was probably left out of the OVL. Run Step 6. |
| Game crashes or won't start | Restore the backup: delete `ovldata\Mod_ProTrack` and move your backup folder back. Then run Step 6 to find the problem. |

To go back to the original ProTrack at any time, replace `ovldata\Mod_ProTrack` with your backup.

---

## Part 4 — Rebuilding after changes

After editing the source in `C:\Modding\Mod_ProTrack`:

1. If you copied the changes from your Mac again, repeat the macOS clean-up from Step 4.3.
2. Rebuild (Step 5), optionally check (Step 6), close the game, then copy `Main.ovl` and `Init.ovl` again (Step 8.5).

### One-click rebuild and install (optional)

Save the following as `C:\Modding\build_and_install.bat`. Adjust the three paths at the top if yours differ, then double-click it whenever you want to rebuild.

```bat
@echo off
setlocal
rem ---- adjust these three paths if needed ----
set "COBRATOOLS=C:\Modding\cobra-tools"
set "MOD=C:\Modding\Mod_ProTrack"
set "OVLDATA=C:\Program Files (x86)\Steam\steamapps\common\Planet Coaster 2\Win64\ovldata"

rem Remove macOS leftovers (silently)
del /s /q /a "%MOD%\._*" >nul 2>&1
del /s /q /a "%MOD%\.DS_Store" >nul 2>&1

rem Build the UI package and both OVLs
python "%MOD%\Build\build.py" "%COBRATOOLS%" "%MOD%\Manifest.xml"
if errorlevel 1 (
    echo.
    echo BUILD FAILED - nothing was copied.
    pause
    exit /b 1
)

rem Install into ovldata
if not exist "%OVLDATA%\Mod_ProTrack" mkdir "%OVLDATA%\Mod_ProTrack"
copy /Y "%MOD%\Manifest.xml" "%OVLDATA%\Mod_ProTrack\" >nul
copy /Y "%MOD%\*.ovl" "%OVLDATA%\Mod_ProTrack\" >nul
if exist "%MOD%\*.ovs" copy /Y "%MOD%\*.ovs" "%OVLDATA%\Mod_ProTrack\" >nul

echo.
echo Installed to "%OVLDATA%\Mod_ProTrack"
pause
```

The script assumes your original ProTrack is already backed up (Step 8.3), and it overwrites `ovldata\Mod_ProTrack`. Close the game before running it.
It doesn't run the Step 6 check, so run that by hand whenever you've edited Lua files.

---

## Extras (optional)

### Visual Studio Code

ProTrack includes VS Code launch configurations (`.vscode\launch.json`): **Run Build** and **Package Build**.

1. Install VS Code from <https://code.visualstudio.com/>, then install the **Python** extension (by Microsoft) from the Extensions panel.
2. Tell the configurations where cobra-tools is. In Command Prompt:

   ```bat
   setx COBRATOOLS C:\Modding\cobra-tools
   ```

   Then **restart VS Code** so it picks up the new variable.
3. Open the folder `C:\Modding\Mod_ProTrack` in VS Code. Press **Ctrl+Shift+P**, choose **Python: Select Interpreter**, and pick **Python 3.11.9**.
4. In **Run and Debug** (Ctrl+Shift+D), choose **Run Build** and press **F5**. This runs the same command as Step 5.

### cobra-tools GUI (for looking inside OVLs)

The graphical tool needs extra packages. The first time you start it, it offers to install them; answer yes:

```bat
python C:\Modding\cobra-tools\ovl_tool_gui.py
```

Use it to open your `Main.ovl` and check the file list, or to open the game's own OVLs to read vanilla scripts.
Decompiling the game's Lua uses cobra-tools' bundled `luadec.exe`, which runs on Windows.

---

### Diagnostics tab (when something crashes)

The ProTrack panel has a **Diagnostics** tab (4th tab). Nothing to install for the basics:

- **Errors don't crash the game any more.** Every ProTrack entry point (buttons, sliders, keybinds, editor hooks, the per-frame update) is protected. A Lua error is caught, the game's own code still runs, and the error shows at the top of the tab with the file and line.
- **Log:** the last 200 lines, newest first. It includes every line ProTrack (and other ForgeUtils mods) logs, plus `[STEP]` lines marking each stage of **Anchor** and **Resimulate**. The first line lists what the game's Lua allows (`Capabilities: …`).
- **Step-by-step mode:** when ticked, Anchor and Resimulate pause about half a second before each step, with the step shown in the log. If the game crashes, **the last `[STEP]` line visible in the log is the step that crashed it**; take a screenshot just before clicking.
- **Try file log:** writes the log to `ProTrack.log`, flushed line by line, so it survives a crash. It tries the game's own file functions first, then ACSEDebug's DLL on its own (below). The status next to the button says which one worked, or `unavailable`.

**Optional, experimental: file log through ACSEDebug's DLL, without the ACSEDebug mod**

1. Make a folder `...\Win64\ovldata\ProTrackDiag\` with **no** `Manifest.xml` and no `.ovl`, so the game doesn't load it as a mod.
2. Copy **only** `ACSEDebug.dll` into it, from the ACSE release for Planet Coaster 1: `ACSE-main\Release\Planet Coaster\ACSEDebug\ACSEDebug.dll`.
3. In game: Diagnostics tab → **Try file log**. The log shows `File log: calling …ACSEDebug.dll (experimental)` and waits half a second before the call.
   - If the game crashes right then, the DLL doesn't work with Planet Coaster 2. Delete the folder and use step-by-step mode instead.
   - If it works, `ProTrack.log` appears in the game folder; search the Planet Coaster 2 install folder for it.

## Troubleshooting reference

| Problem | Fix |
|---|---|
| Game runs fine but ProTrack doesn't load at all (no panel); the Step 6 output shows script names with slashes (`managers/mod_protrack.lua`) | Lua flattening is off. Follow Step 3b, rebuild, reinstall. |
| Step 3b's `config.json` seems ignored (names still have slashes) | The file has a BOM or a typo. Recreate it with the `echo` command in Step 3b. With the GUI, check **Flatten LUA subfolders** is ticked. |
| `'python' is not recognized` / opens the Microsoft Store | Step 1 note: turn off the App execution aliases, then reopen Command Prompt. |
| `python --version` shows something other than 3.11 | Another Python is earlier on PATH. Uninstall it, or reinstall 3.11.9 with "Add python.exe to PATH" ticked. `build.py` always calls plain `python`. |
| `ModuleNotFoundError: No module named 'numpy'` (or imageio, PIL, bitarray) | Re-run Step 2 **with the same `python`** that runs the build. |
| `Error: ovl_tool_cmd.py not found at ...` | The first argument to `build.py` must be the folder that directly contains `ovl_tool_cmd.py`. Check for a doubled `cobra-tools-master` folder. |
| `Error: Manifest file not found` | Run the command from `C:\Modding\Mod_ProTrack`, or pass the full path to `Manifest.xml`. |
| `Processing complete: 1 succeeded, 1 failed`, with `stderr:` text | cobra-tools crashed on that folder. The `stderr` text says why. A common cause is wrong package versions; re-run Step 2. |
| `BinaryNotAvailableError: luacheck` or a "blocked" warning | Windows blocked cobra-tools' bundled `.exe` files. Unblock: re-download the ZIP, tick **Unblock** in its Properties before extracting (Step 3), and extract again. |
| `Could not create: something.lua` in Step 6 | That script has a Lua syntax error at the reported line. Fix it and rebuild. |
| *Access denied* when copying into `ovldata` | Approve the admin prompt, or run Explorer / the `.bat` as administrator. |
| Everything worked before, but broke after a game update | Update cobra-tools (re-download, Step 3), plus ACSE/ForgeUtils if their authors released updates. Then rebuild. |
