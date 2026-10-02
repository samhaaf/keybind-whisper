--- keybind-whisper.lua — Hammerspoon front end for the keybind-whisper CLI.
---
--- Install this file next to your init.lua, then in init.lua:
---
---     require("keybind-whisper").setup({ hotkey = { { "alt" }, "space" } })
---
--- Press the hotkey to start recording, press it again to stop: the text is
--- transcribed locally and pasted at the cursor. Audio is captured from the
--- system default input, so it follows whatever you pick in System Settings.
---
--- setup() options, all optional:
---   hotkey        { mods, key }  toggle dictation             (default ⌥Space)
---   pasteHotkey   { mods, key }  re-paste the last transcription   (unbound)
---   bin           string         path to the keybind-whisper executable
---   menubar       boolean        show the menu bar indicator     (default true)
---   historyCount  number         recent entries in the menu        (default 10)
---   timeout       number         seconds before a wedged run is killed
---
---   autoStop      number         seconds of silence that end a recording
---
--- The menu bar lists recent transcriptions; clicking one copies it. To paste
--- the last one at the cursor without recording again, bind pasteHotkey.
---
--- By default dictation is push-to-talk: the hotkey starts it and the hotkey
--- stops it. Set autoStop to a number of seconds and it instead ends on its
--- own once you stop speaking, with the hotkey still available to end it early.
---
--- The CLI's output contract, which this file depends on:
---   exit 0 + non-empty stdout : the transcript
---   exit 0 + empty stdout     : nothing usable heard; stderr says why
---   exit non-zero             : a real failure; stderr carries the message
--- Nothing here may collapse a failure into "nothing heard". Doing so is what
--- makes a broken dictation setup impossible to diagnose.

local M = {}

local cfg = {
    hotkey       = { { "alt" }, "space" },  -- toggle dictation
    pasteHotkey  = nil,                     -- re-paste the last transcription
    autoStop     = nil,                     -- seconds of silence that end a recording
    bin          = nil,
    menubar      = true,
    timeout      = 180,
    historyCount = 10,                      -- entries listed in the menu
}

-- hs.task objects are terminated when Lua garbage-collects them, so every
-- running task must be held somewhere that outlives the function starting it.
local startTask, stopTask, doctorTask = nil, nil, nil
local watchdog, busyAlert, menu = nil, nil, nil
local hotkey, pasteHotkey = nil, nil
local dictateTask, finishTask, phaseTimer = nil, nil, nil
local recording = false

-- ── Locating the CLI ────────────────────────────────────────────────────────
local function findBin()
    if cfg.bin then return cfg.bin end
    local home = os.getenv("HOME")
    local candidates = {
        home .. "/.local/bin/keybind-whisper",
        "/opt/homebrew/bin/keybind-whisper",
        "/usr/local/bin/keybind-whisper",
        home .. "/code/keybind-whisper/bin/keybind-whisper",
        home .. "/keybind-whisper/bin/keybind-whisper",
    }
    for _, p in ipairs(candidates) do
        local attr = hs.fs.attributes(p)
        if attr and attr.mode ~= "directory" then return p end
    end
    return nil
end

-- Reading history is a file read, fast enough to do synchronously while the
-- menu is being built. Recording and transcription stay asynchronous.
local function cli(args)
    local bin = findBin()
    if not bin then return nil end
    local out, ok = hs.execute(("%q %s 2>/dev/null"):format(bin, args))
    if not ok then return nil end
    return out
end

-- ── UI ──────────────────────────────────────────────────────────────────────
local function setState(state)
    if not menu then return end
    if state == "recording" then
        menu:setTitle("🔴")
        menu:setTooltip("keybind-whisper: recording — press the hotkey to stop")
    elseif state == "transcribing" then
        menu:setTitle("⏳")
        menu:setTooltip("keybind-whisper: transcribing…")
    else
        menu:setTitle("🎙️")
        menu:setTooltip("keybind-whisper: ready")
    end
end

-- Single place to tear down the persistent overlay and its watchdog, so no
-- code path can leave the infinite-duration alert stuck on screen.
local function clearBusy()
    if busyAlert then hs.alert.closeSpecific(busyAlert); busyAlert = nil end
    if watchdog then watchdog:stop(); watchdog = nil end
    if phaseTimer then phaseTimer:stop(); phaseTimer = nil end
end

local function showError(msg)
    msg = (msg or ""):gsub("%s+$", "")
    if msg == "" then msg = "dictation failed (no detail available)" end
    print("[keybind-whisper] " .. msg)
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
        showError("keybind-whisper executable not found — pass setup({ bin = \"/path/to/keybind-whisper\" })")
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
    if not bin then showError("keybind-whisper executable not found"); return end

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

-- ── Auto-stop flow ──────────────────────────────────────────────────────────
-- With auto-stop, something has to wait for the recorder to end by itself, so
-- a single blocking `dictate` owns the whole cycle and its callback delivers
-- the transcript. The hotkey pressed again runs `finish`, which signals the
-- recorder so that same `dictate` finishes early. Using `stop` here instead
-- would have two processes racing to transcribe the same audio.
local function stateDir()
    local out = cli("status")
    if not out then return nil end
    return out:match("state%s+(%S+)")
end

-- Switch the indicator from recording to transcribing when the CLI drops its
-- marker file. A stat() every half second, rather than spawning a process.
local function watchForTranscribing()
    local dir = stateDir()
    if not dir then return end
    local marker = dir .. "/transcribing"
    if phaseTimer then phaseTimer:stop() end
    phaseTimer = hs.timer.doEvery(0.5, function()
        if hs.fs.attributes(marker) then
            setState("transcribing")
            if busyAlert then hs.alert.closeSpecific(busyAlert) end
            busyAlert = hs.alert.show("⏳ transcribing…", math.huge)
            if phaseTimer then phaseTimer:stop(); phaseTimer = nil end
        end
    end)
end

function M.dictate()
    local bin = findBin()
    if not bin then showError("keybind-whisper executable not found"); return end

    recording = true
    setState("recording")
    busyAlert = hs.alert.show("🔴 listening… stops when you pause", math.huge)
    watchForTranscribing()

    dictateTask = hs.task.new(bin, function(code, stdout, stderr)
        dictateTask = nil
        recording = false
        clearBusy()
        setState("idle")

        if code ~= 0 then
            showError(stderr ~= "" and stderr or ("dictation failed (exit " .. tostring(code) .. ")"))
            return
        end
        if not paste(stdout) then
            local why = (stderr or ""):gsub("%s+$", "")
            hs.alert.show("🫥 " .. (why ~= "" and why or "nothing heard"), 6)
        end
    end, { "dictate", "--silence", tostring(cfg.autoStop) })

    if not dictateTask then
        recording = false
        clearBusy()
        setState("idle")
        showError("cannot execute " .. bin)
        return
    end

    -- The watchdog covers the whole cycle here, which includes however long
    -- the speaker keeps talking, so it is the recording cap plus the timeout.
    watchdog = hs.timer.doAfter(cfg.timeout + 1800, function()
        if dictateTask then dictateTask:terminate(); dictateTask = nil end
        recording = false
        clearBusy()
        setState("idle")
        showError("dictation timed out")
    end)

    dictateTask:start()
end

--- End an auto-stop recording early; `dictate` then transcribes what it has.
function M.finish()
    local bin = findBin()
    if not bin then return end
    finishTask = hs.task.new(bin, function() end, { "finish" })
    if finishTask then finishTask:start() end
end

function M.toggle()
    if cfg.autoStop then
        -- Auto-stop mode: `dictate` owns the cycle, `finish` ends it early.
        if recording then M.finish() else M.dictate() end
    else
        if recording then M.stop() else M.start() end
    end
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
    if not bin then showError("keybind-whisper executable not found"); return end
    local alert = hs.alert.show("🎚️ testing microphone for 3s…", math.huge)
    doctorTask = hs.task.new(bin, function(code, stdout, _stderr)
        doctorTask = nil
        hs.alert.closeSpecific(alert)
        hs.alert.show((code == 0 and "✅ " or "⚠️ ") .. (stdout or ""), 12)
        print("[keybind-whisper] doctor:\n" .. (stdout or ""))
    end, { "doctor" })
    if doctorTask then doctorTask:start() else hs.alert.closeSpecific(alert) end
end

-- ── History ─────────────────────────────────────────────────────────────────
--- Recent transcriptions, newest first, as { index = N, when = "...", text = "..." }.
function M.recent(count)
    local out = cli("history list " .. tostring(count or 10))
    if not out then return {} end
    local items = {}
    for line in out:gmatch("[^\r\n]+") do
        -- Rows are "  N  YYYY-MM-DD HH:MM:SS  text", truncated for display.
        local idx, when, text = line:match("^%s*(%d+)%s+([%d%-]+ [%d:]+)%s+(.*)$")
        if idx then
            items[#items + 1] = { index = tonumber(idx), when = when, text = text }
        end
    end
    return items
end

--- Full text of a history entry (1 = most recent), or nil.
function M.historyText(index)
    local out = cli("history show " .. tostring(index or 1))
    if not out or out == "" then return nil end
    return (out:gsub("%s+$", ""))
end

--- Paste a past transcription at the cursor. Bind this to a hotkey to re-paste
--- the last thing you dictated without recording it again.
function M.pasteLast(index)
    local text = M.historyText(index or 1)
    if not text then hs.alert.show("🫥 no history yet", 3); return end
    paste(text)
end

--- Copy a past transcription to the clipboard.
function M.copyHistory(index)
    local text = M.historyText(index or 1)
    if not text then hs.alert.show("🫥 no history yet", 3); return end
    hs.pasteboard.setContents(text)
    hs.alert.show("📋 copied", 2)
end

-- ── Setup ───────────────────────────────────────────────────────────────────
function M.setup(opts)
    for k, v in pairs(opts or {}) do cfg[k] = v end

    if cfg.menubar and not menu then
        menu = hs.menubar.new()
        if menu then
            menu:setMenu(function()
                local items = {
                    { title = recording and "Stop dictation" or "Start dictation",
                      fn = M.toggle },
                    { title = "-" },
                }

                local recent = M.recent(cfg.historyCount)
                if #recent == 0 then
                    items[#items + 1] = { title = "No transcriptions yet", disabled = true }
                else
                    items[#items + 1] = { title = "Recent", disabled = true }
                    for _, item in ipairs(recent) do
                        -- Clicking COPIES rather than pastes. A menu click has
                        -- already moved focus, so pasting could land in the
                        -- wrong window; copying is always correct. Bind
                        -- M.pasteLast to a hotkey for paste-at-cursor.
                        items[#items + 1] = {
                            title = "   " .. item.text,
                            tooltip = item.when .. " — click to copy",
                            fn = function() M.copyHistory(item.index) end,
                        }
                    end
                    items[#items + 1] = { title = "-" }
                    items[#items + 1] = { title = "Paste most recent at cursor",
                                          fn = function() M.pasteLast(1) end }
                end

                items[#items + 1] = { title = "-" }
                items[#items + 1] = { title = "Test microphone (3s)…", fn = M.doctor }
                return items
            end)
        end
    end

    if cfg.hotkey then
        if hotkey then hotkey:delete() end
        hotkey = hs.hotkey.bind(cfg.hotkey[1], cfg.hotkey[2], M.toggle)
    end

    if cfg.pasteHotkey then
        if pasteHotkey then pasteHotkey:delete() end
        pasteHotkey = hs.hotkey.bind(cfg.pasteHotkey[1], cfg.pasteHotkey[2],
                                     function() M.pasteLast(1) end)
    end

    -- Pick the real state back up after a config reload.
    -- Resynchronize in BOTH directions. Setting the indicator to idle without
    -- also clearing the flag would leave the UI and the state disagreeing, and
    -- the next hotkey press would try to stop a recording that is not running.
    if recorderAlive() then
        recording = true
        setState("recording")
        print("[keybind-whisper] resumed: a recording was already in progress")
    else
        recording = false
        setState("idle")
    end

    return M
end

--- Convenience for `require("keybind-whisper").bind({"alt"}, "space")`.
function M.bind(mods, key)
    return M.setup({ hotkey = { mods, key } })
end

return M
