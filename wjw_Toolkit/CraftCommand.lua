--[[---------------------------------------------------------------------------
    CraftCommand —— 专业技能升级规划 · 命令层

    职责：
      * 解析 /wjw craft 下的全部子命令（规划、跳过名单、训练师位置、帮助）；
      * 维护存档 wjwCraftDB（跳过材料 / 跳过配方 / 上次专业 / 目标等级）；
      * 把 CraftCore 的规划结果与 CraftTrainerData 的训练师坐标输出到聊天框。

    兼容与安全：
      * 数据层（CraftCore.lua）未加载时，所有命令入口直接返回或给出提示，不报错；
      * C_Map.GetPlayerMapPosition / C_Map.GetWorldPosFromMapPos / CreateVector2D
        全部先做 type() 守卫并用 pcall 保护，失败时退回只显示地图名与坐标数字。
-----------------------------------------------------------------------------]]

local ADDON_NAME, NS = ...
local Craft = NS.Craft

-- 数据层完全没有加载：本文件不注册任何命令，直接结束
if type(Craft) ~= "table" then
    return
end

---------------------------------------------------------------- 存档
local db

local function EnsureDB()
    if type(wjwCraftDB) ~= "table" then wjwCraftDB = {} end
    if type(wjwCraftDB.skipMaterials) ~= "table" then wjwCraftDB.skipMaterials = {} end
    if type(wjwCraftDB.skipRecipes) ~= "table" then wjwCraftDB.skipRecipes = {} end
    if type(wjwCraftDB.targetLevel) ~= "number" then wjwCraftDB.targetLevel = nil end
    if type(wjwCraftDB.lastProfession) ~= "string" then wjwCraftDB.lastProfession = nil end
    if wjwCraftDB.autoSelect == nil then wjwCraftDB.autoSelect = true end
    if wjwCraftDB.debug == nil then wjwCraftDB.debug = false end
    db = wjwCraftDB
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        EnsureDB()
    end
end)

---------------------------------------------------------------- 基础工具
local function Trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 统一输出：优先使用数据层的 Craft.Print，缺失时退回卖垃圾模块的 NS.Print
local function Say(msg)
    if type(Craft.Print) == "function" then
        Craft.Print(msg)
    elseif type(NS.Print) == "function" then
        NS.Print(msg)
    elseif type(print) == "function" then
        print(tostring(msg))
    end
end

-- 规划所需的接口是否齐全（CraftCore.lua 已加载）
local function CoreReady()
    return type(Craft) == "table"
        and type(Craft.GetProfessions) == "function"
        and type(Craft.FindProfessionByName) == "function"
        and type(Craft.GetOpenProfession) == "function"
        and type(Craft.EnsureRecipeData) == "function"
        and type(Craft.BuildPlan) == "function"
        and type(Craft.FormatPlan) == "function"
end

---------------------------------------------------------------- 跳过名单
-- 大小写不敏感的包含匹配（任一方包含另一方即视为同一项）
local function IsNameMatch(entry, name)
    if type(entry) ~= "string" or type(name) ~= "string" then
        return false
    end
    local a = string.lower(entry)
    local b = string.lower(name)
    if a == "" or b == "" then
        return false
    end
    return string.find(a, b, 1, true) ~= nil or string.find(b, a, 1, true) ~= nil
end

local function IsInList(list, name)
    if type(list) ~= "table" or type(name) ~= "string" or name == "" then
        return false
    end
    for _, entry in ipairs(list) do
        if IsNameMatch(entry, name) then
            return true
        end
    end
    return false
end

local function AddToList(list, name, label)
    name = Trim(name)
    if name == "" then
        Say(string.format("请提供要加入%s名单的名称。", label or ""))
        return false
    end
    if IsInList(list, name) then
        Say(string.format("「%s」已在%s名单中。", name, label or ""))
        return false
    end
    list[#list + 1] = name
    Say(string.format("已加入%s名单：「%s」。", label or "", name))
    return true
end

local function RemoveFromList(list, name)
    local removed = 0
    if type(list) ~= "table" or type(name) ~= "string" or name == "" then
        return removed
    end
    for i = #list, 1, -1 do
        if IsNameMatch(list[i], name) then
            table.remove(list, i)
            removed = removed + 1
        end
    end
    return removed
end

---------------------------------------------------------------- 规划
local function ListProfessions(profs)
    Say("检测到多个已学专业，请指定专业名：")
    for _, prof in ipairs(profs) do
        Say(string.format("  · %s（技能 %s/%s）",
            tostring(prof.name or ("#" .. tostring(prof.skillLineID))),
            tostring(prof.level or "?"),
            tostring(prof.maxLevel or "?")))
    end
    Say("用法：/wjw craft <专业名> [目标等级]")
end

local function RunPlan(professionName, targetLevel)
    if not CoreReady() then
        Say("专业技能模块未加载，请检查 CraftCore.lua。")
        return
    end
    if not db then EnsureDB() end

    local prof
    if type(professionName) == "string" and professionName ~= "" then
        prof = Craft.FindProfessionByName(professionName)
        if not prof then
            Say(string.format("没有找到专业「%s」。输入 /wjw craft help 查看用法。", professionName))
            return
        end
    else
        local profs = Craft.GetProfessions()
        local openID = Craft.GetOpenProfession()
        if openID then
            for _, p in ipairs(profs) do
                if p.skillLineID == openID then
                    prof = p
                    break
                end
            end
        end
        if not prof then
            if #profs == 1 then
                prof = profs[1]
            elseif #profs > 1 then
                ListProfessions(profs)
                return
            else
                Say("没有读到已学专业。请先打开专业窗口（默认快捷键 K）再试。")
                return
            end
        end
    end

    local skillLineID = tonumber(prof.skillLineID)
    if not skillLineID then
        Say("读不到该专业的技能线 ID，无法规划。")
        return
    end

    if not Craft.EnsureRecipeData(skillLineID) then
        Say("读不到配方数据，请先打开该专业的制作窗口再试（打开后再执行一次本命令）。")
        return
    end

    local plan, err = Craft.BuildPlan(skillLineID, targetLevel, {
        skipMaterials = db.skipMaterials,
        skipRecipes  = db.skipRecipes,
    })
    if not plan then
        Say("规划失败：" .. tostring(err or "未知原因"))
        return
    end

    for _, line in ipairs(Craft.FormatPlan(plan)) do
        Craft.Print(line)
    end
    if type(plan.professionName) == "string" then
        db.lastProfession = plan.professionName
    end
end

---------------------------------------------------------------- 训练师位置
local MAX_TRAINERS = 12

-- 八方位（世界坐标 X 轴为南北、Y 轴为东西且西为正）
local DIRECTIONS = { "正北", "东北", "正东", "东南", "正南", "西南", "正西", "西北" }

local function Atan2(y, x)
    if type(math.atan2) == "function" then
        return math.atan2(y, x)
    end
    if x > 0 then
        return math.atan(y / x)
    elseif x < 0 then
        return math.atan(y / x) + ((y >= 0) and math.pi or -math.pi)
    elseif y > 0 then
        return math.pi / 2
    elseif y < 0 then
        return -math.pi / 2
    end
    return 0
end

-- 取 Vector2D 的 xy 分量；不同版本可能是带 GetXY 方法的用户数据或普通表
local function GetVectorXY(v)
    if type(v) ~= "table" and type(v) ~= "userdata" then
        return nil
    end
    if type(v.GetXY) == "function" then
        local ok, x, y = pcall(v.GetXY, v)
        if ok and type(x) == "number" and type(y) == "number" then
            return x, y
        end
    end
    if type(v.x) == "number" and type(v.y) == "number" then
        return v.x, v.y
    end
    return nil
end

-- 从 GetWorldPosFromMapPos 的返回值中取出世界坐标向量。
-- 该接口在不同客户端/版本里的返回顺序不一致（worldPos 在前，或 instanceID 在前，
-- 本插件的 PathMap.lua 实测为 instanceID 在前），这里对两个返回值都做探测，
-- 取其中能读出 xy 的那个，两种顺序都能用。
local function ExtractWorldPos(a, b)
    local x, y = GetVectorXY(a)
    if x then
        return x, y
    end
    x, y = GetVectorXY(b)
    if x then
        return x, y
    end
    return nil
end

-- 地图百分比坐标（0–1）→ 世界坐标；接口缺失或调用失败返回 nil
local function MapPosToWorld(mapID, x, y)
    if type(mapID) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
        return nil
    end
    if type(_G.C_Map) ~= "table" or type(_G.C_Map.GetWorldPosFromMapPos) ~= "function" then
        return nil
    end
    -- 优先用 CreateVector2D；缺失时退回普通表（PathMap.lua 已验证该形式可用）
    local mapPos
    if type(_G.CreateVector2D) == "function" then
        local okVec, vec = pcall(_G.CreateVector2D, x, y)
        if okVec then
            mapPos = vec
        end
    end
    if not mapPos then
        mapPos = { x = x, y = y }
    end
    local okWorld, first, second = pcall(_G.C_Map.GetWorldPosFromMapPos, mapID, mapPos)
    if not okWorld then
        return nil
    end
    return ExtractWorldPos(first, second)
end

-- 玩家在当前地图的世界坐标；任一环节失败返回 nil
local function GetPlayerWorldPos(mapID)
    if type(mapID) ~= "number" then
        return nil
    end
    if type(_G.C_Map) ~= "table"
        or type(_G.C_Map.GetPlayerMapPosition) ~= "function"
        or type(_G.C_Map.GetWorldPosFromMapPos) ~= "function" then
        return nil
    end
    local okPos, pos = pcall(_G.C_Map.GetPlayerMapPosition, mapID, "player")
    if not okPos or not pos then
        return nil
    end
    local okWorld, first, second = pcall(_G.C_Map.GetWorldPosFromMapPos, mapID, pos)
    if not okWorld then
        return nil
    end
    return ExtractWorldPos(first, second)
end

-- 返回：距离（码）、八方位中文名
local function DescribeRelative(playerX, playerY, targetX, targetY)
    local dNorth = targetX - playerX   -- X 轴：北为正
    local dWest  = targetY - playerY   -- Y 轴：西为正
    local dEast  = -dWest
    local distance = math.sqrt(dNorth * dNorth + dWest * dWest)
    local bearing = math.deg(Atan2(dEast, dNorth))
    local index = math.floor(((bearing + 22.5) % 360) / 45) + 1
    return distance, (DIRECTIONS[index] or "未知")
end

local function GetMapName(uiMapID)
    if type(uiMapID) ~= "number" then
        return nil
    end
    if type(_G.C_Map) ~= "table" or type(_G.C_Map.GetMapInfo) ~= "function" then
        return nil
    end
    local ok, info = pcall(_G.C_Map.GetMapInfo, uiMapID)
    if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
        return info.name
    end
    return nil
end

local function GetCurrentMapID()
    if type(_G.C_Map) ~= "table" or type(_G.C_Map.GetBestMapForUnit) ~= "function" then
        return nil
    end
    local ok, mapID = pcall(_G.C_Map.GetBestMapForUnit, "player")
    if ok and type(mapID) == "number" then
        return mapID
    end
    return nil
end

-- 玩家地图链：自身 + 至多 maxDepth 级父地图（层级固定，不做无上限循环）
local function GetMapChain(mapID, maxDepth)
    local chain = {}
    if type(mapID) ~= "number" then
        return chain
    end
    local id = mapID
    for _ = 0, maxDepth do
        chain[#chain + 1] = id
        if type(_G.C_Map) ~= "table" or type(_G.C_Map.GetMapInfo) ~= "function" then
            break
        end
        local ok, info = pcall(_G.C_Map.GetMapInfo, id)
        if not ok or type(info) ~= "table"
            or type(info.parentMapID) ~= "number" or info.parentMapID == 0 then
            break
        end
        id = info.parentMapID
    end
    return chain
end

-- 解析 trainer 参数：识别 all 关键字，其余部分原样作为类型名
local function ParseTrainerArgs(args)
    local showAll = false
    local words = {}
    for token in tostring(args or ""):gmatch("%S+") do
        if string.lower(token) == "all" then
            showAll = true
        else
            words[#words + 1] = token
        end
    end
    local typeName = Trim(table.concat(words, " "))
    if typeName == "" then
        typeName = nil
    end
    return typeName, showAll
end

-- 收集候选训练师：{ trainer = 记录, typeName = 类型名, ui = uiMapID }
-- typeName 为 nil 时收集全部类型（类型顺序固定按名称排序，类型内保持数据原顺序）
local function CollectTrainers(typeName)
    local list = {}
    if type(Craft.Trainers) ~= "table" then
        return list
    end
    local zoneMap = (type(Craft.TrainerZoneMap) == "table") and Craft.TrainerZoneMap or nil

    local function add(typeKey, trainers)
        if type(trainers) ~= "table" then
            return
        end
        for _, t in ipairs(trainers) do
            local ui = zoneMap and zoneMap[t.zone] or nil
            list[#list + 1] = { trainer = t, typeName = typeKey, ui = ui }
        end
    end

    if typeName then
        add(typeName, Craft.Trainers[typeName])
    else
        local typeNames = {}
        for typeKey in pairs(Craft.Trainers) do
            if type(typeKey) == "string" then
                typeNames[#typeNames + 1] = typeKey
            end
        end
        table.sort(typeNames)
        for _, typeKey in ipairs(typeNames) do
            add(typeKey, Craft.Trainers[typeKey])
        end
    end
    return list
end

-- 当前地图过滤：精确匹配 → 父地图 → 祖父地图（最多回退 2 级，命中即停）
local function FilterByCurrentMap(candidates, currentMap)
    for _, mapID in ipairs(GetMapChain(currentMap, 2)) do
        local matched = {}
        for _, c in ipairs(candidates) do
            if c.ui == mapID then
                matched[#matched + 1] = c
            end
        end
        if #matched > 0 then
            return matched
        end
    end
    return {}
end

-- skillLineID → 专业名：先查已学专业列表，再退回 C_TradeSkillUI
local function GetProfessionNameBySkillLine(skillLineID)
    if type(skillLineID) ~= "number" then
        return nil
    end
    if type(Craft.GetProfessions) == "function" then
        local ok, professions = pcall(Craft.GetProfessions)
        if ok and type(professions) == "table" then
            for _, profession in ipairs(professions) do
                if type(profession) == "table" and profession.skillLineID == skillLineID
                    and type(profession.name) == "string" and profession.name ~= "" then
                    return profession.name
                end
            end
        end
    end
    local UI = _G.C_TradeSkillUI
    if type(UI) == "table" and type(UI.GetProfessionInfoBySkillLineID) == "function" then
        local ok, info = pcall(UI.GetProfessionInfoBySkillLineID, skillLineID)
        if ok and type(info) == "table" and type(info.professionName) == "string"
            and info.professionName ~= "" then
            return info.professionName
        end
    end
    return nil
end

-- 专业名 → Craft.Trainers 的键。数据层键名有简称（如「炼金」「草药」），
-- 而游戏读到的专业名可能是「炼金术」「草药学」，先精确匹配再做双向包含匹配。
local function FindTrainerTypeKey(professionName)
    local trainers = Craft.Trainers
    if type(trainers) ~= "table" or type(professionName) ~= "string" or professionName == "" then
        return nil
    end
    if type(trainers[professionName]) == "table" then
        return professionName
    end
    local keys = {}
    for key in pairs(trainers) do
        if type(key) == "string" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        if type(trainers[key]) == "table" and IsNameMatch(key, professionName) then
            return key
        end
    end
    return nil
end

-- 当前专业名：① 当前打开的专业窗口；② 上次规划过的专业。都读不到返回 nil。
local function GetCurrentProfessionName()
    if type(Craft.GetOpenProfession) == "function" then
        local ok, skillLineID = pcall(Craft.GetOpenProfession)
        if ok then
            local name = GetProfessionNameBySkillLine(skillLineID)
            if name then
                return name
            end
        end
    end
    if db and type(db.lastProfession) == "string" and db.lastProfession ~= "" then
        return db.lastProfession
    end
    return nil
end

local function ShowTrainers(args)
    if not db then EnsureDB() end

    local typeName, showAll = ParseTrainerArgs(args)
    local queryCurrentProfession = false

    -- 无类型名且未加 all：跟随当前专业；识别不到就提示用法，不退化成全部类型
    if not typeName and not showAll then
        local professionName = GetCurrentProfessionName()
        if professionName then
            typeName = FindTrainerTypeKey(professionName) or professionName
        end
        if not typeName then
            Say("未识别当前专业。用法：/wjw craft trainer <专业名>，例如 /wjw craft trainer 工程学")
            return
        end
        queryCurrentProfession = true
    end

    local candidates = CollectTrainers(typeName)

    if #candidates == 0 then
        if typeName then
            Say(string.format("内置数据中没有「%s」的训练师坐标。", typeName))
        else
            Say("内置数据中没有训练师坐标。")
        end
        return
    end

    local total = #candidates
    local currentMap = GetCurrentMapID()

    if not showAll then
        if not currentMap then
            Say("无法获取玩家当前地图。用 /wjw craft trainer all 查看全部训练师。")
            return
        end
        candidates = FilterByCurrentMap(candidates, currentMap)
        if #candidates == 0 then
            if typeName then
                Say(string.format("当前地图没有查到「%s」训练师。用 /wjw craft trainer %s all 查看全部 %d 条。",
                    typeName, typeName, total))
            else
                Say(string.format("当前地图没有查到训练师。用 /wjw craft trainer all 查看全部 %d 条。", total))
            end
            return
        end
    end

    local playerX, playerY
    if currentMap then
        playerX, playerY = GetPlayerWorldPos(currentMap)
    end

    -- 逐条算出与玩家的距离；算不出来时 distance 保持 nil，输出退回地图与坐标
    local entries = {}
    for index, c in ipairs(candidates) do
        local t = c.trainer
        local entry = { candidate = c, index = index }
        if c.ui and currentMap and c.ui == currentMap and playerX and playerY then
            local tx, ty = MapPosToWorld(c.ui, (tonumber(t.x) or 0) / 100, (tonumber(t.y) or 0) / 100)
            if tx and ty then
                entry.distance, entry.direction = DescribeRelative(playerX, playerY, tx, ty)
            end
        end
        entries[#entries + 1] = entry
    end

    -- 当前地图的列表按距离由近到远排序；算不出距离的排在有距离的条目之后，
    -- 距离相同或都算不出时保持数据原顺序（用 index 兜底，table.sort 本身不稳定）
    if not showAll then
        table.sort(entries, function(a, b)
            if a.distance and b.distance then
                if a.distance ~= b.distance then
                    return a.distance < b.distance
                end
            elseif a.distance then
                return true
            elseif b.distance then
                return false
            end
            return a.index < b.index
        end)
    end

    local header
    if queryCurrentProfession then
        header = string.format("最近的「%s」训练师：", typeName)
    elseif typeName then
        header = showAll
            and string.format("「%s」训练师（共 %d 条）：", typeName, #entries)
            or string.format("当前地图的「%s」训练师（共 %d 条）：", typeName, #entries)
    else
        header = string.format("全部训练师（共 %d 条）：", #entries)
    end
    Say(header)

    local limit = queryCurrentProfession and 1 or MAX_TRAINERS
    local showTypeName = (typeName == nil)
    local shown = 0
    for _, entry in ipairs(entries) do
        if shown >= limit then
            break
        end

        local c = entry.candidate
        local t = c.trainer
        local line = nil
        if entry.distance then
            line = string.format("%s（距离 %d 码，%s方向）",
                tostring(t.name), math.floor(entry.distance + 0.5), entry.direction)
        else
            local mapName = GetMapName(c.ui) or ("地图 " .. tostring(t.zone))
            line = string.format("%s · %s · 坐标 (%.2f, %.2f)",
                tostring(t.name), mapName, tonumber(t.x) or 0, tonumber(t.y) or 0)
        end
        if showTypeName then
            line = c.typeName .. " · " .. line
        end

        Say(line)
        shown = shown + 1
    end

    -- 默认路径只给最近的一条，不再追加「还有 N 条未显示」；显式列类型时保留截断提示
    if not queryCurrentProfession and #entries > shown then
        Say(string.format("还有 %d 条未显示。", #entries - shown))
    end
end

---------------------------------------------------------------- 帮助
local function ShowHelp()
    Say("专业技能升级规划 · 用法：")
    Say("  /wjw craft                     规划当前打开（或上次使用）的专业到断点")
    Say("  /wjw craft 300                 规划到指定等级")
    Say("  /wjw craft <专业名> [目标等级]  指定专业（和目标）后规划")
    Say("  /wjw craft skip <材料名>        把材料加入跳过名单")
    Say("  /wjw craft skiprecipe <配方名>  把配方加入跳过名单")
    Say("  /wjw craft unskip <名称>        从两个跳过名单中移除")
    Say("  /wjw craft list                 查看两个跳过名单")
    Say("  /wjw craft reset                清空跳过名单与目标等级")
    Say("  /wjw craft trainer [类型] [all]  查询训练师（默认当前专业最近的一个；类型列当前地图该类型；all 列全部）")
    Say("  /wjw craft help                 显示本帮助")
    Say("说明：读配方前需先打开过该专业的制作窗口；等级与涨点概率均为估算。")
end

---------------------------------------------------------------- 命令入口
function Craft.Command(msg)
    if not db then EnsureDB() end

    local cmd, rest = Trim(msg):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    rest = Trim(rest or "")

    if cmd == "" then
        RunPlan(nil, db.targetLevel)

    elseif cmd:match("^%d+$") then
        RunPlan(nil, tonumber(cmd))

    elseif cmd == "skip" then
        AddToList(db.skipMaterials, rest, "跳过材料")

    elseif cmd == "skiprecipe" then
        AddToList(db.skipRecipes, rest, "跳过配方")

    elseif cmd == "unskip" then
        local name = Trim(rest)
        if name == "" then
            Say("用法：/wjw craft unskip <名称>")
            return
        end
        local a = RemoveFromList(db.skipMaterials, name)
        local b = RemoveFromList(db.skipRecipes, name)
        if a + b > 0 then
            Say(string.format("已从名单移除「%s」（材料 %d 项、配方 %d 项）。", name, a, b))
        else
            Say(string.format("两个名单里都没有匹配「%s」的项。", name))
        end

    elseif cmd == "list" then
        local materials = (#db.skipMaterials > 0) and table.concat(db.skipMaterials, "、") or "无"
        local recipes = (#db.skipRecipes > 0) and table.concat(db.skipRecipes, "、") or "无"
        Say(string.format("跳过材料（%d）：%s", #db.skipMaterials, materials))
        Say(string.format("跳过配方（%d）：%s", #db.skipRecipes, recipes))

    elseif cmd == "reset" then
        db.skipMaterials = {}
        db.skipRecipes = {}
        db.targetLevel = nil
        Say("已清空跳过名单与目标等级。")

    elseif cmd == "trainer" then
        ShowTrainers(rest)

    elseif cmd == "help" or cmd == "?" then
        ShowHelp()

    else
        -- 其余情况视为「专业名 [目标等级]」：cmd 是专业名，rest 的首词若是纯数字则作为目标
        local target = nil
        local first = rest:match("^(%S+)")
        if first and first:match("^%d+$") then
            target = tonumber(first)
        end
        RunPlan(cmd, target)
    end
end
