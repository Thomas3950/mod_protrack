-----------------------------------------------------------------------
--/  @file    protrack.diagnostics.lua
--/
--/  @brief  In-game observability for ProTrack, without ACSEDebug:
--/          - a log shown in the ProTrack panel (Diagnostics tab), which also
--/            captures every ForgeUtils logger line,
--/          - an error firewall: Lua errors are logged instead of crashing the game,
--/          - steps (breadcrumbs), with an optional step-by-step mode that waits
--/            before each step so the panel shows what was about to run,
--/          - an optional file log that survives crashes.
-----------------------------------------------------------------------
local global = _G
---@type Api
---@diagnostic disable-next-line: undefined-field
local api = global.api
local coroutine = global.coroutine
local table = global.table
local string = global.string
local tostring = global.tostring
local type = global.type
local ipairs = global.ipairs
local pcall = global.pcall
local xpcall = global.xpcall

--/ Main class definition
---@class Diagnostics
local Diag = {}
Diag.MAX_LINES = 200
Diag.STEP_DELAY_FRAMES = 30 -- about half a second between steps in step-by-step mode
Diag.LOG_FILE = "ProTrack.log"
Diag.PROBE_FILE = "ProTrack_probe.txt"
-- Where ACSEDebug.dll is looked for (without extension), relative to the game folder.
Diag.DLL_PATHS = {
    ".\\Win64\\ovldata\\ProTrackDiag\\ACSEDebug",
    ".\\ovldata\\ProTrackDiag\\ACSEDebug",
    ".\\Win64\\ovldata\\ACSEDebug\\ACSEDebug",
}

Diag.context = nil
Diag.lines = {}
Diag.lineCount = 0
Diag.frame = 0
Diag.dirty = true
Diag.lastError = nil
Diag.lastErrorRaw = nil
Diag.lastErrorRepeats = 0
Diag.stepMode = false
Diag.fileStatus = "off"
Diag.fileWriter = nil
Diag.fileLogRequested = false
Diag.runner = nil
Diag.runnerName = nil
Diag.currentAction = nil
Diag.waitFrames = 0
Diag.installed = false

---Adds a line to the log.
---@param level string? Shown in brackets, nil for lines that already carry one.
---@param message any
function Diag.Log(level, message)
    Diag.lineCount = Diag.lineCount + 1
    local line = "#" .. Diag.lineCount .. " f" .. Diag.frame .. " "
    if level ~= nil then
        line = line .. "[" .. level .. "] "
    end
    line = line .. tostring(message)

    local lines = Diag.lines
    lines[#lines + 1] = line
    if #lines > Diag.MAX_LINES then
        table.remove(lines, 1)
    end
    Diag.dirty = true

    if Diag.fileWriter ~= nil then
        local ok = pcall(Diag.fileWriter, line)
        if not ok then
            Diag.fileWriter = nil
            Diag.fileStatus = "failed"
        end
    end
end

---Clears the log and the last error.
function Diag.Clear()
    Diag.lines = {}
    Diag.lastError = nil
    Diag.lastErrorRaw = nil
    Diag.lastErrorRepeats = 0
    Diag.dirty = true
end

local function Traceback(err)
    local debugLib = global.debug
    if debugLib ~= nil and type(debugLib.traceback) == "function" then
        return debugLib.traceback(tostring(err), 2)
    end
    return tostring(err)
end

---Calls fn(...), catching any Lua error so it is logged instead of crashing the game.
---@param name string What is running, shown with the error.
---@param fn function
---@return boolean ok
---@return any result The first value returned by fn.
function Diag.Guard(name, fn, ...)
    local ok, result = xpcall(fn, Traceback, ...)
    if not ok then
        local raw = name .. ": " .. tostring(result)
        if raw == Diag.lastErrorRaw then
            -- Same error again (e.g. every frame): count it instead of filling the log.
            Diag.lastErrorRepeats = Diag.lastErrorRepeats + 1
            Diag.lastError = raw .. " (x" .. (Diag.lastErrorRepeats + 1) .. ")"
            Diag.dirty = true
        else
            Diag.lastErrorRaw = raw
            Diag.lastErrorRepeats = 0
            Diag.lastError = raw
            Diag.Log("ERROR", raw)
        end
    end
    return ok, result
end

---Marks a step of an action started with Diag.Run (ignored outside one, so
---automatic re-simulations while editing don't flood the log). In step-by-step
---mode, waits before the step runs, so the panel shows which step was about to
---run if the game then crashes.
---@param name string
function Diag.Step(name)
    if Diag.currentAction == nil then
        return
    end
    Diag.Log("STEP", name)
    if Diag.runner ~= nil and coroutine.running() == Diag.runner then
        Diag.waitFrames = Diag.STEP_DELAY_FRAMES
        coroutine.yield()
    end
end

---Runs an action. In step-by-step mode it runs over several frames from Advance.
---@param name string
---@param fn function
---@param forceStepped boolean? Always run step by step.
function Diag.Run(name, fn, forceStepped)
    if not (Diag.stepMode or forceStepped) then
        local previousAction = Diag.currentAction
        Diag.currentAction = name
        Diag.Log("STEP", "Start " .. name)
        Diag.Guard(name, fn)
        Diag.currentAction = previousAction
        return
    end
    if Diag.runner ~= nil then
        Diag.Log("WARN", "'" .. Diag.runnerName .. "' is still running, ignoring '" .. name .. "'")
        return
    end
    Diag.Log("STEP", "Start " .. name .. " (step by step)")
    Diag.currentAction = name
    Diag.runnerName = name
    Diag.runner = coroutine.create(function()
        Diag.Guard(name, fn)
    end)
end

---Turns step-by-step mode on or off (safe to call from the UI).
---@param stepMode boolean
function Diag.SetStepMode(stepMode)
    Diag.stepMode = stepMode and true or false
    Diag.dirty = true
    Diag.Log("INFO", "Step-by-step mode " .. (Diag.stepMode and "on" or "off"))
end

---Returns whether a step-by-step action is running.
---@return boolean
function Diag.IsRunning()
    return Diag.runner ~= nil
end

-- File log -------------------------------------------------------------------

---Tries the game's own file functions, checking that they really write.
---@return boolean
local function TryEngineFileLog()
    local debugApi = api.debug
    if type(debugApi) ~= "table" or type(debugApi.WriteStringToFile) ~= "function"
        or type(debugApi.ReadStringFromFile) ~= "function" then
        Diag.Log("INFO", "File log: the game's file functions are not available")
        return false
    end

    local first = "ProTrack probe A " .. Diag.frame
    local second = "ProTrack probe B " .. Diag.frame
    local ok, readBack = pcall(function()
        debugApi.WriteStringToFile(Diag.PROBE_FILE, first .. "\n", false)
        debugApi.WriteStringToFile(Diag.PROBE_FILE, second .. "\n", true)
        return debugApi.ReadStringFromFile(Diag.PROBE_FILE)
    end)
    if not ok or type(readBack) ~= "string" or string.find(readBack, second, 1, true) == nil then
        Diag.Log("INFO", "File log: the game's file functions don't write (" .. tostring(readBack) .. ")")
        return false
    end

    if string.find(readBack, first, 1, true) ~= nil then
        Diag.fileWriter = function(line)
            debugApi.WriteStringToFile(Diag.LOG_FILE, line .. "\n", true)
        end
    else
        -- No append support: rewrite the whole log each time.
        Diag.fileWriter = function()
            debugApi.WriteStringToFile(Diag.LOG_FILE, table.concat(Diag.lines, "\n") .. "\n", false)
        end
    end
    Diag.fileStatus = "on (game functions)"
    return true
end

---Tries ACSEDebug.dll on its own (without the ACSEDebug mod) through package.loadlib.
---@return boolean
local function TryDllFileLog()
    local package = global.package
    if type(package) ~= "table" or type(package.loadlib) ~= "function" then
        Diag.Log("INFO", "File log: package.loadlib is not available in this game")
        return false
    end

    for _, path in ipairs(Diag.DLL_PATHS) do
        local createLog, err = package.loadlib(path, "fnCreateLog")
        local writeLog = package.loadlib(path, "fnWriteLog")
        if type(createLog) == "function" and type(writeLog) == "function" then
            -- If the game crashes right after this step, the DLL doesn't work with this game.
            Diag.Step("File log: calling " .. path .. ".dll (experimental)")
            createLog(Diag.LOG_FILE)
            Diag.fileWriter = function(line)
                writeLog(line .. "\n")
            end
            Diag.fileStatus = "on (ACSEDebug.dll)"
            return true
        end
        Diag.Log("INFO", "File log: no DLL at " .. path .. ".dll (" .. tostring(err) .. ")")
    end
    return false
end

---Starts the file log, trying the game's functions first, then ACSEDebug.dll.
function Diag.StartFileLog()
    if Diag.fileWriter ~= nil then
        Diag.Log("INFO", "File log is already on: " .. Diag.fileStatus)
        return
    end

    if not TryEngineFileLog() and not TryDllFileLog() then
        Diag.fileStatus = "unavailable"
        Diag.Log("WARN", "No file log available. Use step-by-step mode to find crashes.")
        return
    end

    -- Write what was logged so far, then confirm.
    local history = Diag.lines
    for i = 1, #history do
        pcall(Diag.fileWriter, history[i])
    end
    Diag.Log("INFO", "File log " .. Diag.fileStatus .. ": " .. Diag.LOG_FILE .. " in the game folder")
end

---Asks for the file log to start on the next frame (safe to call from the UI).
function Diag.RequestFileLog()
    Diag.fileLogRequested = true
end

-- Setup ---------------------------------------------------------------------

---Logs what the game's Lua environment offers.
function Diag.LogCapabilities()
    local function has(value)
        return value ~= nil and "yes" or "no"
    end
    local package = global.package
    local debugLib = global.debug
    local debugApi = api.debug or {}
    Diag.Log("INFO", "Capabilities: " .. tostring(global._VERSION)
        .. ", package.loadlib=" .. has(package and package.loadlib)
        .. ", io=" .. has(global.io)
        .. ", os=" .. has(global.os)
        .. ", debug.traceback=" .. has(debugLib and debugLib.traceback)
        .. ", api.debug.Trace=" .. has(debugApi.Trace)
        .. ", api.debug.WriteStringToFile=" .. has(debugApi.WriteStringToFile)
        .. ", api.debug.ReadStringFromFile=" .. has(debugApi.ReadStringFromFile))
end

---Captures every line sent to api.debug.Trace (all ForgeUtils loggers use it).
local function CaptureTrace()
    local debugApi = api.debug
    if type(debugApi) ~= "table" or type(debugApi.Trace) ~= "function" then
        Diag.Log("WARN", "Can't capture the game log: api.debug.Trace is not available")
        return
    end

    local originalTrace = debugApi.Trace
    local ok = pcall(function()
        debugApi.Trace = function(text, ...)
            Diag.Log(nil, text)
            return originalTrace(text, ...)
        end
    end)
    if not ok then
        Diag.Log("WARN", "Can't capture the game log: api.debug is read-only")
    end
end

---Sets up the log. Safe to call early, before the UI exists.
function Diag.Install()
    if Diag.installed then
        return
    end
    Diag.installed = true
    CaptureTrace()
    Diag.LogCapabilities()
end

---Gives the log the ProTrack datastore context, so it can show in the panel.
---@param context any
function Diag.SetContext(context)
    Diag.context = context
    Diag.dirty = true
end

---Sends the log to the panel if it changed.
function Diag.Flush()
    if not Diag.dirty or Diag.context == nil then
        return
    end
    Diag.dirty = false

    -- Newest first, so the latest lines are visible without scrolling.
    local newestFirst = {}
    for i = #Diag.lines, 1, -1 do
        newestFirst[#newestFirst + 1] = Diag.lines[i]
    end
    api.ui2.SetDataStoreElement(Diag.context, "diagLog", table.concat(newestFirst, "\n"))
    api.ui2.SetDataStoreElement(Diag.context, "diagLastError", Diag.lastError or "")
    api.ui2.SetDataStoreElement(Diag.context, "diagStepMode", Diag.stepMode)
    api.ui2.SetDataStoreElement(Diag.context, "diagFileLog", Diag.fileStatus)
end

---Ticks the log: starts a requested file log, runs step-by-step actions, updates the panel.
function Diag.Advance()
    Diag.frame = Diag.frame + 1

    if Diag.fileLogRequested then
        Diag.fileLogRequested = false
        Diag.Run("Start file log", Diag.StartFileLog, true)
    end

    if Diag.runner ~= nil then
        if Diag.waitFrames > 0 then
            Diag.waitFrames = Diag.waitFrames - 1
        else
            local ok, err = coroutine.resume(Diag.runner)
            if not ok then
                Diag.Log("ERROR", Diag.runnerName .. ": " .. tostring(err))
            end
            if coroutine.status(Diag.runner) == "dead" then
                Diag.Log("STEP", "Done " .. Diag.runnerName)
                Diag.runner = nil
                Diag.runnerName = nil
                Diag.currentAction = nil
            end
        end
    end

    Diag.Flush()
end

return Diag
