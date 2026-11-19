--[[---------------------------------------------------------------------------
    CraftTrainerMarker —— 当前专业训练师标记（小地图 + 世界地图）

    职责：
      * 在当前地图内找出离玩家最近的那一个训练师（训练师类型 = 当前专业），
        在小地图和世界地图上各画一个金色标记，常驻显示。
      * 只负责“找”和“画”：不做导航线路、不显示距离文字。

    开关：
      * wjwCraftDB.trainerMarker（默认 true；字段缺失或存档表不存在时按开启处理）。
      * 对外接口：Craft.TrainerMarker = { SetEnabled, IsEnabled, Refresh }。
      * 关闭后立即隐藏两处标记并停止定时器，事件回调也不会再显示。

    专业名来源（按优先级）：
      ① Craft.GetOpenProfession() 的 skillLineID -> 专业名（C_TradeSkillUI /
         Craft.GetProfessions() 两条路）；
      ② wjwCraftDB.lastProfession（CraftCommand.lua 写入的最后一次规划专业名）；
      ③ Craft.GetProfessions() 的第一个已学专业。
      拿不到专业名、或该专业在 Craft.Trainers 里没有数据时，隐藏标记。

    坐标换算复用（不另造一套）：
      * 小地图：PathOverlay.lua 的 UpdateMinimap（343、358–401 行）——
        距离/朝向取自 QP.GetDistanceToPoint（PathMap.lua:141），
        像素距离 = 距离 / C_Minimap.GetViewRadius() * 半径，
        rotateMinimap 开启时屏幕角度再减去玩家朝向。
      * 世界地图：PathOverlay.lua 的 UpdateWorldMap（536–537 行）——
        归一化坐标换算成画布像素。这里用 canvas 的 TOPLEFT 锚点 + 负 Y
        表达同一个公式 x*W, (1-y)*H；世界地图停在上级地图时用
        QP.ConvertBetweenMaps（PathMap.lua:85）换算，换算失败则隐藏。

    兼容与安全：
      * C_Map / C_Minimap / Texture / C_Timer 调用全部先 type() 守卫，
        关键调用 pcall 包裹；任何一步失败只隐藏标记，绝不抛错，
        也不影响暴雪界面与其它模块。
-----------------------------------------------------------------------------]]

local ADDON_NAME, NS = ...

-- CraftCore.lua 未加载或未导出 NS.Craft 时静默退出，不影响其它模块
local Craft = NS and NS.Craft
if type(Craft) ~= "table" then
    return
end

---------------------------------------------------------------- 常量
local MARKER_SIZE        = 10      -- 回退样式：内层金色圆点边长（像素）
local MARKER_BORDER_SIZE = 14      -- 回退样式：外层深色描边边长（托底，避免金色压在亮地图上看不清）
local ATLAS_MARKER_SIZE  = 18      -- 图标图集样式的边长
local MINIMAP_MARGIN     = 8       -- 贴边时标记中心距小地图边缘的余量
local TICKER_SECONDS     = 2       -- 小地图/世界地图定时刷新间隔
local WORLD_RETRY_SECONDS = 0.5    -- 世界地图画布未就绪时的重试间隔
local WORLD_RETRY_LIMIT   = 3      -- 世界地图连续重试上限，超过仍失败才隐藏

local MARKER_R, MARKER_G, MARKER_B = 1.0, 0.82, 0.20
local MARKER_ALPHA = 1.0
local BORDER_R, BORDER_G, BORDER_B = 0.10, 0.08, 0.02
local BORDER_ALPHA = 0.85

-- 标记优先使用的图标图集（按顺序尝试，全部取不到才退回纯色圆点）
local MARKER_ATLASES = {
    "VignetteKill",
    "POI-icon",
    "Waypoint-MapPin-Minimap",
    "poi-camp",
}

---------------------------------------------------------------- 存档与开关
local function GetDB()
    if type(wjwCraftDB) == "table" then
        return wjwCraftDB
    end
    return nil
end

-- 调试开关：wjwCraftDB.debug 为 true 时才输出诊断信息，其余情况完全不打印
local function IsDebug()
    local db = GetDB()
    return db ~= nil and db.debug == true
end

local function DebugPrint(message)
    if not IsDebug() then
        return
    end
    if type(Craft.Print) == "function" then
        pcall(Craft.Print, message)
    elseif type(print) == "function" then
        pcall(print, message)
    end
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
    return db.trainerMarker ~= false
end

---------------------------------------------------------------- 当前专业
-- 把 skillLineID 换成专业名：先问 C_TradeSkillUI，再在 Craft.GetProfessions() 里找
local function GetProfessionNameBySkillLine(skillLineID)
    if type(skillLineID) ~= "number" then
        return nil
    end

    local UI = C_TradeSkillUI
    if type(UI) == "table" and type(UI.GetProfessionInfoBySkillLineID) == "function" then
        local ok, info = pcall(UI.GetProfessionInfoBySkillLineID, skillLineID)
        if ok and type(info) == "table" and type(info.professionName) == "string"
            and info.professionName ~= "" then
            return info.professionName
        end
    end

    if type(Craft.GetProfessions) == "function" then
        local ok, professions = pcall(Craft.GetProfessions)
        if ok and type(professions) == "table" then
            for _, profession in ipairs(professions) do
                if type(profession) == "table" and profession.skillLineID == skillLineID
                    and type(profession.name) == "string" then
                    return profession.name
                end
            end
        end
    end

    return nil
end

-- 当前专业名；读不到返回 nil
local function GetCurrentTypeName()
    if type(Craft.GetOpenProfession) == "function" then
        local ok, skillLineID = pcall(Craft.GetOpenProfession)
        if ok then
            local name = GetProfessionNameBySkillLine(skillLineID)
            if name then
                return name
            end
        end
    end

    local db = GetDB()
    if db and type(db.lastProfession) == "string" and db.lastProfession ~= "" then
        return db.lastProfession
    end

    if type(Craft.GetProfessions) == "function" then
        local ok, professions = pcall(Craft.GetProfessions)
        if ok and type(professions) == "table" and type(professions[1]) == "table"
            and type(professions[1].name) == "string" then
            return professions[1].name
        end
    end

    return nil
end

---------------------------------------------------------------- 最近训练师
-- 归一化坐标差值的平方；只用于比较远近，不需要开方
local function DistanceSquared(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return dx * dx + dy * dy
end

-- 返回 { trainer, x, y, mapID, typeName }；地图/坐标/专业任一不可用都返回 nil
-- 只保留与玩家当前地图一致的训练师（Craft.TrainerZoneMap[旧 AreaID] -> uiMapID）
local function FindNearest()
    if type(C_Map) ~= "table" or type(C_Map.GetBestMapForUnit) ~= "function" then
        return nil
    end
    local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not okMap or type(mapID) ~= "number" then
        return nil
    end

    local typeName = GetCurrentTypeName()
    if not typeName then
        return nil
    end
    local trainers = type(Craft.Trainers) == "table" and Craft.Trainers[typeName] or nil
    if type(trainers) ~= "table" then
        return nil
    end
    local zoneMap = Craft.TrainerZoneMap
    if type(zoneMap) ~= "table" then
        return nil
    end

    if type(C_Map.GetPlayerMapPosition) ~= "function" then
        return nil
    end
    local okPosition, position = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not okPosition or not position then
        return nil
    end
    local playerX, playerY
    if type(position.GetXY) == "function" then
        local okXY, x, y = pcall(position.GetXY, position)
        if okXY then
            playerX, playerY = x, y
        end
    end
    if type(playerX) ~= "number" or type(playerY) ~= "number" then
        playerX, playerY = position.x, position.y
    end
    if type(playerX) ~= "number" or type(playerY) ~= "number" then
        return nil
    end
    if playerX == 0 and playerY == 0 then
        return nil
    end

    local best, bestDistance
    for _, trainer in ipairs(trainers) do
        if type(trainer) == "table" and zoneMap[trainer.zone] == mapID
            and type(trainer.x) == "number" and type(trainer.y) == "number" then
            local trainerX, trainerY = trainer.x / 100, trainer.y / 100
            local distance = DistanceSquared(playerX, playerY, trainerX, trainerY)
            if not bestDistance or distance < bestDistance then
                best, bestDistance = trainer, distance
            end
        end
    end
    if not best then
        return nil
    end

    return {
        trainer = best,
        x = best.x / 100,
        y = best.y / 100,
        mapID = mapID,
        typeName = typeName,
    }
end

---------------------------------------------------------------- 贴图工具
local function CreateMarkerTexture(parent)
    if not parent or type(parent.CreateTexture) ~= "function" then
        return nil
    end
    local ok, texture = pcall(parent.CreateTexture, parent, nil, "OVERLAY")
    if not ok or not texture then
        return nil
    end
    return texture
end

-- 图集是否存在：有 C_Texture.GetAtlasInfo 时以它为准，缺失时交给 SetAtlas 的 pcall 判断
local function AtlasExists(atlasName)
    if type(C_Texture) ~= "table" or type(C_Texture.GetAtlasInfo) ~= "function" then
        return true
    end
    local ok, info = pcall(C_Texture.GetAtlasInfo, atlasName)
    if not ok then
        return false
    end
    return info ~= nil
end

-- 按 MARKER_ATLASES 的顺序尝试图标图集，任一成功返回 true
local function ApplyMarkerAtlas(texture)
    if type(texture.SetAtlas) ~= "function" then
        return false
    end
    for index = 1, #MARKER_ATLASES do
        local atlasName = MARKER_ATLASES[index]
        if AtlasExists(atlasName) then
            local ok = pcall(texture.SetAtlas, texture, atlasName)
            if ok then
                -- 图集名无效时 SetAtlas 可能静默无效，能回读就核对一遍
                if type(texture.GetAtlas) ~= "function" then
                    return true
                end
                local okGet, current = pcall(texture.GetAtlas, texture)
                if okGet and current == atlasName then
                    return true
                end
            end
        end
    end
    return false
end

-- 纯色回退：先用 WHITE8X8 铺底再上色；SetColorTexture 缺失时退回顶点着色
local function ApplySolidColor(texture, red, green, blue, alpha)
    if type(texture.SetTexture) == "function" then
        pcall(texture.SetTexture, texture, "Interface\\Buttons\\WHITE8X8")
    end
    if type(texture.SetColorTexture) == "function" then
        pcall(texture.SetColorTexture, texture, red, green, blue, alpha)
        return
    end
    pcall(texture.SetVertexColor, texture, red, green, blue, alpha)
end

-- 配置一个标记贴图：allowedAtlas 为 true 时优先用图标图集（尺寸 atlasSize），
-- 取不到图集则退回纯色方块（尺寸 size）。第二个返回值表示是否真的用上了图集。
local function ConfigureMarkerTexture(texture, size, subLevel, red, green, blue, alpha, allowedAtlas, atlasSize)
    if not texture then
        return false
    end
    local ok, usedAtlas = pcall(function()
        local useAtlas = allowedAtlas == true and ApplyMarkerAtlas(texture)
        if useAtlas then
            local iconSize = atlasSize or size
            texture:SetSize(iconSize, iconSize)
        else
            texture:SetSize(size, size)
            ApplySolidColor(texture, red, green, blue, alpha)
        end
        texture:SetDrawLayer("OVERLAY", subLevel)
        texture:Hide()
        return useAtlas
    end)
    if not ok then
        return false
    end
    return true, usedAtlas == true
end

---------------------------------------------------------------- 小地图标记
local minimapBorder
local minimapFill
local minimapUsesAtlas

local function EnsureMinimapMarkers()
    if minimapBorder and minimapFill then
        return minimapBorder, minimapFill, minimapUsesAtlas
    end
    if not Minimap or type(Minimap.CreateTexture) ~= "function" then
        return nil
    end
    local border = CreateMarkerTexture(Minimap)
    local fill = CreateMarkerTexture(Minimap)
    local okBorder = border
        and ConfigureMarkerTexture(border, MARKER_BORDER_SIZE, 0, BORDER_R, BORDER_G, BORDER_B, BORDER_ALPHA)
    -- 图集可用时只画一枚 18×18 图标；否则退回 14×14 深色托底 + 10×10 金色圆点
    local okFill, usedAtlas = fill
        and ConfigureMarkerTexture(fill, MARKER_SIZE, 1, MARKER_R, MARKER_G, MARKER_B, MARKER_ALPHA,
            true, ATLAS_MARKER_SIZE)
    if not okBorder or not okFill then
        if border then pcall(border.Hide, border) end
        if fill then pcall(fill.Hide, fill) end
        return nil
    end
    minimapBorder, minimapFill, minimapUsesAtlas = border, fill, usedAtlas == true
    return minimapBorder, minimapFill, minimapUsesAtlas
end

local function HideMinimapMarkers()
    if minimapBorder then
        pcall(minimapBorder.Hide, minimapBorder)
    end
    if minimapFill then
        pcall(minimapFill.Hide, minimapFill)
    end
end

-- 距离/朝向 -> 小地图像素偏移。公式照 PathOverlay.lua:358–401（UpdateMinimap）
local function UpdateMinimapMarker(nearest)
    local border, fill, usedAtlas = EnsureMinimapMarkers()
    if not border or not fill then
        return
    end

    local QP = QuestPath
    if type(QP) ~= "table" or type(QP.GetDistanceToPoint) ~= "function" then
        HideMinimapMarkers()
        return
    end
    local okDistance, distance, bearing = pcall(QP.GetDistanceToPoint, nearest.mapID, nearest.x, nearest.y)
    if not okDistance or type(distance) ~= "number" or type(bearing) ~= "number" then
        HideMinimapMarkers()
        return
    end

    local facing = 0
    if type(GetCVar) == "function" and type(GetPlayerFacing) == "function" then
        local okCvar, rotateMinimap = pcall(GetCVar, "rotateMinimap")
        if okCvar and rotateMinimap == "1" then
            local okFacing, playerFacing = pcall(GetPlayerFacing)
            if okFacing and type(playerFacing) == "number" then
                facing = playerFacing
            end
        end
    end
    local screenAngle = bearing - facing
    local directionX = -math.sin(screenAngle)
    local directionY = math.cos(screenAngle)

    local okSize, width, height = pcall(function()
        return Minimap:GetWidth(), Minimap:GetHeight()
    end)
    if not okSize or type(width) ~= "number" or type(height) ~= "number" then
        HideMinimapMarkers()
        return
    end
    local radius = math.min(width, height) / 2
    local maxDistance = radius - MINIMAP_MARGIN
    if radius <= 0 or maxDistance <= 0 then
        HideMinimapMarkers()
        return
    end

    if type(C_Minimap) ~= "table" or type(C_Minimap.GetViewRadius) ~= "function" then
        HideMinimapMarkers()
        return
    end
    local okView, viewRadius = pcall(C_Minimap.GetViewRadius)
    if not okView or type(viewRadius) ~= "number" or viewRadius <= 0 then
        HideMinimapMarkers()
        return
    end

    local pixelDistance = distance / viewRadius * radius
    if pixelDistance > maxDistance then
        pixelDistance = maxDistance
    end
    if pixelDistance < 0 then
        pixelDistance = 0
    end
    local offsetX = directionX * pixelDistance
    local offsetY = directionY * pixelDistance

    local okPoint = pcall(function()
        border:ClearAllPoints()
        fill:ClearAllPoints()
        if usedAtlas then
            border:Hide()
            fill:SetPoint("CENTER", Minimap, "CENTER", offsetX, offsetY)
            fill:Show()
        else
            border:SetPoint("CENTER", Minimap, "CENTER", offsetX, offsetY)
            border:Show()
            fill:SetPoint("CENTER", Minimap, "CENTER", offsetX, offsetY)
            fill:Show()
        end
    end)
    if not okPoint then
        HideMinimapMarkers()
    end
end

---------------------------------------------------------------- 世界地图标记
local worldFrame
local worldBorder
local worldFill
local worldParent
local worldUsesAtlas

-- Refresh 定义在文件后半段；这里先声明，供画布未就绪时的延迟重试回调调用
local Refresh

local function HideWorldMarkers()
    if worldBorder then
        pcall(worldBorder.Hide, worldBorder)
    end
    if worldFill then
        pcall(worldFill.Hide, worldFill)
    end
end

local function DestroyWorldMarkers()
    HideWorldMarkers()
    if worldFrame then
        pcall(worldFrame.Hide, worldFrame)
    end
    worldFrame, worldBorder, worldFill, worldParent, worldUsesAtlas = nil, nil, nil, nil, nil
end

local worldRetryCount = 0
local worldRetrySeq = 0

-- 让已排队但尚未执行的重试作废，并把重试计数清零
local function ResetWorldRetry()
    worldRetrySeq = worldRetrySeq + 1
    worldRetryCount = 0
end

-- 画布/尺寸尚未就绪：延迟 0.5 秒重试，最多 WORLD_RETRY_LIMIT 次，超过才隐藏
local function ScheduleWorldRetry(reason)
    if worldRetryCount >= WORLD_RETRY_LIMIT then
        DebugPrint(reason .. "（已重试 " .. WORLD_RETRY_LIMIT .. " 次仍不可用，隐藏标记）")
        HideWorldMarkers()
        ResetWorldRetry()
        return
    end
    worldRetryCount = worldRetryCount + 1
    worldRetrySeq = worldRetrySeq + 1
    local sequence = worldRetrySeq
    if worldRetryCount == 1 then
        DebugPrint(reason .. "（" .. WORLD_RETRY_SECONDS .. " 秒后重试）")
    end
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
        HideWorldMarkers()
        return
    end
    local ok = pcall(C_Timer.After, WORLD_RETRY_SECONDS, function()
        -- 序列号变了说明期间已成功绘制或被重置，这次重试作废
        if sequence ~= worldRetrySeq then
            return
        end
        Refresh()
    end)
    if not ok then
        HideWorldMarkers()
    end
end

-- 当前显示的地图 ID：GetMapID() → frame.mapID → C_Map.GetBestMapForUnit("player")
local function ResolveDisplayMapID()
    local frame = WorldMapFrame
    if frame and type(frame.GetMapID) == "function" then
        local okMap, mapID = pcall(frame.GetMapID, frame)
        if okMap and type(mapID) == "number" then
            return mapID
        end
        DebugPrint("world: GetMapID 返回异常，改用回退取值")
    end
    if frame and type(frame.mapID) == "number" then
        return frame.mapID
    end
    if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
        local okBest, mapID = pcall(C_Map.GetBestMapForUnit, "player")
        if okBest and type(mapID) == "number" then
            return mapID
        end
    end
    DebugPrint("world: no GetMapID")
    return nil
end

-- 每次调用都核对绘制层父级：地图关闭再打开时游戏可能重建 canvas（同 PathOverlay.lua:479–499）
local function EnsureWorldMarkers()
    local frame = WorldMapFrame
    if not frame or type(frame.GetCanvas) ~= "function" then
        return nil
    end
    local okCanvas, canvas = pcall(frame.GetCanvas, frame)
    if not okCanvas or not canvas or type(canvas.CreateTexture) ~= "function" then
        return nil
    end
    if worldFrame and worldParent == canvas then
        return worldBorder, worldFill, canvas, worldUsesAtlas
    end

    DestroyWorldMarkers()
    local okFrame, newFrame = pcall(CreateFrame, "Frame", nil, canvas)
    if not okFrame or not newFrame then
        return nil
    end
    local okSetup = pcall(function()
        newFrame:SetAllPoints(canvas)
        -- 画布上还叠着 POI 图钉等子框体，只加 1 层可能被盖住；抬到 +100 确保标记在最上层
        newFrame:SetFrameLevel(canvas:GetFrameLevel() + 100)
        newFrame:Show()
    end)
    if not okSetup then
        pcall(newFrame.Hide, newFrame)
        return nil
    end

    local border = CreateMarkerTexture(newFrame)
    local fill = CreateMarkerTexture(newFrame)
    local okBorder = border
        and ConfigureMarkerTexture(border, MARKER_BORDER_SIZE, 0, BORDER_R, BORDER_G, BORDER_B, BORDER_ALPHA)
    local okFill, usedAtlas = fill
        and ConfigureMarkerTexture(fill, MARKER_SIZE, 1, MARKER_R, MARKER_G, MARKER_B, MARKER_ALPHA,
            true, ATLAS_MARKER_SIZE)
    if not okBorder or not okFill then
        pcall(newFrame.Hide, newFrame)
        return nil
    end

    worldFrame, worldParent = newFrame, canvas
    worldBorder, worldFill = border, fill
    worldUsesAtlas = usedAtlas == true
    return worldBorder, worldFill, canvas, worldUsesAtlas
end

-- debug 模式下的定位/层级快照：偏移、画布尺寸、框体层级与可见性
local function DescribeWorldMarker(canvas, offsetX, offsetY, width, height)
    local frameLevel, canvasLevel, frameShown, fillShown = "?", "?", "?", "?"
    if worldFrame then
        local okLevel, level = pcall(worldFrame.GetFrameLevel, worldFrame)
        if okLevel then frameLevel = level end
        local okFrameShown, value = pcall(worldFrame.IsShown, worldFrame)
        if okFrameShown then frameShown = value end
    end
    if canvas then
        local okLevel, level = pcall(canvas.GetFrameLevel, canvas)
        if okLevel then canvasLevel = level end
    end
    if worldFill then
        local okShown, value = pcall(worldFill.IsShown, worldFill)
        if okShown then fillShown = value end
    end
    return string.format(
        "world: x=%.1f y=%.1f canvas=%sx%s frameLevel=%s canvasLevel=%s frameShown=%s fillShown=%s",
        offsetX, offsetY, tostring(width), tostring(height),
        tostring(frameLevel), tostring(canvasLevel), tostring(frameShown), tostring(fillShown))
end

local function UpdateWorldMarker(nearest)
    local frame = WorldMapFrame
    if not frame or type(frame.IsShown) ~= "function" then
        ResetWorldRetry()
        HideWorldMarkers()
        return
    end
    local okShown, shown = pcall(frame.IsShown, frame)
    if not okShown or not shown then
        ResetWorldRetry()
        HideWorldMarkers()
        return
    end

    local displayMapID = ResolveDisplayMapID()
    if not displayMapID then
        ResetWorldRetry()
        HideWorldMarkers()
        return
    end

    local mapX, mapY = nearest.x, nearest.y
    if displayMapID ~= nearest.mapID then
        mapX, mapY = nil, nil
        local QP = QuestPath
        if type(QP) == "table" and type(QP.ConvertBetweenMaps) == "function" then
            local okConvert, convertedX, convertedY =
                pcall(QP.ConvertBetweenMaps, nearest.mapID, nearest.x, nearest.y, displayMapID)
            if okConvert then
                mapX, mapY = convertedX, convertedY
            end
        end
    end
    if type(mapX) ~= "number" or type(mapY) ~= "number" then
        DebugPrint("world: convert failed")
        ResetWorldRetry()
        HideWorldMarkers()
        return
    end

    local border, fill, canvas, usedAtlas = EnsureWorldMarkers()
    if not border or not fill or not canvas then
        ScheduleWorldRetry("world: no canvas")
        return
    end

    local okSize, width, height = pcall(function()
        return canvas:GetWidth(), canvas:GetHeight()
    end)
    if not okSize or type(width) ~= "number" or type(height) ~= "number"
        or width <= 1 or height <= 1 then
        -- 地图刚打开时画布可能还没布局完（w=0），延迟重试而不是立刻放弃
        ScheduleWorldRetry(okSize and "world: canvas w=0" or "world: canvas size error")
        return
    end

    ResetWorldRetry()

    -- PathOverlay.lua:536–537 以 BOTTOMLEFT 为原点写 x*W, (1-y)*H；
    -- 这里改用 TOPLEFT 锚点 + 负 Y，两条公式画在同一像素位置。
    -- 贴图挂在绘制层框体（与 canvas 同尺寸）的 TOPLEFT，避免跨框体锚定。
    local offsetX, offsetY = mapX * width, -mapY * height
    local okPoint = pcall(function()
        border:ClearAllPoints()
        fill:ClearAllPoints()
        if usedAtlas then
            border:Hide()
            fill:SetPoint("CENTER", worldFrame, "TOPLEFT", offsetX, offsetY)
            fill:Show()
        else
            border:SetPoint("CENTER", worldFrame, "TOPLEFT", offsetX, offsetY)
            border:Show()
            fill:SetPoint("CENTER", worldFrame, "TOPLEFT", offsetX, offsetY)
            fill:Show()
        end
    end)
    if not okPoint then
        ResetWorldRetry()
        HideWorldMarkers()
        return
    end
    if IsDebug() then
        DebugPrint(DescribeWorldMarker(canvas, offsetX, offsetY, width, height))
    end
end

---------------------------------------------------------------- 刷新
local ticker

local function HideAllMarkers()
    HideMinimapMarkers()
    HideWorldMarkers()
end

local function RefreshInternal()
    if not IsEnabled() then
        HideAllMarkers()
        return
    end
    local nearest = FindNearest()
    if not nearest then
        HideAllMarkers()
        return
    end
    UpdateMinimapMarker(nearest)
    UpdateWorldMarker(nearest)
end

-- 任何未预料的失败（例如暴雪界面结构变化）只收起标记，不把错误抛给用户
-- 注意：Refresh 已在世界地图段先前置声明，这里赋值给同一个局部变量
Refresh = function()
    local ok = pcall(RefreshInternal)
    if not ok then
        HideAllMarkers()
    end
end

local function StopTicker()
    if not ticker then
        return
    end
    pcall(ticker.Cancel, ticker)
    ticker = nil
end

local function StartTicker()
    if ticker then
        return
    end
    if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then
        return
    end
    local ok, newTicker = pcall(C_Timer.NewTicker, TICKER_SECONDS, Refresh)
    if ok then
        ticker = newTicker
    end
end

---------------------------------------------------------------- 对外接口
local function SetEnabled(enabled)
    local db = EnsureDBTable()
    db.trainerMarker = enabled and true or false
    if enabled then
        StartTicker()
        Refresh()
    else
        StopTicker()
        HideAllMarkers()
    end
end

Craft.TrainerMarker = {
    SetEnabled = SetEnabled,
    IsEnabled = IsEnabled,
    Refresh = Refresh,
}

---------------------------------------------------------------- 事件与初始化
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

-- 世界地图事件名在不同客户端版本间不完全一致；注册失败只少一次即时刷新，
-- 由 2 秒定时器兜底，因此逐个 pcall 注册而不是让整段初始化失败
local worldMapEvents = { "WORLD_MAP_OPEN", "WORLD_MAP_UPDATE", "WORLD_MAP_CLOSE" }
for index = 1, #worldMapEvents do
    pcall(eventFrame.RegisterEvent, eventFrame, worldMapEvents[index])
end

eventFrame:SetScript("OnEvent", function()
    Refresh()
end)

-- 世界地图框可能在文件加载后才被创建；存在时补挂 OnShow，做到打开即刷新
if WorldMapFrame and type(WorldMapFrame.HookScript) == "function" then
    pcall(WorldMapFrame.HookScript, WorldMapFrame, "OnShow", function()
        Refresh()
    end)
end

-- 开启状态下启动定时刷新（小地图位置、canvas 重建都靠它兜底）
if IsEnabled() then
    StartTicker()
end
