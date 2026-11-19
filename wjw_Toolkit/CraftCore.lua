--[[---------------------------------------------------------------------------
    CraftCore —— 专业技能升级规划 · 数据读取层

    职责：
      * 只负责"读"：已学专业列表、当前打开的专业、某专业的配方、配方的材料、
        背包/银行里的材料数量。
      * 不做任何规划计算、不画界面、不注册命令——这些由上层模块使用本文件的
        返回值自行实现。

    兼容与安全：
      * 所有 C_TradeSkillUI / C_Item 调用都先用 type() 守卫，再用 pcall 保护；
        接口不存在或调用失败时返回空值（{} / 0 / nil），绝不抛错、也不把失败
        当成成功。
      * 配方枚举（GetAllRecipeIDs）只有在"该专业窗口打开过一次"后才返回数据，
        因此提供 EnsureRecipeData 供上层在需要时主动打开专业窗口。
      * 导出的全部接口挂在 NS.Craft 子表下，避免与卖垃圾模块的 NS 字段冲突。

    已知限制（游戏内待复核）：
      * 读到的配方永远是"当前游戏里打开的那个专业"的配方，skillLineID 参数只
        用于调用一致性，不能切换到别的专业；要换专业必须先打开对应专业窗口。
      * GetRecipeSchematic 的返回结构在不同版本里字段名有差异（id / itemID），
        本文件对两种形态都做了兼容。
-----------------------------------------------------------------------------]]

local ADDON_NAME, NS = ...

local Craft = NS.Craft or {}
NS.Craft = Craft

Craft.ADDON_NAME = ADDON_NAME
Craft.PREFIX     = "|cff33ff99[wjw_工具箱]|r "

---------------------------------------------------------------- 基础工具
function Craft.Print(msg)
    local text = Craft.PREFIX .. tostring(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    elseif type(print) == "function" then
        print(text)
    end
end

-- 取 C_TradeSkillUI 表本身；接口整体缺失时返回 nil
local function GetTradeSkillUI()
    local UI = C_TradeSkillUI
    if type(UI) ~= "table" then
        return nil
    end
    return UI
end

---------------------------------------------------------------- 专业列表
-- 返回：{ { skillLineID, name, level, maxLevel, modifier, isPrimary }, ... }
-- API 不存在或未学任何专业时返回空表
-- 数据来源：
--   * 主专业：GetAllProfessionTradeSkillLines 返回的 ID，经 GetProfessionInfoBySkillLineID
--     读取详情；同一专业会出现新旧两个 ID（如工程学 2941 与 202、采矿 2946 与 186）。
--   * 次要专业：上面的接口不返回烹饪/钓鱼/急救/考古，按固定 ID 逐个补充；读不到的
--     跳过（不同版本 ID 可能不同，允许失败）。
--   * 最后按 professionName 去重，同名只保留一条。
Craft.SECONDARY_PROFESSION_IDS = { 185, 356, 129, 794 }

-- 把 GetProfessionInfoBySkillLineID 的返回值转成结果条目；读不到 professionName 返回 nil
local function BuildProfessionEntry(skillLineID, info)
    if type(info) ~= "table" then
        return nil
    end
    local name = info.professionName
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return {
        skillLineID = skillLineID,
        name        = name,
        level       = info.skillLevel,
        maxLevel    = info.maxSkillLevel,
        modifier    = info.skillModifier,
        isPrimary   = info.isPrimaryProfession and true or false,
    }
end

-- 同名专业的去重选优：① 当前打开的专业优先；② skillLevel 更大者；
-- ③ skillLineID 更大者（新版本 ID 通常更大）；全部相同时保留先出现的那条。
local function IsBetterProfessionEntry(candidate, current, selectedSkillLineID)
    local candidateSelected = selectedSkillLineID ~= nil
        and candidate.skillLineID == selectedSkillLineID
    local currentSelected = selectedSkillLineID ~= nil
        and current.skillLineID == selectedSkillLineID
    if candidateSelected ~= currentSelected then
        return candidateSelected
    end
    local candidateLevel = tonumber(candidate.level) or 0
    local currentLevel = tonumber(current.level) or 0
    if candidateLevel ~= currentLevel then
        return candidateLevel > currentLevel
    end
    return (tonumber(candidate.skillLineID) or 0) > (tonumber(current.skillLineID) or 0)
end

function Craft.GetProfessions()
    local result = {}
    local UI = GetTradeSkillUI()
    if not UI or type(UI.GetAllProfessionTradeSkillLines) ~= "function" then
        return result
    end

    local okLines, lines = pcall(UI.GetAllProfessionTradeSkillLines)
    if not okLines or type(lines) ~= "table" then
        return result
    end

    if type(UI.GetProfessionInfoBySkillLineID) ~= "function" then
        return result
    end

    local function ReadProfession(skillLineID)
        if type(skillLineID) ~= "number" then
            return nil
        end
        local okInfo, info = pcall(UI.GetProfessionInfoBySkillLineID, skillLineID)
        if not okInfo then
            return nil
        end
        return BuildProfessionEntry(skillLineID, info)
    end

    local entries = {}
    -- 主专业
    for _, skillLineID in ipairs(lines) do
        local entry = ReadProfession(skillLineID)
        if entry then
            entries[#entries + 1] = entry
        end
    end
    -- 次要专业
    for _, skillLineID in ipairs(Craft.SECONDARY_PROFESSION_IDS) do
        local entry = ReadProfession(skillLineID)
        if entry then
            entries[#entries + 1] = entry
        end
    end

    -- 按 professionName 去重：同名只保留一条，位置沿用首次出现处
    local selectedSkillLineID
    local frame = _G.ProfessionsFrame
    if type(frame) == "table" and type(frame.selectedSkillLine) == "number" then
        selectedSkillLineID = frame.selectedSkillLine
    end

    local indexByName = {}
    for _, entry in ipairs(entries) do
        local index = indexByName[entry.name]
        if not index then
            result[#result + 1] = entry
            indexByName[entry.name] = #result
        elseif IsBetterProfessionEntry(entry, result[index], selectedSkillLineID) then
            result[index] = entry
        end
    end

    return result
end

-- 按名称做包含匹配（大小写不敏感），找不到返回 nil
function Craft.FindProfessionByName(text)
    if type(text) ~= "string" then
        return nil
    end
    local needle = string.lower(text)
    if needle == "" then
        return nil
    end
    for _, prof in ipairs(Craft.GetProfessions()) do
        if type(prof.name) == "string" then
            local haystack = string.lower(prof.name)
            if string.find(haystack, needle, 1, true) then
                return prof
            end
        end
    end
    return nil
end

---------------------------------------------------------------- 当前打开的专业
-- 从专业界面（ProfessionsFrame）读取当前技能线；读不到返回 nil。
-- 不同客户端版本 CraftingPage 上的字段/方法名可能不同，逐个用 type 守卫尝试。
-- 结果会与已学专业列表比对，避免界面结构变化时返回一个错误 ID。
local function GetSkillLineFromFrame()
    local frame = _G.ProfessionsFrame
    if type(frame) ~= "table" then
        return nil
    end
    if type(frame.IsShown) ~= "function" then
        return nil
    end
    local okShown, shown = pcall(frame.IsShown, frame)
    if not okShown or not shown then
        return nil
    end

    local page = frame.CraftingPage
    if type(page) ~= "table" then
        return nil
    end

    local candidates = {}
    candidates[#candidates + 1] = page.skillLineID
    candidates[#candidates + 1] = page.SkillLineID
    if type(page.GetSkillLineID) == "function" then
        local ok, id = pcall(page.GetSkillLineID, page)
        if ok then
            candidates[#candidates + 1] = id
        end
    end

    local known
    for _, id in ipairs(candidates) do
        if type(id) == "number" then
            if known == nil then
                known = {}
                for _, prof in ipairs(Craft.GetProfessions()) do
                    known[prof.skillLineID] = true
                end
            end
            if known[id] then
                return id
            end
        end
    end
    return nil
end

-- 返回当前打开专业的 skillLineID；读不到返回 nil。
-- 顺序：① ProfessionsFrame.selectedSkillLine（本客户端实测字段，是数字，打开烹饪时为 185）；
--       ② 专业界面 CraftingPage 上的候选字段（兜底，见 GetSkillLineFromFrame）；
--       ③ C_TradeSkillUI.GetTradeSkillLine（保留，本客户端不存在）。
function Craft.GetOpenProfession()
    local frame = _G.ProfessionsFrame
    if type(frame) == "table" and type(frame.selectedSkillLine) == "number" then
        return frame.selectedSkillLine
    end

    local fromFrame = GetSkillLineFromFrame()
    if fromFrame then
        return fromFrame
    end

    local UI = GetTradeSkillUI()
    if UI and type(UI.GetTradeSkillLine) == "function" then
        local ok, first = pcall(UI.GetTradeSkillLine)
        -- 只接受数字：部分版本第一个返回值是专业名称字符串，此时算读取失败
        if ok and type(first) == "number" then
            return first
        end
    end

    return nil
end

---------------------------------------------------------------- 配方数据准备
-- 已尝试过打开窗口的专业：每个专业只弹一次窗口，失败后不再重复打扰
local openAttempted = {}

-- 确保该专业的配方数据可读；返回 true/false。
-- GetAllRecipeIDs 已有数据时直接返回 true；否则尝试打开专业窗口后再读一次。
-- 注意：打开窗口是异步的，刚打开后立刻再读可能仍为空，此时返回 false，调用方
-- 可以稍后（如下一次刷新）重新调用本函数再取配方。
function Craft.EnsureRecipeData(skillLineID)
    if type(skillLineID) ~= "number" then
        return false
    end
    local UI = GetTradeSkillUI()
    if not UI or type(UI.GetAllRecipeIDs) ~= "function" then
        return false
    end

    local okIds, ids = pcall(UI.GetAllRecipeIDs)
    if okIds and type(ids) == "table" and #ids > 0 then
        return true
    end

    if openAttempted[skillLineID] then
        return false
    end
    openAttempted[skillLineID] = true

    if type(UI.OpenTradeSkill) ~= "function" then
        return false
    end
    local okOpen = pcall(UI.OpenTradeSkill, skillLineID)
    if not okOpen then
        return false
    end

    -- 打开后立即再读一次；仍为空就如实返回 false（调用方可稍后重试）
    local okRecheck, idsAfter = pcall(UI.GetAllRecipeIDs)
    return okRecheck and type(idsAfter) == "table" and #idsAfter > 0
end

---------------------------------------------------------------- 配方列表
-- 返回当前已打开专业的全部配方（含未学），每条字段见下方构造。
-- skillLineID 仅用于调用一致性；实际读取以游戏当前打开的专业为准。
function Craft.GetRecipes(skillLineID)
    local result = {}
    if type(skillLineID) ~= "number" then
        return result
    end
    local UI = GetTradeSkillUI()
    if not UI or type(UI.GetAllRecipeIDs) ~= "function" then
        return result
    end
    if type(UI.GetRecipeInfo) ~= "function" then
        return result
    end

    local okIds, ids = pcall(UI.GetAllRecipeIDs)
    if not okIds or type(ids) ~= "table" then
        return result
    end

    for _, recipeID in ipairs(ids) do
        if type(recipeID) == "number" then
            local okInfo, info = pcall(UI.GetRecipeInfo, recipeID)
            if okInfo and type(info) == "table" then
                local resolvedID = type(info.recipeID) == "number" and info.recipeID or recipeID
                result[#result + 1] = {
                    recipeID           = resolvedID,
                    name               = info.name,
                    learned            = info.learned and true or false,
                    craftable          = info.craftable and true or false,
                    canSkillUp         = info.canSkillUp and true or false,
                    numSkillUps        = info.numSkillUps or 0,
                    maxTrivialLevel    = info.maxTrivialLevel,
                    relativeDifficulty = info.relativeDifficulty,
                    previousRecipeID   = info.previousRecipeID,
                    nextRecipeID       = info.nextRecipeID,
                }
            end
        end
    end

    return result
end

---------------------------------------------------------------- 材料
-- 返回：{ { itemID, quantity, name }, ... }
-- 解析 GetRecipeSchematic(recipeID, false) 的 reagentSlotSchematics；
-- 每个槽位只取第一条备选材料（数量取该槽位需求数），其余备选忽略。
function Craft.GetRecipeReagents(recipeID)
    local result = {}
    if type(recipeID) ~= "number" then
        return result
    end
    local UI = GetTradeSkillUI()
    if not UI or type(UI.GetRecipeSchematic) ~= "function" then
        return result
    end

    local okSchema, schematic = pcall(UI.GetRecipeSchematic, recipeID, false)
    if not okSchema or type(schematic) ~= "table" then
        return result
    end
    local slots = schematic.reagentSlotSchematics
    if type(slots) ~= "table" then
        return result
    end

    for _, slot in ipairs(slots) do
        local reagents = type(slot) == "table" and slot.reagents or nil
        if type(reagents) == "table" and reagents[1] ~= nil then
            -- 每个槽位只取第一条备选材料，其余备选一律忽略
            local reagent = reagents[1]
            if type(reagent) == "table" then
                -- quantityRequired 缺失时按 1 计
                local quantity = tonumber(slot.quantityRequired) or 1
                -- 兼容两种字段形态：reagents[i].id 与 reagents[i].itemID
                local itemID = reagent.id
                if type(itemID) ~= "number" then
                    itemID = reagent.itemID
                end
                if type(itemID) == "number" then
                    result[#result + 1] = {
                        itemID   = itemID,
                        quantity = quantity,
                        name     = Craft.GetItemName(itemID),
                    }
                end
            end
        end
    end

    return result
end

---------------------------------------------------------------- 物品
-- 物品名称：先按 ID 查本地数据，查不到时退化为 ID 字符串；nil 输入返回空串
function Craft.GetItemName(itemID)
    if type(itemID) ~= "number" then
        return ""
    end
    local Item = C_Item
    if type(Item) == "table" then
        if type(Item.GetItemNameByID) == "function" then
            local ok, name = pcall(Item.GetItemNameByID, itemID)
            if ok and type(name) == "string" and name ~= "" then
                return name
            end
        end
        if type(Item.GetItemInfo) == "function" then
            local ok, name = pcall(Item.GetItemInfo, itemID)
            if ok and type(name) == "string" and name ~= "" then
                return name
            end
        end
    end
    return tostring(itemID)
end

-- 材料持有数量：含银行、材料银行、账号银行（不含公会银行）；API 缺失返回 0
function Craft.GetItemCount(itemID)
    if type(itemID) ~= "number" then
        return 0
    end
    local Item = C_Item
    if type(Item) ~= "table" or type(Item.GetItemCount) ~= "function" then
        return 0
    end
    local ok, count = pcall(Item.GetItemCount, itemID, true, false, true, true)
    if not ok or type(count) ~= "number" then
        return 0
    end
    return count
end

-- 当前材料/天赋条件下该配方的可制作次数；API 缺失或读取失败返回 0
function Craft.GetCraftableCount(recipeID)
    if type(recipeID) ~= "number" then
        return 0
    end
    local UI = GetTradeSkillUI()
    if not UI or type(UI.GetCraftableCount) ~= "function" then
        return 0
    end
    local ok, count = pcall(UI.GetCraftableCount, recipeID)
    if not ok or type(count) ~= "number" then
        return 0
    end
    return count
end

---------------------------------------------------------------- 升级规划（算法层）
-- 本段只使用文件内已导出的函数（GetProfessions / GetRecipes / GetRecipeReagents /
-- GetItemCount），不调用任何新的 WoW API，不注册命令、不涉及界面。
-- 口径：只看已学配方；不考虑金币价格，只按材料件数最省；优先消耗现有材料并输出缺口。

-- 涨点概率估算（社区经验值，非官方数据）：橙 100%、黄 60%、绿 25%
Craft.SKILLUP_CHANCE = { orange = 1.00, yellow = 0.60, green = 0.25 }

-- 难度分段的经验比例：配方有效区间的前 25% 视为橙、25%-65% 视为黄、余下视为绿
-- （官方不公开分界，此处为估算，输出中必须标注）
Craft.DIFFICULTY_BANDS = { orange = 0.25, yellow = 0.65 }

-- 名字是否命中跳过名单（精确匹配；名单不是表或名字不是字符串时视为不跳过）
local function IsSkipped(name, list)
    if type(name) ~= "string" or type(list) ~= "table" then
        return false
    end
    for _, entry in ipairs(list) do
        if type(entry) == "string" and entry == name then
            return true
        end
    end
    return false
end

-- 期望制作次数：把 [fromLevel, toLevel] 按 DIFFICULTY_BANDS 比例切成橙/黄/绿三段，
-- 每段要涨 N 点，期望次数 = ceil(N / (numSkillUps * chance))，三段相加。
-- 说明：分段比例按“本次规划的子区间”计算；官方不公开分界，此为估算。
local function ExpectedCrafts(fromLevel, toLevel, numSkillUps)
    local span = toLevel - fromLevel
    if span <= 0 then
        return 0
    end
    local bands = Craft.DIFFICULTY_BANDS
    local chance = Craft.SKILLUP_CHANCE
    local orangeEnd = fromLevel + span * bands.orange
    local yellowEnd = fromLevel + span * bands.yellow
    local sections = {
        { levels = orangeEnd - fromLevel, chance = chance.orange },
        { levels = yellowEnd - orangeEnd, chance = chance.yellow },
        { levels = toLevel - yellowEnd,     chance = chance.green },
    }
    local total = 0
    for _, section in ipairs(sections) do
        if section.levels > 0 then
            total = total + math.ceil(section.levels / (numSkillUps * section.chance))
        end
    end
    return total
end

-- 单条配方的单次制作材料表：{ { itemID, name, perCraft }, ... }
-- 说明：GetRecipeReagents 每个槽位只返回第一条备选材料，此处按 itemID 合并
-- 同一配方里多个槽位用到同一种材料的需求。
local function BuildRecipeReagentList(recipeID)
    local byItem = {}
    local order = {}
    for _, reagent in ipairs(Craft.GetRecipeReagents(recipeID)) do
        local itemID = reagent.itemID
        local quantity = tonumber(reagent.quantity) or 1
        if type(itemID) == "number" and quantity > 0 then
            if not byItem[itemID] then
                byItem[itemID] = { itemID = itemID, name = reagent.name, perCraft = 0 }
                order[#order + 1] = itemID
            end
            byItem[itemID].perCraft = byItem[itemID].perCraft + quantity
        end
    end
    local list = {}
    for _, itemID in ipairs(order) do
        list[#list + 1] = byItem[itemID]
    end
    return list
end

-- 候选池：已学、maxTrivialLevel 为数字且高于当前等级、配方名与材料名都不在跳过名单
local function CollectCandidates(skillLineID, currentLevel, options)
    local candidates = {}
    local skipRecipes = options.skipRecipes
    local skipMaterials = options.skipMaterials

    for _, recipe in ipairs(Craft.GetRecipes(skillLineID)) do
        local maxTrivial = recipe.maxTrivialLevel
        if recipe.learned == true
            and type(maxTrivial) == "number"
            and maxTrivial > currentLevel
            and not IsSkipped(recipe.name, skipRecipes) then
            local reagents = BuildRecipeReagentList(recipe.recipeID)
            local skippedByMaterial = false
            local perCraftCount = 0
            for _, reagent in ipairs(reagents) do
                perCraftCount = perCraftCount + reagent.perCraft
                if IsSkipped(reagent.name, skipMaterials) then
                    skippedByMaterial = true
                end
            end
            if not skippedByMaterial then
                local numSkillUps = tonumber(recipe.numSkillUps) or 0
                if numSkillUps <= 0 then
                    numSkillUps = 1
                end
                candidates[#candidates + 1] = {
                    recipeID = recipe.recipeID,
                    name = recipe.name or tostring(recipe.recipeID),
                    maxTrivialLevel = maxTrivial,
                    numSkillUps = numSkillUps,
                    reagents = reagents,
                    perCraftCount = perCraftCount,
                }
            end
        end
    end

    return candidates
end

-- 生成升级规划；失败时返回 nil, 原因。
-- options = { skipRecipes = { 配方名, ... }, skipMaterials = { 材料名, ... } }
function Craft.BuildPlan(skillLineID, targetLevel, options)
    if type(skillLineID) ~= "number" then
        return nil, "skillLineID 无效"
    end
    if type(options) ~= "table" then
        options = {}
    end

    local requestedTarget = nil
    if type(targetLevel) == "number" then
        requestedTarget = targetLevel
    end

    local profession
    for _, prof in ipairs(Craft.GetProfessions()) do
        if prof.skillLineID == skillLineID then
            profession = prof
            break
        end
    end
    if not profession or type(profession.level) ~= "number" then
        return nil, "读不到该专业的技能等级（专业未学或接口不可用）"
    end

    local currentLevel = profession.level
    local professionName = profession.name or tostring(skillLineID)

    local notes = {
        "涨点概率为社区经验值估算（橙 100% / 黄 60% / 绿 25%）",
        "难度分界按规划区间的前 25% / 25%-65% / 余下估算，非官方数据",
        "备选材料按每个槽位第一项估算",
        "优先消耗你已有的材料，其次才比较材料总件数",
    }

    -- 目标不高于当前等级：不需要规划
    if requestedTarget and requestedTarget <= currentLevel then
        notes[#notes + 1] = string.format("目标 %d 不高于当前等级 %d，无需升级",
            math.floor(requestedTarget), math.floor(currentLevel))
        return {
            professionName = professionName,
            currentLevel = currentLevel,
            requestedTarget = requestedTarget,
            targetLevel = currentLevel,
            breakpoint = currentLevel,
            segments = {},
            materials = {},
            notes = notes,
        }
    end

    local candidates = CollectCandidates(skillLineID, currentLevel, options)
    if #candidates == 0 then
        return nil, "没有可用的已学配方（专业窗口未打开、配方未学或全部被跳过名单剔除）"
    end

    local cur = currentLevel
    local segments = {}
    local materials = {}
    local inventory = {}
    local remaining = {}
    local deadEnd = false

    -- 剩余库存：惰性缓存，同一种材料只向游戏查询一次；段与段之间会扣减
    local function GetRemaining(itemID)
        local count = remaining[itemID]
        if count == nil then
            count = Craft.GetItemCount(itemID)
            remaining[itemID] = count
        end
        return count
    end

    while true do
        -- 到达目标即停
        if requestedTarget and cur >= requestedTarget then
            break
        end

        -- 贪心：在所有能覆盖 cur 的配方里，优先选“到 min(maxTrivialLevel, target) 缺口件数最少”的；
        -- 缺口相同时再比材料总件数，仍相同则优先能推进更远的配方，最后按 recipeID 升序保证结果稳定。
        -- 缺口 = Σ max(0, 本段需求 - 剩余库存)，剩余库存会随已选段扣减，避免重复把同一批材料算作可用。
        local best
        local bestMissing
        local bestTotal
        local bestTo
        for _, candidate in ipairs(candidates) do
            if candidate.maxTrivialLevel > cur then
                local toLevel = candidate.maxTrivialLevel
                if requestedTarget and requestedTarget < toLevel then
                    toLevel = requestedTarget
                end
                if toLevel > cur then
                    local crafts = ExpectedCrafts(cur, toLevel, candidate.numSkillUps)
                    local missingCount = 0
                    local totalCount = 0
                    for _, reagent in ipairs(candidate.reagents) do
                        local need = crafts * reagent.perCraft
                        totalCount = totalCount + need
                        local gap = need - GetRemaining(reagent.itemID)
                        if gap > 0 then
                            missingCount = missingCount + gap
                        end
                    end
                    if not best
                        or missingCount < bestMissing
                        or (missingCount == bestMissing and totalCount < bestTotal)
                        or (missingCount == bestMissing and totalCount == bestTotal and toLevel > bestTo)
                        or (missingCount == bestMissing and totalCount == bestTotal and toLevel == bestTo and candidate.recipeID < best.recipeID) then
                        best = candidate
                        bestMissing = missingCount
                        bestTotal = totalCount
                        bestTo = toLevel
                    end
                end
            end
        end

        if not best then
            deadEnd = true
            break
        end

        local crafts = ExpectedCrafts(cur, bestTo, best.numSkillUps)
        local segmentReagents = {}
        for _, reagent in ipairs(best.reagents) do
            local need = crafts * reagent.perCraft
            local have = inventory[reagent.itemID]
            if have == nil then
                -- 该材料尚未在任何已选段出现，剩余库存此时仍是初始持有量；复用同一份缓存，避免重复查询
                have = GetRemaining(reagent.itemID)
                inventory[reagent.itemID] = have
            end
            local missing = need - have
            if missing < 0 then
                missing = 0
            end
            segmentReagents[#segmentReagents + 1] = {
                itemID = reagent.itemID,
                name = reagent.name,
                perCraft = reagent.perCraft,
                need = need,
                have = have,
                missing = missing,
            }

            -- 本段消耗后扣减剩余库存，供后续选段评分使用，避免重复计算已有材料
            local leftover = GetRemaining(reagent.itemID) - need
            if leftover < 0 then
                leftover = 0
            end
            remaining[reagent.itemID] = leftover

            local summary = materials[reagent.itemID]
            if not summary then
                summary = { name = reagent.name, need = 0, have = have, missing = 0 }
                materials[reagent.itemID] = summary
            end
            summary.need = summary.need + need
        end

        segments[#segments + 1] = {
            from = cur,
            to = bestTo,
            recipeID = best.recipeID,
            recipeName = best.name,
            expectedCrafts = crafts,
            missingCount = bestMissing,
            reagents = segmentReagents,
        }

        cur = bestTo
    end

    -- 材料汇总缺口：多段累加需求，have 取当前持有数量
    for _, summary in pairs(materials) do
        summary.missing = summary.need - summary.have
        if summary.missing < 0 then
            summary.missing = 0
        end
    end

    local breakpoint = cur
    if deadEnd and requestedTarget and requestedTarget > cur then
        notes[#notes + 1] = string.format("目标 %d 超出断点 %d，已按断点规划",
            math.floor(requestedTarget), math.floor(cur))
    elseif deadEnd and not requestedTarget then
        notes[#notes + 1] = string.format("未指定目标，已规划到断点 %d", math.floor(cur))
    end

    return {
        professionName = professionName,
        currentLevel = currentLevel,
        requestedTarget = requestedTarget,
        targetLevel = cur,
        breakpoint = breakpoint,
        segments = segments,
        materials = materials,
        notes = notes,
    }
end

-- 把规划格式化成纯文本行，供聊天框逐行输出；不写颜色代码，便于复制。
function Craft.FormatPlan(plan)
    local lines = {}
    lines[#lines + 1] = "wjw_工具箱 · 专业技能升级规划"

    if type(plan) ~= "table" then
        lines[#lines + 1] = "规划失败：没有可用的规划数据"
        return lines
    end

    local current = math.floor(tonumber(plan.currentLevel) or 0)
    local target = math.floor(tonumber(plan.targetLevel) or current)
    local breakpoint = math.floor(tonumber(plan.breakpoint) or target)
    local professionName = tostring(plan.professionName or "未知")

    lines[#lines + 1] = string.format("专业：%s    当前 %d    目标 %d（现有配方断点 %d）",
        professionName, current, target, breakpoint)
    lines[#lines + 1] = "估算口径：橙 100% / 黄 60% / 绿 25%（社区经验值，非官方）"

    for _, segment in ipairs(plan.segments or {}) do
        local title = string.format("%d → %d   %s ×%d",
            math.floor(tonumber(segment.from) or 0),
            math.floor(tonumber(segment.to) or 0),
            tostring(segment.recipeName or segment.recipeID),
            math.floor(tonumber(segment.expectedCrafts) or 0))
        -- missingCount 为数字且为 0 时，说明这一段要用的材料已经全部备齐
        if tonumber(segment.missingCount) == 0 then
            title = title .. "（材料已备齐）"
        end
        lines[#lines + 1] = title

        local parts = {}
        for _, reagent in ipairs(segment.reagents or {}) do
            parts[#parts + 1] = string.format("%s ×%d（你有 %d，还需 %d）",
                tostring(reagent.name or reagent.itemID),
                math.floor(tonumber(reagent.need) or 0),
                math.floor(tonumber(reagent.have) or 0),
                math.floor(tonumber(reagent.missing) or 0))
        end
        if #parts > 0 then
            lines[#lines + 1] = "          材料：" .. table.concat(parts, "、")
        end
    end

    local requested = tonumber(plan.requestedTarget)
    if breakpoint < (requested or math.huge) then
        lines[#lines + 1] = string.format("断点：%d 级后现有配方已不涨点，请找「%s」训练师学习新配方",
            breakpoint, professionName)
    end

    for _, note in ipairs(plan.notes or {}) do
        lines[#lines + 1] = "· " .. tostring(note)
    end

    return lines
end
