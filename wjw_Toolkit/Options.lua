--[[---------------------------------------------------------------------------
    wjw_工具箱 —— 任务寻路设置面板
    直接读写全局 QuestPath 表（寻路模块不使用 local NS 命名空间）。
    兼容 Retail 的 Settings API 与旧版 InterfaceOptions API。
-----------------------------------------------------------------------------]]

local ADDON_NAME, NS = ...
-- 说明：NS 是卖垃圾模块使用的命名空间，本文件不往 NS 写任何字段。

local PANEL_W = 620
local PANEL_H = 380

local panel
local category
local registered = false

---------------------------------------------------------------- 面板刷新
-- 存档在 ADDON_LOADED 之后才载入，因此建面板时不读值，只在面板显示时按当前值刷新
local function Refresh()
    if not panel then return end

    if panel.autoTrackCheck then
        panel.autoTrackCheck:SetChecked(QuestPath.autoTrack and true or false)
    end
    if panel.arrowCheck then
        panel.arrowCheck:SetChecked(QuestPath.arrowEnabled and true or false)
    end
    if panel.quietCheck then
        panel.quietCheck:SetChecked(QuestPath.quiet and true or false)
    end
end

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

    panel = CreateFrame("Frame", "wjw_QuestPathOptionsPanel", UIParent)
    panel.name = "wjw_工具箱 · 任务寻路"
    panel:SetSize(PANEL_W, PANEL_H)

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("wjw_工具箱 · 任务寻路")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -44)
    subtitle:SetWidth(PANEL_W - 40)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("打开追踪的任务或选中任务时，自动在小地图、屏幕与世界地图上画出指向任务目的地的连线。"
        .. "游戏没有给出任务点的任务不会画线。命令：/qp 查看当前目标与距离。")

    panel.autoTrackCheck = CreateCheckButton(panel,
        "自动跟随追踪/选中的任务",
        24, -110,
        function(self)
            QuestPath.autoTrack = self:GetChecked() and true or false
            QuestPath.SaveSettings()
        end)

    panel.arrowCheck = CreateCheckButton(panel,
        "显示屏幕箭头",
        24, -142,
        function(self)
            QuestPath.arrowEnabled = self:GetChecked() and true or false
            QuestPath.SaveSettings()
        end)

    panel.quietCheck = CreateCheckButton(panel,
        "静默模式（不输出自动追踪提示）",
        24, -174,
        function(self)
            QuestPath.quiet = self:GetChecked() and true or false
            QuestPath.SaveSettings()
        end)

    local closeButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    closeButton:SetSize(100, 24)
    closeButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -16, 20)
    closeButton:SetText("关闭")
    closeButton:SetScript("OnClick", function()
        panel:Hide()
    end)

    panel:SetScript("OnShow", Refresh)

    return panel
end

---------------------------------------------------------------- 注册
local function RegisterCategory()
    if registered or not panel then return end
    registered = true

    if type(Settings) == "table" and type(Settings.RegisterCanvasLayoutCategory) == "function" then
        local ok, cat = pcall(Settings.RegisterCanvasLayoutCategory, panel, panel.name)
        if ok and cat then
            category = cat
            if type(Settings.RegisterAddOnCategory) == "function" then
                pcall(Settings.RegisterAddOnCategory, cat)
            end
            return
        end
    end

    if type(InterfaceOptions_AddCategory) == "function" then
        pcall(InterfaceOptions_AddCategory, panel)
    end
end

-- 在 ADDON_LOADED 之后注册：此时 QuestPath 表已随文件加载建立，存档也已载入
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if arg1 ~= ADDON_NAME then return end
    self:UnregisterEvent("ADDON_LOADED")
    BuildPanel()
    RegisterCategory()
end)
