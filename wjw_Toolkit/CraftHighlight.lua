--[[---------------------------------------------------------------------------
    CraftHighlight —— 专业技能升级规划 · 配方行内推荐高亮

    职责：
      * 在专业制作窗口的配方列表行内，给 Craft.BuildPlan 推荐的配方加一层
        半透明金色高亮，并在行右侧显示「×N」（该配方建议制作次数）。
      * 只负责"贴标记"：不做规划计算、不注册命令、不改暴雪原有控件。

    开关：
      * wjwCraftDB.highlight（默认 true；表不存在时按开启处理）。
      * 关闭后立即清除所有可见行的标记，且后续不再贴标记，完全不影响暴雪界面。
      * 对外接口：Craft.Highlight = { SetEnabled, IsEnabled, Refresh }。

    挂接方式（只用 hooksecurefunc / HookScript，绝不覆盖暴雪函数）：
      * hooksecurefunc(ProfessionsRecipeListRecipeMixin, "Init", OnRowInit)
        —— 行由 ScrollBox 池化复用，Init 是每次绑定数据时都会调用的入口，
           因此每次进入 OnRowInit 都必须先清掉上一轮留下的标记。
      * ProfessionsFrame:HookScript("OnShow"/"OnHide", ...)
        —— 打开时计算推荐表并重贴可见行；关闭时停掉刷新计时器。

    兼容与安全：
      * ProfessionsFrame / ProfessionsRecipeListRecipeMixin / ScrollBox 等都是
        暴雪内部实现，全部先 type() 守卫、关键调用 pcall 包裹；任何一步失败
        只让对应行不高亮，绝不抛错，也不影响暴雪界面。
      * 暴雪界面是按需加载的（Blizzard_Professions），本文件既监听它自己的
        ADDON_LOADED，也在首次行初始化时补挂一次，保证晚加载也能挂上。
-----------------------------------------------------------------------------]]

local ADDON_NAME, NS = ...

-- CraftCore.lua 未加载或未导出 NS.Craft 时静默退出，不影响其它模块
local Craft = NS and NS.Craft
if type(Craft) ~= "table" then
    return
end

---------------------------------------------------------------- 常量
local REFRESH_SECONDS        = 3     -- 面板显示期间的推荐表刷新间隔
local MAX_DATA_ATTEMPTS      = 5     -- 配方数据读取失败时的重试次数（每次间隔 1 秒）
local FRAME_HOOK_MAX_RETRIES = 10    -- 专业界面晚加载时最多再等 10 秒
local DEFAULT_ROW_WIDTH      = 200   -- 行宽读不到时的兜底宽度
local ROW_MARK_HEIGHT        = 16    -- 高亮纹理高度（行高约 20px）

local HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B = 1.0, 0.82, 0.0
local HIGHLIGHT_ALPHA        = 0.18

local MARK_FIELD  = "wjwCraftMark"   -- 行上的高亮纹理字段
local COUNT_FIELD = "wjwCraftCount"  -- 行上的次数文字字段

---------------------------------------------------------------- 状态
local recommended = {}    -- 推荐表：recipeID -> 建议制作次数
local calcSeq     = 0     -- 计算序号，用于作废过期的排队重试
local ticker              -- 3 秒刷新计时器
local rowHooked   = false -- 是否已挂接行初始化
local frameHooked = false -- 是否已挂接专业主框架
local repaintScheduled = false

-- 前向声明：计时器 / 窗口事件 / 行初始化与刷新函数互相引用
local RepaintVisibleRows
local RecomputeRecommendations
local EnsureRowHook
local EnsureFrameHook

---------------------------------------------------------------- 存档与开关
local function GetDB()
    if type(wjwCraftDB) == "table" then
        return wjwCraftDB
    end
    return nil
end

-- 写开关时确保存档表存在（其余字段默认值由 CraftCommand.lua 负责补齐）
local function EnsureDBTable()
    if type(wjwCraftDB) ~= "table" then
        wjwCraftDB = {}
    end
    return wjwCraftDB
end

-- 开关状态：存档表不存在、或字段尚未写过时按默认开启处理
local function IsEnabled()
    local db = GetDB()
    if not db then
        return true
    end
    return db.highlight ~= false
end

---------------------------------------------------------------- 基础工具
-- C_Timer 不可用时直接执行一次，保证功能至少尝试一次而不是完全失效
local function ScheduleAfter(seconds, fn)
    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        C_Timer.After(seconds, fn)
    else
        fn()
    end
end

local function GetProfessionsFrame()
    local frame = _G.ProfessionsFrame
    if type(frame) ~= "table" then
        return nil
    end
    return frame
end

-- 专业窗口当前是否处于显示状态；读不到时返回 false，避免在后台空转
local function IsProfessionsFrameShown()
    local frame = GetProfessionsFrame()
    if not frame then
        return false
    end
    if type(frame.IsShown) == "function" then
        local ok, shown = pcall(frame.IsShown, frame)
        if ok then
            return shown and true or false
        end
    end
    return true
end

---------------------------------------------------------------- 行数据解析
-- 从行绑定的数据里取 recipeID。
-- 兼容两种形态：元素数据外层带 .data（ScrollBox）与直接带 .recipeInfo。
local function ExtractRecipeID(data)
    if type(data) ~= "table" then
        return nil
    end

    local wrapper = data.data
    if type(wrapper) == "table" then
        local info = wrapper.recipeInfo
        if type(info) == "table" and type(info.recipeID) == "number" then
            return info.recipeID
        end
    end

    local info = data.recipeInfo
    if type(info) == "table" and type(info.recipeID) == "number" then
        return info.recipeID
    end

    return nil
end

-- 读取行的 recipeID：先 GetElementData，再 GetData，都失败返回 nil
local function GetRowRecipeID(row)
    if type(row.GetElementData) == "function" then
        local ok, data = pcall(row.GetElementData, row)
        if ok then
            local recipeID = ExtractRecipeID(data)
            if recipeID then
                return recipeID
            end
        end
    end

    if type(row.GetData) == "function" then
        local ok, data = pcall(row.GetData, row)
        if ok then
            local recipeID = ExtractRecipeID(data)
            if recipeID then
                return recipeID
            end
        end
    end

    return nil
end

---------------------------------------------------------------- 行内标记
-- 清掉该行上一轮的标记。行是池化复用的，每次绑定数据（Init）都必须先清。
local function ClearRowMark(row)
    local mark = row[MARK_FIELD]
    if type(mark) == "table" then
        if type(mark.Hide) == "function" then
            pcall(mark.Hide, mark)
        end
        if type(mark.SetTexture) == "function" then
            pcall(mark.SetTexture, mark, nil)
        end
    end

    local count = row[COUNT_FIELD]
    if type(count) == "table" then
        if type(count.Hide) == "function" then
            pcall(count.Hide, count)
        end
        if type(count.SetText) == "function" then
            pcall(count.SetText, count, "")
        end
    end
end

-- 首次调用时在行上创建两个控件，之后复用：
--   * 高亮纹理：BACKGROUND 层、sublevel 1（压在本行自带的背景之上、文字之下）；
--   * 次数文字：OVERLAY 层小字体，贴右侧。
local function EnsureRowWidgets(row)
    local mark = row[MARK_FIELD]
    if type(mark) ~= "table" or type(mark.SetColorTexture) ~= "function" then
        if type(row.CreateTexture) ~= "function" then
            return nil, nil
        end
        local ok, texture = pcall(row.CreateTexture, row, nil, "BACKGROUND", nil, 1)
        if not ok or type(texture) ~= "table" then
            return nil, nil
        end
        row[MARK_FIELD] = texture
        mark = texture
    end

    local count = row[COUNT_FIELD]
    if type(count) ~= "table" or type(count.SetText) ~= "function" then
        if type(row.CreateFontString) ~= "function" then
            return nil, nil
        end
        local ok, fontString = pcall(row.CreateFontString, row, nil, "OVERLAY", "GameFontNormalSmall")
        if not ok or type(fontString) ~= "table" then
            return nil, nil
        end
        row[COUNT_FIELD] = fontString
        count = fontString
    end

    -- 高亮尺寸：Init 时行宽可能尚未确定（读不到或为 0），此时退回兜底宽度
    local rowWidth = DEFAULT_ROW_WIDTH
    if type(row.GetWidth) == "function" then
        local ok, width = pcall(row.GetWidth, row)
        if ok and type(width) == "number" and width >= 20 then
            rowWidth = width
        end
    end

    if type(mark.ClearAllPoints) == "function" then
        pcall(mark.ClearAllPoints, mark)
    end
    if type(mark.SetPoint) == "function" then
        pcall(mark.SetPoint, mark, "LEFT", row, "LEFT", 2, 0)
    end
    if type(mark.SetSize) == "function" then
        pcall(mark.SetSize, mark, rowWidth - 4, ROW_MARK_HEIGHT)
    end
    pcall(mark.SetColorTexture, mark,
        HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B, HIGHLIGHT_ALPHA)

    -- 次数文字位置：行内自带 Count（可制作数）时贴在它左边，避免两个数字叠在一起；
    -- Count 不存在时退回行右边缘
    if type(count.ClearAllPoints) == "function" then
        pcall(count.ClearAllPoints, count)
    end
    local rowCount = row.Count
    if type(rowCount) == "table" and type(rowCount.GetPoint) == "function" then
        pcall(count.SetPoint, count, "RIGHT", rowCount, "LEFT", -4, 0)
    else
        pcall(count.SetPoint, count, "RIGHT", row, "RIGHT", -6, 0)
    end
    pcall(count.SetTextColor, count, HIGHLIGHT_R, HIGHLIGHT_G, HIGHLIGHT_B)

    return mark, count
end

-- 给一行贴标记；任何失败只影响这一行
local function ApplyRow(row)
    -- 1. 先清理上一轮标记（行复用，必须每次重贴）
    ClearRowMark(row)

    -- 2. 读该行的 recipeID
    local recipeID = GetRowRecipeID(row)
    if not recipeID then
        return
    end

    -- 3. 开关关闭或推荐表为空：清理后直接返回，不做任何绘制
    if not IsEnabled() then
        return
    end
    if next(recommended) == nil then
        return
    end

    -- 4. 不在推荐表：已清理，直接返回
    local crafts = recommended[recipeID]
    crafts = tonumber(crafts)
    if not crafts or crafts <= 0 then
        return
    end

    -- 5. 创建/复用控件并显示
    local mark, count = EnsureRowWidgets(row)
    if not mark or not count then
        return
    end

    pcall(mark.Show, mark)
    pcall(count.SetText, count, string.format("×%d", math.floor(crafts)))
    pcall(count.Show, count)
end

-- 行初始化入口（hooksecurefunc 会以 row 作为第一个参数调用）
-- hideCraftableCount 是暴雪 Init 的参数，本模块不使用
local function OnRowInit(row, hideCraftableCount)
    if type(row) ~= "table" then
        return
    end
    -- 兜底：若主框架钩子因故没挂上，借行初始化补挂一次（成本极低、幂等）
    if not frameHooked then
        EnsureFrameHook(0)
    end
    pcall(ApplyRow, row)
end

---------------------------------------------------------------- 可见行重贴
-- 遍历当前可见行重贴标记；只在行上有 Init 方法时调用（说明它是一行配方）
function RepaintVisibleRows()
    local frame = GetProfessionsFrame()
    if not frame then
        return
    end

    local page = frame.CraftingPage
    if type(page) ~= "table" then
        return
    end
    local recipeList = page.RecipeList
    if type(recipeList) ~= "table" then
        return
    end
    local scrollBox = recipeList.ScrollBox
    if type(scrollBox) ~= "table" or type(scrollBox.GetFrames) ~= "function" then
        return
    end

    local ok, frames = pcall(scrollBox.GetFrames, scrollBox)
    if not ok or type(frames) ~= "table" then
        return
    end

    for _, row in ipairs(frames) do
        if type(row) == "table" and type(row.Init) == "function" then
            pcall(OnRowInit, row)
        end
    end
end

-- 稍后补一次重贴：用于"行已创建、钩子才挂上"的场景，避免首批行漏贴
local function ScheduleRepaintSoon()
    if repaintScheduled then
        return
    end
    repaintScheduled = true
    ScheduleAfter(0, function()
        repaintScheduled = false
        if IsEnabled() then
            RepaintVisibleRows()
        end
    end)
end

---------------------------------------------------------------- 推荐表计算
-- seq：本次计算的序号；attempt：配方数据读取的第几次尝试（从 1 开始）
local function DoCompute(seq, attempt)
    -- 序号已过期（窗口重新打开 / 手动刷新 / 关闭开关）：旧任务作废
    if seq ~= calcSeq then
        return
    end

    if not IsEnabled() then
        recommended = {}
        return
    end

    if type(Craft.GetOpenProfession) ~= "function"
        or type(Craft.EnsureRecipeData) ~= "function"
        or type(Craft.BuildPlan) ~= "function"
    then
        recommended = {}
        return
    end

    local okProfession, skillLineID = pcall(Craft.GetOpenProfession)
    if not okProfession or type(skillLineID) ~= "number" then
        if attempt < MAX_DATA_ATTEMPTS then
            ScheduleAfter(1.0, function()
                DoCompute(seq, attempt + 1)
            end)
        else
            recommended = {}
        end
        return
    end

    -- 配方数据可能晚于窗口出现：每秒重试，最多 MAX_DATA_ATTEMPTS 次
    local okEnsure, ready = pcall(Craft.EnsureRecipeData, skillLineID)
    if not okEnsure or not ready then
        if attempt < MAX_DATA_ATTEMPTS then
            ScheduleAfter(1.0, function()
                DoCompute(seq, attempt + 1)
            end)
        else
            recommended = {}
        end
        return
    end

    local db = GetDB()
    local okPlan, plan = pcall(Craft.BuildPlan, skillLineID, db and db.targetLevel or nil, {
        skipMaterials = db and db.skipMaterials or nil,
        skipRecipes   = db and db.skipRecipes or nil,
    })
    if not okPlan or type(plan) ~= "table" or type(plan.segments) ~= "table" then
        -- 计算失败：清空表并静默
        recommended = {}
        return
    end

    local newTable = {}
    for _, segment in ipairs(plan.segments) do
        if type(segment) == "table" and type(segment.recipeID) == "number" then
            local crafts = tonumber(segment.expectedCrafts) or 0
            if crafts > 0 then
                newTable[segment.recipeID] = crafts
            end
        end
    end
    recommended = newTable

    -- 推荐表变了：立刻把可见行重贴一次，不必等下一次 3 秒刷新
    RepaintVisibleRows()
end

-- 重算推荐表（自增序号，作废所有排队中的旧重试）
function RecomputeRecommendations()
    calcSeq = calcSeq + 1
    DoCompute(calcSeq, 1)
end

---------------------------------------------------------------- 定时刷新
local function StopTicker()
    if not ticker then
        return
    end
    if type(ticker.Cancel) == "function" then
        pcall(ticker.Cancel, ticker)
    end
    ticker = nil
end

local function OnTick()
    -- 开关关闭或窗口已隐藏：停止计时器，避免后台空转
    if not IsEnabled() or not IsProfessionsFrameShown() then
        StopTicker()
        return
    end
    RecomputeRecommendations()
end

local function StartTicker()
    if ticker then
        return
    end
    if not IsEnabled() or not IsProfessionsFrameShown() then
        return
    end
    if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then
        return
    end
    local ok, newTicker = pcall(C_Timer.NewTicker, REFRESH_SECONDS, OnTick)
    if ok and type(newTicker) == "table" then
        ticker = newTicker
    end
end

---------------------------------------------------------------- 钩子挂接
-- 挂接行初始化；mixin 未加载时静默返回，之后由窗口事件 / 行初始化补挂
function EnsureRowHook()
    if rowHooked then
        return
    end

    local mixin = _G.ProfessionsRecipeListRecipeMixin
    if type(mixin) ~= "table" or type(mixin.Init) ~= "function" then
        return
    end
    if type(hooksecurefunc) ~= "function" then
        return
    end

    local ok = pcall(hooksecurefunc, mixin, "Init", OnRowInit)
    if not ok then
        return
    end

    rowHooked = true
    -- 钩子挂上之前已创建的可见行不会被 Init 回调，这里补一次
    ScheduleRepaintSoon()
end

local function OnProfessionsFrameShow()
    -- 暴雪界面晚加载时，窗口第一次显示后才拿得到 mixin
    EnsureRowHook()

    if not IsEnabled() then
        return
    end

    StartTicker()
    RecomputeRecommendations()
end

local function OnProfessionsFrameHide()
    StopTicker()
    -- 作废尚未执行的排队重试
    calcSeq = calcSeq + 1
end

-- 挂接专业主框架；retriesLeft > 0 时每秒重试一次
function EnsureFrameHook(retriesLeft)
    if frameHooked then
        return
    end

    local frame = GetProfessionsFrame()
    if not frame or type(frame.HookScript) ~= "function" then
        if retriesLeft and retriesLeft > 0 then
            ScheduleAfter(1, function()
                EnsureFrameHook(retriesLeft - 1)
            end)
        end
        return
    end

    local okShow = pcall(frame.HookScript, frame, "OnShow", OnProfessionsFrameShow)
    if not okShow then
        if retriesLeft and retriesLeft > 0 then
            ScheduleAfter(1, function()
                EnsureFrameHook(retriesLeft - 1)
            end)
        end
        return
    end

    pcall(frame.HookScript, frame, "OnHide", OnProfessionsFrameHide)
    frameHooked = true

    EnsureRowHook()

    -- 挂接时专业窗口已经开着（例如插件重载后立即查看）：补一次
    if IsProfessionsFrameShown() then
        OnProfessionsFrameShow()
    end
end

---------------------------------------------------------------- 公开接口
local function SetEnabled(v)
    local enabled = v and true or false
    EnsureDBTable().highlight = enabled

    if not enabled then
        -- 关闭：停计时器、清推荐表，并立即清掉所有可见行标记。
        -- ApplyRow 会先清理标记再判断开关，因此这里能干净清空。
        calcSeq = calcSeq + 1
        recommended = {}
        StopTicker()
        RepaintVisibleRows()
        return
    end

    -- 打开：若窗口正开着就立刻重算并贴标记
    EnsureRowHook()
    EnsureFrameHook(0)
    if IsProfessionsFrameShown() then
        StartTicker()
        RecomputeRecommendations()
    end
end

local function Refresh()
    EnsureRowHook()
    EnsureFrameHook(0)

    if not IsEnabled() then
        recommended = {}
        RepaintVisibleRows()
        return
    end

    if IsProfessionsFrameShown() then
        StartTicker()
        RecomputeRecommendations()
    end
end

Craft.Highlight = {
    SetEnabled = SetEnabled,
    IsEnabled  = IsEnabled,
    Refresh    = Refresh,
}

---------------------------------------------------------------- 启动
local eventFrame = CreateFrame("Frame", "wjwCraftHighlightEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(_, event, addonName)
    if event ~= "ADDON_LOADED" then
        return
    end

    if addonName == ADDON_NAME then
        -- 本插件加载完成（存档已就绪）：尝试挂接，暴雪界面未加载时每秒重试
        EnsureFrameHook(FRAME_HOOK_MAX_RETRIES)
        EnsureRowHook()
    elseif addonName == "Blizzard_Professions" then
        -- 暴雪专业界面刚加载：立即挂接（不再重试）
        EnsureFrameHook(0)
        EnsureRowHook()
    end
end)
