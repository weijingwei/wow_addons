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

    训练师类型来源（统一在 CraftCore.lua 的 Craft.GetCurrentTrainerType 里判定）：
      ① 专业窗口可见时的专业（Craft.GetVisibleProfession；窗口关着不算）；
      ② wjwCraftDB.trainerType（用户显式指定过、且内置数据里有该类型）；
      ③ wjwCraftDB.lastProfession（CraftCommand.lua 写入的最后一次规划专业名）。
      都取不到、或该类型在 Craft.Trainers 里没有数据时，隐藏标记（不再猜测第一个已学专业）。

    坐标换算复用（不另造一套）：
      * 小地图：PathOverlay.lua 的 UpdateMinimap（343、358–401 行）——
        距离/朝向取自 QP.GetDistanceToPoint（PathMap.lua:141），
        像素距离 = 距离 / C_Minimap.GetViewRadius() * 半径，
        rotateMinimap 开启时屏幕角度再减去玩家朝向。
      * 世界地图：PathOverlay.lua 的 UpdateWorldMap（536–537 行）——
        归一化坐标换算成画布像素。贴图直接创建在地图画布上，锚点用
        canvas 的 TOPLEFT + 负 Y 表达同一个公式 x*W, (1-y)*H（画布局部
        坐标，缩放由画布自身处理，不再乘 canvas:GetScale()）。世界地图
        停在上级地图时用 QP.ConvertBetweenMaps（PathMap.lua:85）换算；
        偶发失败时保留上一次成功位置，连续 3 次失败才隐藏。

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
local WORLD_MARKER_SIZE        = 12  -- 世界地图回退样式：内层金色圆点边长（大地图上更醒目）
local WORLD_MARKER_BORDER_SIZE = 16  -- 世界地图回退样式：外层深色描边边长
local WORLD_ATLAS_MARKER_SIZE  = 24  -- 世界地图图标图集样式的边长
local WORLD_FAIL_LIMIT         = 3   -- 世界地图连续刷新失败上限，达到才隐藏标记
local MINIMAP_MARGIN     = 8       -- 贴边时标记中心距小地图边缘的余量
local TICKER_SECONDS     = 2       -- 世界地图定时刷新间隔（小地图改用下方高频间隔）
local MINIMAP_TICK_SECONDS = 0.1   -- 小地图标记跟随刷新间隔（与世界地图解耦）
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
-- 当前训练师类型（Craft.Trainers 的键）；判定链见 CraftCore.lua 的 Craft.GetCurrentTrainerType。
-- 读不到返回 nil（不猜测），调用方据此隐藏标记。
local function GetCurrentTypeName()
    if type(Craft.GetCurrentTrainerType) ~= "function" then
        return nil
    end
    local ok, typeName = pcall(Craft.GetCurrentTrainerType)
    if ok and type(typeName) == "string" and typeName ~= "" then
        return typeName
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
    -- 规范成 Craft.Trainers 的数据键（如「工程学」→「工程」）；映射不到时按原样取，取不到自然返回 nil
    local typeKey = typeName
    if type(Craft.FindTrainerTypeKey) == "function" then
        typeKey = Craft.FindTrainerTypeKey(typeName) or typeName
    end
    local trainers = type(Craft.Trainers) == "table" and Craft.Trainers[typeKey] or nil
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
        typeName = typeKey,
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

-- 按 MARKER_ATLASES 的顺序尝试图标图集，任一成功返回 true 和实际用上的图集名
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
                    return true, atlasName
                end
                local okGet, current = pcall(texture.GetAtlas, texture)
                if okGet and current == atlasName then
                    return true, atlasName
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
-- 取不到图集则退回纯色方块（尺寸 size）。
-- 第二个返回值表示是否真的用上了图集，第三个是实际用上的图集名。
local function ConfigureMarkerTexture(texture, size, subLevel, red, green, blue, alpha, allowedAtlas, atlasSize)
    if not texture then
        return false
    end
    local ok, usedAtlas, atlasName = pcall(function()
        local useAtlas, name
        if allowedAtlas == true then
            useAtlas, name = ApplyMarkerAtlas(texture)
        end
        if useAtlas then
            local iconSize = atlasSize or size
            texture:SetSize(iconSize, iconSize)
        else
            texture:SetSize(size, size)
            ApplySolidColor(texture, red, green, blue, alpha)
        end
        texture:SetDrawLayer("OVERLAY", subLevel)
        texture:Hide()
        return useAtlas, name
    end)
    if not ok then
        return false
    end
    return true, usedAtlas == true, atlasName
end

---------------------------------------------------------------- 标记悬停提示
-- 标记本身是贴图，收不到鼠标事件：另建一个同尺寸的透明框体盖在标记上接收悬停。
-- 提示内容在刷新时算好存到 frame.info，鼠标事件里只读缓存，不现算距离。

-- 地图名：C_Map.GetMapInfo(mapID).name，取不到用「未知地图」
local function GetMapName(mapID)
    if type(C_Map) == "table" and type(C_Map.GetMapInfo) == "function"
        and type(mapID) == "number" then
        local ok, info = pcall(C_Map.GetMapInfo, mapID)
        if ok and type(info) == "table"
            and type(info.name) == "string" and info.name ~= "" then
            return info.name
        end
    end
    return "未知地图"
end

-- 训练师坐标是 0–100 制，直接显示两位小数；
-- nearest.x / nearest.y 是 0–1 归一化坐标，不能拿来显示。
local function BuildMarkerInfo(nearest)
    if type(nearest) ~= "table" or type(nearest.trainer) ~= "table" then
        return nil
    end
    local trainer = nearest.trainer
    local typeName = type(nearest.typeName) == "string" and nearest.typeName ~= ""
        and nearest.typeName or "?"
    return {
        name = type(trainer.name) == "string" and trainer.name ~= "" and trainer.name or "?",
        typeName = typeName,
        mapName = GetMapName(nearest.mapID),
        x = type(trainer.x) == "number" and trainer.x or 0,
        y = type(trainer.y) == "number" and trainer.y or 0,
    }
end

-- 仅当提示正由该标记显示时才收起，避免误关别人的 tooltip
local function HideMarkerTooltip(frame)
    if not frame then
        return
    end
    if not GameTooltip or type(GameTooltip.GetOwner) ~= "function"
        or type(GameTooltip.Hide) ~= "function" then
        return
    end
    local ok, owner = pcall(GameTooltip.GetOwner, GameTooltip)
    if ok and owner == frame then
        pcall(GameTooltip.Hide, GameTooltip)
    end
end

local function MarkerTooltip_OnEnter(self)
    local info = self and self.info
    if type(info) ~= "table" then
        return
    end
    if not GameTooltip or type(GameTooltip.SetOwner) ~= "function" then
        return
    end
    local ok = pcall(function()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(tostring(info.name))
        GameTooltip:AddLine(tostring(info.typeName) .. "训练师", 1, 1, 1)
        GameTooltip:AddLine(
            string.format("%s · 坐标 (%.2f, %.2f)", tostring(info.mapName), info.x, info.y),
            0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    if not ok then
        pcall(GameTooltip.Hide, GameTooltip)
    end
end

local function MarkerTooltip_OnLeave(self)
    HideMarkerTooltip(self)
end

-- 透明悬停感应框：尺寸与标记贴图一致，父级由调用方决定（小地图 / 世界地图画布）
local function CreateMarkerHover(parent, size)
    if not parent then
        return nil
    end
    local okFrame, frame = pcall(CreateFrame, "Frame", nil, parent)
    if not okFrame or not frame then
        return nil
    end
    local okSetup = pcall(function()
        frame:SetSize(size, size)
        frame:EnableMouse(true)
        -- 只借悬停事件：点击/拖动向下穿透，不挡住小地图点击与世界地图拖动
        if type(frame.SetPropagateMouseClicks) == "function" then
            frame:SetPropagateMouseClicks(true)
        end
        if type(frame.SetPropagateMouseMotion) == "function" then
            frame:SetPropagateMouseMotion(true)
        end
        frame:SetScript("OnEnter", MarkerTooltip_OnEnter)
        frame:SetScript("OnLeave", MarkerTooltip_OnLeave)
        frame:Hide()
    end)
    if not okSetup then
        pcall(frame.Hide, frame)
        return nil
    end
    return frame
end

---------------------------------------------------------------- 小地图标记
local minimapBorder
local minimapFill
local minimapUsesAtlas
local minimapHover        -- 悬停感应框（透明，只负责接收鼠标悬停）
local minimapNearest     -- 最近一次 FindNearest() 的结果，供小地图高频刷新复用

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
    -- 注意：不能写成 `fill and ConfigureMarkerTexture(...)`——Lua 5.1 的 and 会把右侧调用的
    -- 多返回值截成一个，usedAtlas 恒为 nil，托底方块就不会被隐藏。
    local okFill, usedAtlas, atlasName
    if fill then
        okFill, usedAtlas, atlasName = ConfigureMarkerTexture(fill, MARKER_SIZE, 1,
            MARKER_R, MARKER_G, MARKER_B, MARKER_ALPHA, true, ATLAS_MARKER_SIZE)
    end
    if not okBorder or not okFill then
        if border then pcall(border.Hide, border) end
        if fill then pcall(fill.Hide, fill) end
        return nil
    end
    minimapBorder, minimapFill, minimapUsesAtlas = border, fill, usedAtlas == true
    -- 悬停感应框：尺寸跟随最终实际使用的标记样式（图集 18 / 纯色托底 14）
    minimapHover = CreateMarkerHover(Minimap,
        minimapUsesAtlas and ATLAS_MARKER_SIZE or MARKER_BORDER_SIZE)
    if minimapUsesAtlas then
        DebugPrint("marker atlas: " .. tostring(atlasName))
    else
        DebugPrint("marker atlas: none（纯色回退）")
    end
    return minimapBorder, minimapFill, minimapUsesAtlas
end

local function HideMinimapMarkers()
    if minimapBorder then
        pcall(minimapBorder.Hide, minimapBorder)
    end
    if minimapFill then
        pcall(minimapFill.Hide, minimapFill)
    end
    if minimapHover then
        HideMarkerTooltip(minimapHover)
        pcall(minimapHover.Hide, minimapHover)
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
        return
    end

    -- 感应框与标记同位置同步显隐，供鼠标悬停弹提示
    if minimapHover then
        local okHover = pcall(function()
            minimapHover.info = BuildMarkerInfo(nearest)
            minimapHover:ClearAllPoints()
            minimapHover:SetPoint("CENTER", Minimap, "CENTER", offsetX, offsetY)
            minimapHover:Show()
        end)
        if not okHover then
            pcall(minimapHover.Hide, minimapHover)
        end
    end
end

-- 高频刷新：训练师坐标不变，只需按玩家当前坐标重算屏幕位置；
-- 只调 UpdateMinimapMarker，不触碰世界地图的重试与失败计数逻辑。
local function RefreshMinimapPosition()
    if not IsEnabled() then
        return
    end
    if minimapNearest then
        UpdateMinimapMarker(minimapNearest)
    end
end

---------------------------------------------------------------- 世界地图标记
local worldBorder
local worldFill
local worldParent        -- 贴图当前父级：正常情况就是 WorldMapFrame 的 canvas
local worldContainer     -- 兜底：画布不能直接挂贴图时才创建的中转框体
local worldUsesAtlas
local worldHover         -- 悬停感应框（透明，只负责接收鼠标悬停）

-- 最近一次成功绘制的位置；刷新偶发失败时保留它，避免标记闪一下就没
local lastWorldDraw      -- { mapX = , mapY = , mapID = }
local worldFailCount = 0

-- Refresh 定义在文件后半段；这里先声明，供画布未就绪时的延迟重试回调调用
local Refresh

local function HideWorldMarkers()
    if worldBorder then
        pcall(worldBorder.Hide, worldBorder)
    end
    if worldFill then
        pcall(worldFill.Hide, worldFill)
    end
    if worldHover then
        HideMarkerTooltip(worldHover)
        pcall(worldHover.Hide, worldHover)
    end
end

local function DestroyWorldMarkers()
    HideWorldMarkers()
    if worldContainer then
        pcall(worldContainer.Hide, worldContainer)
    end
    worldBorder, worldFill, worldParent, worldContainer, worldUsesAtlas = nil, nil, nil, nil, nil
    worldHover = nil
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

-- 刷新失败时不要立刻收掉标记：地图数据偶发不可用（专业窗口切换、坐标暂不可得、
-- 跨地图换算失败）时保留上一次成功绘制的位置；只有连续失败到上限、或当前显示的
-- 地图已经不是上次绘制那张图时才隐藏。
local function FailWorldDraw(reason, displayMapID)
    -- 连续失败到上限时已隐藏标记并打印过日志：后续失败不再累计、不再重复打印，
    -- 直到某次成功绘制或全量收起把计数清零。
    if worldFailCount >= WORLD_FAIL_LIMIT then
        return
    end
    worldFailCount = worldFailCount + 1
    local keep = lastWorldDraw ~= nil
        and displayMapID ~= nil
        and lastWorldDraw.mapID == displayMapID
        and worldFailCount < WORLD_FAIL_LIMIT
    if keep then
        DebugPrint(string.format("%s（连续失败 %d/%d，保留上次位置）",
            reason, worldFailCount, WORLD_FAIL_LIMIT))
        return
    end
    DebugPrint(string.format("%s（连续失败 %d/%d，隐藏标记）",
        reason, worldFailCount, WORLD_FAIL_LIMIT))
    lastWorldDraw = nil
    HideWorldMarkers()
end

-- 每次调用都核对贴图父级：地图关闭再打开时游戏可能重建 canvas（同 PathOverlay.lua:482–499）。
-- 贴图直接创建在画布上，坐标使用画布局部单位；画布自身的缩放与平移会一并作用到贴图上，
-- 不需要也不应该再乘 canvas:GetScale()。
local function EnsureWorldMarkers()
    local frame = WorldMapFrame
    if not frame or type(frame.GetCanvas) ~= "function" then
        return nil
    end
    local okCanvas, canvas = pcall(frame.GetCanvas, frame)
    if not okCanvas or not canvas then
        return nil
    end
    if worldBorder and worldFill and worldParent == canvas then
        return worldBorder, worldFill, canvas, worldParent, worldUsesAtlas
    end

    -- 父级变了（画布被重建）或首次创建：旧贴图收起后按新画布重建
    if worldBorder or worldFill then
        DebugPrint("world: canvas changed, rebuild markers")
    end
    DestroyWorldMarkers()

    local parent = canvas
    if type(canvas.CreateTexture) ~= "function" then
        -- 兜底：画布不允许直接挂贴图时，退回同尺寸的中转框体（坐标与画布一致）
        local okFrame, container = pcall(CreateFrame, "Frame", nil, canvas)
        if not okFrame or not container then
            return nil
        end
        local okSetup = pcall(function()
            container:SetAllPoints(canvas)
            container:SetFrameLevel(canvas:GetFrameLevel() + 100)
            container:Show()
        end)
        if not okSetup then
            pcall(container.Hide, container)
            return nil
        end
        parent = container
        worldContainer = container
    end

    local border = CreateMarkerTexture(parent)
    local fill = CreateMarkerTexture(parent)
    local okBorder = border
        and ConfigureMarkerTexture(border, WORLD_MARKER_BORDER_SIZE, 0,
            BORDER_R, BORDER_G, BORDER_B, BORDER_ALPHA)
    -- 同小地图：不能写成 `fill and ConfigureMarkerTexture(...)`，否则 usedAtlas 恒为 nil，
    -- 托底方块会一直显示（Lua 5.1 的 and 截断右侧调用的多返回值）。
    local okFill, usedAtlas, atlasName
    if fill then
        okFill, usedAtlas, atlasName = ConfigureMarkerTexture(fill, WORLD_MARKER_SIZE, 1,
            MARKER_R, MARKER_G, MARKER_B, MARKER_ALPHA, true, WORLD_ATLAS_MARKER_SIZE)
    end
    if not okBorder or not okFill then
        if border then pcall(border.Hide, border) end
        if fill then pcall(fill.Hide, fill) end
        if worldContainer then
            pcall(worldContainer.Hide, worldContainer)
            worldContainer = nil
        end
        return nil
    end

    worldBorder, worldFill, worldParent = border, fill, parent
    worldUsesAtlas = usedAtlas == true
    -- 悬停感应框：与标记同尺寸，父级与贴图一致；画布重建时随标记一起重建
    worldHover = CreateMarkerHover(parent,
        worldUsesAtlas and WORLD_ATLAS_MARKER_SIZE or WORLD_MARKER_BORDER_SIZE)
    if worldHover then
        -- 略高于画布，保证能收到悬停；点击/拖动已设为向下穿透，不影响地图拖动
        pcall(function()
            worldHover:SetFrameLevel(parent:GetFrameLevel() + 10)
        end)
    end
    if worldUsesAtlas then
        DebugPrint("world marker atlas: " .. tostring(atlasName))
    else
        DebugPrint("world marker atlas: none（纯色回退）")
    end
    return worldBorder, worldFill, canvas, worldParent, worldUsesAtlas
end

-- debug 快照：训练师类型、训练师、地图 ID、换算坐标、偏移、画布尺寸/缩放、贴图父级、连续失败计数
local function DescribeWorldMarker(canvas, width, height, offsetX, offsetY, nearest, displayMapID, mapX, mapY)
    local trainerName = "?"
    if nearest and type(nearest.trainer) == "table" and type(nearest.trainer.name) == "string" then
        trainerName = nearest.trainer.name
    end
    local typeName = "?"
    if nearest and type(nearest.typeName) == "string" and nearest.typeName ~= "" then
        typeName = nearest.typeName
    end
    local fillShown = "?"
    if worldFill and type(worldFill.IsShown) == "function" then
        local okShown, value = pcall(worldFill.IsShown, worldFill)
        if okShown then fillShown = tostring(value) end
    end
    local canvasScale = "?"
    if canvas and type(canvas.GetScale) == "function" then
        local okScale, scale = pcall(canvas.GetScale, canvas)
        if okScale then canvasScale = string.format("%.4f", scale) end
    end
    return string.format(
        "world: type=%s trainer=%s nearestMap=%s displayMap=%s mapXY=%.4f,%.4f offset=%.1f,%.1f "
            .. "canvas=%sx%s canvasScale=%s parentIsCanvas=%s fillShown=%s fails=%d",
        typeName, trainerName, tostring(nearest and nearest.mapID), tostring(displayMapID),
        mapX, mapY, offsetX, offsetY,
        tostring(width), tostring(height), canvasScale,
        tostring(worldParent ~= nil and worldParent == canvas), tostring(fillShown),
        worldFailCount)
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
        -- 地图没开：收起即可，缓存留到下次打开时继续用
        ResetWorldRetry()
        worldFailCount = 0
        HideWorldMarkers()
        return
    end

    local displayMapID = ResolveDisplayMapID()
    if not displayMapID then
        FailWorldDraw("world: no display mapID", nil)
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
        -- 换算失败：同一张显示地图时保留上次成功画出的位置
        FailWorldDraw("world: convert failed", displayMapID)
        return
    end

    local border, fill, canvas, parent, usedAtlas = EnsureWorldMarkers()
    if not border or not fill or not canvas or not parent then
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

    -- 画布局部坐标：x∈[0,1] 映射到 [0,W]，y 自顶向下，所以 Y 取负。
    -- 贴图直接挂在画布上（或兜底的中转框体，其 TOPLEFT 与画布重合），
    -- 画布缩放 0.6956 之类由画布自身处理，这里绝不乘 GetScale()。
    local offsetX, offsetY = mapX * width, -mapY * height
    local okPoint = pcall(function()
        border:ClearAllPoints()
        fill:ClearAllPoints()
        if usedAtlas then
            border:Hide()
            fill:SetPoint("CENTER", parent, "TOPLEFT", offsetX, offsetY)
            fill:Show()
        else
            border:SetPoint("CENTER", parent, "TOPLEFT", offsetX, offsetY)
            border:Show()
            fill:SetPoint("CENTER", parent, "TOPLEFT", offsetX, offsetY)
            fill:Show()
        end
    end)
    if not okPoint then
        ResetWorldRetry()
        FailWorldDraw("world: SetPoint failed", displayMapID)
        return
    end

    -- 感应框与标记同位置（画布局部坐标）同步显隐，供鼠标悬停弹提示
    if worldHover then
        local okHover = pcall(function()
            worldHover.info = BuildMarkerInfo(nearest)
            worldHover:ClearAllPoints()
            worldHover:SetPoint("CENTER", parent, "TOPLEFT", offsetX, offsetY)
            worldHover:Show()
        end)
        if not okHover then
            pcall(worldHover.Hide, worldHover)
        end
    end

    -- 画成功才更新缓存与失败计数
    worldFailCount = 0
    lastWorldDraw = { mapX = mapX, mapY = mapY, mapID = displayMapID }
    if IsDebug() then
        DebugPrint(DescribeWorldMarker(
            canvas, width, height, offsetX, offsetY, nearest, displayMapID, mapX, mapY))
    end
end

---------------------------------------------------------------- 刷新
local ticker
local minimapTicker

local function HideAllMarkers()
    HideMinimapMarkers()
    HideWorldMarkers()
    -- 全量收起（功能关闭 / 未预料错误）时一并清掉世界地图缓存，
    -- 避免下次刷新把标记画回到过期的位置
    worldFailCount = 0
    lastWorldDraw = nil
    -- 小地图位置缓存同样作废，避免高频刷新把标记画回旧位置
    minimapNearest = nil
end

local function RefreshInternal()
    if not IsEnabled() then
        HideAllMarkers()
        return
    end
    local nearest = FindNearest()
    -- 供 0.1 秒高频刷新复用；读不到时置 nil，小地图标记随之收起
    minimapNearest = nearest
    if not nearest then
        -- 偶发读不到（专业窗口切换、玩家坐标暂时不可得）时不立刻收掉世界地图标记：
        -- 同一张显示地图时保留上次成功绘制的位置，连续失败到上限才隐藏。
        -- 小地图缓存已在上方清空，立即收起即可。
        HideMinimapMarkers()
        FailWorldDraw("world: no nearest", ResolveDisplayMapID())
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
    if ticker then
        pcall(ticker.Cancel, ticker)
        ticker = nil
    end
    if minimapTicker then
        pcall(minimapTicker.Cancel, minimapTicker)
        minimapTicker = nil
    end
end

local function StartTicker()
    if ticker and minimapTicker then
        return
    end
    if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then
        return
    end
    if not ticker then
        local ok, newTicker = pcall(C_Timer.NewTicker, TICKER_SECONDS, Refresh)
        if ok then
            ticker = newTicker
        end
    end
    if not minimapTicker then
        local okMinimap, newMinimapTicker =
            pcall(C_Timer.NewTicker, MINIMAP_TICK_SECONDS, RefreshMinimapPosition)
        if okMinimap then
            minimapTicker = newMinimapTicker
        end
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
