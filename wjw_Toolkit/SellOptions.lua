--[[---------------------------------------------------------------------------
    WuXianAutoSell —— 设置面板（可选）
    懒加载：只有第一次打开设置面板时才会创建界面元素。
    兼容 Retail 的 Settings API 与旧版 InterfaceOptions API。
-----------------------------------------------------------------------------]]

local ADDON_NAME, NS = ...

local PANEL_W    = 620
local PANEL_H    = 560
local MAX_ROWS   = 12
local ROW_HEIGHT = 20

local panel
local category
local registered = false
local rows       = {}
local clearButton
local clearArmed = false

local function GetDB()
    return NS.db
end

---------------------------------------------------------------- 名单刷新
local function Refresh()
    if not panel or not panel.countText then return end

    local db = GetDB()
    local entries = {}
    if db and db.blacklist then
        for id, name in pairs(db.blacklist) do
            entries[#entries + 1] = { id = id, name = name }
        end
    end
    table.sort(entries, function(a, b)
        local na, nb = tostring(a.name):lower(), tostring(b.name):lower()
        if na == nb then return a.id < b.id end
        return na < nb
    end)

    panel.countText:SetText(string.format("永不卖出名单：共 %d 项", #entries))

    for i = 1, MAX_ROWS do
        local fs = rows[i]
        if fs then
            local e = entries[i]
            if e then
                fs:SetText(string.format("%d. %s   ·   itemID %d", i, tostring(e.name), e.id))
                fs:Show()
            else
                fs:SetText("")
                fs:Hide()
            end
        end
    end

    if #entries > MAX_ROWS then
        panel.moreText:SetText(string.format("还有 %d 项未显示，可用 /wjw sell list 在聊天框查看完整名单。",
            #entries - MAX_ROWS))
        panel.moreText:Show()
    else
        panel.moreText:Hide()
    end

    if panel.enableCheck then
        panel.enableCheck:SetChecked(db and db.enabled and true or false)
    end
    if panel.verboseCheck then
        panel.verboseCheck:SetChecked(db and db.verbose and true or false)
    end
end
NS.RefreshOptions = Refresh

---------------------------------------------------------------- 界面构建
local function CreateCheckButton(parent, text, x, y, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local label = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(text)
    cb:SetScript("OnClick", onClick)
    return cb
end

local function BuildPanel()
    if panel then return panel end

    panel = CreateFrame("Frame", "WuXianAutoSellOptionsPanel", UIParent)
    panel.name = "wjw_工具箱 · 自动卖垃圾"
    panel:SetSize(PANEL_W, PANEL_H)

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("魔兽世界-无限 · 自动卖垃圾")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -44)
    subtitle:SetWidth(PANEL_W - 40)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("打开商人界面（会买卖的 NPC）后，自动把背包里所有灰色（品质 0）物品卖给商人；"
        .. "卖出结束后在聊天框提示件数与获得的金币。永不卖出名单里的物品不会被卖出。")

    panel.enableCheck = CreateCheckButton(panel,
        "打开商人界面时自动卖出灰色物品",
        24, -120,
        function(self)
            if NS.SetEnabled then
                NS.SetEnabled(self:GetChecked() and true or false)
            end
        end)

    panel.verboseCheck = CreateCheckButton(panel,
        "逐件提示卖出的物品（会在聊天框刷屏，默认关闭）",
        24, -152,
        function(self)
            local db = GetDB()
            if not db then return end
            db.verbose = self:GetChecked() and true or false
            NS.Print("逐件提示已" .. (db.verbose and "开启" or "关闭") .. "。")
        end)

    local divider = panel:CreateTexture(nil, "ARTWORK")
    if divider.SetColorTexture then
        divider:SetColorTexture(1, 1, 1, 0.12)
    else
        divider:SetTexture(1, 1, 1, 0.12)
    end
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -186)
    divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -186)

    panel.countText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    panel.countText:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -200)
    panel.countText:SetText("永不卖出名单：共 0 项")

    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 220, -201)
    hint:SetText("用 /wjw sell add 把鼠标指向的物品加入名单")

    for i = 1, MAX_ROWS do
        local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 26, -224 - (i - 1) * ROW_HEIGHT)
        fs:SetWidth(PANEL_W - 60)
        fs:SetJustifyH("LEFT")
        fs:SetText("")
        rows[i] = fs
    end

    panel.moreText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    panel.moreText:SetPoint("TOPLEFT", panel, "TOPLEFT", 26, -224 - MAX_ROWS * ROW_HEIGHT - 4)
    panel.moreText:SetWidth(PANEL_W - 60)
    panel.moreText:SetJustifyH("LEFT")
    panel.moreText:Hide()

    clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearButton:SetSize(170, 24)
    clearButton:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 20)
    clearButton:SetText("清空永不卖出名单")
    clearButton:SetScript("OnClick", function(self)
        local db = GetDB()
        if not db or not db.blacklist then return end

        local count = 0
        for _ in pairs(db.blacklist) do count = count + 1 end
        if count == 0 then
            NS.Print("永不卖出名单已经是空的。")
            return
        end

        if not clearArmed then
            clearArmed = true
            self:SetText(string.format("再点一次确认清空（%d 项）", count))
            if C_Timer and C_Timer.After then
                C_Timer.After(4, function()
                    clearArmed = false
                    if clearButton then clearButton:SetText("清空永不卖出名单") end
                end)
            end
            return
        end

        clearArmed = false
        self:SetText("清空永不卖出名单")
        if type(wipe) == "function" then
            wipe(db.blacklist)
        else
            for k in pairs(db.blacklist) do db.blacklist[k] = nil end
        end
        NS.Print(string.format("已清空永不卖出名单（%d 项）。", count))
        Refresh()
    end)

    local closeButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    closeButton:SetSize(100, 24)
    closeButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -16, 20)
    closeButton:SetText("关闭")
    closeButton:SetScript("OnClick", function()
        panel:Hide()
    end)

    local footer = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 200, 26)
    footer:SetText("命令速查：/wjw sell toggle · /wjw sell add · /wjw sell remove · /wjw sell list · /wjw sell clear")

    panel:SetScript("OnShow", Refresh)

    return panel
end

---------------------------------------------------------------- 注册与打开
local function RegisterCategory()
    if registered or not panel then return end
    registered = true

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, panel, panel.name)
        if ok and cat then
            category = cat
            if Settings.RegisterAddOnCategory then
                pcall(Settings.RegisterAddOnCategory, cat)
            end
            return
        end
    end

    if type(InterfaceOptions_AddCategory) == "function" then
        pcall(InterfaceOptions_AddCategory, panel)
    end
end

function NS.InitOptions()
    BuildPanel()
    RegisterCategory()
end

function NS.OpenOptions()
    BuildPanel()
    RegisterCategory()
    Refresh()

    if category and Settings and Settings.OpenToCategory then
        local ok, id = pcall(function() return category:GetID() end)
        if ok and id then
            local opened = pcall(Settings.OpenToCategory, id)
            if opened then return end
        end
    end

    if type(InterfaceOptionsFrame_OpenToCategory) == "function" then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
        return
    end

    panel:Show()
end
