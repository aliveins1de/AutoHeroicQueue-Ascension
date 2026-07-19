-- AutoHeroicQueue (Ascension edition)
-- При входе в игру автоматически выставляет в дропдауне "Тип" сохранённый выбор.
-- /ahq - открыть окно выбора нужного варианта из списка (сохраняется навсегда).

AutoHeroicQueueDB = AutoHeroicQueueDB or {}

local AHQ = CreateFrame("Frame")
AHQ:RegisterEvent("PLAYER_ENTERING_WORLD")

local DEBUG = true

local function Debug(msg)
    if DEBUG then
        print("|cff33ff99[AutoHeroicQueue]|r " .. msg)
    end
end

-- Имена фреймов на Ascension (уточнены по /fstack, см. скриншоты).
-- Если после патча имена сменятся - поменяй тут.
local ROOT_FRAME_NAME   = "AscensionLFGFrame"
local LFD_FRAME_NAME    = "AscensionPVEFrameLFDFrame"
local TYPE_DROPDOWN_NAME = "AscensionPVEFrameLFDFrameTypeDropDown"

-- Собирает список всех вариантов, которые показываются в дропдауне "Тип"
-- (те же условия, что использует сама Blizzard в LFDQueueFrameTypeDropDown_Initialize)
local function GetAllTypeOptions()
    local options = {}

    for i = 1, GetNumRandomDungeons() do
        local id, name = GetLFGRandomDungeonInfo(i)
        if id then
            local _, _, minLevel, maxLevel, _, _, _, expansionLevel = GetLFGDungeonInfo(id)
            local myLevel = UnitLevel("player")
            local isDisplayable = myLevel >= minLevel and myLevel <= maxLevel and EXPANSION_LEVEL >= expansionLevel
            if isDisplayable then
                table.insert(options, { id = id, name = name })
            end
        end
    end

    return options
end

-- Эмулирует выбор пункта в стандартном UIDropDownMenu, к которому привязан
-- дропдаун "Тип" на Ascension. Мы не знаем их внутреннюю set-функцию,
-- но нам это и не нужно: открываем меню (Ascension сам заполнит
-- DropDownList1 актуальными пунктами через свой Initialize) и жмём
-- нужную кнопку по тексту - это триггернёт их родной OnClick/func так,
-- будто кликнул сам игрок.
local function ClickDropdownOptionByName(dropDown, optionName)
    if not dropDown then
        return false
    end

    ToggleDropDownMenu(1, nil, dropDown, "cursor", 0, 0)

    local found = false
    local maxButtons = UIDROPDOWNMENU_MAXBUTTONS or 32
    for i = 1, maxButtons do
        local btn = _G["DropDownList1Button" .. i]
        if btn and btn:IsShown() then
            local text = btn:GetText()
            if text == optionName then
                btn:Click()
                found = true
                break
            end
        end
    end

    if not found then
        CloseDropDownMenus()
    end

    return found
end

local function ApplySavedType()
    local lfdFrame = _G[LFD_FRAME_NAME]
    if not lfdFrame then
        return
    end
    if not AutoHeroicQueueDB.selectedDungeonID then
        Debug("Сохранённого выбора нет (похоже, SavedVariables не записались с прошлой сессии). Набери /ahq и выбери заново.")
        return
    end

    -- IsLFGDungeonJoinable может отсутствовать/вести себя иначе на Ascension -
    -- страхуемся pcall'ом, чтобы не сломать остальное, если функции нет.
    local ok, joinable = pcall(IsLFGDungeonJoinable, AutoHeroicQueueDB.selectedDungeonID)
    if ok and joinable == false then
        Debug("Сохранённый выбор ('" .. tostring(AutoHeroicQueueDB.selectedDungeonName) .. "') сейчас недоступен, пропуск.")
        return
    end

    local dropDown = _G[TYPE_DROPDOWN_NAME]
    if not dropDown then
        Debug("Не найден дропдаун типа (" .. TYPE_DROPDOWN_NAME .. "). Возможно, имя фрейма изменилось - проверь через /fstack.")
        return
    end

    local success = ClickDropdownOptionByName(dropDown, AutoHeroicQueueDB.selectedDungeonName)
    if success then
        Debug("Тип очереди выставлен: " .. tostring(AutoHeroicQueueDB.selectedDungeonName))
    else
        Debug("Не удалось найти пункт '" .. tostring(AutoHeroicQueueDB.selectedDungeonName) .. "' в дропдауне сейчас.")
    end
end

AHQ:SetScript("OnEvent", function(self, event, ...)
    local waitFrame = CreateFrame("Frame")
    local elapsedTotal = 0
    waitFrame:SetScript("OnUpdate", function(self, elapsed)
        elapsedTotal = elapsedTotal + elapsed
        if elapsedTotal >= 3 then
            self:SetScript("OnUpdate", nil)
            ApplySavedType()
        end
    end)
end)

do
    local rootFrame = _G[ROOT_FRAME_NAME]
    if rootFrame then
        rootFrame:HookScript("OnShow", function()
            ApplySavedType()
        end)
    else
        Debug("Не найден корневой фрейм (" .. ROOT_FRAME_NAME .. ") для автопривязки к OnShow - автовыбор при открытии окна вручную работать не будет, только при входе в игру.")
    end
end

----------------------------------------------------------------
-- UI выбора подземелья
----------------------------------------------------------------

local function SelectDungeon(id, name)
    AutoHeroicQueueDB.selectedDungeonID = id
    AutoHeroicQueueDB.selectedDungeonName = name
    Debug("Сохранён выбор: " .. name)
    ApplySavedType()
    if AutoHeroicQueueConfigFrame then
        AutoHeroicQueueConfigFrame:Hide()
    end
end

-- Возвращает объект E из ElvUI, если он загружен, иначе nil
local function GetElvUI()
    if _G.ElvUI then
        local E = unpack(_G.ElvUI)
        return E
    end
    return nil
end

-- Безопасно дёргает метод модуля Skins: не падает, если модуля/метода
-- нет или он ещё не готов (частая история на кастомных серверах,
-- где версия/сборка ElvUI отличается от привычной).
-- Возвращает true, если метод реально нашёлся и выполнился без ошибок.
local function SafeSkin(S, methodName, ...)
    if not S or type(S[methodName]) ~= "function" then
        return false
    end
    local ok, err = pcall(S[methodName], S, ...)
    if not ok then
        Debug("ElvUI skin (" .. methodName .. ") не сработал: " .. tostring(err))
        return false
    end
    return true
end

local function BuildConfigFrame()
    if AutoHeroicQueueConfigFrame then
        return AutoHeroicQueueConfigFrame
    end

    local options = GetAllTypeOptions()
    local E = GetElvUI()
    local S = E and E:GetModule("Skins")

    local PADDING = 16
    local BUTTON_HEIGHT = 24
    local BUTTON_GAP = 4
    local FRAME_WIDTH = 320

    local frame = CreateFrame("Frame", "AutoHeroicQueueConfigFrame", UIParent)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetPoint("CENTER")

    local numOptions = #options
    local height = 78 + numOptions * (BUTTON_HEIGHT + BUTTON_GAP)
    frame:SetSize(FRAME_WIDTH, height)

    local skinned = S and SafeSkin(S, "HandleFrame", frame, true)
    if not skinned then
        frame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
    end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -PADDING)
    title:SetText("AutoHeroicQueue")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -2, -2)
    if S then
        SafeSkin(S, "HandleCloseButton", closeButton)
    end

    local current = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    current:SetPoint("TOP", title, "BOTTOM", 0, -6)
    current:SetTextColor(0.2, 1, 0.4)
    current:SetText(AutoHeroicQueueDB.selectedDungeonName and
        ("Выбрано: " .. AutoHeroicQueueDB.selectedDungeonName) or
        "Пока ничего не выбрано")
    frame.currentText = current

    local buttonWidth = FRAME_WIDTH - PADDING * 2
    local lastButton
    for _, option in ipairs(options) do
        local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        btn:SetSize(buttonWidth, BUTTON_HEIGHT)
        btn:SetText(option.name)
        if lastButton then
            btn:SetPoint("TOP", lastButton, "BOTTOM", 0, -BUTTON_GAP)
        else
            btn:SetPoint("TOP", current, "BOTTOM", 0, -14)
        end
        btn:SetScript("OnClick", function()
            SelectDungeon(option.id, option.name)
        end)

        if S then
            SafeSkin(S, "HandleButton", btn)
        end

        if AutoHeroicQueueDB.selectedDungeonID == option.id then
            local textObj = btn:GetFontString()
            if textObj then
                textObj:SetTextColor(0.2, 1, 0.4)
            end
        end

        lastButton = btn
    end

    frame:Hide()
    return frame
end

local function ToggleConfigFrame()
    if AutoHeroicQueueConfigFrame and AutoHeroicQueueConfigFrame:IsShown() then
        AutoHeroicQueueConfigFrame:Hide()
        return
    end

    if AutoHeroicQueueConfigFrame then
        AutoHeroicQueueConfigFrame:Hide()
        AutoHeroicQueueConfigFrame:SetParent(nil)
        AutoHeroicQueueConfigFrame = nil
    end

    local frame = BuildConfigFrame()
    frame:Show()
end

SLASH_AUTOHEROICQUEUE1 = "/ahq"
SlashCmdList["AUTOHEROICQUEUE"] = function()
    ToggleConfigFrame()
end

Debug("Аддон загружен (Ascension edition). /ahq - открыть меню выбора подземелья.")
