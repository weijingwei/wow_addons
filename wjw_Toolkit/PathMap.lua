-- QuestPath v0.1 - 坐标换算与距离计算
local QP = QuestPath

local MAX_MAP_DEPTH = 32

local function GetParentMapID(mapID)
	local info = C_Map.GetMapInfo(mapID)
	if not info or not info.parentMapID or info.parentMapID == 0 then
		return nil
	end
	return info.parentMapID
end

local function IsCosmicMap(mapID)
	local info = C_Map.GetMapInfo(mapID)
	return info and info.mapType == Enum.UIMapType.Cosmic
end

function QP.GetPlayerMapAndPos()
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID then
		return nil
	end
	local position = C_Map.GetPlayerMapPosition(mapID, "player")
	if not position then
		return nil
	end
	local x, y = position:GetXY()
	if not x or not y or (x == 0 and y == 0) then
		return nil
	end
	return mapID, x, y
end

function QP.FindCommonAncestor(mapA, mapB)
	if not mapA or not mapB then
		return nil
	end
	local ancestors = {}
	local id, depth = mapA, 0
	while id and depth < MAX_MAP_DEPTH do
		ancestors[id] = true
		id = GetParentMapID(id)
		depth = depth + 1
	end
	id, depth = mapB, 0
	while id and depth < MAX_MAP_DEPTH do
		if ancestors[id] then
			return id
		end
		id = GetParentMapID(id)
		depth = depth + 1
	end
	return nil
end

-- 把 mapID 上的归一化坐标逐级换算到祖先地图 ancestorID 上
function QP.ConvertToAncestor(mapID, x, y, ancestorID)
	local id, depth = mapID, 0
	while id and id ~= ancestorID and depth < MAX_MAP_DEPTH do
		local parent = GetParentMapID(id)
		if not parent then
			return nil
		end
		local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(id, parent)
		if not minX or not maxX or not minY or not maxY then
			return nil
		end
		local width, height = maxX - minX, maxY - minY
		if width == 0 or height == 0 then
			return nil
		end
		x = minX + x * width
		y = minY + y * height
		id = parent
		depth = depth + 1
	end
	if id ~= ancestorID then
		return nil
	end
	return x, y
end

-- 把 fromMapID 上的归一化坐标换算到 toMapID 上（可跨多级地图）
function QP.ConvertBetweenMaps(fromMapID, x, y, toMapID)
	if fromMapID == toMapID then
		return x, y
	end
	local common = QP.FindCommonAncestor(fromMapID, toMapID)
	if not common or IsCosmicMap(common) then
		return nil
	end
	local commonX, commonY = QP.ConvertToAncestor(fromMapID, x, y, common)
	if not commonX then
		return nil
	end
	-- 从共同祖先自上而下换算到目标地图
	local path = {}
	local id, depth = toMapID, 0
	while id and id ~= common and depth < MAX_MAP_DEPTH do
		local parent = GetParentMapID(id)
		if not parent then
			return nil
		end
		path[#path + 1] = id
		id = parent
		depth = depth + 1
	end
	if id ~= common then
		return nil
	end
	for index = #path, 1, -1 do
		local child = path[index]
		local parent = GetParentMapID(child)
		local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(child, parent)
		if not minX or not maxX or not minY or not maxY then
			return nil
		end
		local width, height = maxX - minX, maxY - minY
		if width == 0 or height == 0 then
			return nil
		end
		commonX = (commonX - minX) / width
		commonY = (commonY - minY) / height
	end
	return commonX, commonY
end

local function GetWorldPosition(mapID, x, y)
	local instanceID, worldPosition = C_Map.GetWorldPosFromMapPos(mapID, { x = x, y = y })
	if not instanceID or not worldPosition then
		return nil
	end
	local worldX, worldY = worldPosition:GetXY()
	if not worldX or not worldY then
		return nil
	end
	return instanceID, worldX, worldY
end

-- 返回：玩家到指定地图坐标的直线距离（码）、朝向（弧度，0=北，逆时针增大）；失败时返回 nil, 错误文字
function QP.GetDistanceToPoint(pointMap, pointX, pointY)
	local playerMap, playerX, playerY = QP.GetPlayerMapAndPos()
	if not playerMap then
		return nil, "当前地图不支持"
	end

	-- 世界坐标的 X 轴向北为正、Y 轴向西为正
	local playerInstance, playerWorldX, playerWorldY = GetWorldPosition(playerMap, playerX, playerY)
	local targetInstance, targetWorldX, targetWorldY = GetWorldPosition(pointMap, pointX, pointY)
	if playerWorldX and targetWorldX and playerInstance == targetInstance then
		local north = targetWorldX - playerWorldX
		local east = playerWorldY - targetWorldY
		return math.sqrt(east * east + north * north), math.atan2(-east, north)
	end

	local common = QP.FindCommonAncestor(playerMap, pointMap)
	if not common or IsCosmicMap(common) then
		return nil, "目标不在当前地图"
	end
	local playerOnCommonX, playerOnCommonY = QP.ConvertToAncestor(playerMap, playerX, playerY, common)
	local targetOnCommonX, targetOnCommonY = QP.ConvertToAncestor(pointMap, pointX, pointY, common)
	if not playerOnCommonX or not targetOnCommonX then
		return nil, "目标不在当前地图"
	end
	local worldWidth, worldHeight = C_Map.GetMapWorldSize(common)
	if not worldWidth or worldWidth == 0 or not worldHeight or worldHeight == 0 then
		return nil, "无法计算距离"
	end
	local east = (targetOnCommonX - playerOnCommonX) * worldWidth
	local north = -(targetOnCommonY - playerOnCommonY) * worldHeight
	return math.sqrt(east * east + north * north), math.atan2(-east, north)
end

-- 返回：到目标的直线距离（码）、朝向（弧度，0=北，逆时针增大）；失败时返回 nil, 错误文字
function QP.GetTargetRelative()
	local target = QP.target
	if not target then
		return nil, "未设定目标"
	end
	return QP.GetDistanceToPoint(target.uiMapID, target.x, target.y)
end

-- 世界地图绘制用：返回玩家与目标在 displayMapID 上的归一化坐标
function QP.GetPositionsOnMap(displayMapID)
	if not displayMapID then
		return nil, nil, nil, nil, "地图未就绪"
	end
	local playerMap, playerX, playerY = QP.GetPlayerMapAndPos()
	if not playerMap then
		return nil, nil, nil, nil, "当前地图不支持"
	end
	local target = QP.target
	if not target then
		return nil, nil, nil, nil, "未设定目标"
	end

	local displayPlayerX, displayPlayerY = QP.ConvertBetweenMaps(playerMap, playerX, playerY, displayMapID)
	local displayTargetX, displayTargetY = QP.ConvertBetweenMaps(target.uiMapID, target.x, target.y, displayMapID)
	if not displayPlayerX or not displayTargetX then
		return nil, nil, nil, nil, "目标不在当前地图"
	end
	return displayPlayerX, displayPlayerY, displayTargetX, displayTargetY
end
