--[[---------------------------------------------------------------------------
    CraftAutoSelect —— 专业技能升级规划 · 自动选中推荐配方

    职责：
      * 专业窗口每次打开时，按 Craft.BuildPlan 的第一段推荐配方，调用
        C_TradeSkillUI.OpenRecipe 让游戏自动选中该配方。
      * 只做"自动选中"这一件事：不做规划计算、不画界面、不注册命令。

    开关：
      * wjwCraftDB.autoSelect（默认 true，CraftCommand.lua 负责建表）。
      * 本文件只读该字段；wjwCraftDB 尚未建立时视为默认开启。
      * 关闭后完全不调用 OpenRecipe（包括已排队的重试也会中止）。

    不干扰用户：
      * 每次打开窗口只自动选一次；用户随后手动点选任何配方，本插件一律不再干预。
      * 若用户在自动选中完成前就手动点了配方，后续排队中的自动重试会被取消。

    兼容与安全：
      * ProfessionsFrame / ProfessionsRecipeListRecipeMixin / C_TradeSkillUI.OpenRecipe
        都是暴雪内部实现，全部先 type() 守卫再 pcall，任何失败静默降级，不弹错。
-----------------------------------------------------------------------------]]

local ADDON_NAME, NS = ...

-- CraftCore.lua 未加载或未导出 NS.Craft 时静默退出，不影响其它模块
local Craft = NS and NS.Craft
if type(Craft) ~= "table" then
    return
end

---------------------------------------------------------------- 常量与状态
local FRAME_HOOK_MAX_RETRIES = 10   -- 专业界面找不到时最多再等 10 秒
local DATA_READ_MAX_ATTEMPTS  = 3   -- 配方数据读取最多尝试 3 次（每次间隔 1 秒）

local frameHooked          = false  -- 是否已成功挂接 ProfessionsFrame 的 OnShow
local mixinHooked          = false  -- 是否已成功挂接 ProfessionsRecipeListRecipeMixin
local openSeq              = 0      -- 窗口打开序号，用于作废上一次打开时的排队重试
local autoSelectedThisOpen = false  -- 本次打开窗口是否已经自动选过一次
local autoSelecting        = false  -- 本插件自己正在调用 OpenRecipe（区分用户手动选择）
local userPickedManually   = false  -- 用户先于自动选中手动点了配方，取消后续自动选中

---------------------------------------------------------------- 基础守卫
-- 取存档表；wjwCraftDB 由 CraftCommand.lua 建立，本文件不负责初始化
local function GetDB()
    if type(wjwCraftDB) == "table" then
        return wjwCraftDB
    end
    return nil
end

-- 开关状态：表不存在时按默认开启处理
local function IsEnabled()
    local db = GetDB()
    if not db then
        return true
    end
    return db.autoSelect ~= false
end

-- 调试开关：wjwCraftDB.debug 为 true 时才输出诊断信息
local function IsDebug()
    local db = GetDB()
    return db ~= nil and db.debug == true
end

local function SafePrint(msg)
    if type(Craft.Print) == "function" then
        Craft.Print(msg)
    end
end

local function DebugPrint(msg)
    if IsDebug() then
        SafePrint(msg)
    end
end

-- C_Timer 不可用时直接执行一次，保证功能至少尝试一次而不是完全失效
local function ScheduleAfter(seconds, fn)
    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        C_Timer.After(seconds, fn)
    else
        fn()
    end
end

-- 专业窗口当前是否仍处于显示状态；读不到时按"仍在显示"处理，交给后续守卫
local function IsProfessionsFrameShown()
    if type(ProfessionsFrame) == "table"
        and type(ProfessionsFrame.IsShown) == "function"
    then
        local ok, shown = pcall(ProfessionsFrame.IsShown, ProfessionsFrame)
        if ok and shown == false then
            return false
        end
    end
    return true
end

---------------------------------------------------------------- 用户选择回调
-- 用户手动点击配方时触发（本插件自己的 OpenRecipe 也会触发，用 autoSelecting 区分）。
-- 已经自动选过一次之后一律忽略，避免把用户的选择强行拉回推荐配方。
local function OnRecipeSelected()
    if autoSelecting then
        return
    end
    if autoSelectedThisOpen then
        return
    end
    -- 用户抢在自动选中之前自己点了配方：取消后续排队中的自动选中
    userPickedManually = true
end

-- 只在 ProfessionsRecipeListRecipeMixin 是 table 时注册；重复调用无副作用
local function RegisterSelectionHook()
    if mixinHooked then
        return
    end
    local mixin = ProfessionsRecipeListRecipeMixin
    if type(mixin) ~= "table" then
        return
    end
    if type(mixin.SetSelected) ~= "function" then
        return
    end
    if type(hooksecurefunc) ~= "function" then
        return
    end
    local ok = pcall(hooksecurefunc, mixin, "SetSelected", OnRecipeSelected)
    if ok then
        mixinHooked = true
    else
        DebugPrint("挂接 ProfessionsRecipeListRecipeMixin.SetSelected 失败")
    end
end

---------------------------------------------------------------- 自动选中主流程
-- seq：本次窗口打开的序号；attempt：配方数据读取的第几次尝试（从 1 开始）
local function TrySelect(seq, attempt)
    -- 窗口已重新打开或已产生新的会话编号，旧任务作废
    if seq ~= openSeq then
        return
    end
    -- 已自动选过、或用户已手动选择：不再干预
    if autoSelectedThisOpen or userPickedManually then
        return
    end
    -- 开关关闭后一律不再调用 OpenRecipe（排队中的重试也在这里中止）
    if not IsEnabled() then
        return
    end
    -- 窗口已关闭时中止，避免在后台弹选配方
    if not IsProfessionsFrameShown() then
        return
    end

    if type(Craft.GetOpenProfession) ~= "function"
        or type(Craft.EnsureRecipeData) ~= "function"
        or type(Craft.BuildPlan) ~= "function"
    then
        return
    end

    local skillLineID = Craft.GetOpenProfession()
    if type(skillLineID) ~= "number" then
        return
    end

    -- 配方数据可能晚于窗口出现，失败时每秒重试，最多 3 次
    if not Craft.EnsureRecipeData(skillLineID) then
        if attempt < DATA_READ_MAX_ATTEMPTS then
            ScheduleAfter(1.0, function()
                TrySelect(seq, attempt + 1)
            end)
        else
            DebugPrint("配方数据读取失败，已放弃自动选中")
        end
        return
    end

    local db = GetDB()
    local plan = Craft.BuildPlan(skillLineID, nil, {
        skipMaterials = db and db.skipMaterials or nil,
        skipRecipes   = db and db.skipRecipes or nil,
    })
    if type(plan) ~= "table" or type(plan.segments) ~= "table" then
        DebugPrint("未能生成升级规划，跳过自动选中")
        return
    end

    local first = plan.segments[1]
    local recipeID = type(first) == "table" and first.recipeID or nil
    if type(recipeID) ~= "number" then
        DebugPrint("规划里没有可推荐的配方，跳过自动选中")
        return
    end

    local UI = C_TradeSkillUI
    if type(UI) ~= "table" or type(UI.OpenRecipe) ~= "function" then
        DebugPrint("当前客户端没有 C_TradeSkillUI.OpenRecipe，跳过自动选中")
        return
    end

    autoSelecting = true
    local ok = pcall(UI.OpenRecipe, recipeID)
    autoSelecting = false
    if not ok then
        DebugPrint(string.format("调用 OpenRecipe 选中配方 %d 失败", recipeID))
        return
    end

    -- 标记本次打开已经自动选过：用户之后的手动选择不再被本插件干预
    autoSelectedThisOpen = true

    local recipeName = first.recipeName
    if type(recipeName) ~= "string" or recipeName == "" then
        recipeName = tostring(recipeID)
    end
    local crafts = tonumber(first.expectedCrafts) or 0
    local breakpoint = tonumber(plan.breakpoint) or tonumber(plan.targetLevel) or 0
    SafePrint(string.format("已自动选中推荐配方：%s（做 ×%d 次，断点 %d）",
        recipeName, crafts, math.floor(breakpoint)))
end

---------------------------------------------------------------- 窗口事件
local function OnProfessionsShow()
    -- 新的一次打开：作废旧会话、重置本次打开的自动选中状态
    openSeq = openSeq + 1
    autoSelectedThisOpen = false
    userPickedManually = false

    -- 用户可能先打开窗口、后加载暴雪界面；这里顺带补注册（幂等）
    RegisterSelectionHook()

    if not IsEnabled() then
        return
    end

    TrySelect(openSeq, 1)
end

-- 专业主框架可能晚于本插件加载：每 1 秒重试，最多重试 FRAME_HOOK_MAX_RETRIES 次
-- retriesLeft：还剩多少次重试机会（首次调用传 FRAME_HOOK_MAX_RETRIES）
local function TryHookProfessionsFrame(retriesLeft)
    if frameHooked then
        return
    end

    local frame = ProfessionsFrame
    if type(frame) ~= "table" or type(frame.HookScript) ~= "function" then
        if retriesLeft > 0 then
            ScheduleAfter(1, function()
                TryHookProfessionsFrame(retriesLeft - 1)
            end)
        else
            DebugPrint("长时间未找到专业界面 ProfessionsFrame，自动选中功能不可用")
        end
        return
    end

    local ok = pcall(frame.HookScript, frame, "OnShow", OnProfessionsShow)
    if not ok then
        DebugPrint("挂接 ProfessionsFrame.OnShow 失败，自动选中功能不可用")
        return
    end

    frameHooked = true
    RegisterSelectionHook()
end

---------------------------------------------------------------- 启动
local eventFrame = CreateFrame("Frame", "wjwCraftAutoSelectEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(_, event, addonName)
    if event ~= "ADDON_LOADED" or addonName ~= ADDON_NAME then
        return
    end
    eventFrame:UnregisterEvent("ADDON_LOADED")
    TryHookProfessionsFrame(FRAME_HOOK_MAX_RETRIES)
end)

---------------------------------------------------------------- 公开接口
local AutoSelect = {}

-- 打开/关闭自动选中；wjwCraftDB 不存在时什么都不做（由 CraftCommand 负责建表）
function AutoSelect.SetEnabled(v)
    local db = GetDB()
    if not db then
        return
    end
    db.autoSelect = v and true or false
end

-- 是否开启；wjwCraftDB 不存在时按默认开启返回 true
function AutoSelect.IsEnabled()
    return IsEnabled()
end

Craft.AutoSelect = AutoSelect
