--- whisper-local.lua — Hammerspoon front end for the whisper-local CLI.
---
--- Install this file next to your init.lua, then in init.lua:
---
---     require("whisper-local").setup({ hotkey = { { "alt" }, "space" } })
---
--- Press the hotkey to start recording, press it again to stop: the text is
--- transcribed locally and pasted at the cursor. Audio is captured from the
--- system default input, so it follows whatever you pick in System Settings.
---
--- setup() options, all optional:
---   hotkey   { mods, key }  key binding to toggle dictation  (default ⌥Space)
---   bin      string         path to the whisper-local executable
---   menubar  boolean        show the menu bar indicator       (default true)
---   timeout  number         seconds before a wedged transcription is killed
---
--- The CLI's output contract, which this file depends on:
---   exit 0 + non-empty stdout : the transcript
---   exit 0 + empty stdout     : nothing usable heard; stderr says why
---   exit non-zero             : a real failure; stderr carries the message
--- Nothing here may collapse a failure into "nothing heard". Doing so is what
--- makes a broken dictation setup impossible to diagnose.

local M = {}

local cfg = {
    hotkey  = { { "alt" }, "space" },
    bin     = nil,
    menubar = true,
    timeout = 180,
}

-- hs.task objects are terminated when Lua garbage-collects them, so every
-- running task must be held somewhere that outlives the function starting it.
local startTask, stopTask, doctorTask = nil, nil, nil
local watchdog, busyAlert, menu, hotkey = nil, nil, nil, nil
local recording = false

-- ── Locating the CLI ────────────────────────────────────────────────────────
local function findBin()
    if cfg.bin then return cfg.bin end
    local home = os.getenv("HOME")
    local candidates = {
        home .. "/.local/bin/whisper-local",
        "/opt/homebrew/bin/whisper-local",
        "/usr/local/bin/whisper-local",
        home .. "/code/whisper-local/bin/whisper-local",
        home .. "/whisper-local/bin/whisper-local",
    }
    for _, p in ipairs(candidates) do
        local attr = hs.fs.attributes(p)
        if attr and attr.mode ~= "directory" then return p end
    end
    return nil
end

-- ── UI ──────────────────────────────────────────────────────────────────────
local function setState(state)
    if not menu then return end
    if state == "recording" then
        menu:setTitle("🔴")
        menu:setTooltip("whisper-local: recording — press the hotkey to stop")
    elseif state == "transcribing" then
        menu:setTitle("⏳")
        menu:setTooltip("whisper-local: transcribing…")
    else
        menu:setTitle("🎙️")
        menu:setTooltip("whisper-local: ready")
    end
end

-- Single place to tear down the persistent overlay and its watchdog, so no
-- code path can leave the infinite-duration alert stuck on screen.
local function clearBusy()
    if busyAlert then hs.alert.closeSpecific(busyAlert); busyAlert = nil end
    if watchdog then watchdog:stop(); watchdog = nil end
end

local function showError(msg)
    msg = (msg or ""):gsub("%s+$", "")
    if msg == "" then msg = "dictation failed (no detail available)" end
    print("[whisper-local] " .. msg)
    hs.alert.show("⚠️ " .. msg, 6)
end

local function paste(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return false end
    -- Paste through the clipboard, then put back what was there — but only if
    -- nothing else has touched it meanwhile, so a copy made during the paste
    -- is never clobbered.
    local prev = hs.pasteboard.getContents()
    hs.pasteboard.setContents(text)
    local ours = hs.pasteboard.changeCount()
    hs.eventtap.keyStroke({ "cmd" }, "v")
    hs.timer.doAfter(0.4, function()
        if prev ~= nil and hs.pasteboard.changeCount() == ours then
            hs.pasteboard.setContents(prev)
        end
    end)
    return true
end

-- ── Recording ───────────────────────────────────────────────────────────────
function M.start()
    local bin = findBin()
    if not bin then
        showError("whisper-local executable not found — pass setup({ bin = \"/path/to/whisper-local\" })")
        return
    end

    recording = true
    setState("recording")
    hs.alert.show("🔴 recording… press the hotkey to stop")

    -- `start` verifies the recorder actually came up, so a non-zero exit here
    -- means the microphone never opened. Reporting it now is the difference
    -- between a clear "device unavailable" and a recording that silently turns
    -- out empty a minute later.
    startTask = hs.task.new(bin, function(code, _stdout, stderr)
        startTask = nil
        if code ~= 0 then
            recording = false
            setState("idle")
            showError("could not start recording: " .. (stderr or ""))
        end
    end, { "start" })

    if not startTask then
        recording = false
        setState("idle")
        showError("cannot execute " .. bin)
        return
    end
    startTask:start()
end

function M.stop()
    local bin = findBin()
    if not bin then showError("whisper-local executable not found"); return end

    recording = false
    setState("transcribing")
    -- Hold the overlay for the whole transcription rather than letting it fade
    -- after ~2s, and dismiss it the moment the CLI returns.
    busyAlert = hs.alert.show("⏳ transcribing…", math.huge)

    stopTask = hs.task.new(bin, function(code, stdout, stderr)
        stopTask = nil
        clearBusy()
        setState("idle")

        if code ~= 0 then
            -- A genuine failure: never paste, and never call it silence.
            showError(stderr ~= "" and stderr or ("dictation failed (exit " .. tostring(code) .. ")"))
            return
        end

        if not paste(stdout) then
            -- Exit 0 with no transcript. The CLI explains itself on stderr
            -- (silent capture, too short, no speech); show that reason rather
            -- than a generic shrug.
            local why = (stderr or ""):gsub("%s+$", "")
            hs.alert.show("🫥 " .. (why ~= "" and why or "nothing heard"), 6)
        end
    end, { "stop" })

    if not stopTask then
        clearBusy()
        setState("idle")
        showError("cannot execute " .. bin)
        return
    end

    -- If whisper wedges, the infinite overlay would sit on screen with the
    -- menu stuck on ⏳ and no way back short of reloading the config.
    watchdog = hs.timer.doAfter(cfg.timeout, function()
        if stopTask then stopTask:terminate(); stopTask = nil end
        clearBusy()
        setState("idle")
        showError("transcription timed out after " .. cfg.timeout .. "s")
    end)

    stopTask:start()
end

function M.toggle()
    if recording then M.stop() else M.start() end
end

function M.isRecording() return recording end

-- Is a recorder running right now? A config reload loses `recording` while the
-- capture process keeps holding the microphone, which would leave the UI idle
-- and let the hotkey start a second recorder.
local function recorderAlive()
    local bin = findBin()
    if not bin then return false end
    local out = hs.execute(("%q status 2>/dev/null"):format(bin)) or ""
    return out:match("recording%s+YES") ~= nil
end

function M.doctor()
    local bin = findBin()
    if not bin then showError("whisper-local executable not found"); return end
    local alert = hs.alert.show("🎚️ testing microphone for 3s…", math.huge)
    doctorTask = hs.task.new(bin, function(code, stdout, _stderr)
        doctorTask = nil
        hs.alert.closeSpecific(alert)
        hs.alert.show((code == 0 and "✅ " or "⚠️ ") .. (stdout or ""), 12)
        print("[whisper-local] doctor:\n" .. (stdout or ""))
    end, { "doctor" })
    if doctorTask then doctorTask:start() else hs.alert.closeSpecific(alert) end
end

-- ── Setup ───────────────────────────────────────────────────────────────────
function M.setup(opts)
    for k, v in pairs(opts or {}) do cfg[k] = v end

    if cfg.menubar and not menu then
        menu = hs.menubar.new()
        if menu then
            menu:setMenu(function()
                return {
                    { title = recording and "Stop dictation" or "Start dictation",
                      fn = M.toggle },
                    { title = "-" },
                    { title = "Test microphone (3s)…", fn = M.doctor },
                }
            end)
        end
    end

    if cfg.hotkey then
        if hotkey then hotkey:delete() end
        hotkey = hs.hotkey.bind(cfg.hotkey[1], cfg.hotkey[2], M.toggle)
    end

    -- Pick the real state back up after a config reload.
    if recorderAlive() then
        recording = true
        setState("recording")
        print("[whisper-local] resumed: a recording was already in progress")
    else
        setState("idle")
    end

    return M
end

--- Convenience for `require("whisper-local").bind({"alt"}, "space")`.
function M.bind(mods, key)
    return M.setup({ hotkey = { mods, key } })
end

return M
