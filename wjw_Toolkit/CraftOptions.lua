--[[---------------------------------------------------------------------------
    CraftOptions —— 专业技能升级规划 · 设置面板

    职责：
      * 在「界面 → 插件」里注册「wjw_工具箱 · 专业技能」设置页；
      * 展示当前已学专业与等级，编辑目标等级；
      * 维护「跳过材料 / 跳过配方」两个名单（与 /wjw craft skip 系列命令同一份存档）；
      * 开关「自动选中推荐配方」，并可从面板直接发起一次规划。

    约束：
      * 只读写 wjwCraftDB 与 Craft 的公开接口，不重复实现规划逻辑；
      * 本文件不注册任何斜杠命令；
      * Settings / InterfaceOptions / C_Timer 全部先 type() 守卫，接口缺失时静默降级。
-----------------------------------------------------------------------------]]

local ADDON_NAME, NS = ...
local Craft = NS and NS.Craft

-- 数据层（CraftCore.lua）未加载：本文件不建面板、不注册设置分类
if type(Craft) ~= "table" then
    return
end

---------------------------------------------------------------- 常量与状态
local PANEL_W  = 620
local PANEL_H  = 590
local MAX_ROWS = 8      -- 每个名单最多在面板里显示的行数
local ROW_HEIGHT = 17
local COL_W    = 286    -- 左右两列名单各自的宽度
local CLEAR_CONFIRM_SECONDS = 4

local panel
local category
local registered = false

-- 「清空」按钮的二次确认状态。
-- clearArmToken[kind] 保存当前这次「已按下第一次」的令牌，0 表示未进入确认状态；
-- clearTokenCounter 单调递增，保证每次 arm 拿到的令牌都不同。
-- 定时器回调只在「令牌仍是自己发出的那一个」时才复位，因此重复 arm、
-- 或已经确认清空之后，旧定时器都不会提前复位按钮
-- （SellOptions 里每次 arm 都新起定时器、彼此覆盖的写法在这里被修正）。
local clearArmToken = { materials = 0, recipes = 0 }
local clearTokenCounter = 0

-- 两个名单的元信息：存档字段、显示标题
local LIST_KINDS = {
    materials = { key = "skipMaterials", title = "跳过材料" },
    recipes   = { key = "skipRecipes",   title = "跳过配方" },
}

---------------------------------------------------------------- 基础工具
local function Trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Say(msg)
    if type(Craft.Print) == "function" then
        Craft.Print(msg)
    elseif type(NS.Print) == "function" then
        NS.Print(msg)
    elseif type(print) == "function" then
        print(tostring(msg))
    end
end

-- 名单去重口径与 CraftCommand.lua 的 IsNameMatch 保持一致：
-- 大小写不敏感的「任一方包含另一方」视为同一项
local function IsSameName(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        return false
    end
    local x = string.lower(a)
    local y = string.lower(b)
    if x == "" or y == "" then
        return false
    end
    return string.find(x, y, 1, true) ~= nil or string.find(y, x, 1, true) ~= nil
end

local function FindInList(list, name)
    for i, entry in ipairs(list) do
        if IsSameName(entry, name) then
            return i
        end
    end
    return nil
end

-- 存档可能在 ADDON_LOADED 之后才由 CraftCommand.lua 建好；这里做同样的兜底
local function EnsureDB()
    if type(wjwCraftDB) ~= "table" then
        wjwCraftDB = {}
    end
    if type(wjwCraftDB.skipMaterials) ~= "table" then
        wjwCraftDB.skipMaterials = {}
    end
    if type(wjwCraftDB.skipRecipes) ~= "table" then
        wjwCraftDB.skipRecipes = {}
    end
    if type(wjwCraftDB.targetLevel) ~= "number" then
        wjwCraftDB.targetLevel = nil
    end
    return wjwCraftDB
end

local function GetList(kind)
    local meta = LIST_KINDS[kind]
    local db = EnsureDB()
    return db[meta.key], meta
end

-- 自动选中接口（CraftAutoSelect.lua）存在且导出齐全时才可用
local function GetAutoSelect()
    local auto = Craft.AutoSelect
    if type(auto) ~= "table" then
        return nil
    end
    if type(auto.SetEnabled) ~= "function" or type(auto.IsEnabled) ~= "function" then
        return nil
    end
    return auto
end

-- 行内高亮接口（CraftHighlight.lua）存在且导出齐全时才可用
local function GetHighlight()
    local highlight = Craft.Highlight
    if type(highlight) ~= "table" then
        return nil
    end
    if type(highlight.SetEnabled) ~= "function" or type(highlight.IsEnabled) ~= "function" then
        return nil
    end
    return highlight
end

-- 训练师地图标记接口（CraftTrainerMarker.lua）存在且导出齐全时才可用
local function GetTrainerMarker()
    local marker = Craft.TrainerMarker
    if type(marker) ~= "table" then
        return nil
    end
    if type(marker.SetEnabled) ~= "function" or type(marker.IsEnabled) ~= "function" then
        return nil
    end
    return marker
end

---------------------------------------------------------------- 面板刷新
local function RefreshProfessions()
    if not panel or not panel.profText then return end

    local profs = {}
    if type(Craft.GetProfessions) == "function" then
        local ok, list = pcall(Craft.GetProfessions)
        if ok and type(list) == "table" then
            profs = list
        end
    end

    if #profs == 0 then
        panel.profText:SetText("未学习任何专业技能")
        return
    end

    local lines = {}
    for i, prof in ipairs(profs) do
        if i > 5 then
            break
        end
        lines[#lines + 1] = string.format("%s　等级 %s / %s",
            tostring(prof.name or "未知专业"),
            tostring(prof.level or "?"),
            tostring(prof.maxLevel or "?"))
    end
    if #profs > 5 then
        lines[#lines + 1] = string.format("……另有 %d 个专业未显示", #profs - 5)
    end
    panel.profText:SetText(table.concat(lines, "\n"))
end

local function RefreshTargetBox()
    if not panel or not panel.targetBox then return end
    -- 用户正在输入时不覆盖
    if type(panel.targetBox.HasFocus) == "function" and panel.targetBox:HasFocus() then
        return
    end
    local db = EnsureDB()
    if type(db.targetLevel) == "number" then
        panel.targetBox:SetText(tostring(db.targetLevel))
    else
        panel.targetBox:SetText("")
    end
end

local function RefreshList(kind)
    if not panel then return end
    local rows       = panel.listRows and panel.listRows[kind]
    local countText  = panel.listCount and panel.listCount[kind]
    local moreText   = panel.listMore and panel.listMore[kind]
    if not rows or not countText or not moreText then return end

    local list, meta = GetList(kind)
    countText:SetText(string.format("%s（共 %d 项）", meta.title, #list))

    for i = 1, MAX_ROWS do
        local row = rows[i]
        local entry = list[i]
        if entry ~= nil then
            row.text:SetText(tostring(entry))
            row.text:Show()
            row.delete.entryName = entry
            row.delete:Show()
        else
            row.text:SetText("")
            row.text:Hide()
            row.delete.entryName = nil
            row.delete:Hide()
        end
    end

    if #list > MAX_ROWS then
        moreText:SetText(string.format("还有 %d 项未显示，可用 /wjw craft list 查看完整名单。",
            #list - MAX_ROWS))
        moreText:Show()
    else
        moreText:Hide()
    end
end

local function RefreshAutoSelect()
    if not panel or not panel.autoSelectCheck then return end
    local auto = GetAutoSelect()
    if not auto then
        panel.autoSelectCheck:SetChecked(false)
        return
    end
    local ok, enabled = pcall(auto.IsEnabled)
    panel.autoSelectCheck:SetChecked(ok and enabled and true or false)
end

local function RefreshHighlight()
    if not panel or not panel.highlightCheck then return end
    local highlight = GetHighlight()
    if not highlight then
        panel.highlightCheck:SetChecked(false)
        return
    end
    local ok, enabled = pcall(highlight.IsEnabled)
    panel.highlightCheck:SetChecked(ok and enabled and true or false)
end

local function RefreshTrainerMarker()
    if not panel or not panel.trainerMarkerCheck then return end
    local marker = GetTrainerMarker()
    if not marker then
        panel.trainerMarkerCheck:SetChecked(false)
        return
    end
    local ok, enabled = pcall(marker.IsEnabled)
    panel.trainerMarkerCheck:SetChecked(ok and enabled and true or false)
end

-- 面板显示时刷新全部动态内容
local function Refresh()
    RefreshProfessions()
    RefreshTargetBox()
    RefreshList("materials")
    RefreshList("recipes")
    RefreshAutoSelect()
    RefreshHighlight()
    RefreshTrainerMarker()
end

---------------------------------------------------------------- 名单操作
local function AddEntry(kind)
    if not panel then return end
    local box = panel.listInput and panel.listInput[kind]
    if not box then return end

    local list, meta = GetList(kind)
    local name = Trim(box:GetText())
    if name == "" then
        Say(string.format("请先输入要加入「%s」的名称。", meta.title))
        return
    end
    if FindInList(list, name) then
        Say(string.format("「%s」已在%s名单中。", name, meta.title))
        box:SetText("")
        return
    end

    list[#list + 1] = name
    box:SetText("")
    box:ClearFocus()
    Say(string.format("已加入%s名单：「%s」。", meta.title, name))
    RefreshList(kind)
end

local function RemoveEntry(kind, name)
    local list, meta = GetList(kind)
    if type(name) ~= "string" then
        return
    end

    local removed = 0
    for i = #list, 1, -1 do
        if IsSameName(list[i], name) then
            table.remove(list, i)
            removed = removed + 1
        end
    end

    if removed > 0 then
        Say(string.format("已从%s名单移除「%s」。", meta.title, name))
        RefreshList(kind)
    end
end

local function ResetClearButton(kind)
    local button = panel and panel.listClear and panel.listClear[kind]
    if button then
        button:SetText("清空")
    end
end

-- 进入「再点一次确认」状态；重复 arm 不会让旧定时器影响新状态
local function ArmClear(kind)
    clearTokenCounter = clearTokenCounter + 1
    local token = clearTokenCounter
    clearArmToken[kind] = token

    local button = panel and panel.listClear and panel.listClear[kind]
    if button then
        button:SetText("确认清空")
    end

    -- C_Timer 不可用时保持确认状态，再点一次同样能清空
    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        C_Timer.After(CLEAR_CONFIRM_SECONDS, function()
            -- 期间已确认清空、或又按了一次（令牌已变）：旧定时器不做事
            if clearArmToken[kind] ~= token then
                return
            end
            clearArmToken[kind] = 0
            ResetClearButton(kind)
        end)
    end
end

local function ClearList(kind)
    local list, meta = GetList(kind)
    if #list == 0 then
        Say(string.format("%s名单已经是空的。", meta.title))
        return
    end

    if clearArmToken[kind] == 0 then
        ArmClear(kind)
        return
    end

    local count = #list
    clearArmToken[kind] = 0
    ResetClearButton(kind)

    if type(wipe) == "function" then
        wipe(list)
    else
        for i = #list, 1, -1 do
            list[i] = nil
        end
    end

    Say(string.format("已清空%s名单（%d 项）。", meta.title, count))
    RefreshList(kind)
end

---------------------------------------------------------------- 目标等级与规划
local function GetTargetText()
    if not panel or not panel.targetBox then
        return ""
    end
    return Trim(panel.targetBox:GetText())
end

-- 回车保存目标等级：空 = 规划到断点；非法输入清空为 nil 并提示
local function CommitTargetLevel()
    local db = EnsureDB()
    local text = GetTargetText()

    if text == "" then
        db.targetLevel = nil
        if panel and panel.targetBox then
            panel.targetBox:SetText("")
        end
        Say("目标等级已清空：规划到现有配方断点。")
        return
    end

    local level = tonumber(text)
    if not level or level <= 0 or level ~= math.floor(level) then
        db.targetLevel = nil
        if panel and panel.targetBox then
            panel.targetBox:SetText("")
        end
        Say("目标等级必须是正整数，已清空（改为规划到现有配方断点）。")
        return
    end

    db.targetLevel = level
    if panel and panel.targetBox then
        panel.targetBox:SetText(tostring(level))
    end
    Say(string.format("目标等级已保存：%d。", level))
end

local function StartPlan()
    if type(Craft.Command) ~= "function" then
        Say("命令入口未加载（CraftCommand.lua），无法开始规划。")
        return
    end

    local text = GetTargetText()
    if text ~= "" then
        local level = tonumber(text)
        if not level or level <= 0 or level ~= math.floor(level) then
            -- 非法输入按「清空为断点模式」处理，并中止本次规划
            EnsureDB().targetLevel = nil
            if panel and panel.targetBox then
                panel.targetBox:SetText("")
            end
            Say("目标等级必须是正整数，已清空；留空时按现有配方断点规划。")
            return
        end
    end

    -- 与 /wjw craft 走同一个入口：空字符串 = 规划到断点
    Craft.Command(text)
end

local function OnAutoSelectClick(checkButton)
    local auto = GetAutoSelect()
    if not auto then
        return
    end

    local enabled = checkButton:GetChecked() and true or false
    local ok = pcall(auto.SetEnabled, enabled)
    if not ok then
        checkButton:SetChecked(not enabled)
        Say("切换「自动选中推荐配方」开关失败。")
        return
    end
    Say("自动选中推荐配方已" .. (enabled and "开启" or "关闭") .. "。")
end

local function OnHighlightClick(checkButton)
    local highlight = GetHighlight()
    if not highlight then
        return
    end

    local enabled = checkButton:GetChecked() and true or false
    local ok = pcall(highlight.SetEnabled, enabled)
    if not ok then
        checkButton:SetChecked(not enabled)
        Say("切换「配方行内高亮」开关失败。")
        return
    end
    Say("配方行内高亮已" .. (enabled and "开启" or "关闭") .. "。")
end

local function OnTrainerMarkerClick(checkButton)
    local marker = GetTrainerMarker()
    if not marker then
        return
    end

    local enabled = checkButton:GetChecked() and true or false
    local ok = pcall(marker.SetEnabled, enabled)
    if not ok then
        checkButton:SetChecked(not enabled)
        Say("切换「在地图上标记最近的专业训练师」开关失败。")
        return
    end
    Say("训练师地图标记已" .. (enabled and "开启" or "关闭") .. "。")
end

---------------------------------------------------------------- 界面构建
local function CreateDivider(parent, y)
    local line = parent:CreateTexture(nil, "ARTWORK")
    if type(line.SetColorTexture) == "function" then
        line:SetColorTexture(1, 1, 1, 0.12)
    else
        line:SetTexture(1, 1, 1, 0.12)
    end
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
    line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -16, y)
    return line
end

local function CreateCheckButton(parent, text, x, y, onClick)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local label = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetText(text)
    cb.label = label
    if type(onClick) == "function" then
        cb:SetScript("OnClick", onClick)
    end
    return cb
end

-- 一列名单：标题、最多 8 行（每行带 × 删除）、超出提示、输入框与按钮
local function BuildListColumn(kind, x, headerY)
    local meta = LIST_KINDS[kind]

    local countText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    countText:SetPoint("TOPLEFT", panel, "TOPLEFT", x, headerY)
    countText:SetText(meta.title .. "（共 0 项）")
    panel.listCount[kind] = countText

    local rows = {}
    for i = 1, MAX_ROWS do
        local rowY = headerY - 20 - (i - 1) * ROW_HEIGHT

        local text = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", panel, "TOPLEFT", x + 10, rowY)
        text:SetWidth(COL_W - 40)
        text:SetJustifyH("LEFT")
        text:SetText("")
        text:Hide()

        local delete = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        delete:SetSize(20, 16)
        delete:SetPoint("TOPLEFT", panel, "TOPLEFT", x + COL_W - 22, rowY + 1)
        delete:SetText("×")
        delete:SetScript("OnClick", function(self)
            RemoveEntry(kind, self.entryName)
        end)
        delete:Hide()

        rows[i] = { text = text, delete = delete }
    end
    panel.listRows[kind] = rows

    local moreText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    moreText:SetPoint("TOPLEFT", panel, "TOPLEFT", x + 10, headerY - 20 - MAX_ROWS * ROW_HEIGHT)
    moreText:SetWidth(COL_W - 10)
    moreText:SetJustifyH("LEFT")
    moreText:Hide()
    panel.listMore[kind] = moreText

    local inputY = headerY - 20 - MAX_ROWS * ROW_HEIGHT - 22

    local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    box:SetSize(130, 24)
    box:SetPoint("TOPLEFT", panel, "TOPLEFT", x, inputY)
    box:SetAutoFocus(false)
    box:SetScript("OnEnterPressed", function()
        AddEntry(kind)
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    panel.listInput[kind] = box

    local addButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    addButton:SetSize(46, 24)
    addButton:SetPoint("TOPLEFT", panel, "TOPLEFT", x + 136, inputY)
    addButton:SetText("添加")
    addButton:SetScript("OnClick", function()
        AddEntry(kind)
    end)

    local clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearButton:SetSize(74, 24)
    clearButton:SetPoint("TOPLEFT", panel, "TOPLEFT", x + 188, inputY)
    clearButton:SetText("清空")
    clearButton:SetScript("OnClick", function()
        ClearList(kind)
    end)
    panel.listClear[kind] = clearButton
end

local function BuildPanel()
    if panel then
        return panel
    end

    panel = CreateFrame("Frame", "wjw_CraftOptionsPanel", UIParent)
    panel.name = "wjw_工具箱 · 专业技能"
    panel:SetSize(PANEL_W, PANEL_H)

    panel.listRows = {}
    panel.listCount = {}
    panel.listMore = {}
    panel.listInput = {}
    panel.listClear = {}

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("wjw_工具箱 · 专业技能")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -44)
    subtitle:SetWidth(PANEL_W - 32)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("点「开始规划」后，在聊天框给出从当前等级升到目标等级所需制作的配方与材料；"
        .. "跳过名单里的材料与配方不会被选入规划。")

    CreateDivider(panel, -80)

    -- 当前专业与等级
    local profLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    profLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -90)
    profLabel:SetText("当前专业与等级")

    panel.profText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    panel.profText:SetPoint("TOPLEFT", panel, "TOPLEFT", 26, -112)
    panel.profText:SetWidth(PANEL_W - 52)
    panel.profText:SetJustifyH("LEFT")
    panel.profText:SetText("")

    CreateDivider(panel, -190)

    -- 目标等级
    local targetLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    targetLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -200)
    targetLabel:SetText("目标等级")

    panel.targetBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    panel.targetBox:SetSize(96, 24)
    panel.targetBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 92, -193)
    panel.targetBox:SetAutoFocus(false)
    panel.targetBox:SetNumeric(true)
    panel.targetBox:SetScript("OnEnterPressed", function(self)
        CommitTargetLevel()
        self:ClearFocus()
    end)
    panel.targetBox:SetScript("OnEscapePressed", function(self)
        -- 先失焦，否则 RefreshTargetBox 的「正在输入不覆盖」判断会跳过复位
        self:ClearFocus()
        RefreshTargetBox()
    end)

    local targetHint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    targetHint:SetPoint("TOPLEFT", panel, "TOPLEFT", 196, -201)
    targetHint:SetText("留空 = 按断点规划")

    -- 自动选中推荐配方
    local auto = GetAutoSelect()
    panel.autoSelectCheck = CreateCheckButton(panel,
        auto and "自动选中推荐配方" or "自动选中推荐配方（不可用）",
        300, -193,
        OnAutoSelectClick)
    if not auto then
        panel.autoSelectCheck:Disable()
    end

    -- 在配方列表中高亮推荐配方（实验性）
    local highlight = GetHighlight()
    panel.highlightCheck = CreateCheckButton(panel,
        highlight and "在配方列表中高亮推荐配方（实验性，版本更新后可能需要修复）"
            or "在配方列表中高亮推荐配方（不可用）",
        16, -224,
        OnHighlightClick)
    if type(panel.highlightCheck.label.SetWidth) == "function" then
        panel.highlightCheck.label:SetWidth(PANEL_W - 60)
    end
    if type(panel.highlightCheck.label.SetJustifyH) == "function" then
        panel.highlightCheck.label:SetJustifyH("LEFT")
    end
    if not highlight then
        panel.highlightCheck:Disable()
    end

    -- 在地图上标记最近的专业训练师
    local marker = GetTrainerMarker()
    panel.trainerMarkerCheck = CreateCheckButton(panel,
        marker and "在地图上标记最近的专业训练师"
            or "在地图上标记最近的专业训练师（不可用）",
        16, -254,
        OnTrainerMarkerClick)
    if not marker then
        panel.trainerMarkerCheck:Disable()
    end

    CreateDivider(panel, -286)

    -- 跳过名单
    local skipLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    skipLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -296)
    skipLabel:SetText("跳过名单（规划时排除的材料与配方）")

    BuildListColumn("materials", 16, -326)
    BuildListColumn("recipes", 318, -326)

    -- 底部按钮
    local startButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    startButton:SetSize(120, 24)
    startButton:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 20)
    startButton:SetText("开始规划")
    startButton:SetScript("OnClick", StartPlan)

    local closeButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    closeButton:SetSize(100, 24)
    closeButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -16, 20)
    closeButton:SetText("关闭")
    closeButton:SetScript("OnClick", function()
        panel:Hide()
    end)

    local footer = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 150, 26)
    footer:SetWidth(340)
    footer:SetJustifyH("LEFT")
    footer:SetText("跳过名单也可用 /wjw craft skip <名称> 添加，/wjw craft list 查看完整名单。")

    panel:SetScript("OnShow", Refresh)

    -- 面板建好时先按存档填一次目标等级（此后每次显示由 OnShow 刷新）
    RefreshTargetBox()

    return panel
end

---------------------------------------------------------------- 注册
local function RegisterCategory()
    if registered or not panel then
        return
    end
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

-- 在 ADDON_LOADED 之后建面板并注册分类：此时存档（wjwCraftDB）已载入
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event ~= "ADDON_LOADED" or arg1 ~= ADDON_NAME then
        return
    end
    self:UnregisterEvent("ADDON_LOADED")
    BuildPanel()
    RegisterCategory()
end)
