-- QuestPath v0.3 - 事件注册与节流刷新
local ADDON_NAME = ...
local QP = QuestPath

local initialized = false

-- 初始化：ADDON_LOADED 触发时存档变量已加载完毕，这里才允许读 QuestPathDB
-- 新装用户首次登录时 QuestPathDB 为 nil，建空表后各项取 Core.lua 里的默认值
local function Initialize()
	if initialized then
		return
	end
	initialized = true
	QuestPathDB = QuestPathDB or {}
	QP.LoadSettings()
end

local eventFrame = CreateFrame("Frame", "QuestPathEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("CVAR_UPDATE")
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("QUEST_WATCH_UPDATE")
eventFrame:RegisterEvent("QUEST_TURNED_IN")
eventFrame:RegisterEvent("QUEST_REMOVED")
eventFrame:RegisterEvent("SUPER_TRACKING_PATH_UPDATED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		local addonName = ...
		if addonName == ADDON_NAME then
			Initialize()
		end
		return
	end
	if event == "PLAYER_ENTERING_WORLD" then
		-- 兜底：正常情况下 ADDON_LOADED 已先完成初始化
		Initialize()
		-- 登录/读条结束后立刻按当前追踪任务设定目标，不必等 2 秒的自动检查周期
		QP.AutoTick()
	end
	-- 初始化完成前不做任何刷新，避免拿默认值覆盖存档
	if not initialized then
		return
	end
	if event == "CVAR_UPDATE" then
		local cvarName = ...
		if cvarName ~= "rotateMinimap" and cvarName ~= "ROTATE_MINIMAP" then
			return
		end
	elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_WATCH_UPDATE" or event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED" then
		-- 任务日志变化、目标进度更新、任务交付、任务移除时立即检查一次；
		-- 自动追踪关闭时 AutoTick 直接返回，无副作用
		QP.AutoTick()
		return
	elseif event == "SUPER_TRACKING_PATH_UPDATED" then
		-- 游戏更新导航路径时立刻重取本段路点并重画，不必等 0.5 秒节流
		QP.UpdateRouteWaypoint()
		QP.RefreshAll()
		return
	end
	QP.RefreshAll()
end)

local REFRESH_INTERVAL = 0.1
local AUTO_CHECK_INTERVAL = 2
local elapsed = 0
local autoElapsed = 0
local ARRIVAL_CHECK_INTERVAL = 0.5
local arrivalElapsed = 0

local ticker = CreateFrame("Frame", "QuestPathTicker")
ticker:SetScript("OnUpdate", function(_, delta)
	if not initialized then
		return
	end
	if QP.autoTrack then
		autoElapsed = autoElapsed + delta
		if autoElapsed >= AUTO_CHECK_INTERVAL then
			autoElapsed = autoElapsed - AUTO_CHECK_INTERVAL
			QP.AutoTick()
		end
	else
		autoElapsed = 0
	end

	arrivalElapsed = arrivalElapsed + delta
	if arrivalElapsed >= ARRIVAL_CHECK_INTERVAL then
		arrivalElapsed = 0
		QP.UpdateRouteWaypoint()
		QP.UpdateArrival()
	end

	elapsed = elapsed + delta
	if elapsed < REFRESH_INTERVAL then
		return
	end
	elapsed = 0
	-- 兜底：超级追踪或任务日志点选不保证触发事件，每 0.1 秒比对一次当前任务
	if QP.autoTrack and QP.GetAutoQuestID() ~= QP.autoLastCheckedID then
		QP.AutoTick()
	end
	QP.RefreshAll()
end)
