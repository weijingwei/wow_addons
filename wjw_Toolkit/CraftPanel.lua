--[[---------------------------------------------------------------------------
    CraftPanel —— 专业技能升级规划 · 制作队列浮动面板

    职责：
      * 在专业制作窗口旁边显示一个可拖动的浮动面板，展示 Craft.BuildPlan 的
        分段规划（每段：等级区间 + 推荐配方 + 次数，缩进行显示材料缺口）；
      * 不负责规划计算、不读配方原始数据、不注册斜杠命令。

    显示规则：
      * 专业窗口（ProfessionsFrame）打开时按存档 wjwCraftDB.showPanel 决定是否
        显示（默认显示，关闭面板后记住 false）；
      * 专业窗口关闭时本面板一起隐藏；
      * 面板显示期间每 3 秒自动刷新一次，关闭后停止，避免频繁统计材料。

    对外接口：
      * Craft.Panel.Show() / Hide() / Toggle() / Refresh()
        供后续设置页或命令接入，不依赖任何斜杠命令。

    兼容与安全：
      * 面板模板 BasicFrameTemplateWithInset 缺失时依次退回 BackdropTemplate、
        空模板（用字符串常量 + pcall 判断是否创建成功）；
      * 对 ProfessionsFrame / C_Timer 等全部先 type() 守卫，失败静默降级。
-----------------------------------------------------------------------------]]

local ADDON_NAME, NS = ...

-- CraftCore.lua 未加载或未导出 NS.Craft 时静默退出
local Craft = NS and NS.Craft
if type(Craft) ~= "table" then
    return
end

---------------------------------------------------------------- 常量
local PANEL_WIDTH           = 360
local PANEL_HEIGHT          = 420
local MAX_ROWS              = 12      -- 内容区最多 12 行 FontString
local ROW_HEIGHT            = 16
local AUTO_REFRESH_SECONDS  = 3       -- 面板打开时的自动刷新间隔
local MAX_DATA_ATTEMPTS     = 5       -- 配方数据读取失败时的重试次数（每次 1 秒）
local FRAME_HOOK_MAX_RETRIES = 10     -- 专业界面晚加载时最多再等 10 秒

local TEMPLATE_PRIMARY  = "BasicFrameTemplateWithInset"
local TEMPLATE_FALLBACK = "BackdropTemplate"

local PANEL_TITLE          = "wjw_工具箱 · 制作队列"
local MSG_OPEN_PROFESSION  = "请打开专业制作窗口"
local MSG_READING          = "正在读取配方数据…"
local BOTTOM_NOTE          = "估算口径：橙 100% / 黄 60% / 绿 25%（社区经验，非官方）"

local COLOR_HEADER = { 1.00, 0.82, 0.00 }
local COLOR_TEXT   = { 1.00, 1.00, 1.00 }
local COLOR_DIM    = { 0.72, 0.72, 0.72 }
local COLOR_WARN   = { 1.00, 0.55, 0.30 }

---------------------------------------------------------------- 状态
local panel          -- 面板本体（懒创建）
local rows           = {}   -- 内容区的 12 行文本
local ticker         -- 3 秒自动刷新计时器
local refreshSeq     = 0    -- 刷新序号，用于作废过期的排队重试
local frameHooked    = false

-- 前向声明：StartTicker 的计时回调需要调用 Refresh，
-- Refresh 需要调用 EnsurePanel（二者都在文件后半段赋值）
local Refresh
local EnsurePanel

---------------------------------------------------------------- 存档
local function GetDB()
    if type(wjwCraftDB) == "table" then
        return wjwCraftDB
    end
    return nil
end

-- 写面板开关时确保存档表存在（字段默认值由 CraftCommand.lua 负责补齐）
local function EnsureDBTable()
    if type(wjwCraftDB) ~= "table" then
        wjwCraftDB = {}
    end
    return wjwCraftDB
end

local function SetShowPanel(v)
    EnsureDBTable().showPanel = v and true or false
end

---------------------------------------------------------------- 计时器
-- C_Timer 不可用时直接执行一次，保证功能至少尝试一次而不是完全失效
local function ScheduleAfter(seconds, fn)
    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        C_Timer.After(seconds, fn)
    else
        fn()
    end
end

---------------------------------------------------------------- 位置保存 / 恢复
local function SavePosition()
    if not panel or type(panel.GetPoint) ~= "function" then
        return
    end
    local point, _, _, x, y = panel:GetPoint(1)
    if type(point) ~= "string" then
        return
    end
    EnsureDBTable().panelPoint = {
        point = point,
        x = tonumber(x) or 0,
        y = tonumber(y) or 0,
    }
end

local function RestorePosition()
    if not panel then
        return
    end
    local db = GetDB()
    local saved = db and db.panelPoint
    if type(saved) ~= "table" or type(saved.point) ~= "string" then
        return
    end
    panel:ClearAllPoints()
    panel:SetPoint(saved.point, UIParent, saved.point, tonumber(saved.x) or 0, tonumber(saved.y) or 0)
end

---------------------------------------------------------------- 自动刷新计时器
local function StartTicker()
    if ticker then
        return
    end
    if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then
        return
    end
    ticker = C_Timer.NewTicker(AUTO_REFRESH_SECONDS, function()
        if panel and panel:IsShown() then
            Refresh()
        end
    end)
end

local function StopTicker()
    if not ticker then
        return
    end
    if type(ticker.Cancel) == "function" then
        pcall(ticker.Cancel, ticker)
    end
    ticker = nil
end

---------------------------------------------------------------- 内容渲染
-- 把 1..MAX_ROWS 行刷到界面；bodyLines 之后固定追加一行估算口径备注。
-- 超出 MAX_ROWS 时保留前面部分，并插入一行“还有 N 行未显示”的提示。
local function RenderLines(bodyLines)
    if not panel then
        return
    end

    local lines = {}
    for i = 1, #bodyLines do
        lines[i] = bodyLines[i]
    end

    local maxBody = MAX_ROWS - 1   -- 最后一行固定留给底部备注
    if #lines > maxBody then
        local hidden = #lines - (maxBody - 1)
        while #lines > (maxBody - 1) do
            table.remove(lines)
        end
        lines[maxBody] = {
            text = string.format("……还有 %d 行未显示（/wjw craft 查看完整规划）", hidden),
            color = COLOR_DIM,
        }
    end

    lines[#lines + 1] = { text = BOTTOM_NOTE, color = COLOR_DIM }

    for i = 1, MAX_ROWS do
        local fs = rows[i]
        if fs then
            local line = lines[i]
            if line then
                fs:SetText(line.text)
                fs:SetTextColor(line.color[1], line.color[2], line.color[3])
                fs:Show()
            else
                fs:SetText("")
                fs:Hide()
            end
        end
    end
end

-- 只显示一条状态信息（打开专业窗口 / 正在读取 / 读取失败等）
local function RenderMessage(text, color)
    if not panel then
        return
    end
    for i = 1, MAX_ROWS do
        local fs = rows[i]
        if fs then
            if i == 1 then
                fs:SetText(text)
                fs:SetTextColor(color[1], color[2], color[3])
                fs:Show()
            else
                fs:SetText("")
                fs:Hide()
            end
        end
    end
end

-- 把 Craft.BuildPlan 的结果渲染成面板行
local function RenderPlan(plan)
    local current = math.floor(tonumber(plan.currentLevel) or 0)
    local target = math.floor(tonumber(plan.targetLevel) or current)
    local breakpoint = math.floor(tonumber(plan.breakpoint) or target)
    local professionName = tostring(plan.professionName or "未知专业")

    local body = {}

    -- a. 专业名 + 当前等级 → 目标（断点）
    body[#body + 1] = {
        text = string.format("%s    %d → %d（断点 %d）",
            professionName, current, target, breakpoint),
        color = COLOR_HEADER,
    }

    -- b. 每个分段：等级区间 + 配方 + 次数；下一行缩进显示材料缺口
    local segments = plan.segments or {}
    local requested = tonumber(plan.requestedTarget)
    for _, segment in ipairs(segments) do
        body[#body + 1] = {
            text = string.format("%d → %d   %s ×%d",
                math.floor(tonumber(segment.from) or 0),
                math.floor(tonumber(segment.to) or 0),
                tostring(segment.recipeName or segment.recipeID or "?"),
                math.floor(tonumber(segment.expectedCrafts) or 0)),
            color = COLOR_TEXT,
        }

        local parts = {}
        for _, reagent in ipairs(segment.reagents or {}) do
            parts[#parts + 1] = string.format("%s %d（需补 %d）",
                tostring(reagent.name or reagent.itemID or "?"),
                math.floor(tonumber(reagent.need) or 0),
                math.floor(tonumber(reagent.missing) or 0))
        end
        if #parts > 0 then
            body[#body + 1] = {
                text = "    " .. table.concat(parts, "  "),
                color = COLOR_DIM,
            }
        end
    end

    if #segments == 0 then
        if requested and current >= requested then
            body[#body + 1] = { text = "当前等级已达到目标，无需升级", color = COLOR_DIM }
        else
            body[#body + 1] = {
                text = string.format("现有配方无法让该专业继续升级（断点 %d）", breakpoint),
                color = COLOR_DIM,
            }
        end
    end

    -- c. 断点提示
    if requested and breakpoint < requested then
        body[#body + 1] = {
            text = string.format("断点 %d：现有配方不再涨点，请找「%s」训练师学新配方",
                breakpoint, professionName),
            color = COLOR_WARN,
        }
    elseif not requested and #segments > 0 then
        body[#body + 1] = {
            text = string.format("未指定目标，已规划到断点 %d", breakpoint),
            color = COLOR_DIM,
        }
    end

    -- d. 底部备注由 RenderLines 统一追加
    RenderLines(body)
end

---------------------------------------------------------------- 刷新
-- seq：本次刷新序号；attempt：本次刷新内配方数据的第几次读取（从 1 开始）
local function DoRefresh(seq, attempt)
    if seq ~= refreshSeq or not panel then
        return
    end

    if type(Craft.GetOpenProfession) ~= "function"
        or type(Craft.EnsureRecipeData) ~= "function"
        or type(Craft.BuildPlan) ~= "function"
    then
        RenderMessage("专业技能模块未就绪", COLOR_WARN)
        return
    end

    local skillLineID = Craft.GetOpenProfession()
    if type(skillLineID) ~= "number" then
        RenderMessage(MSG_OPEN_PROFESSION, COLOR_DIM)
        return
    end

    -- 配方数据可能晚于窗口出现：每秒重试，最多 MAX_DATA_ATTEMPTS 次
    if not Craft.EnsureRecipeData(skillLineID) then
        RenderMessage(MSG_READING, COLOR_DIM)
        if attempt < MAX_DATA_ATTEMPTS then
            ScheduleAfter(1, function()
                if seq == refreshSeq then
                    DoRefresh(seq, attempt + 1)
                end
            end)
        else
            RenderMessage("配方数据读取失败，请稍后重新打开专业窗口", COLOR_WARN)
        end
        return
    end

    local db = GetDB()
    local plan, err = Craft.BuildPlan(skillLineID, db and db.targetLevel or nil, {
        skipMaterials = db and db.skipMaterials or nil,
        skipRecipes   = db and db.skipRecipes or nil,
    })
    if type(plan) ~= "table" then
        RenderMessage("规划失败：" .. tostring(err or "未知原因"), COLOR_WARN)
        return
    end

    RenderPlan(plan)
end

Refresh = function()
    if not EnsurePanel() then
        return
    end
    -- 序号自增：作废之前排队的配方数据重试
    refreshSeq = refreshSeq + 1
    DoRefresh(refreshSeq, 1)
end

---------------------------------------------------------------- 面板创建
local function CreatePanel()
    local frame
    local ok

    -- 模板缺失时 CreateFrame 会报错，必须用 pcall；逐级退回
    ok, frame = pcall(CreateFrame, "Frame", "wjw_CraftPanel", UIParent, TEMPLATE_PRIMARY)
    if not ok or type(frame) ~= "table" then
        ok, frame = pcall(CreateFrame, "Frame", "wjw_CraftPanel", UIParent, TEMPLATE_FALLBACK)
    end
    if not ok or type(frame) ~= "table" then
        ok, frame = pcall(CreateFrame, "Frame", "wjw_CraftPanel", UIParent)
    end
    if not ok or type(frame) ~= "table" then
        return nil
    end

    frame:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    if type(frame.SetClampedToScreen) == "function" then
        frame:SetClampedToScreen(true)
    end
    if type(frame.RegisterForDrag) == "function" then
        frame:RegisterForDrag("LeftButton")
    end

    frame:SetScript("OnDragStart", function(self)
        if type(self.StartMoving) == "function" then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        if type(self.StopMovingOrSizing) == "function" then
            self:StopMovingOrSizing()
        end
        SavePosition()
    end)

    -- 标题：模板自带 TitleText 就直接用，否则自建一行标题
    if type(frame.TitleText) == "table" and type(frame.TitleText.SetText) == "function" then
        frame.TitleText:SetText(PANEL_TITLE)
    else
        local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -8)
        title:SetText(PANEL_TITLE)
    end

    -- 退回到 BackdropTemplate / 空模板时补一个背景框
    if type(frame.NineSlice) ~= "table" and type(frame.SetBackdrop) == "function" then
        frame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
    end

    -- 关闭按钮：模板自带则复用（追加“记住关闭”），否则自建
    local closeButton = frame.CloseButton
    if type(closeButton) == "table" and type(closeButton.HookScript) == "function" then
        closeButton:HookScript("OnClick", function()
            SetShowPanel(false)
        end)
    else
        local okBtn, btn = pcall(CreateFrame, "Button", nil, frame, "UIPanelButtonTemplate")
        if okBtn and type(btn) == "table" then
            btn:SetSize(48, 20)
            btn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
            btn:SetText("隐藏")
            btn:SetScript("OnClick", function()
                SetShowPanel(false)
                frame:Hide()
            end)
        end
    end

    -- 内容区锚点：优先放进模板自带的 Inset
    local anchor = frame
    local offsetX, offsetY = 14, -34
    local contentWidth = PANEL_WIDTH - 28
    if type(frame.Inset) == "table" then
        anchor = frame.Inset
        offsetX, offsetY = 8, -8
        contentWidth = PANEL_WIDTH - 48
    end

    for i = 1, MAX_ROWS do
        local fs = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", anchor, "TOPLEFT", offsetX, offsetY - (i - 1) * ROW_HEIGHT)
        fs:SetSize(contentWidth, ROW_HEIGHT)
        fs:SetJustifyH("LEFT")
        if type(fs.SetWordWrap) == "function" then
            fs:SetWordWrap(false)
        end
        fs:SetText("")
        fs:Hide()
        rows[i] = fs
    end

    -- OnShow/OnHide 用 HookScript 追加，避免覆盖模板自带的脚本
    local function OnPanelShow()
        RestorePosition()
        StartTicker()
    end
    local function OnPanelHide()
        StopTicker()
    end
    if type(frame.HookScript) == "function" then
        frame:HookScript("OnShow", OnPanelShow)
        frame:HookScript("OnHide", OnPanelHide)
    else
        frame:SetScript("OnShow", OnPanelShow)
        frame:SetScript("OnHide", OnPanelHide)
    end

    return frame
end

EnsurePanel = function()
    if panel then
        return panel
    end
    panel = CreatePanel()
    if panel then
        panel:Hide()
    end
    return panel
end

---------------------------------------------------------------- 专业窗口联动
local function OnProfessionsFrameShow()
    local db = GetDB()
    if db and db.showPanel == false then
        return
    end
    if not EnsurePanel() then
        return
    end
    panel:Show()
    Refresh()
end

local function OnProfessionsFrameHide()
    if panel then
        panel:Hide()
    end
end

-- ProfessionsFrame 可能晚于本插件加载：每 1 秒重试，最多 FRAME_HOOK_MAX_RETRIES 次
local function TryHookProfessionsFrame(retriesLeft)
    if frameHooked then
        return
    end

    local frame = _G.ProfessionsFrame
    if type(frame) ~= "table" or type(frame.HookScript) ~= "function" then
        if retriesLeft > 0 then
            ScheduleAfter(1, function()
                TryHookProfessionsFrame(retriesLeft - 1)
            end)
        end
        return
    end

    local okShow = pcall(frame.HookScript, frame, "OnShow", OnProfessionsFrameShow)
    if not okShow then
        if retriesLeft > 0 then
            ScheduleAfter(1, function()
                TryHookProfessionsFrame(retriesLeft - 1)
            end)
        end
        return
    end
    pcall(frame.HookScript, frame, "OnHide", OnProfessionsFrameHide)
    frameHooked = true

    -- 挂接时专业窗口已经开着（例如重载后立即打开）：补一次显示
    if type(frame.IsShown) == "function" then
        local ok, shown = pcall(frame.IsShown, frame)
        if ok and shown then
            OnProfessionsFrameShow()
        end
    end
end

---------------------------------------------------------------- 启动
local eventFrame = CreateFrame("Frame", "wjwCraftPanelEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self, event, addonName)
    if event ~= "ADDON_LOADED" or addonName ~= ADDON_NAME then
        return
    end
    self:UnregisterEvent("ADDON_LOADED")
    EnsurePanel()
    TryHookProfessionsFrame(FRAME_HOOK_MAX_RETRIES)
end)

---------------------------------------------------------------- 公开接口
Craft.Panel = {
    Show = function()
        if not EnsurePanel() then
            return
        end
        SetShowPanel(true)
        panel:Show()
        Refresh()
    end,

    Hide = function()
        SetShowPanel(false)
        if panel then
            panel:Hide()
        end
    end,

    Toggle = function()
        if not EnsurePanel() then
            return
        end
        if panel:IsShown() then
            Craft.Panel.Hide()
        else
            Craft.Panel.Show()
        end
    end,

    Refresh = Refresh,
}
