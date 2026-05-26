-- ============================================================
-- Gurubashi Timer
-- WoW 1.12.1 / Lua 5.0 compatible
-- Countdown + alarm helper for the Gurubashi Arena chest.
-- ============================================================

GurubashiTimer = {};
local GT = GurubashiTimer;

local PERIOD_SECONDS = 3 * 60 * 60;
local DAY_SECONDS = 24 * 60 * 60;
local UPDATE_RATE = 0.20;
local MINUTE_POLL_RATE = 0.25;
local FLASH_SECONDS = 90;

local ALARM_INTERVALS = { 120, 60, 30, 15, 10, 5, 1, 0 };

local DEFAULT_DB = {
    locked = false,
    hidden = false,
    scale = 1.0,
    alpha = 0.85,
    alarmOn = true,
    chestNowMinutes = 5,
    snoozeMinutes = 5,
    useCustomCycle = false,
    offsetMinutes = 0,
    -- Legacy v1.1 fields are migrated on load if present.
    manualTarget = false,
    targetHour = 0,
    targetMinute = 0,
    point = "TOPLEFT",
    relativePoint = "TOPLEFT",
    x = 20,
    y = -120,
    alarmIntervals = {
        [120] = false,
        [60] = true,
        [30] = true,
        [15] = true,
        [10] = false,
        [5] = true,
        [1] = true,
        [0] = true,
    },
    alertTargets = {
        self = true,
        party = false,
        raid = false,
        guild = false,
    },
};

local GT_EstimatedServerSeconds;
local GT_RefreshOptions;

-- ------------------------------------------------------------
-- Utility
-- ------------------------------------------------------------

local function GT_CopyDefaults(src, dst)
    if not dst then dst = {}; end
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {}; end
            GT_CopyDefaults(v, dst[k]);
        elseif dst[k] == nil then
            dst[k] = v;
        end
    end
    return dst;
end

local function GT_Bool(v)
    if v then return true; end
    return false;
end

local function GT_FormatTime(seconds)
    if seconds < 0 then seconds = 0; end
    seconds = math.floor(seconds + 0.5);
    local h = math.floor(seconds / 3600);
    local m = math.floor((seconds - (h * 3600)) / 60);
    local s = seconds - (h * 3600) - (m * 60);
    return string.format("%02d:%02d:%02d", h, m, s);
end

local function GT_MinuteLabel(mins)
    if mins == 0 then return "now"; end
    if mins == 1 then return "1 minute"; end
    if mins == 60 then return "1 hour"; end
    if mins == 120 then return "2 hours"; end
    if mins > 60 then
        local h = math.floor(mins / 60);
        local m = mins - h * 60;
        if m == 0 then return h .. " hours"; end
        return h .. "h " .. m .. "m";
    end
    return mins .. " minutes";
end

local function GT_GetTimeColor(secondsLeft, chestActive)
    if chestActive then
        return 1.0, 0.10, 0.05;
    end
    if secondsLeft > 7200 then
        return 0.25, 0.55, 1.00; -- blue
    elseif secondsLeft > 3600 then
        return 0.25, 1.00, 0.25; -- green
    elseif secondsLeft > 1800 then
        return 1.00, 0.90, 0.10; -- yellow
    elseif secondsLeft > 900 then
        return 1.00, 0.45, 0.05; -- orange
    end
    return 1.00, 0.05, 0.05; -- red
end

local function GT_SafeChat(msg, r, g, b)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(msg, r or 1, g or 0.82, b or 0);
    end
end

local function GT_ClampNumber(v, minValue, maxValue, fallback)
    v = tonumber(v);
    if not v then v = fallback; end
    if v < minValue then v = minValue; end
    if v > maxValue then v = maxValue; end
    return math.floor(v + 0.5);
end

local function GT_PosMod(value, base)
    local m = math.mod(value, base);
    if m < 0 then m = m + base; end
    return m;
end

local function GT_NormalizeOffset()
    local db = GurubashiTimerDB;
    if not db then return; end
    db.offsetMinutes = GT_ClampNumber(db.offsetMinutes, 0, 179, 0);
end

local function GT_ResetAlarmCycle()
    GT.fired = {};
    GT.cycleKey = nil;
    GT.lastSecondsLeft = nil;
end

local function GT_MinutesToClockText(minuteOfDay)
    minuteOfDay = GT_PosMod(minuteOfDay, 1440);
    local h = math.floor(minuteOfDay / 60);
    local m = minuteOfDay - (h * 60);
    return string.format("%02d:%02d", h, m);
end

local function GT_OffsetScheduleText(offsetMinutes)
    offsetMinutes = GT_ClampNumber(offsetMinutes, 0, 179, 0);
    return GT_MinutesToClockText(offsetMinutes) .. ", " ..
        GT_MinutesToClockText(offsetMinutes + 180) .. ", " ..
        GT_MinutesToClockText(offsetMinutes + 360) .. ", ...";
end

local function GT_GetCurrentServerMinuteOfDay()
    local nowSeconds = GT_EstimatedServerSeconds();
    return math.floor(nowSeconds / 60);
end

local function GT_SetCustomOffset(offsetMinutes, reason)
    GurubashiTimerDB.useCustomCycle = true;
    GurubashiTimerDB.offsetMinutes = GT_ClampNumber(offsetMinutes, 0, 179, 0);
    -- Clear legacy one-off target mode if upgrading from v1.1.
    GurubashiTimerDB.manualTarget = false;
    GT_ResetAlarmCycle();
    GT_RefreshOptions();
    GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Custom 3-hour cycle enabled. Offset " .. GurubashiTimerDB.offsetMinutes .. " min. Schedule: " .. GT_OffsetScheduleText(GurubashiTimerDB.offsetMinutes) .. " server." .. (reason or ""), 1, 0.82, 0);
end

local function GT_SetDefaultCycle()
    GurubashiTimerDB.useCustomCycle = false;
    GurubashiTimerDB.offsetMinutes = 0;
    GurubashiTimerDB.manualTarget = false;
    GT_ResetAlarmCycle();
    GT_RefreshOptions();
    GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Using default 3-hour Gurubashi schedule: 02:00, 05:00, 08:00, ... server.", 1, 0.82, 0);
end

local function GT_SetChestNow()
    local minuteOfDay = GT_GetCurrentServerMinuteOfDay();
    local offsetMinutes = GT_PosMod(minuteOfDay, 180);
    GT_SetCustomOffset(offsetMinutes, " Chest Now calibrated from current server time.");
end

local function GT_SetChestAt(hourValue, minuteValue)
    local minuteOfDay = (hourValue * 60) + minuteValue;
    local offsetMinutes = GT_PosMod(minuteOfDay, 180);
    GT_SetCustomOffset(offsetMinutes, " Calibrated from known chest time " .. GT_MinutesToClockText(minuteOfDay) .. ".");
end

local function GT_PlayAlarmSound()
    -- Try both because old clients/private clients vary on which sound alias/path exists.
    if PlaySound then
        PlaySound("RaidWarning");
    end
    if PlaySoundFile then
        PlaySoundFile("Sound\\Interface\\RaidWarning.wav");
    end
end

local function GT_SendAlert(msg)
    local db = GurubashiTimerDB;
    if db.alertTargets.self then
        GT_SafeChat("|cffffcc00[Gurubashi Timer]|r " .. msg, 1, 0.82, 0);
    end

    if db.alertTargets.party and GetNumPartyMembers and GetNumPartyMembers() > 0 then
        if not GetNumRaidMembers or GetNumRaidMembers() == 0 then
            SendChatMessage("[Gurubashi Timer] " .. msg, "PARTY");
        end
    end

    if db.alertTargets.raid and GetNumRaidMembers and GetNumRaidMembers() > 0 then
        SendChatMessage("[Gurubashi Timer] " .. msg, "RAID");
    end

    if db.alertTargets.guild and IsInGuild and IsInGuild() then
        SendChatMessage("[Gurubashi Timer] " .. msg, "GUILD");
    end
end

-- ------------------------------------------------------------
-- Server time estimation
-- Vanilla GetGameTime() gives server hour/minute, not seconds.
-- Seconds are estimated between detected minute ticks.
-- ------------------------------------------------------------

local function GT_SyncServerMinute(force)
    if not GetGameTime then return; end
    local h, m = GetGameTime();
    if force or GT.serverHour ~= h or GT.serverMinute ~= m then
        GT.serverHour = h;
        GT.serverMinute = m;
        GT.serverBaseSeconds = (h * 3600) + (m * 60);
        GT.serverSyncLocal = GetTime();
    end
end

GT_EstimatedServerSeconds = function()
    if not GT.serverBaseSeconds or not GT.serverSyncLocal then
        GT_SyncServerMinute(true);
    end
    local elapsed = GetTime() - (GT.serverSyncLocal or GetTime());
    local s = (GT.serverBaseSeconds or 0) + elapsed;
    while s >= DAY_SECONDS do s = s - DAY_SECONDS; end
    while s < 0 do s = s + DAY_SECONDS; end
    return s;
end

local function GT_GetActiveOffsetMinutes()
    if GurubashiTimerDB and GurubashiTimerDB.useCustomCycle then
        GT_NormalizeOffset();
        return GurubashiTimerDB.offsetMinutes or 0, true;
    end
    return -60, false;
end

local function GT_GetCycleChestState()
    local nowSeconds = GT_EstimatedServerSeconds();
    local offsetMinutes, customCycle = GT_GetActiveOffsetMinutes();
    local offsetSeconds = offsetMinutes * 60;
    local chestNowSeconds = (GurubashiTimerDB.chestNowMinutes or 5) * 60;

    local elapsedInCycle = GT_PosMod(nowSeconds - offsetSeconds, PERIOD_SECONDS);
    local currentCycleIndex = math.floor((nowSeconds - offsetSeconds) / PERIOD_SECONDS);

    local currentChestSeconds = nowSeconds - elapsedInCycle;
    local nextChestSeconds;
    local secondsLeft;
    local chestActive = false;
    local cycleKey;

    if elapsedInCycle < chestNowSeconds then
        chestActive = true;
        secondsLeft = 0;
        nextChestSeconds = currentChestSeconds + PERIOD_SECONDS;
        cycleKey = "cycle:" .. offsetMinutes .. ":active:" .. currentCycleIndex;
    else
        chestActive = false;
        secondsLeft = PERIOD_SECONDS - elapsedInCycle;
        nextChestSeconds = currentChestSeconds + PERIOD_SECONDS;
        cycleKey = "cycle:" .. offsetMinutes .. ":next:" .. (currentCycleIndex + 1);
    end

    local nextChestMinuteOfDay = math.floor(GT_PosMod(nextChestSeconds, DAY_SECONDS) / 60);
    local currentChestMinuteOfDay = math.floor(GT_PosMod(currentChestSeconds, DAY_SECONDS) / 60);

    return secondsLeft, chestActive, nextChestMinuteOfDay, cycleKey, nowSeconds, customCycle, offsetMinutes, currentChestMinuteOfDay;
end

local function GT_GetChestState()
    return GT_GetCycleChestState();
end

-- ------------------------------------------------------------
-- Alarm logic
-- ------------------------------------------------------------

local function GT_StartAlarm(msg, bypassSnooze)
    if not GurubashiTimerDB.alarmOn then return; end
    if GT.snoozeUntil and GetTime() < GT.snoozeUntil and not bypassSnooze then
        return;
    end

    GT.activeAlarm = true;
    GT.alarmMessage = msg;
    GT.alarmFlashUntil = GetTime() + FLASH_SECONDS;

    GT_PlayAlarmSound();
    GT_SendAlert(msg);

    if GT.snoozeButton then
        GT.snoozeButton:Show();
    end
end

function GurubashiTimer_Snooze()
    local mins = GurubashiTimerDB.snoozeMinutes or 5;
    GT.snoozeUntil = GetTime() + (mins * 60);
    GT.snoozeMessage = "Snoozed reminder: Gurubashi chest soon.";
    GT.activeAlarm = false;
    GT.alarmFlashUntil = nil;

    if GT.snoozeButton then GT.snoozeButton:Hide(); end
    if GT.dismissButton then GT.dismissButton:Hide(); end
    if GT.frame then GT.frame.flashAlpha = 0; end
    GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Snoozed for " .. mins .. " minute(s).", 1, 0.82, 0);
end

function GurubashiTimer_DismissAlarm()
    GT.activeAlarm = false;
    GT.alarmFlashUntil = nil;
    if GT.snoozeButton then GT.snoozeButton:Hide(); end
    if GT.dismissButton then GT.dismissButton:Hide(); end
end

local function GT_CheckAlarms(secondsLeft, chestActive, cycleKey)
    local db = GurubashiTimerDB;
    if not db.alarmOn then return; end

    if GT.cycleKey ~= cycleKey then
        GT.cycleKey = cycleKey;
        GT.fired = {};
        GT.lastSecondsLeft = nil;
    end

    if chestActive then
        if db.alarmIntervals[0] and not GT.fired[0] then
            GT_StartAlarm("Gurubashi chest is spawning now!");
            GT.fired[0] = true;
        end
        GT.lastSecondsLeft = secondsLeft;
        return;
    end

    if GT.snoozeUntil and GetTime() >= GT.snoozeUntil then
        GT.snoozeUntil = nil;
        GT_StartAlarm(GT.snoozeMessage or "Snoozed Gurubashi reminder.", true);
    end

    if GT.lastSecondsLeft == nil then
        GT.lastSecondsLeft = secondsLeft;
        return;
    end

    local i;
    for i = 1, table.getn(ALARM_INTERVALS) do
        local mins = ALARM_INTERVALS[i];
        if mins > 0 and db.alarmIntervals[mins] and not GT.fired[mins] then
            local threshold = mins * 60;
            if GT.lastSecondsLeft > threshold and secondsLeft <= threshold then
                local msg = "Gurubashi chest in " .. GT_MinuteLabel(mins) .. ".";
                GT_StartAlarm(msg);
                GT.fired[mins] = true;
            end
        end
    end

    GT.lastSecondsLeft = secondsLeft;
end

-- ------------------------------------------------------------
-- Main frame
-- ------------------------------------------------------------

local function GT_SavePosition()
    if not GT.frame then return; end
    local point, relativeTo, relativePoint, x, y = GT.frame:GetPoint();
    GurubashiTimerDB.point = point or "TOPLEFT";
    GurubashiTimerDB.relativePoint = relativePoint or "TOPLEFT";
    GurubashiTimerDB.x = x or 20;
    GurubashiTimerDB.y = y or -120;
end

local function GT_SetFlashVisible(visible, alpha)
    if not GT.flashTextures then return; end
    local i;
    for i = 1, table.getn(GT.flashTextures) do
        if visible then
            GT.flashTextures[i]:SetAlpha(alpha or 1);
            GT.flashTextures[i]:Show();
        else
            GT.flashTextures[i]:Hide();
        end
    end
end

local GT_ButtonBackdrop = {
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\ChatFrame\\ChatFrameBackground",
    tile = false,
    tileSize = 0,
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 }
};

local function GT_UpdateButtonVisual(button, state)
    if not button then return; end

    local r = 0.055;
    local g = 0.065;
    local b = 0.075;
    local a = 0.96;
    local br = 0.30;
    local bg = 0.34;
    local bb = 0.38;

    if button.gtSelected then
        r = 0.12; g = 0.095; b = 0.035;
        br = 1.00; bg = 0.82; bb = 0.05;
    elseif state == "down" then
        r = 0.025; g = 0.030; b = 0.035;
        br = 1.00; bg = 0.82; bb = 0.05;
    elseif state == "hover" then
        r = 0.090; g = 0.100; b = 0.115;
        br = 0.62; bg = 0.68; bb = 0.74;
    end

    if button.SetBackdropColor then button:SetBackdropColor(r, g, b, a); end
    if button.SetBackdropBorderColor then button:SetBackdropBorderColor(br, bg, bb, 1); end
    if button.gtText then
        if button.gtSelected then
            button.gtText:SetTextColor(1.0, 0.82, 0.05);
        else
            button.gtText:SetTextColor(0.92, 0.92, 0.92);
        end
    end
end

local function GT_CreateButton(parent, name, text, width, height)
    local b = CreateFrame("Button", name, parent);
    b:SetWidth(width or 80);
    b:SetHeight(height or 22);
    b:SetBackdrop(GT_ButtonBackdrop);

    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    fs:SetPoint("CENTER", b, "CENTER", 0, 0);
    fs:SetJustifyH("CENTER");
    fs:SetText(text or "");
    b:SetFontString(fs);
    b.gtText = fs;

    b:SetScript("OnEnter", function()
        this.gtHover = true;
        GT_UpdateButtonVisual(this, "hover");
    end);
    b:SetScript("OnLeave", function()
        this.gtHover = false;
        GT_UpdateButtonVisual(this, nil);
    end);
    b:SetScript("OnMouseDown", function()
        GT_UpdateButtonVisual(this, "down");
    end);
    b:SetScript("OnMouseUp", function()
        if this.gtHover then
            GT_UpdateButtonVisual(this, "hover");
        else
            GT_UpdateButtonVisual(this, nil);
        end
    end);

    GT_UpdateButtonVisual(b, nil);
    return b;
end

local function GT_CreateFlashTexture(parent, point, relPoint, x, y, w, h)
    local t = parent:CreateTexture(nil, "OVERLAY");
    t:SetWidth(w);
    t:SetHeight(h);
    t:SetPoint(point, parent, relPoint, x, y);
    t:SetTexture(1, 0.82, 0.05);
    t:SetAlpha(0);
    t:Hide();
    return t;
end

local function GT_CreateMainFrame()
    local f = CreateFrame("Frame", "GurubashiTimerFrame", UIParent);
    GT.frame = f;

    f:SetWidth(190);
    f:SetHeight(78);
    f:SetMovable(true);
    f:EnableMouse(true);
    f:SetClampedToScreen(true);

    local bg = f:CreateTexture(nil, "BACKGROUND");
    bg:SetAllPoints(f);
    bg:SetTexture(0, 0, 0);
    bg:SetAlpha(0.62);
    f.bg = bg;

    local border = f:CreateTexture(nil, "BORDER");
    border:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0);
    border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0);
    border:SetTexture(0.10, 0.10, 0.10);
    border:SetAlpha(0.45);
    f.border = border;

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    label:SetPoint("TOP", f, "TOP", 0, -6);
    label:SetText("GURUBASHI");
    label:SetTextColor(1, 0.82, 0);
    GT.labelText = label;

    local timer = f:CreateFontString(nil, "OVERLAY");
    timer:SetFont("Fonts\\FRIZQT__.TTF", 31, "OUTLINE");
    timer:SetShadowOffset(2, -2);
    timer:SetPoint("CENTER", f, "CENTER", 0, -4);
    timer:SetText("--:--:--");
    GT.timerText = timer;

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    sub:SetPoint("BOTTOM", f, "BOTTOM", 0, 5);
    sub:SetText("right-click options");
    sub:SetTextColor(0.65, 0.65, 0.65);
    GT.subText = sub;

    GT.flashTextures = {};
    table.insert(GT.flashTextures, GT_CreateFlashTexture(f, "TOPLEFT", "TOPLEFT", -2, 2, 24, 5));
    table.insert(GT.flashTextures, GT_CreateFlashTexture(f, "TOPLEFT", "TOPLEFT", -2, 2, 5, 24));
    table.insert(GT.flashTextures, GT_CreateFlashTexture(f, "TOPRIGHT", "TOPRIGHT", 2, 2, 24, 5));
    table.insert(GT.flashTextures, GT_CreateFlashTexture(f, "TOPRIGHT", "TOPRIGHT", 2, 2, 5, 24));
    table.insert(GT.flashTextures, GT_CreateFlashTexture(f, "BOTTOMLEFT", "BOTTOMLEFT", -2, -2, 24, 5));
    table.insert(GT.flashTextures, GT_CreateFlashTexture(f, "BOTTOMLEFT", "BOTTOMLEFT", -2, -2, 5, 24));
    table.insert(GT.flashTextures, GT_CreateFlashTexture(f, "BOTTOMRIGHT", "BOTTOMRIGHT", 2, -2, 24, 5));
    table.insert(GT.flashTextures, GT_CreateFlashTexture(f, "BOTTOMRIGHT", "BOTTOMRIGHT", 2, -2, 5, 24));

    local snooze = GT_CreateButton(f, "GurubashiTimerSnoozeButton", "Snooze", 70, 18);
    snooze:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, -20);
    snooze:SetScript("OnClick", function() GurubashiTimer_Snooze(); end);
    snooze:Hide();
    GT.snoozeButton = snooze;

    local dismiss = GT_CreateButton(f, "GurubashiTimerDismissButton", "Dismiss", 70, 18);
    dismiss:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, -20);
    dismiss:SetScript("OnClick", function() GurubashiTimer_DismissAlarm(); end);
    dismiss:Hide();
    GT.dismissButton = dismiss;

    f:SetScript("OnMouseDown", function()
        local button = arg1;
        if button == "LeftButton" then
            if not GurubashiTimerDB.locked then
                this:StartMoving();
            end
        elseif button == "RightButton" then
            GurubashiTimer_ToggleOptions();
        end
    end);

    f:SetScript("OnMouseUp", function()
        this:StopMovingOrSizing();
        GT_SavePosition();
    end);

    f:SetScript("OnEnter", function()
        if GameTooltip then
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT");
            GameTooltip:AddLine("Gurubashi Timer", 1, 0.82, 0);
            GameTooltip:AddLine("Left-drag to move.", 1, 1, 1);
            GameTooltip:AddLine("Right-click for options.", 1, 1, 1);
            GameTooltip:AddLine("/gt test to test alarm.", 0.8, 0.8, 0.8);
            GameTooltip:Show();
        end
    end);

    f:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide(); end
    end);
end

local function GT_ApplySettings()
    if not GT.frame then return; end
    local db = GurubashiTimerDB;
    GT.frame:ClearAllPoints();
    GT.frame:SetPoint(db.point or "TOPLEFT", UIParent, db.relativePoint or "TOPLEFT", db.x or 20, db.y or -120);
    GT.frame:SetScale(db.scale or 1.0);
    GT.frame:SetAlpha(db.alpha or 0.85);
    if db.hidden then GT.frame:Hide(); else GT.frame:Show(); end
end

-- ------------------------------------------------------------
-- Options UI
-- ------------------------------------------------------------

local function GT_SetCheckboxText(box, text)
    local fs = getglobal(box:GetName() .. "Text");
    if fs then fs:SetText(text); end
end

local function GT_MakeCheck(parent, name, text, x, y, onClick)
    local cb = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate");
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y);
    cb:SetWidth(24);
    cb:SetHeight(24);
    GT_SetCheckboxText(cb, text);
    cb:SetScript("OnClick", function()
        local checked = false;
        if this:GetChecked() then checked = true; end
        onClick(checked);
    end);
    return cb;
end

local function GT_UpdateSliderValueText(slider)
    if not slider or not slider.gtValueText then return; end
    local value = slider:GetValue();
    local valueText;
    if slider.gtFormatter then
        valueText = slider.gtFormatter(value);
    else
        valueText = tostring(math.floor(value + 0.5));
    end
    slider.gtValueText:SetText((slider.gtLabel or "Value") .. ": " .. valueText);
end

local function GT_MakeSlider(parent, name, label, x, y, minValue, maxValue, step, onChanged, formatter)
    local s = CreateFrame("Slider", name, parent, "OptionsSliderTemplate");
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y);
    s:SetWidth(180);
    s:SetMinMaxValues(minValue, maxValue);
    s:SetValueStep(step);
    s.gtLabel = label;
    s.gtFormatter = formatter;

    local defaultLabel = getglobal(name .. "Text");
    if defaultLabel then defaultLabel:SetText(""); end
    getglobal(name .. "Low"):SetText(tostring(minValue));
    getglobal(name .. "High"):SetText(tostring(maxValue));

    local valueLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    valueLabel:SetPoint("BOTTOM", s, "TOP", 0, 5);
    valueLabel:SetTextColor(1.0, 0.82, 0.05);
    valueLabel:SetJustifyH("CENTER");
    valueLabel:SetText(label .. ": --");
    s.gtValueText = valueLabel;

    s:SetScript("OnValueChanged", function()
        local value = this:GetValue();
        GT_UpdateSliderValueText(this);
        onChanged(value);
    end);
    GT_UpdateSliderValueText(s);
    return s;
end

local function GT_CreateLabel(parent, text, x, y, small)
    local template = "GameFontNormal";
    if small then template = "GameFontNormalSmall"; end
    local fs = parent:CreateFontString(nil, "OVERLAY", template);
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y);
    fs:SetText(text);
    return fs;
end

local function GT_CreateText(parent, text, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall");
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y);
    fs:SetWidth(width or 360);
    fs:SetJustifyH("LEFT");
    fs:SetJustifyV("TOP");
    fs:SetText(text);
    fs:SetTextColor(0.82, 0.82, 0.82);
    return fs;
end

local function GT_ShowOptionsTab(tabName)
    if not GT.options or not GT.optionPanels then return; end
    if not tabName then tabName = GT.activeOptionsTab or "general"; end
    GT.activeOptionsTab = tabName;

    local panels = GT.optionPanels;
    if panels.general then panels.general:Hide(); end
    if panels.alarms then panels.alarms:Hide(); end
    if panels.schedule then panels.schedule:Hide(); end

    if panels[tabName] then panels[tabName]:Show(); end

    if GT.optionTabButtons then
        local k, btn;
        for k, btn in pairs(GT.optionTabButtons) do
            if k == tabName then
                btn.gtSelected = true;
            else
                btn.gtSelected = false;
            end
            btn:SetText(btn.baseText);
            GT_UpdateButtonVisual(btn, nil);
        end
    end
end

GT_RefreshOptions = function()
    if not GT.options then return; end
    local db = GurubashiTimerDB;
    local c = GT.optionControls;
    if not c then return; end

    if c.locked then c.locked:SetChecked(db.locked); end
    if c.alarmOn then c.alarmOn:SetChecked(db.alarmOn); end
    if c.useCustomCycle then c.useCustomCycle:SetChecked(db.useCustomCycle); end
    if c.self then c.self:SetChecked(db.alertTargets.self); end
    if c.party then c.party:SetChecked(db.alertTargets.party); end
    if c.raid then c.raid:SetChecked(db.alertTargets.raid); end
    if c.guild then c.guild:SetChecked(db.alertTargets.guild); end

    local i;
    for i = 1, table.getn(ALARM_INTERVALS) do
        local mins = ALARM_INTERVALS[i];
        if c.intervals and c.intervals[mins] then
            c.intervals[mins]:SetChecked(db.alarmIntervals[mins]);
        end
    end

    GT.refreshingOptions = true;
    if c.scale then c.scale:SetValue(db.scale or 1.0); GT_UpdateSliderValueText(c.scale); end
    if c.alpha then c.alpha:SetValue(db.alpha or 0.85); GT_UpdateSliderValueText(c.alpha); end
    if c.snooze then c.snooze:SetValue(db.snoozeMinutes or 5); GT_UpdateSliderValueText(c.snooze); end
    if c.chestNow then c.chestNow:SetValue(db.chestNowMinutes or 5); GT_UpdateSliderValueText(c.chestNow); end
    if c.offset then c.offset:SetValue(db.offsetMinutes or 0); GT_UpdateSliderValueText(c.offset); end
    GT.refreshingOptions = false;

    if c.scheduleText then
        if db.useCustomCycle then
            c.scheduleText:SetText("Custom cycle: " .. GT_OffsetScheduleText(db.offsetMinutes or 0));
        else
            c.scheduleText:SetText("Default cycle: 02:00, 05:00, 08:00, ...");
        end
    end

    if c.nextText then
        local secondsLeft, chestActive, nextChestMinuteOfDay, cycleKey, nowSeconds, customCycle, offsetMinutes, currentChestMinuteOfDay = GT_GetChestState();
        if chestActive then
            c.nextText:SetText("Chest window is active. Next: " .. GT_MinutesToClockText(nextChestMinuteOfDay) .. " server.");
        else
            c.nextText:SetText("Next chest: " .. GT_MinutesToClockText(nextChestMinuteOfDay) .. " server. Time left: " .. GT_FormatTime(secondsLeft) .. ".");
        end
    end

    GT_ShowOptionsTab(GT.activeOptionsTab or "general");
end

local function GT_CreateTabButton(parent, name, text, x, tabName)
    local b = GT_CreateButton(parent, name, text, 112, 24);
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -44);
    b.baseText = text;
    b:SetScript("OnClick", function() GT_ShowOptionsTab(tabName); end);
    return b;
end

local function GT_CreatePanel(parent, name)
    local f = CreateFrame("Frame", name, parent);
    f:SetWidth(388);
    f:SetHeight(300);
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -78);
    f:Hide();
    return f;
end

local function GT_CreateOptions()
    local opt = CreateFrame("Frame", "GurubashiTimerOptionsFrame", UIParent);
    GT.options = opt;
    GT.optionControls = { intervals = {} };
    GT.optionPanels = {};
    GT.optionTabButtons = {};

    opt:SetWidth(420);
    opt:SetHeight(430);
    opt:SetPoint("CENTER", UIParent, "CENTER", 0, 0);
    opt:SetFrameStrata("DIALOG");
    opt:EnableMouse(true);
    opt:SetMovable(true);
    opt:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    });
    opt:SetBackdropColor(0, 0, 0, 0.92);
    opt:Hide();

    opt:SetScript("OnMouseDown", function()
        if arg1 == "LeftButton" then this:StartMoving(); end
    end);
    opt:SetScript("OnMouseUp", function()
        this:StopMovingOrSizing();
    end);

    local title = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge");
    title:SetPoint("TOP", opt, "TOP", 0, -14);
    title:SetText("Gurubashi Timer Options");

    GT.optionTabButtons.general = GT_CreateTabButton(opt, "GurubashiTimerTabGeneral", "General", 24, "general");
    GT.optionTabButtons.alarms = GT_CreateTabButton(opt, "GurubashiTimerTabAlarms", "Alarms", 154, "alarms");
    GT.optionTabButtons.schedule = GT_CreateTabButton(opt, "GurubashiTimerTabSchedule", "Schedule", 284, "schedule");

    local close = GT_CreateButton(opt, "GurubashiTimerOptionsCloseButton", "Close", 70, 22);
    close:SetPoint("BOTTOMRIGHT", opt, "BOTTOMRIGHT", -14, 14);
    close:SetScript("OnClick", function() GT.options:Hide(); end);

    local test = GT_CreateButton(opt, "GurubashiTimerOptionsTestButton", "Test", 70, 22);
    test:SetPoint("BOTTOMLEFT", opt, "BOTTOMLEFT", 14, 14);
    test:SetScript("OnClick", function() GurubashiTimer_TestAlarm(); end);

    local c = GT.optionControls;

    -- General tab
    local general = GT_CreatePanel(opt, "GurubashiTimerOptionsGeneralPanel");
    GT.optionPanels.general = general;

    GT_CreateLabel(general, "Display", 8, -6, false);
    c.locked = GT_MakeCheck(general, "GurubashiTimerLockCheck", "Lock position", 18, -34, function(v)
        GurubashiTimerDB.locked = v;
    end);

    c.scale = GT_MakeSlider(general, "GurubashiTimerScaleSlider", "Scale", 18, -82, 0.6, 2.0, 0.05, function(v)
        v = math.floor((v * 20) + 0.5) / 20;
        GurubashiTimerDB.scale = v;
        GT_ApplySettings();
    end, function(v) return string.format("%.2fx", math.floor((v * 20) + 0.5) / 20); end);

    c.alpha = GT_MakeSlider(general, "GurubashiTimerAlphaSlider", "Transparency", 214, -82, 0.2, 1.0, 0.05, function(v)
        v = math.floor((v * 20) + 0.5) / 20;
        GurubashiTimerDB.alpha = v;
        GT_ApplySettings();
    end, function(v) return tostring(math.floor((v * 100) + 0.5)) .. "%"; end);

    GT_CreateText(general, "Left-drag the timer to move it. Right-click the timer to reopen this menu. Use /gt status to print the current schedule.", 18, -150, 350);

    local reset = GT_CreateButton(general, "GurubashiTimerOptionsResetButton", "Reset...", 104, 22);
    reset:SetPoint("TOPLEFT", general, "TOPLEFT", 18, -214);
    reset:SetScript("OnClick", function()
        local now = GetTime();
        if GT.resetConfirmUntil and now <= GT.resetConfirmUntil then
            GT.resetConfirmUntil = nil;
            this:SetText("Reset...");
            GurubashiTimer_Reset();
        else
            GT.resetConfirmUntil = now + 6;
            this:SetText("Confirm Reset");
            GT_UpdateButtonVisual(this, "down");
            GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Click Confirm Reset within 6 seconds to reset settings.", 1, 0.82, 0);
        end
    end);

    -- Alarms tab
    local alarms = GT_CreatePanel(opt, "GurubashiTimerOptionsAlarmsPanel");
    GT.optionPanels.alarms = alarms;

    c.alarmOn = GT_MakeCheck(alarms, "GurubashiTimerAlarmCheck", "Alarm On", 18, -6, function(v)
        GurubashiTimerDB.alarmOn = v;
    end);

    GT_CreateLabel(alarms, "Alert intervals", 8, -42, false);

    local i;
    for i = 1, table.getn(ALARM_INTERVALS) do
        local mins = ALARM_INTERVALS[i];
        local col = 0;
        local row = i - 1;
        if i > 4 then col = 1; row = i - 5; end
        local label;
        if mins == 0 then label = "At chest time"; else label = GT_MinuteLabel(mins) .. " out"; end
        c.intervals[mins] = GT_MakeCheck(alarms, "GurubashiTimerInterval" .. mins, label, 18 + (col * 188), -66 - (row * 25), function(v)
            GurubashiTimerDB.alarmIntervals[mins] = v;
        end);
    end

    GT_CreateLabel(alarms, "Send alert to", 8, -178, false);
    c.self = GT_MakeCheck(alarms, "GurubashiTimerSelfCheck", "Self", 18, -202, function(v)
        GurubashiTimerDB.alertTargets.self = v;
    end);
    c.party = GT_MakeCheck(alarms, "GurubashiTimerPartyCheck", "Party", 98, -202, function(v)
        GurubashiTimerDB.alertTargets.party = v;
    end);
    c.raid = GT_MakeCheck(alarms, "GurubashiTimerRaidCheck", "Raid", 188, -202, function(v)
        GurubashiTimerDB.alertTargets.raid = v;
    end);
    c.guild = GT_MakeCheck(alarms, "GurubashiTimerGuildCheck", "Guild", 268, -202, function(v)
        GurubashiTimerDB.alertTargets.guild = v;
    end);

    c.snooze = GT_MakeSlider(alarms, "GurubashiTimerSnoozeSlider", "Snooze", 18, -248, 1, 30, 1, function(v)
        GurubashiTimerDB.snoozeMinutes = math.floor(v + 0.5);
    end, function(v) return tostring(math.floor(v + 0.5)) .. " min"; end);

    -- Schedule tab
    local schedule = GT_CreatePanel(opt, "GurubashiTimerOptionsSchedulePanel");
    GT.optionPanels.schedule = schedule;

    GT_CreateLabel(schedule, "3-hour cycle calibration", 8, -6, false);

    c.useCustomCycle = GT_MakeCheck(schedule, "GurubashiTimerCustomCycleCheck", "Use custom repeating cycle", 18, -34, function(v)
        GurubashiTimerDB.useCustomCycle = v;
        GurubashiTimerDB.manualTarget = false;
        GT_ResetAlarmCycle();
        GT_RefreshOptions();
    end);

    local defaultButton = GT_CreateButton(schedule, "GurubashiTimerDefaultCycleButton", "Default", 90, 22);
    defaultButton:SetPoint("TOPLEFT", schedule, "TOPLEFT", 18, -70);
    defaultButton:SetScript("OnClick", function()
        GT_SetDefaultCycle();
    end);

    local chestNowButton = GT_CreateButton(schedule, "GurubashiTimerChestNowButton", "Chest Now", 100, 22);
    chestNowButton:SetPoint("LEFT", defaultButton, "RIGHT", 8, 0);
    chestNowButton:SetScript("OnClick", function()
        GT_SetChestNow();
    end);

    c.offset = GT_MakeSlider(schedule, "GurubashiTimerOffsetSlider", "Cycle offset", 18, -118, 0, 179, 1, function(v)
        local newOffset = math.floor(v + 0.5);
        if GurubashiTimerDB.offsetMinutes ~= newOffset then
            GurubashiTimerDB.offsetMinutes = newOffset;
            GurubashiTimerDB.useCustomCycle = true;
            GurubashiTimerDB.manualTarget = false;
            if c.useCustomCycle then c.useCustomCycle:SetChecked(true); end
            if c.scheduleText then c.scheduleText:SetText("Custom cycle: " .. GT_OffsetScheduleText(newOffset)); end
            if not GT.refreshingOptions then GT_ResetAlarmCycle(); end
        end
    end, function(v) return tostring(math.floor(v + 0.5)) .. " min"; end);
    c.offset:SetWidth(340);

    c.chestNow = GT_MakeSlider(schedule, "GurubashiTimerChestNowSlider", "Chest window", 18, -178, 1, 10, 1, function(v)
        GurubashiTimerDB.chestNowMinutes = math.floor(v + 0.5);
    end, function(v) return tostring(math.floor(v + 0.5)) .. " min"; end);

    c.scheduleText = GT_CreateText(schedule, "Default cycle: 02:00, 05:00, 08:00, ...", 18, -232, 350);
    c.nextText = GT_CreateText(schedule, "Next chest: --:-- server.", 18, -254, 350);
    GT_CreateText(schedule, "Chest Now calibrates the repeating cycle from the current server minute. It does not mean the alarm checkbox; that one is named At chest time.", 18, -278, 350);

    GT.activeOptionsTab = GT.activeOptionsTab or "general";
    GT_ShowOptionsTab(GT.activeOptionsTab);
end

function GurubashiTimer_ToggleOptions()
    if not GT.options then GT_CreateOptions(); end
    GT_RefreshOptions();
    if GT.options:IsShown() then GT.options:Hide(); else GT.options:Show(); end
end

-- ------------------------------------------------------------
-- Public slash functions
-- ------------------------------------------------------------

function GurubashiTimer_TestAlarm()
    GT_StartAlarm("Test alarm: Gurubashi chest reminder.", true);
end

function GurubashiTimer_Reset()
    GurubashiTimerDB = GT_CopyDefaults(DEFAULT_DB, {});
    GT_ResetAlarmCycle();
    GT_ApplySettings();
    GT_RefreshOptions();
    GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Settings reset.", 1, 0.82, 0);
end

local function GT_PrintHelp()
    GT_SafeChat("|cffffcc00Gurubashi Timer commands:|r", 1, 0.82, 0);
    GT_SafeChat("/gt options - open options", 1, 1, 1);
    GT_SafeChat("/gt test - test alarm", 1, 1, 1);
    GT_SafeChat("/gt lock - lock position", 1, 1, 1);
    GT_SafeChat("/gt unlock - unlock position", 1, 1, 1);
    GT_SafeChat("/gt show - show timer", 1, 1, 1);
    GT_SafeChat("/gt hide - hide timer", 1, 1, 1);
    GT_SafeChat("/gt default - use normal 02/05/08/11 schedule", 1, 1, 1);
    GT_SafeChat("/gt offset MINUTES - shift repeating 3-hour cycle, 0-179", 1, 1, 1);
    GT_SafeChat("/gt chestnow - set current server minute as a chest spawn", 1, 1, 1);
    GT_SafeChat("/gt chestat HH:MM - set known server chest time", 1, 1, 1);
    GT_SafeChat("/gt status - print active schedule", 1, 1, 1);
    GT_SafeChat("/gt reset - reset settings", 1, 1, 1);
end

local function GT_SlashHandler(msg)
    msg = string.lower(msg or "");

    local _, _, offsetText = string.find(msg, "^offset%s+(%d+)$");
    if offsetText then
        local offset = tonumber(offsetText);
        if offset and offset >= 0 and offset <= 179 then
            GT_SetCustomOffset(offset, "");
        else
            GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Use /gt offset MINUTES with a value from 0 to 179.", 1, 0.82, 0);
        end
        return;
    end

    local _, _, chestHourText, chestMinuteText = string.find(msg, "^chestat%s+(%d%d?):(%d%d)$");
    if chestHourText and chestMinuteText then
        local h = tonumber(chestHourText);
        local m = tonumber(chestMinuteText);
        if h and m and h >= 0 and h <= 23 and m >= 0 and m <= 59 then
            GT_SetChestAt(h, m);
        else
            GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Use /gt chestat HH:MM with hour 00-23 and minute 00-59.", 1, 0.82, 0);
        end
        return;
    end

    if msg == "default" or msg == "auto" then
        GT_SetDefaultCycle();
        return;
    end

    if msg == "chestnow" or msg == "now" then
        GT_SetChestNow();
        return;
    end

    if msg == "status" or msg == "schedule" then
        if GurubashiTimerDB.useCustomCycle then
            GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Custom cycle offset " .. (GurubashiTimerDB.offsetMinutes or 0) .. " min. Schedule: " .. GT_OffsetScheduleText(GurubashiTimerDB.offsetMinutes or 0) .. " server.", 1, 0.82, 0);
        else
            GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Default cycle: 02:00, 05:00, 08:00, 11:00, ... server.", 1, 0.82, 0);
        end
        return;
    end

    if msg == "options" or msg == "config" then
        GurubashiTimer_ToggleOptions();
    elseif msg == "test" then
        GurubashiTimer_TestAlarm();
    elseif msg == "lock" then
        GurubashiTimerDB.locked = true;
        GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Position locked.", 1, 0.82, 0);
    elseif msg == "unlock" then
        GurubashiTimerDB.locked = false;
        GT_SafeChat("|cffffcc00[Gurubashi Timer]|r Position unlocked.", 1, 0.82, 0);
    elseif msg == "show" then
        GurubashiTimerDB.hidden = false;
        if GT.frame then GT.frame:Show(); end
    elseif msg == "hide" then
        GurubashiTimerDB.hidden = true;
        if GT.frame then GT.frame:Hide(); end
    elseif msg == "reset" then
        GurubashiTimer_Reset();
    else
        GT_PrintHelp();
    end
end

-- ------------------------------------------------------------
-- Update loop
-- ------------------------------------------------------------

local function GT_UpdateDisplay(elapsed)
    GT.elapsedSinceUpdate = (GT.elapsedSinceUpdate or 0) + elapsed;
    GT.elapsedSinceMinutePoll = (GT.elapsedSinceMinutePoll or 0) + elapsed;

    if GT.elapsedSinceMinutePoll >= MINUTE_POLL_RATE then
        GT.elapsedSinceMinutePoll = 0;
        GT_SyncServerMinute(false);
    end

    if GT.elapsedSinceUpdate < UPDATE_RATE then return; end
    GT.elapsedSinceUpdate = 0;

    local secondsLeft, chestActive, nextChestMinuteOfDay, cycleKey, nowSeconds, customCycle, offsetMinutes, currentChestMinuteOfDay = GT_GetChestState();

    if GT.timerText then
        local r, g, b = GT_GetTimeColor(secondsLeft, chestActive);
        if chestActive then
            local flash = math.mod(math.floor(GetTime() * 3), 2);
            if flash == 0 then
                GT.timerText:SetTextColor(1, 0.9, 0.05);
            else
                GT.timerText:SetTextColor(1, 0.05, 0.05);
            end
            GT.timerText:SetText("CHEST NOW");
            GT.labelText:SetText("GURUBASHI");
            GT.subText:SetText("next: " .. GT_MinutesToClockText(nextChestMinuteOfDay) .. " server");
        else
            GT.timerText:SetTextColor(r, g, b);
            GT.timerText:SetText(GT_FormatTime(secondsLeft));
            GT.labelText:SetText("GURUBASHI");
            if customCycle then
                GT.subText:SetText("next: " .. GT_MinutesToClockText(nextChestMinuteOfDay) .. " server | offset " .. offsetMinutes .. "m");
            else
                GT.subText:SetText("next: " .. GT_MinutesToClockText(nextChestMinuteOfDay) .. " server");
            end
        end
    end

    if GT.alarmFlashUntil and GetTime() < GT.alarmFlashUntil then
        local a = 0.35 + (math.abs(math.sin(GetTime() * 8)) * 0.65);
    GT_SetFlashVisible(true, a);

    if GT.snoozeButton then GT.snoozeButton:Show(); end
        if GT.dismissButton then GT.dismissButton:Show(); end
            else
                GT_SetFlashVisible(false, 0);

            if GT.snoozeButton then GT.snoozeButton:Hide(); end
                if GT.dismissButton then GT.dismissButton:Hide(); end

                    GT.activeAlarm = false;
                end

    GT_CheckAlarms(secondsLeft, chestActive, cycleKey);
end

-- ------------------------------------------------------------
-- Init
-- ------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "GurubashiTimerEventFrame");
eventFrame:RegisterEvent("ADDON_LOADED");
eventFrame:RegisterEvent("PLAYER_LOGIN");

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "GurubashiTimer" then
        GurubashiTimerDB = GT_CopyDefaults(DEFAULT_DB, GurubashiTimerDB);
    elseif event == "PLAYER_LOGIN" then
        if not GurubashiTimerDB then
            GurubashiTimerDB = GT_CopyDefaults(DEFAULT_DB, {});
        else
            GurubashiTimerDB = GT_CopyDefaults(DEFAULT_DB, GurubashiTimerDB);
        end

        -- Migrate v1.1 one-off manual target into the new repeating-cycle offset model.
        if GurubashiTimerDB.manualTarget then
            local oldHour = GT_ClampNumber(GurubashiTimerDB.targetHour, 0, 23, 0);
            local oldMinute = GT_ClampNumber(GurubashiTimerDB.targetMinute, 0, 59, 0);
            GurubashiTimerDB.offsetMinutes = GT_PosMod((oldHour * 60) + oldMinute, 180);
            GurubashiTimerDB.useCustomCycle = true;
            GurubashiTimerDB.manualTarget = false;
        end
        GT_NormalizeOffset();

        GT_ResetAlarmCycle();
        GT_SyncServerMinute(true);
        GT_CreateMainFrame();
        GT_ApplySettings();

        SLASH_GURUBASHITIMER1 = "/gt";
        SLASH_GURUBASHITIMER2 = "/gurubashi";
        SlashCmdList["GURUBASHITIMER"] = GT_SlashHandler;

        if GT.frame then
            GT.frame:SetScript("OnUpdate", function()
                GT_UpdateDisplay(arg1 or 0);
            end);
        end

        GT_SafeChat("|cffffcc00[Gurubashi Timer]|r loaded. /gt options", 1, 0.82, 0);
    end
end);
