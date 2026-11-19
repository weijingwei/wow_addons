--[[---------------------------------------------------------------------------
    WuXianAutoSell —— 魔兽世界-无限 · 自动卖垃圾

    功能：
      * 打开商人界面（NPC 商人 / 修理商 / 杂货商等）时，自动卖出背包中所有
        灰色（品质 0）物品；
      * 卖出结束后在聊天框提示本次卖出的件数与获得的金币；
      * 提供永不卖出名单，名单内的物品（即使品质为 0）永远不会被卖出；
      * 命令：/wjw sell（开关）、/wjw sell add、/wjw sell list、/wjw sell clear 等。

    兼容：
      * 正式服（Retail）与怀旧服（Classic）通用；
      * 容器 API 优先使用 C_Container，缺失时自动回退到旧全局函数；
      * 卖出使用 UseContainerItem（商人界面打开时即为"出售给商人"）。

    安全：
      * 只处理 quality == 0 的物品，绝不触碰绿色及以上品质；
      * 名单内物品、商人不出价（hasNoValue）的物品、被锁定的物品一律跳过；
      * 每件之间有固定的时间间隔，同一格子重试有上限，避免刷屏与卡死。
-----------------------------------------------------------------------------]]

local ADDON_NAME, NS = ...

NS.ADDON_NAME = ADDON_NAME
NS.PREFIX     = "|cff33ff99[wjw_工具箱]|r "
NS.VERSION    = "1.0.0"

-- 指向 SavedVariables 表，仅在 ADDON_LOADED 之后有值
local db

---------------------------------------------------------------- 可调参数
local SELL_INTERVAL = 0.35   -- 相邻两次出售之间的间隔（秒）
local TICK_INTERVAL = 0.05   -- OnUpdate 采样间隔（秒）
local IDLE_WAIT     = 1.2    -- 连续多久找不到可卖物品即视为本次卖出结束（秒）
local MAX_ATTEMPTS  = 2      -- 同一个格子最多尝试出售次数，防止无限重试

---------------------------------------------------------------- 基础工具
local function Trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function Print(msg)
    local text = NS.PREFIX .. tostring(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    elseif type(print) == "function" then
        print(text)
    end
end
NS.Print = Print

local function FormatMoney(copper)
    copper = math.max(0, math.floor(tonumber(copper) or 0))
    if type(_G.GetMoneyString) == "function" then
        local ok, text = pcall(_G.GetMoneyString, copper)
        if ok and type(text) == "string" and text ~= "" then
            return text
        end
    end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "金" end
    if s > 0 then parts[#parts + 1] = s .. "银" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "铜" end
    return table.concat(parts, " ")
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

local function MerchantOpen()
    if MerchantFrame and MerchantFrame.IsShown then
        return MerchantFrame:IsShown() and true or false
    end
    return false
end
NS.IsMerchantOpen = MerchantOpen

---------------------------------------------------------------- 容器 API 兼容层
local Container = {}

function Container.NumSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then
        return C_Container.GetContainerNumSlots(bag) or 0
    end
    if type(_G.GetContainerNumSlots) == "function" then
        return _G.GetContainerNumSlots(bag) or 0
    end
    return 0
end

-- 统一返回：{ icon, count, quality, itemID, hyperlink, isLocked, hasNoValue }
function Container.ItemInfo(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if not info then return nil end
        return {
            icon       = info.iconFileID,
            count      = info.stackCount,
            quality    = info.quality,
            itemID     = info.itemID,
            hyperlink  = info.hyperlink,
            isLocked   = info.isLocked,
            hasNoValue = info.hasNoValue,
        }
    end
    if type(_G.GetContainerItemInfo) ~= "function" then return nil end
    local icon, count, locked, quality, _readable, _lootable, hyperlink, _filtered, noValue, itemID =
        _G.GetContainerItemInfo(bag, slot)
    if not icon and not hyperlink then return nil end
    return {
        icon       = icon,
        count      = count,
        quality    = quality,
        itemID     = itemID,
        hyperlink  = hyperlink,
        isLocked   = locked,
        hasNoValue = noValue,
    }
end

function Container.Link(bag, slot)
    if C_Container and C_Container.GetContainerItemLink then
        return C_Container.GetContainerItemLink(bag, slot)
    end
    if type(_G.GetContainerItemLink) == "function" then
        return _G.GetContainerItemLink(bag, slot)
    end
    return nil
end

-- 商人界面打开时，对背包格子调用 UseContainerItem 等价于"出售给商人"
function Container.Use(bag, slot)
    if C_Container and C_Container.UseContainerItem then
        local ok = pcall(C_Container.UseContainerItem, bag, slot)
        if ok then return true end
    end
    if type(_G.UseContainerItem) == "function" then
        local ok = pcall(_G.UseContainerItem, bag, slot)
        if ok then return true end
    end
    return false
end

---------------------------------------------------------------- 存档初始化
local function EnsureDB()
    if type(WuXianAutoSellDB) ~= "table" then
        WuXianAutoSellDB = {}
    end
    if type(WuXianAutoSellDB.blacklist) ~= "table" then
        WuXianAutoSellDB.blacklist = {}
    end
    if WuXianAutoSellDB.enabled == nil then
        WuXianAutoSellDB.enabled = true
    end
    if WuXianAutoSellDB.verbose == nil then
        WuXianAutoSellDB.verbose = false
    end
    db = WuXianAutoSellDB
    NS.db = db
    return db
end
NS.EnsureDB = EnsureDB

---------------------------------------------------------------- 背包扫描
local function MaxBagIndex()
    return tonumber(_G.NUM_BAG_SLOTS) or 4
end

-- 扫描背包，返回第一个可以安全出售的灰色物品
-- 返回值：target 表（bag / slot / key / itemID / link / count），或 nil + 是否跳过了灰色物品
local function FindSellable(attempts)
    local maxBag = MaxBagIndex()
    local skipped = false

    for bag = 0, maxBag do
        local slots = Container.NumSlots(bag)
        for slot = 1, slots do
            local info = Container.ItemInfo(bag, slot)
            if info and info.quality == 0 then
                local key       = bag .. ":" .. slot
                local hyperlink = info.hyperlink or Container.Link(bag, slot)
                local itemID    = info.itemID or ItemIDFromLink(hyperlink)

                if itemID and db and db.blacklist and db.blacklist[itemID] then
                    -- 永不卖出名单中的物品：直接跳过，不提示
                elseif info.hasNoValue or info.isLocked then
                    -- 商人不出价 / 物品被锁定（交易、拍卖、邮寄中）
                    skipped = true
                elseif (attempts[key] or 0) >= MAX_ATTEMPTS then
                    -- 该格子已经重试过多次，仍然卖不出去
                    skipped = true
                else
                    return {
                        bag    = bag,
                        slot   = slot,
                        key    = key,
                        itemID = itemID,
                        link   = hyperlink,
                        count  = info.count,
                    }
                end
            end
        end
    end

    return nil, skipped
end

---------------------------------------------------------------- 自动卖出会话
local ticker = CreateFrame("Frame")
ticker:Hide()

local session = {
    active     = false,
    sold       = 0,
    startMoney = 0,
    startTime  = 0,
    lastSell   = 0,
    nextAction = 0,
    skipped    = false,
    attempts   = {},
    pending    = nil,
}

local function FlushPending()
    local p = session.pending
    if not p then return end
    session.pending = nil
    local info = Container.ItemInfo(p.bag, p.slot)
    -- 物品已消失或该格已换成别的物品 => 认定为卖出成功
    if not info or info.itemID ~= p.itemID then
        session.sold = session.sold + (tonumber(p.count) or 1)
    end
end

local function StopSession(reason)
    if not session.active then return end
    FlushPending()
    session.active = false
    ticker:Hide()

    local gained = 0
    if type(_G.GetMoney) == "function" then
        gained = (tonumber(_G.GetMoney()) or 0) - session.startMoney
    end
    if gained < 0 then gained = 0 end

    if session.sold > 0 then
        Print(string.format("本次共卖出 %d 件灰色物品，获得 %s。", session.sold, FormatMoney(gained)))
        if session.skipped and reason ~= "disabled" then
            Print("背包里仍有无法出售的灰色物品（商人不收购或被锁定），已跳过。")
        end
    elseif reason == "done" or reason == "closed" then
        if session.skipped then
            Print("没有可出售的灰色物品（部分灰色物品商人不收购，已跳过）。")
        else
            Print("背包里没有可出售的灰色物品。")
        end
    end

    session.attempts = {}
    session.skipped  = false
end

local function StartSession()
    if not db then return end
    if not db.enabled then return end
    if session.active then return end
    if not MerchantOpen() then return end

    session.active     = true
    session.sold       = 0
    session.startMoney = (type(_G.GetMoney) == "function" and tonumber(_G.GetMoney())) or 0
    session.startTime  = GetTime()
    session.lastSell   = 0
    session.nextAction = GetTime() + 0.2
    session.skipped    = false
    session.attempts   = {}
    session.pending    = nil

    ticker:Show()
end
NS.StartSession  = StartSession
NS.StopSession   = StopSession
NS.IsSelling     = function() return session.active end

local tickAccum = 0

ticker:SetScript("OnUpdate", function(self, elapsed)
    if not session.active then
        self:Hide()
        return
    end

    tickAccum = tickAccum + (elapsed or 0)
    if tickAccum < TICK_INTERVAL then return end
    tickAccum = 0

    -- 商人界面已经关闭，立刻结算
    if not MerchantOpen() then
        StopSession("closed")
        return
    end

    local now = GetTime()
    if now < session.nextAction then return end

    local target, skipped = FindSellable(session.attempts)
    if skipped then session.skipped = true end

    if not target then
        local since = (session.lastSell > 0) and session.lastSell or session.startTime
        if now - since >= IDLE_WAIT then
            StopSession("done")
        else
            session.nextAction = now + 0.2
        end
        return
    end

    session.nextAction = now + SELL_INTERVAL
    session.attempts[target.key] = (session.attempts[target.key] or 0) + 1
    session.lastSell = now

    if db and db.verbose then
        Print(string.format("卖出 %s x%s",
            tostring(target.link or ("itemID " .. tostring(target.itemID))),
            tostring(target.count or 1)))
    end

    -- 先记下这一件，等下次扫描确认它真的从格子里消失后才计入已卖出
    FlushPending()
    session.pending = { bag = target.bag, slot = target.slot, itemID = target.itemID, count = target.count }

    if not Container.Use(target.bag, target.slot) then
        Print("调用出售接口失败，本次自动卖出已中止。")
        StopSession("silent")
    end
end)

---------------------------------------------------------------- 光标 / 鼠标指向物品
local function GetCursorItemID()
    -- 通用：GetCursorInfo() 返回 type, id, link
    if type(_G.GetCursorInfo) == "function" then
        local cType, cID, cLink = _G.GetCursorInfo()
        if cType == "item" then
            if type(cID) == "string" and cLink == nil then
                cLink = cID
                cID = nil
            end
            local itemID = (type(cID) == "number") and cID or ItemIDFromLink(cLink)
            if itemID then return itemID, cLink end
        end
    end
    return nil
end

-- 鼠标悬停在背包格子（未拾起）时，尽量从界面元素上解析出物品
local function GetHoveredBagItemID()
    if type(_G.GetMouseFocus) ~= "function" then return nil end
    local frame = _G.GetMouseFocus()
    if not frame then return nil end

    local bag, slot
    if frame.bag ~= nil and frame.slot ~= nil then
        bag, slot = frame.bag, frame.slot
    elseif frame.GetBagAndSlot then
        local ok, b, s = pcall(frame.GetBagAndSlot, frame)
        if ok and b ~= nil and s ~= nil then
            bag, slot = b, s
        end
    end
    if bag == nil or slot == nil then return nil end

    local info = Container.ItemInfo(bag, slot)
    local link = (info and info.hyperlink) or Container.Link(bag, slot)
    local itemID = (info and info.itemID) or ItemIDFromLink(link)
    return itemID, link
end

local function ResolveTargetItemID()
    local itemID, link = GetCursorItemID()
    if itemID then return itemID, link end
    return GetHoveredBagItemID()
end

---------------------------------------------------------------- 永不卖出名单操作
local function CountBlacklist()
    local n = 0
    if db and db.blacklist then
        for _ in pairs(db.blacklist) do n = n + 1 end
    end
    return n
end

local function AddToBlacklist(itemID, link)
    if not db then return end
    if not itemID then
        Print("请先把鼠标指向背包里的物品（或把它拾起到光标上），再输入 /wjw sell add。")
        return
    end
    if db.blacklist[itemID] then
        Print(string.format("「%s」已经在永不卖出名单里了。", tostring(db.blacklist[itemID])))
        return
    end

    local name
    if type(_G.GetItemInfo) == "function" then
        local ok, itemName = pcall(_G.GetItemInfo, itemID)
        if ok and itemName then name = itemName end
    end
    if not name then name = link or ("物品 " .. tostring(itemID)) end

    db.blacklist[itemID] = name
    Print(string.format("已加入永不卖出名单：「%s」（itemID %d）。", tostring(name), itemID))

    if NS.RefreshOptions then NS.RefreshOptions() end
end

local function ListBlacklist()
    if not db then return end
    local total = CountBlacklist()
    if total == 0 then
        Print("永不卖出名单为空。")
        return
    end

    local ids = {}
    for id in pairs(db.blacklist) do ids[#ids + 1] = id end
    table.sort(ids)

    Print(string.format("永不卖出名单（共 %d 项）：", total))
    for _, id in ipairs(ids) do
        Print(string.format("  %s  (itemID %d)", tostring(db.blacklist[id]), id))
    end
end

local function ClearBlacklist()
    if not db then return end
    local total = CountBlacklist()
    if total == 0 then
        Print("永不卖出名单已经是空的。")
        return
    end
    if type(_G.wipe) == "function" then
        _G.wipe(db.blacklist)
    else
        for k in pairs(db.blacklist) do db.blacklist[k] = nil end
    end
    Print(string.format("已清空永不卖出名单（%d 项）。", total))
    if NS.RefreshOptions then NS.RefreshOptions() end
end

local function RemoveFromBlacklist(arg)
    if not db then return end
    arg = Trim(arg)

    local itemID
    if arg == "" then
        itemID = ResolveTargetItemID()
        if not itemID then
            Print("请把鼠标指向背包里的物品，或输入 /wjw sell remove <itemID|名字片段>。")
            return
        end
    elseif tonumber(arg) then
        itemID = tonumber(arg)
    else
        local needle = arg:lower()
        for id, storedName in pairs(db.blacklist) do
            if tostring(storedName):lower():find(needle, 1, true) then
                itemID = id
                break
            end
        end
        if not itemID then
            Print("名单里没有匹配「" .. arg .. "」的物品。")
            return
        end
    end

    local storedName = db.blacklist[itemID]
    if storedName then
        db.blacklist[itemID] = nil
        Print(string.format("已从名单移除「%s」（itemID %d）。", tostring(storedName), itemID))
        if NS.RefreshOptions then NS.RefreshOptions() end
    else
        Print(string.format("名单里不存在 itemID %d。", itemID))
    end
end

---------------------------------------------------------------- 命令
local function ShowHelp()
    Print("命令列表：")
    Print("  /wjw sell                     开 / 关自动卖出（不带参数直接切换）")
    Print("  /wjw sell on | off | toggle   开启 / 关闭 / 切换自动卖出")
    Print("  /wjw sell status              查看当前开关状态与名单数量")
    Print("  /wjw sell add                 把鼠标指向（或拾起到光标）的物品加入永不卖出名单")
    Print("  /wjw sell remove [ID或名字]   从名单移除物品，不填参数则取光标上的物品")
    Print("  /wjw sell list                查看永不卖出名单")
    Print("  /wjw sell clear               清空永不卖出名单")
    Print("  /wjw sell config              打开设置面板")
    Print("  /wjw sell help                显示本帮助")
    Print("说明：打开商人界面（会买卖的 NPC）时才会自动卖出。")
end

local function SetEnabled(enabled, silent)
    if not db then return end
    db.enabled = enabled and true or false
    if not silent then
        Print("自动卖出已" .. (db.enabled and "|cff00ff00开启|r" or "|cffff5555关闭|r") .. "。")
    end
    if db.enabled then
        if MerchantOpen() then StartSession() end
    elseif session.active then
        StopSession("disabled")
    end
    if NS.RefreshOptions then NS.RefreshOptions() end
end
NS.SetEnabled = SetEnabled

local function SellCommand(msg)
    if not db then EnsureDB() end

    local cmd, rest = Trim(msg):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "toggle" then
        SetEnabled(not db.enabled)
    elseif cmd == "on" or cmd == "1" or cmd == "enable" then
        SetEnabled(true)
    elseif cmd == "off" or cmd == "0" or cmd == "disable" then
        SetEnabled(false)
    elseif cmd == "status" then
        Print("自动卖出当前：" .. (db.enabled and "|cff00ff00开启|r" or "|cffff5555关闭|r")
            .. string.format("；永不卖出名单 %d 项。", CountBlacklist()))
    elseif cmd == "add" then
        AddToBlacklist(ResolveTargetItemID())
    elseif cmd == "remove" or cmd == "del" or cmd == "rm" then
        RemoveFromBlacklist(rest)
    elseif cmd == "list" or cmd == "ls" then
        ListBlacklist()
    elseif cmd == "clear" then
        ClearBlacklist()
    elseif cmd == "config" or cmd == "options" or cmd == "set" then
        if NS.OpenOptions then
            NS.OpenOptions()
        else
            Print("设置面板不可用，请检查 Options.lua 是否随插件一起安装。")
        end
    elseif cmd == "help" or cmd == "?" then
        ShowHelp()
    else
        ShowHelp()
    end
end

NS.SellCommand = SellCommand

---------------------------------------------------------------- 命令总入口
local function ShowWJWHelp()
    Print("wjw_工具箱 · 用法")
    Print("  /wjw qp                           任务寻路：查看当前目标与距离")
    Print("  /wjw qp <x> <y>                   按地图百分比设定目标（0-1 或 0-100）")
    Print("  /wjw qp quest                     用当前选中/追踪的任务设定目标")
    Print("  /wjw qp clear                     清除目标")
    Print("  /wjw qp auto on|off               自动跟随任务开关")
    Print("  /wjw qp arrow on|off              屏幕箭头开关")
    Print("  /wjw qp quiet on|off              静默模式")
    Print("  /wjw qp debug                     打印排障信息")
    Print("  /wjw sell                         自动卖垃圾开/关")
    Print("  /wjw sell on|off|status           开关状态")
    Print("  /wjw sell add|remove|list|clear   永不卖出名单")
    Print("  /wjw sell config                  打开卖垃圾设置面板")
    Print("  /wjw craft                        专业技能升级规划")
    Print("  /wjw craft <目标等级>             规划到指定等级")
    Print("  /wjw craft <专业名> [目标等级]     指定专业规划")
    Print("  /wjw craft skip <材料名>          跳过某材料")
    Print("  /wjw craft skiprecipe <配方名>    跳过某配方")
    Print("  /wjw craft list|reset             查看/清空跳过名单")
    Print("  /wjw craft trainer [专业名]       训练师位置")
    Print("设置页：选项 → 插件 → wjw_工具箱 · 任务寻路 / wjw_工具箱 · 自动卖垃圾 / wjw_工具箱 · 专业技能")
end

SLASH_WJW1 = "/wjw"
SlashCmdList["WJW"] = function(msg)
    local cmd, rest = Trim(msg):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "qp" then
        if QuestPath and QuestPath.HandleSlash then
            QuestPath.HandleSlash(rest)
        else
            Print("任务寻路模块未加载，请检查 PathCore.lua。")
        end
    elseif cmd == "sell" or cmd == "xsell" then
        SellCommand(rest)
    elseif cmd == "craft" then
        if NS.Craft and NS.Craft.Command then
            NS.Craft.Command(rest)
        else
            Print("专业技能模块未加载，请检查 CraftCore.lua 与 CraftCommand.lua。")
        end
    else
        ShowWJWHelp()
    end
end

---------------------------------------------------------------- 事件
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("MERCHANT_SHOW")
eventFrame:RegisterEvent("MERCHANT_CLOSED")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        EnsureDB()
        if NS.InitOptions then NS.InitOptions() end
        Print(string.format("v%s 已加载，自动卖出当前%s。输入 /wjw 查看用法。",
            NS.VERSION, db.enabled and "开启" or "关闭"))
    elseif event == "MERCHANT_SHOW" then
        if db and db.enabled then
            StartSession()
        end
    elseif event == "MERCHANT_CLOSED" then
        if session.active then
            StopSession("closed")
        end
    end
end)
