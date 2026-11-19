-- QuestPath v0.3 - 斜杠命令与目标状态
QuestPath = QuestPath or {}
local QP = QuestPath

QP.target = nil
QP.arrowEnabled = true
-- 自动追踪默认开启：装好即用，登录后只要有追踪/选中任务就自动出线路
QP.autoTrack = true
-- 当前已成功应用的任务 ID：与当前任务相同时不重复设定，避免重置到达判定
QP.autoAppliedQuestID = nil
-- 上一轮 AutoTick 看到的任务 ID：Main.lua 每 0.1 秒比对它，变化时立即检查
QP.autoLastCheckedID = nil
-- 解析失败已提示过的任务 ID 集合：每个任务只提示一次，但重试不受限
QP.autoWarnedQuests = {}
-- 静默模式：开启后不输出自动追踪类提示；错误提示与手动命令反馈不受影响
QP.quiet = false

-- 到达判定：离目标不超过该距离（码）时视为已到达，隐藏全部线路与箭头
local ARRIVE_RADIUS = 15
QP.arrived = false
QP.arriveNotified = false
local arriveTarget -- 上次检查时的目标，用于识别目标是否改变

local function Print(message)
	print("|cff33ff99QuestPath|r: " .. tostring(message))
end
QP.Print = Print

-- ===== 设置持久化（存档变量 QuestPathDB 由 QuestPath.toc 的 ## SavedVariables 声明）=====
-- 存档在对应插件的 ADDON_LOADED 事件触发前才可用，因此所有访问都做 nil 保护：
-- 新装用户首次登录时 QuestPathDB 为 nil，此时各项保持文件开头的默认值（自动追踪开启）。
function QP.LoadSettings()
	local db = QuestPathDB
	if type(db) ~= "table" then
		return
	end
	-- false 是合法值（用户主动关闭），只能用 ~= nil 判断，不能用 or 兜底
	if db.autoTrack ~= nil then
		QP.autoTrack = db.autoTrack
	end
	if db.arrowEnabled ~= nil then
		QP.arrowEnabled = db.arrowEnabled
	end
	if db.quiet ~= nil then
		QP.quiet = db.quiet
	end
	-- 自动追踪关闭时恢复上次的目标；开启时交给自动追踪按当前任务重新推导
	if not QP.autoTrack then
		local saved = db.target
		if type(saved) == "table" and type(saved.uiMapID) == "number"
			and type(saved.x) == "number" and type(saved.y) == "number" then
			-- 旧存档没有 questID：读回为 nil，按手动目标对待
			local questID = type(saved.questID) == "number" and saved.questID or nil
			QP.target = { uiMapID = saved.uiMapID, x = saved.x, y = saved.y, questID = questID, source = "saved" }
		end
	end
end

function QP.SaveSettings()
	QuestPathDB = QuestPathDB or {}
	QuestPathDB.autoTrack = QP.autoTrack
	QuestPathDB.arrowEnabled = QP.arrowEnabled
	QuestPathDB.quiet = QP.quiet
end

-- 目标变化后调用：把当前目标镜像进存档；QP.target 为 nil 时清掉存档里的目标
function QP.SaveTarget()
	if not QuestPathDB then
		return
	end
	local target = QP.target
	if target then
		QuestPathDB.target = { uiMapID = target.uiMapID, x = target.x, y = target.y, questID = target.questID }
	else
		QuestPathDB.target = nil
	end
end

-- 静默提示：用于自动追踪等非用户直接触发的事件；quiet 开启时不输出
function QP.Notify(message)
	if QP.quiet then
		return
	end
	Print(message)
end

local function Trim(text)
	return (text or ""):match("^%s*(.-)%s*$")
end

local function NormalizeCoordinate(value)
	if value <= 1 then
		return value
	end
	return value / 100
end

-- 校验路点坐标：两套路点 API 正常返回 0-1 归一化坐标，
-- 但为防某一版本改用 0-100 百分数，任一值大于 1 时整体按百分数处理
local function SanitizeWaypoint(x, y)
	x, y = tonumber(x), tonumber(y)
	if not x or not y or x < 0 or y < 0 then
		return nil
	end
	if x > 1 or y > 1 then
		x, y = x / 100, y / 100
	end
	if x > 1 or y > 1 or (x == 0 and y == 0) then
		return nil
	end
	return x, y
end

local function DescribeTarget()
	local target = QP.target
	if not target then
		return "未设定目标"
	end
	local info = C_Map.GetMapInfo(target.uiMapID)
	local mapName = info and info.name or tostring(target.uiMapID)
	local questTitle = ""
	if target.questID then
		questTitle = "（" .. (C_QuestLog.GetTitleForQuestID(target.questID) or ("任务 " .. target.questID)) .. "）"
	end
	return string.format("目标%s：%s %.1f, %.1f", questTitle, mapName, target.x * 100, target.y * 100)
end

local QUEST_MAP_DEPTH = 4

-- 从玩家当前地图向上收集地图（当前地图 → 上级 → 大陆），宇宙层没有任务 POI，不纳入
local function GetQuestMapChain()
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID then
		return {}
	end
	local chain = {}
	local id, depth = mapID, 0
	while id and depth < QUEST_MAP_DEPTH do
		local info = C_Map.GetMapInfo(id)
		if not info or info.mapType == Enum.UIMapType.Cosmic then
			break
		end
		chain[#chain + 1] = id
		if info.mapType == Enum.UIMapType.Continent then
			break
		end
		if not info.parentMapID or info.parentMapID == 0 then
			break
		end
		id = info.parentMapID
		depth = depth + 1
	end
	return chain
end

-- 收集一个任务的目标点：优先进行中的任务 POI，其次世界任务位置，再次下一路点
local function CollectQuestPoints(questID)
	local chain = GetQuestMapChain()
	local points = {}
	local seen = {}
	local function Add(mapID, x, y)
		if not mapID or not x or not y or not C_Map.GetMapInfo(mapID) then
			return
		end
		local key = string.format("%d:%.4f:%.4f", mapID, x, y)
		if seen[key] then
			return
		end
		seen[key] = true
		points[#points + 1] = { uiMapID = mapID, x = x, y = y }
	end

	-- 任务日志中该任务进行中的目标点（坐标相对于被查询的地图，与暴雪地图面板的用法一致）
	for _, mapID in ipairs(chain) do
		local quests = C_QuestLog.GetQuestsOnMap(mapID)
		if quests then
			for _, info in ipairs(quests) do
				if info.questID == questID and info.inProgress then
					Add(mapID, info.x, info.y)
				end
			end
		end
	end

	-- 世界任务（task quest）位置
	if #points == 0 then
		for _, mapID in ipairs(chain) do
			Add(mapID, C_TaskQuest.GetQuestLocation(questID, mapID))
		end
	end

	-- 各层地图上的下一路点
	if #points == 0 then
		for _, mapID in ipairs(chain) do
			Add(mapID, C_QuestLog.GetNextWaypointForMap(questID, mapID))
		end
	end

	-- 全局下一路点（可跨大陆）
	if #points == 0 then
		local mapID, x, y = C_QuestLog.GetNextWaypoint(questID)
		Add(mapID, x, y)
	end

	return points
end

local function SelectNearestPoint(points)
	local best, bestDistance
	for _, point in ipairs(points) do
		local distance = QP.GetDistanceToPoint(point.uiMapID, point.x, point.y)
		if distance and (not bestDistance or distance < bestDistance) then
			best, bestDistance = point, distance
		end
	end
	return best or points[1], bestDistance
end

function QP.GetTrackedQuestID()
	local questID = C_SuperTrack.GetSuperTrackedQuestID()
	if questID and questID > 0 then
		return questID
	end
	return nil
end

function QP.GetSelectedQuestID()
	local questID = C_QuestLog.GetSelectedQuest()
	if questID and questID > 0 then
		return questID
	end
	return nil
end

-- 自动追踪的当前任务：优先超级追踪（与官方黄色箭头同源），没有时才用任务日志选中
function QP.GetAutoQuestID()
	local questID = QP.GetTrackedQuestID()
	if questID then
		return questID
	end
	return QP.GetSelectedQuestID()
end

-- source 标记目标来源（tracked/selected/auto）；silent 为真时不输出设定成功提示（自动追踪用）
function QP.SetQuestTarget(questID, source, silent)
	local points = CollectQuestPoints(questID)
	if #points == 0 then
		return false
	end
	local point, distance = SelectNearestPoint(points)
	QP.target = { uiMapID = point.uiMapID, x = point.x, y = point.y, questID = questID, source = source }
	QP.SaveTarget()

	-- 自动追踪触发的目标设定一律静默，避免每次切换追踪任务都往聊天框刷屏
	if silent then
		return true
	end

	local info = C_Map.GetMapInfo(point.uiMapID)
	local mapName = info and info.name or tostring(point.uiMapID)
	local title = C_QuestLog.GetTitleForQuestID(questID) or ("任务 " .. questID)
	if #points > 1 then
		Print(string.format("该任务有 %d 个目标，已选最近的", #points))
	end
	if distance then
		Print(string.format("目标已设定：%s（%s %.1f, %.1f），直线距离 %.0f 码", title, mapName, point.x * 100, point.y * 100, distance))
	else
		Print(string.format("目标已设定：%s（%s %.1f, %.1f）；该地点不在当前地图，暂时无法计算直线距离", title, mapName, point.x * 100, point.y * 100))
	end
	return true
end

function QP.UseQuestTarget()
	local questID = QP.GetTrackedQuestID()
	local source = "tracked"
	if not questID then
		questID = QP.GetSelectedQuestID()
		source = "selected"
	end
	if not questID then
		Print("没有可用的任务目标：请先在任务追踪或任务日志中选中一个任务")
		return false
	end
	if not QP.SetQuestTarget(questID, source) then
		Print("没有可用的任务目标：该任务在当前地图附近读不到目标点")
		return false
	end
	return true
end

-- 同一任务重新解析目标点时，两点的差异阈值（归一化坐标）：
-- 0.0015 约为地图宽度的千分之一点五（1000 码宽的地图约 1.5 码），
-- 小于它视为同一个点，避免玩家走动时目标反复重建
local TARGET_CHANGE_THRESHOLD = 0.0015

-- 同一个任务重新解析目标点：任务 ID 不变时目标点仍可能变化
-- （目标做完后从击杀地点改指交付 NPC）。只在点确实变化时才更新：
-- 点没变时什么都不做——不重置到达、不写存档、不打日志。
local function RefreshAutoTarget(questID)
	local target = QP.target
	-- 手动目标（/qp <x> <y>、/qp quest）优先，自动追踪不覆盖
	if target and target.source ~= "auto" then
		return false
	end

	local points = CollectQuestPoints(questID)
	if #points == 0 then
		return false
	end
	local point = SelectNearestPoint(points)

	-- 目标点没变（同一张地图、差异在阈值内）：什么都不做
	if target and target.uiMapID == point.uiMapID
		and math.abs(point.x - target.x) <= TARGET_CHANGE_THRESHOLD
		and math.abs(point.y - target.y) <= TARGET_CHANGE_THRESHOLD then
		return false
	end

	-- 目标点确实变了：走统一设定路径，保持 source、存档与提示一致
	if not QP.SetQuestTarget(questID, "auto", true) then
		return false
	end
	-- 新目标必须复位到达状态，否则会被旧的"已到达"挡住
	QP.arrived = false
	QP.arriveNotified = false
	QP.UpdateRouteWaypoint()
	return true
end

-- 自动追踪：每轮按当前任务重新推导目标
-- 优先级与官方黄色箭头同源：先超级追踪（C_SuperTrack），没有时才退回任务日志选中（C_QuestLog）
-- 解析失败不记为"已处理"：下一轮继续重试；失败提示按任务只提示一次
function QP.AutoTick()
	if not QP.autoTrack then
		return
	end

	-- 目标归属的任务已不在任务日志中（交付/放弃后消失）时清除目标：
	-- 判据是"目标挂的任务还在不在"，不看 source —— 存档恢复的 saved 目标同样会清；
	-- 手动目标（/qp <x> <y>）没有 questID，永远不会被这条清掉
	local current = QP.target
	if current and type(current.questID) == "number" and not C_QuestLog.IsOnQuest(current.questID) then
		QP.target = nil
		QP.SaveTarget()
		QP.autoAppliedQuestID = nil
		QP.arrived = false
		QP.arriveNotified = false
		QP.Notify("任务已不在任务日志中，目标已清除")
	end

	local questID = QP.GetAutoQuestID()
	QP.autoLastCheckedID = questID

	if not questID then
		-- 既没有超级追踪任务，也没有任务日志选中任务：
		-- 只清除自动推导的目标；手动目标（/qp <x> <y>、/qp quest）保持不变
		local target = QP.target
		if target and target.source == "auto" then
			QP.target = nil
			QP.SaveTarget()
			QP.Notify("追踪任务已取消，自动目标已清除")
		end
		QP.autoAppliedQuestID = nil
		return
	end

	-- 同一个任务不再直接跳过：任务目标完成后任务 ID 不变，
	-- 但目标点会从击杀地点变成交付人，必须重新解析一次（见 RefreshAutoTarget）
	if QP.autoAppliedQuestID == questID then
		RefreshAutoTarget(questID)
		return
	end

	if QP.SetQuestTarget(questID, "auto", true) then
		QP.autoAppliedQuestID = questID
		QP.autoWarnedQuests[questID] = nil
		return
	end
	-- 解析失败：不清 autoAppliedQuestID，下一轮（每 2 秒）继续重试；提示只出一次
	-- 这是自动重试的过程通知，不是硬错误：走 Notify，受 /qp quiet on 控制
	if not QP.autoWarnedQuests[questID] then
		QP.autoWarnedQuests[questID] = true
		QP.Notify("自动追踪：暂时读不到该任务的目标点，将每 2 秒重试")
	end
end

-- 读取"游戏给出的下一个路点"，作为本段线路的临时终点
-- 取点顺序：a) 按任务取（C_QuestLog）；b) 当前超级追踪的就是本目标时，按导航路径取（C_Navigation）
-- 取不到就清空路点，绘制回落到最终目标（与旧版行为完全一致）
-- 只在 0.5 秒节流与 SUPER_TRACKING_PATH_UPDATED 事件里调用，不进入逐帧路径
function QP.UpdateRouteWaypoint()
	local target = QP.target
	if not target then
		return
	end
	target.waypoint = nil
	target.waypointSource = nil

	local questID = target.questID
	if type(questID) ~= "number" then
		return
	end
	local playerMap = C_Map.GetBestMapForUnit("player")
	if not playerMap then
		return
	end

	local x, y = SanitizeWaypoint(C_QuestLog.GetNextWaypointForMap(questID, playerMap))
	local source = x and "quest" or nil
	if not x and C_SuperTrack.GetSuperTrackedQuestID() == questID then
		x, y = SanitizeWaypoint(C_Navigation.GetNextWaypointForMap(playerMap))
		source = x and "nav" or nil
	end
	if not x then
		return
	end

	target.waypoint = { uiMapID = playerMap, x = x, y = y }
	target.waypointSource = source
end

-- 本段的绘制终点：优先用下一个路点，没有可用路点时用最终目标
function QP.GetRoutePoint()
	local target = QP.target
	if not target then
		return nil
	end
	local waypoint = target.waypoint
	if type(waypoint) == "table" and type(waypoint.uiMapID) == "number"
		and type(waypoint.x) == "number" and type(waypoint.y) == "number" then
		return waypoint
	end
	return target
end

-- 到本段绘制终点的距离与朝向；路点换不过去时回落到最终目标
function QP.GetRouteRelative()
	local target = QP.target
	if not target then
		return nil, "未设定目标"
	end
	local point = QP.GetRoutePoint()
	if point ~= target then
		local distance, bearing = QP.GetDistanceToPoint(point.uiMapID, point.x, point.y)
		if distance then
			return distance, bearing
		end
	end
	return QP.GetDistanceToPoint(target.uiMapID, target.x, target.y)
end

-- 世界地图绘制用：玩家与本段绘制终点在 displayMapID 上的归一化坐标
-- 路点在这个世界地图上换不过去时，回落到最终目标
function QP.GetRoutePositionsOnMap(displayMapID)
	if not displayMapID then
		return nil, nil, nil, nil, "地图未就绪"
	end
	local playerMap, playerX, playerY = QP.GetPlayerMapAndPos()
	if not playerMap then
		return nil, nil, nil, nil, "当前地图不支持"
	end
	local displayPlayerX, displayPlayerY = QP.ConvertBetweenMaps(playerMap, playerX, playerY, displayMapID)
	if not displayPlayerX then
		return nil, nil, nil, nil, "目标不在当前地图"
	end

	local target = QP.target
	if not target then
		return nil, nil, nil, nil, "未设定目标"
	end
	local point = QP.GetRoutePoint()
	local displayTargetX, displayTargetY = QP.ConvertBetweenMaps(point.uiMapID, point.x, point.y, displayMapID)
	if not displayTargetX and point ~= target then
		displayTargetX, displayTargetY = QP.ConvertBetweenMaps(target.uiMapID, target.x, target.y, displayMapID)
	end
	if not displayTargetX then
		return nil, nil, nil, nil, "目标不在当前地图"
	end
	return displayPlayerX, displayPlayerY, displayTargetX, displayTargetY
end

function QP.SetAutoTracking(enabled)
	QP.autoTrack = enabled
	QP.SaveSettings()
	QP.autoAppliedQuestID = nil
	QP.autoLastCheckedID = nil
	QP.autoWarnedQuests = {}
	if not enabled then
		Print("自动追踪已关闭，当前目标保持不变")
		return
	end
	if QP.GetAutoQuestID() then
		Print("自动追踪已开启，每 2 秒检查一次当前追踪任务")
	else
		Print("自动追踪已开启，每 2 秒检查一次；当前没有追踪或选中的任务，开始追踪后会自动设定目标")
	end
	QP.AutoTick()
end

-- 到达判定：距离 ≤ ARRIVE_RADIUS 码时进入到达状态，Overlay 据此隐藏全部路线
-- 目标改变或距离重新超出阈值时复位提示状态，只在刚进入到达状态时提示一次
function QP.UpdateArrival()
	local target = QP.target
	if target ~= arriveTarget then
		arriveTarget = target
		QP.arrived = false
		QP.arriveNotified = false
	end
	if not target then
		QP.arrived = false
		return
	end
	local distance = QP.GetTargetRelative()
	if not distance then
		QP.arrived = false
		return
	end
	if distance > ARRIVE_RADIUS then
		QP.arrived = false
		QP.arriveNotified = false
		return
	end
	QP.arrived = true
	if not QP.arriveNotified then
		QP.arriveNotified = true
		QP.Notify("已到达目标附近")
	end
end

local function DescribeQuestBrief(questID)
	if not questID then
		return "无"
	end
	return string.format("%d（%s）", questID, C_QuestLog.GetTitleForQuestID(questID) or "无")
end

-- ===== 诊断：选中任务的目标点解析链路（仅 /qp debug 调用，不进入任何循环路径）=====
-- 安全调用：命名空间或方法缺失、调用抛错时返回 false 与原因，保证诊断本身不报错
local function TryApi(namespace, apiName, ...)
	if type(namespace) ~= "table" or type(namespace[apiName]) ~= "function" then
		return false, "不可用"
	end
	local ok, a, b, c = pcall(namespace[apiName], ...)
	if not ok then
		return false, "调用失败：" .. tostring(a)
	end
	return true, a, b, c
end

local function FormatQuestCoord(x, y)
	if type(x) ~= "number" or type(y) ~= "number" then
		return "无"
	end
	return string.format("%.4f, %.4f", x, y)
end

-- 逐级打印一个任务的目标点解析链路：任务状态 → 地图链上各 API 的原始返回 → 现有解析逻辑的最终结果
local function PrintQuestPointChain()
	-- 取任务顺序与自动追踪一致：优先任务日志选中，没有时退回超级追踪
	local questID = QP.GetSelectedQuestID() or QP.GetTrackedQuestID()
	Print("===== 目标点解析链路 =====")
	if not questID then
		Print("无选中/追踪任务，跳过")
		return
	end

	local okTitle, title = TryApi(C_QuestLog, "GetTitleForQuestID", questID)
	local okOnQuest, onQuest = TryApi(C_QuestLog, "IsOnQuest", questID)
	local okComplete, isComplete = TryApi(C_QuestLog, "IsComplete", questID)
	Print(string.format("任务：%d（%s）/ 在任务日志中：%s / 已完成：%s",
		questID,
		okTitle and (title and tostring(title) or "无标题") or "不可用",
		okOnQuest and tostring(onQuest) or "不可用",
		okComplete and tostring(isComplete) or "不可用"))

	local function MapName(mapID)
		local ok, info = TryApi(C_Map, "GetMapInfo", mapID)
		if ok and type(info) == "table" and info.name then
			return info.name
		end
		return "未知地图"
	end

	local chain = GetQuestMapChain()
	if #chain == 0 then
		Print("地图链为空（当前地图不可用），无法继续")
		return
	end

	for index, mapID in ipairs(chain) do
		-- 任务日志 POI：匹配条目数量 + 每条的坐标与状态
		local okQuests, quests = TryApi(C_QuestLog, "GetQuestsOnMap", mapID)
		local questPart
		if not okQuests then
			questPart = "GetQuestsOnMap " .. tostring(quests)
		else
			local matched = {}
			if type(quests) == "table" then
				for _, info in ipairs(quests) do
					if type(info) == "table" and info.questID == questID then
						matched[#matched + 1] = string.format("x=%s, y=%s, inProgress=%s, isQuestStart=%s",
							tostring(info.x), tostring(info.y),
							tostring(info.inProgress), tostring(info.isQuestStart))
					end
				end
			end
			if #matched == 0 then
				questPart = "GetQuestsOnMap 匹配 0 条"
			else
				questPart = string.format("GetQuestsOnMap 匹配 %d 条[%s]", #matched, table.concat(matched, "；"))
			end
		end

		-- 世界任务位置
		local okLocation, locationX, locationY = TryApi(C_TaskQuest, "GetQuestLocation", questID, mapID)
		local locationPart
		if okLocation then
			locationPart = "TaskQuest 位置 " .. FormatQuestCoord(locationX, locationY)
		else
			locationPart = "TaskQuest " .. tostring(locationX)
		end

		-- 该地图上的下一路点
		local okWaypoint, waypointX, waypointY = TryApi(C_QuestLog, "GetNextWaypointForMap", questID, mapID)
		local waypointPart
		if okWaypoint then
			waypointPart = "NextWaypointForMap " .. FormatQuestCoord(waypointX, waypointY)
		else
			waypointPart = "NextWaypointForMap " .. tostring(waypointX)
		end

		Print(string.format("地图 %d %s（ID %d）：%s / %s / %s",
			index, MapName(mapID), mapID, questPart, locationPart, waypointPart))
	end

	-- 全局下一路点（可跨大陆）
	local okGlobal, globalMap, globalX, globalY = TryApi(C_QuestLog, "GetNextWaypoint", questID)
	if not okGlobal then
		Print("全局路点（GetNextWaypoint）：" .. tostring(globalMap))
	elseif type(globalMap) == "number" then
		Print(string.format("全局路点（GetNextWaypoint）：%s（ID %d）%s",
			MapName(globalMap), globalMap, FormatQuestCoord(globalX, globalY)))
	else
		Print("全局路点（GetNextWaypoint）：无返回")
	end

	-- 结论：直接调用现有解析逻辑，确保与自动追踪结果一致（不复制逻辑）
	local okPoints, points = pcall(CollectQuestPoints, questID)
	if not okPoints or type(points) ~= "table" then
		Print("结论：CollectQuestPoints 调用失败：" .. tostring(points))
		return
	end
	if #points == 0 then
		Print("结论：候选点 0 个，未选中任何点（自动追踪无法设定目标）")
		return
	end
	local okPick, point, distance = pcall(SelectNearestPoint, points)
	if not okPick or type(point) ~= "table" then
		Print(string.format("结论：候选点 %d 个，选点失败：%s", #points, tostring(point)))
		return
	end
	Print(string.format("结论：候选点 %d 个，选中 %s（ID %d）%s / %s",
		#points, MapName(point.uiMapID), point.uiMapID, FormatQuestCoord(point.x, point.y),
		type(distance) == "number" and string.format("距离 %.0f 码", distance) or "距离不可算"))
end

-- 调试输出（/qp debug）：打印坐标换算链路，便于核对世界地图的绘制位置
function QP.DebugPrint()
	local mapID, playerX, playerY = QP.GetPlayerMapAndPos()
	if mapID then
		local info = C_Map.GetMapInfo(mapID)
		Print(string.format("当前地图：%s（ID %d）", info and info.name or "未知", mapID))
	else
		Print("当前地图：无法读取（该地图不支持定位）")
	end
	if playerX then
		Print(string.format("玩家归一化坐标：%.4f, %.4f", playerX, playerY))
	end

	-- 自动追踪来源核对：任务日志选中任务、超级追踪任务与目标来源
	Print("任务日志选中：" .. DescribeQuestBrief(QP.GetSelectedQuestID()))
	Print("超级追踪：" .. DescribeQuestBrief(QP.GetTrackedQuestID()))
	Print(string.format("超级追踪类型：任务=%s，用户标记点=%s",
		tostring(C_SuperTrack.IsSuperTrackingQuest()), tostring(C_SuperTrack.IsSuperTrackingUserWaypoint())))
	local target = QP.target
	local targetSource = "none"
	if target then
		if target.source == "auto" or target.source == "saved" then
			targetSource = target.source
		else
			targetSource = "manual"
		end
	end
	Print("目标来源：" .. targetSource)
	-- 目标归属的任务是否仍在任务日志中：自动追踪据此清除过期目标
	if target and type(target.questID) == "number" then
		Print(string.format("目标 questID：%d（%s）；该任务仍在日志中：%s",
			target.questID,
			C_QuestLog.GetTitleForQuestID(target.questID) or "无标题",
			tostring(C_QuestLog.IsOnQuest(target.questID))))
	elseif target then
		Print("目标 questID：无（手动目标，自动追踪不会清除）")
	else
		Print("目标 questID：无（当前未设定目标）")
	end

	-- 官方箭头同源判定：解释小地图连线为何可能被隐藏（判定逻辑在 Overlay.lua）
	if type(QP.DescribeOfficialArrow) == "function" then
		for _, line in ipairs(QP.DescribeOfficialArrow(target and target.questID)) do
			Print(line)
		end
	else
		Print("官方箭头同源判定：不可用（Overlay.lua 未加载）")
	end

	if target then
		local targetInfo = C_Map.GetMapInfo(target.uiMapID)
		Print(string.format("目标：%s（ID %d）%.4f, %.4f",
			targetInfo and targetInfo.name or "未知", target.uiMapID, target.x, target.y))
	else
		Print("目标：未设定")
	end

	-- 选中任务的目标点解析链路：逐级核对目标点在哪一步丢失
	PrintQuestPointChain()

	-- 路点来源核对：分别打印两套 API 的原始返回，以及本段实际采用的来源
	if target then
		local questID = target.questID
		local waypointMap = mapID or C_Map.GetBestMapForUnit("player")
		if type(questID) == "number" and waypointMap then
			local questX, questY = C_QuestLog.GetNextWaypointForMap(questID, waypointMap)
			Print(string.format("路点 A（C_QuestLog.GetNextWaypointForMap）：%s",
				questX and string.format("%.4f, %.4f", questX, questY) or "无返回"))
			local navX, navY = C_Navigation.GetNextWaypointForMap(waypointMap)
			local superTracked = C_SuperTrack.GetSuperTrackedQuestID()
			local note = ""
			if superTracked ~= questID then
				note = string.format("（当前超级追踪任务 %s 与本目标不同，不采用）", tostring(superTracked))
			end
			Print(string.format("路点 B（C_Navigation.GetNextWaypointForMap）：%s%s",
				navX and string.format("%.4f, %.4f", navX, navY) or "无返回", note))
			if target.waypoint then
				local waypointInfo = C_Map.GetMapInfo(target.waypoint.uiMapID)
				Print(string.format("本段采用：%s（%s ID %d）%.4f, %.4f",
					target.waypointSource == "quest" and "路点 A（任务）" or "路点 B（导航）",
					waypointInfo and waypointInfo.name or "未知", target.waypoint.uiMapID,
					target.waypoint.x, target.waypoint.y))
			else
				Print("本段采用：无可用路点，线路指向最终目标")
			end
		else
			Print("路点：当前目标没有任务 ID 或地图不可用，线路直接指向最终目标")
		end
	end

	-- 世界地图绘制层诊断：worldOverlay / dashSpecs / dashPools 是 Overlay.lua 的 local，
	-- 由 QP.DescribeWorldOverlay() 汇总成文本，这里只负责打印
	if type(QP.DescribeWorldOverlay) == "function" then
		for _, line in ipairs(QP.DescribeWorldOverlay()) do
			Print(line)
		end
	else
		Print("世界地图绘制层：诊断不可用（Overlay.lua 未加载）")
	end

	local mapFrame, canvas
	if type(QP.GetActiveMapFrame) == "function" then
		mapFrame, canvas = QP.GetActiveMapFrame()
	end
	if not canvas then
		Print("世界地图 canvas：不可用（请先打开一次世界地图）")
		return
	end
	local width, height = canvas:GetWidth(), canvas:GetHeight()
	if not width or width <= 1 or not height or height <= 1 then
		Print("世界地图 canvas：尺寸无效（请先打开一次世界地图）")
		return
	end
	Print(string.format("世界地图 canvas：%.0f × %.0f", width, height))
	local displayMapID
	if type(mapFrame.GetMapID) == "function" then
		displayMapID = mapFrame:GetMapID()
	end
	local displayInfo = displayMapID and C_Map.GetMapInfo(displayMapID)
	Print(string.format("世界地图当前显示：%s（ID %s）",
		displayInfo and displayInfo.name or "未知", tostring(displayMapID)))
	local playerPixelX, playerPixelY, targetPixelX, targetPixelY, errorMessage = QP.GetPositionsOnMap(displayMapID)
	if playerPixelX then
		Print(string.format("玩家 canvas 像素：%.1f, %.1f", playerPixelX * width, (1 - playerPixelY) * height))
		Print(string.format("目标 canvas 像素：%.1f, %.1f", targetPixelX * width, (1 - targetPixelY) * height))
	else
		Print("canvas 像素换算失败：" .. tostring(errorMessage))
	end
end

local function HandleSlash(message)
	local input = Trim(message)
	local command, first = input:match("^(%S*)%s*(%S*)")

	if not command or command == "" then
		if not QP.target then
			Print("未设定目标。用法：/qp <x> <y>、/qp quest、/qp auto on|off、/qp quiet on|off、/qp debug")
			return
		end
		local distance, bearingOrError = QP.GetTargetRelative()
		if distance then
			Print(string.format("%s，直线距离 %.0f 码", DescribeTarget(), distance))
		else
			Print(string.format("%s；%s", DescribeTarget(), bearingOrError or "无法计算距离"))
		end
		return
	end

	if command == "clear" then
		QP.target = nil
		QP.SaveTarget()
		-- 自动追踪开启时，下一次检查会按当前追踪任务或任务日志中选中的任务重新设定目标
		QP.autoAppliedQuestID = nil
		Print("已清除目标")
		return
	end

	if command == "debug" then
		QP.DebugPrint()
		return
	end

	if command == "quest" then
		QP.UseQuestTarget()
		return
	end

	if command == "auto" then
		if first == "on" then
			QP.SetAutoTracking(true)
		elseif first == "off" then
			QP.SetAutoTracking(false)
		else
			Print("自动追踪当前" .. (QP.autoTrack and "开启" or "关闭") .. "。用法：/qp auto on|off")
		end
		return
	end

	if command == "quiet" then
		if first == "on" then
			QP.quiet = true
			QP.SaveSettings()
			-- 该确认行不受 quiet 限制，否则切换成静默后用户看不到反馈
			Print("静默模式已开启：自动追踪不再提示目标设定与到达信息，错误提示仍会显示")
		elseif first == "off" then
			QP.quiet = false
			QP.SaveSettings()
			Print("静默模式已关闭")
		else
			Print("静默模式当前" .. (QP.quiet and "开启" or "关闭") .. "。用法：/qp quiet on|off")
		end
		return
	end

	if command == "arrow" then
		if first == "on" then
			QP.arrowEnabled = true
			QP.SaveSettings()
			Print("屏幕箭头已开启")
		elseif first == "off" then
			QP.arrowEnabled = false
			QP.SaveSettings()
			Print("屏幕箭头已关闭")
		else
			Print("屏幕箭头当前" .. (QP.arrowEnabled and "开启" or "关闭") .. "。用法：/qp arrow on|off")
		end
		return
	end

	local x = tonumber(command)
	local y = tonumber(first)
	if not x or not y then
		Print("参数无效。用法：/qp <x> <y>（0-1 小数或 0-100 百分数）、/qp quest、/qp auto on|off、/qp quiet on|off、/qp clear、/qp arrow on|off、/qp debug")
		return
	end

	x = NormalizeCoordinate(x)
	y = NormalizeCoordinate(y)
	if x < 0 or x > 1 or y < 0 or y > 1 then
		Print("坐标超出范围：请输入 0-1 或 0-100")
		return
	end

	local mapID = QP.GetPlayerMapAndPos()
	if not mapID then
		Print("当前地图不支持定位，无法设定目标")
		return
	end

	QP.target = { uiMapID = mapID, x = x, y = y }
	QP.SaveTarget()
	local info = C_Map.GetMapInfo(mapID)
	Print(string.format("目标已设定：%s %.1f, %.1f", info and info.name or tostring(mapID), x * 100, y * 100))
end

SLASH_QUESTPATH1 = "/qp"
SlashCmdList["QUESTPATH"] = HandleSlash
QuestPath.HandleSlash = HandleSlash
