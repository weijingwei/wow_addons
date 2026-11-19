-- QuestPath v0.1 - 小地图、世界地图与屏幕箭头绘制
local QP = QuestPath

local LINE_TEXTURE = "Interface\\Buttons\\WHITE8X8"

-- 外观参数（亮金色虚线：深色描边托底，金色主线，外圈更亮的金色光晕）
local GLOW_COLOR = { 1.0, 0.72, 0.18 }
local MAIN_COLOR = { 1.0, 0.80, 0.30 }
local MAIN_ALPHA = 0.95
-- 主线下面垫一圈深色描边：土黄地图上金线本身对比度低，靠暗边把轮廓托出来
local OUTLINE_COLOR = { 0.10, 0.08, 0.06 }
local OUTLINE_ALPHA = 0.45
local OUTLINE_WIDTH_FACTOR = 1.35
-- 世界地图的柔光宽度倍数
local GLOW_WIDTH_FACTOR = 2.1
-- 小地图单独用更窄的柔光：连续两个周期之间的金边不至于连成双线
local MINIMAP_GLOW_WIDTH_FACTOR = 2.1
-- 光晕用加色混合（ADD）：只往上加亮，压在土黄地图上才看得见
local GLOW_BLEND_MODE = "ADD"
local WORLD_LINE_WIDTH = 2
-- 加色混合下光晕透明度要比普通混合高得多；实机过亮时下调这两个值
local WORLD_GLOW_ALPHA = 0.60
local MINIMAP_LINE_WIDTH = 1.6
local MINIMAP_GLOW_ALPHA = 0.38
-- 世界地图虚线周期（像素）：段长约 12.4、间隔约 9.6，保持 9:7
-- 线宽变细后不再由线宽推导（2 * 16/3 ≈ 10.7 会让段过短），改为独立常量
local WORLD_DASH_CYCLE = 22
-- 小地图虚线周期（像素）：26 时段长约 14.6、间隔约 11.4，仍保持 9:7；140px 的小地图上不至于太碎
local MINIMAP_DASH_CYCLE = 26
-- 虚线沿线路流动的速度（像素/秒）
local DASH_SPEED = 7

-- 屏幕箭头：游戏内置的小地图玩家箭头贴图（默认朝上，即屏幕北方向）
local ARROW_TEXTURE = "Interface\\Minimap\\MinimapArrow"
-- 贴图控件边长；SetRotation 会把图像缩到 1/√2（约 0.71 倍），实际视觉约 26–36px
-- 箭头贴图原始尺寸较小，56px 放大后发糊，36px 更接近 1:1
local ARROW_SIZE = 36
-- 箭头整体相对框体中心上移一点，给下方的距离文字留出空隙
local ARROW_OFFSET_Y = 6
local ARROW_COLOR = { 1, 0.82, 0.1, 0.8 }
-- 箭头背后垫一层同贴图的柔光：放大 1.35 倍、加色混合、低透明度
local ARROW_GLOW_SCALE = 1.35
local ARROW_GLOW_ALPHA = 0.22
-- 箭头贴图的像素吸附：暴雪开发者说明 texelSnappingBias（0-1）越大越倾向取单个纹素、
-- 越少混纹素，视觉上是"锐化"；配合 SetSnapToPixelGrid(true) 让边缘更实
-- 见 https://warcraft.wiki.gg/wiki/API:TextureBase_SetTexelSnappingBias
local ARROW_SNAP_TO_PIXEL_GRID = true
local ARROW_TEXEL_SNAPPING_BIAS = 0.5

local dashPools = {}
local dashSpecs = {}

local function AcquireLine(parent, pools)
	local pool = pools[parent]
	if not pool then
		pool = { textures = {}, used = 0 }
		pools[parent] = pool
	end
	pool.used = pool.used + 1
	local texture = pool.textures[pool.used]
	if not texture then
		texture = parent:CreateTexture(nil, "ARTWORK")
		texture:SetTexture(LINE_TEXTURE)
		texture:SetTexelSnappingBias(0)
		texture:SetSnapToPixelGrid(false)
		pool.textures[pool.used] = texture
	end
	return texture
end

-- 在 parent 上从 (startX, startY) 到 (endX, endY) 画一条直线
-- 坐标系：parent 的左下角为原点，X 向右，Y 向上（与 WoW UI 一致）
-- 做法：贴图尺寸设为「长 × 粗」、摆在线段中点，再按线段方向旋转整张贴图
-- color[5]（可选）是混合模式，不传时为普通混合（"BLEND"）
-- pools：纹理池（虚线动画传入 dashPools）
local function DrawLine(parent, startX, startY, endX, endY, thickness, color, layer, sublevel, pools)
	local texture = AcquireLine(parent, pools)
	texture:SetDrawLayer(layer or "ARTWORK", sublevel or 0)
	texture:SetVertexColor(color[1], color[2], color[3], color[4])
	texture:SetBlendMode(color[5] or "BLEND")

	local deltaX, deltaY = endX - startX, endY - startY
	local length = math.sqrt(deltaX * deltaX + deltaY * deltaY)
	if length == 0 then
		texture:Hide()
		return
	end

	texture:ClearAllPoints()
	texture:SetSize(length, thickness)
	texture:SetPoint("CENTER", parent, "BOTTOMLEFT", (startX + endX) / 2, (startY + endY) / 2)
	-- 贴图默认横放（长边指向 +X），SetRotation 正值在屏幕上是逆时针
	-- 旋转角 = 线段方向相对 +X 的逆时针夹角 = atan2(deltaY, deltaX)
	-- 若实机看到线段朝镜像方向偏，改成 -math.atan2(deltaY, deltaX)
	texture:SetRotation(math.atan2(deltaY, deltaX))
	texture:Show()
end

-- 记录 parent 上要绘制的流动虚线：cycle 决定切分（段长/间隔/相位），layers 是叠在一起的各层线条
-- 同一 parent 的所有层共用同一组虚线段，只在线宽、颜色、绘制层级上不同
local function SetDashLine(parent, startX, startY, endX, endY, cycle)
	local spec = {
		startX = startX,
		startY = startY,
		endX = endX,
		endY = endY,
		cycle = cycle,
		layers = {},
	}
	dashSpecs[parent] = spec
	return spec
end

-- 每层可指定混合模式（blendMode），光晕层用 ADD；color[5] 把混合模式一并交给 DrawLine
local function AddDashLayer(spec, thickness, color, layer, sublevel, blendMode)
	spec.layers[#spec.layers + 1] = {
		thickness = thickness,
		color = { color[1], color[2], color[3], color[4], blendMode or "BLEND" },
		layer = layer,
		sublevel = sublevel,
	}
end

local function HideDashTextures(parent)
	local pool = dashPools[parent]
	if not pool then
		return
	end
	for index = 1, pool.used do
		pool.textures[index]:Hide()
	end
	pool.used = 0
end

local function ClearDashSpec(parent)
	if dashSpecs[parent] then
		dashSpecs[parent] = nil
		HideDashTextures(parent)
	end
end

-- 按时间相位把虚线切成若干段重绘，每段依次画各层（光晕、描边、主线依次叠上去）
-- 各层用同一个 dashStart/dashEnd，因此各层逐段对齐、同相位、同流速
local function RenderDashes()
	local time = GetTime()
	for parent, spec in pairs(dashSpecs) do
		local pool = dashPools[parent]
		if not pool then
			pool = { textures = {}, used = 0 }
			dashPools[parent] = pool
		end
		local previousUsed = pool.used
		pool.used = 0

		local deltaX, deltaY = spec.endX - spec.startX, spec.endY - spec.startY
		local length = math.sqrt(deltaX * deltaX + deltaY * deltaY)
		local cycle = spec.cycle
		if length > 0.5 and cycle > 0 then
			local dashLength = cycle * 9 / 16
			local offset = (time * DASH_SPEED) % cycle
			local position = offset - cycle
			while position < length do
				local dashStart, dashEnd = position, position + dashLength
				if dashStart < 0 then
					dashStart = 0
				end
				if dashEnd > length then
					dashEnd = length
				end
				if dashEnd > dashStart then
					local startRatio, endRatio = dashStart / length, dashEnd / length
					local startX = spec.startX + deltaX * startRatio
					local startY = spec.startY + deltaY * startRatio
					local finishX = spec.startX + deltaX * endRatio
					local finishY = spec.startY + deltaY * endRatio
					local layers = spec.layers
					for layerIndex = 1, #layers do
						local layer = layers[layerIndex]
						DrawLine(
							parent, startX, startY, finishX, finishY,
							layer.thickness, layer.color, layer.layer, layer.sublevel, dashPools
						)
					end
				end
				position = position + cycle
			end
		end

		for index = pool.used + 1, previousUsed do
			pool.textures[index]:Hide()
		end
	end
end

local dashAnimator = CreateFrame("Frame", "QuestPathDashAnimator")
dashAnimator:SetScript("OnUpdate", function()
	if next(dashSpecs) == nil then
		return
	end
	RenderDashes()
end)

local minimapStatus
local minimapDistance

local function EnsureMinimapStatus()
	if minimapStatus then
		return minimapStatus
	end
	minimapStatus = Minimap:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	minimapStatus:SetPoint("BOTTOM", Minimap, "BOTTOM", 0, 10)
	minimapStatus:SetTextColor(1, 0.35, 0.35)
	minimapStatus:Hide()
	return minimapStatus
end

local function EnsureMinimapDistance()
	if minimapDistance then
		return minimapDistance
	end
	minimapDistance = Minimap:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	minimapDistance:SetTextColor(1, 0.9, 0.3)
	minimapDistance:Hide()
	return minimapDistance
end

-- ===== 官方黄色任务箭头同源判定 =====
-- 游戏自带的黄色任务箭头（SuperTrackedFrame）与我们的目标可能指向同一处，
-- 此时小地图上再画一条线就是重复信息，应当让位给官方箭头。
-- 不能只看 SuperTrackedFrame:IsShown()：透明度为 0 时它仍处于“显示”状态，
-- 必须同时确认导航目标状态、屏幕位置有效、最高优先级超级追踪类型是任务。
-- 所有 API 均做存在性判断：任一缺失时返回 false，保证线照常显示。
-- 返回值：(是否同源, 分项说明表)；分项说明表仅供 /qp debug 使用。
local function EvaluateOfficialArrow(ourQuestID)
	local details = {}
	local function Add(text)
		details[#details + 1] = text
	end

	if type(ourQuestID) ~= "number" then
		Add("我们的目标：没有数值型任务 ID（手动目标或未设定），不隐藏连线")
		return false, details
	end

	if type(C_Navigation) ~= "table" or type(C_Navigation.GetFrame) ~= "function" then
		Add("C_Navigation.GetFrame：不存在")
		return false, details
	end
	if C_Navigation.GetFrame() == nil then
		Add("官方箭头框体：不存在（当前没有任何导航目标）")
		return false, details
	end
	Add("官方箭头框体：存在")

	local navigationState = Enum and Enum.NavigationState
	if not navigationState then
		Add("Enum.NavigationState：不存在")
		return false, details
	end
	if type(C_Navigation.GetTargetState) ~= "function" then
		Add("C_Navigation.GetTargetState：不存在")
		return false, details
	end
	local state = C_Navigation.GetTargetState()
	local stateText = tostring(state)
	if type(state) == "number" then
		stateText = ({ "Invalid", "Occluded", "InRange", "Disabled" })[state + 1] or stateText
	end
	if state == nil or state == navigationState.Invalid or state == navigationState.Disabled then
		Add(string.format("导航目标状态：%s（官方箭头不显示）", stateText))
		return false, details
	end
	Add("导航目标状态：" .. stateText)

	if type(C_Navigation.HasValidScreenPosition) ~= "function" then
		Add("C_Navigation.HasValidScreenPosition：不存在（跳过该项）")
	elseif not C_Navigation.HasValidScreenPosition() then
		Add("屏幕位置有效：否（官方箭头不显示）")
		return false, details
	else
		Add("屏幕位置有效：是")
	end

	local trackingType = Enum and Enum.SuperTrackingType
	if not trackingType then
		Add("Enum.SuperTrackingType：不存在")
		return false, details
	end
	if type(C_SuperTrack) ~= "table"
		or type(C_SuperTrack.GetHighestPrioritySuperTrackingType) ~= "function" then
		Add("C_SuperTrack.GetHighestPrioritySuperTrackingType：不存在")
		return false, details
	end
	local highestType = C_SuperTrack.GetHighestPrioritySuperTrackingType()
	if highestType ~= trackingType.Quest then
		local typeText = tostring(highestType)
		if type(highestType) == "number" then
			typeText = ({ "Quest", "UserWaypoint", "Corpse", "Scenario",
				"Content", "PartyMember", "MapPin", "Vignette" })[highestType + 1] or typeText
		end
		Add(string.format("最高优先级超级追踪类型：%s（不是任务）", typeText))
		return false, details
	end
	Add("最高优先级超级追踪类型：任务")

	if type(C_SuperTrack.GetSuperTrackedQuestID) ~= "function" then
		Add("C_SuperTrack.GetSuperTrackedQuestID：不存在")
		return false, details
	end
	local trackedQuestID = C_SuperTrack.GetSuperTrackedQuestID()
	local same = trackedQuestID == ourQuestID
	Add(string.format("超级追踪任务 ID：%s；我们的任务 ID：%d；%s",
		tostring(trackedQuestID), ourQuestID, same and "同源" or "不同"))
	return same, details
end

-- 小地图绘制用：官方箭头此刻是否正指向我们的目标
function QP.OfficialArrowShowsOurTarget(questID)
	local same = EvaluateOfficialArrow(questID)
	return same
end

-- /qp debug 用：返回判定结论与每个分项的说明
function QP.DescribeOfficialArrow(questID)
	local same, details = EvaluateOfficialArrow(questID)
	local lines = { "官方箭头同源判定：" .. (same and "是" or "否") }
	for index = 1, #details do
		lines[#lines + 1] = "  · " .. details[index]
	end
	return lines
end

function QP.UpdateMinimap()
	local distanceText = EnsureMinimapDistance()
	distanceText:Hide()
	local status = EnsureMinimapStatus()
	if not QP.target then
		ClearDashSpec(Minimap)
		status:Hide()
		return
	end

	local distance, bearingOrError = QP.GetRouteRelative()
	if not distance then
		ClearDashSpec(Minimap)
		status:SetText(bearingOrError or "当前地图不支持")
		status:Show()
		return
	end
	status:Hide()

	-- 官方黄色任务箭头已在显示同一目标时，小地图不再重复画线（只影响小地图）
	if QP.OfficialArrowShowsOurTarget(QP.target.questID) then
		ClearDashSpec(Minimap)
		return
	end

	local bearing = bearingOrError
	local facing = 0
	if GetCVar("rotateMinimap") == "1" then
		facing = GetPlayerFacing() or 0
	end
	local screenAngle = bearing - facing
	local directionX = -math.sin(screenAngle)
	local directionY = math.cos(screenAngle)

	local width, height = Minimap:GetWidth(), Minimap:GetHeight()
	local radius = math.min(width, height) / 2 - 2
	local viewRadius = C_Minimap.GetViewRadius()
	if not viewRadius or viewRadius <= 0 or radius <= 0 then
		ClearDashSpec(Minimap)
		return
	end

	local pixelDistance = distance / viewRadius * radius
	local clamped = false
	if pixelDistance > radius then
		pixelDistance = radius
		clamped = true
	end

	local startX, startY = width / 2, height / 2
	local endX = startX + directionX * pixelDistance
	local endY = startY + directionY * pixelDistance
	-- 三层共用同一组虚线段（同相位同流速）：光晕 → 描边 → 主线，由宽到窄依次叠上去
	local spec = SetDashLine(Minimap, startX, startY, endX, endY, MINIMAP_DASH_CYCLE)
	AddDashLayer(spec, MINIMAP_LINE_WIDTH * MINIMAP_GLOW_WIDTH_FACTOR,
		{ GLOW_COLOR[1], GLOW_COLOR[2], GLOW_COLOR[3], MINIMAP_GLOW_ALPHA }, "ARTWORK", 0, GLOW_BLEND_MODE)
	-- 描边层：比主线略宽、普通混合，用深色把金线从土黄地图上"抠"出来
	AddDashLayer(spec, MINIMAP_LINE_WIDTH * OUTLINE_WIDTH_FACTOR,
		{ OUTLINE_COLOR[1], OUTLINE_COLOR[2], OUTLINE_COLOR[3], OUTLINE_ALPHA }, "ARTWORK", 1)
	AddDashLayer(spec, MINIMAP_LINE_WIDTH,
		{ MAIN_COLOR[1], MAIN_COLOR[2], MAIN_COLOR[3], MAIN_ALPHA }, "ARTWORK", 2)

	if clamped then
		distanceText:ClearAllPoints()
		distanceText:SetPoint("BOTTOMLEFT", Minimap, "BOTTOMLEFT", endX + 2, endY + 2)
		distanceText:SetText(string.format("%.0f 码", distance))
		distanceText:Show()
	end
end

local worldOverlay
local worldStatus

-- 取一个框体的 canvas；框体不支持 GetCanvas 时返回 nil
local function GetCanvasIfAvailable(frame)
	if not frame or type(frame.GetCanvas) ~= "function" then
		return nil
	end
	return frame:GetCanvas()
end

-- 框体是否真的在地图上显示：已显示且 canvas 有实际宽高
local function IsFrameDisplayable(frame, canvas)
	if not frame or not canvas or not frame:IsShown() then
		return false
	end
	local width, height = canvas:GetWidth(), canvas:GetHeight()
	return width and width > 1 and height and height > 1
end

-- 解析当前用来画世界地图的框体，返回 (框体, canvas)
-- 不同客户端版本里世界地图可能挂在 QuestMapFrame 或 WorldMapFrame 上：
-- 依次尝试 QuestMapFrame → WorldMapFrame，要求框体存在、带 GetCanvas、canvas 非空且宽高大于 1、框体处于显示状态；
-- 两个都不可用时退回第一个「存在且有 canvas」的框（正式服就是 WorldMapFrame），由调用方按未显示处理。
-- 正式服 QuestMapFrame 是任务日志侧栏（mixin QuestLogMixin，没有 GetCanvas），会自动落到 WorldMapFrame
local function GetActiveMapFrame()
	local questCanvas = GetCanvasIfAvailable(QuestMapFrame)
	if questCanvas and IsFrameDisplayable(QuestMapFrame, questCanvas) then
		return QuestMapFrame, questCanvas
	end
	local worldCanvas = GetCanvasIfAvailable(WorldMapFrame)
	if worldCanvas and IsFrameDisplayable(WorldMapFrame, worldCanvas) then
		return WorldMapFrame, worldCanvas
	end
	if questCanvas then
		return QuestMapFrame, questCanvas
	end
	if worldCanvas then
		return WorldMapFrame, worldCanvas
	end
	return nil
end

QP.GetActiveMapFrame = GetActiveMapFrame

-- 诊断输出用：把地图框转成可读名字
local function MapFrameName(frame)
	if not frame then
		return "无"
	end
	if frame == QuestMapFrame then
		return "QuestMapFrame"
	end
	if frame == WorldMapFrame then
		return "WorldMapFrame"
	end
	local name = frame:GetName()
	if name and name ~= "" then
		return name
	end
	return "未知框体"
end

-- 拆除旧的绘制层：先清掉虚线记录，再清纹理池（池里的贴图都是旧父级的子控件），最后隐藏旧框
local function DestroyWorldOverlay()
	local overlay = worldOverlay
	if not overlay then
		return
	end
	ClearDashSpec(overlay)
	dashPools[overlay] = nil
	overlay:Hide()
	worldOverlay = nil
	worldStatus = nil
end

-- 每次调用都确认绘制层挂在当前 canvas 上
-- 关闭再打开世界地图时游戏可能重建 canvas，旧绘制层会随旧画布一起失效，必须重建
-- 返回值：(overlay, 地图框, canvas)；没有可用地图框时返回 nil
local function EnsureWorldOverlay()
	local mapFrame, canvas = GetActiveMapFrame()
	if not mapFrame or not canvas then
		return nil
	end
	if worldOverlay and worldOverlay:GetParent() == canvas then
		return worldOverlay, mapFrame, canvas
	end
	DestroyWorldOverlay()
	worldOverlay = CreateFrame("Frame", nil, canvas)
	worldOverlay:SetAllPoints(canvas)
	worldOverlay:SetFrameLevel(canvas:GetFrameLevel() + 1)
	worldStatus = worldOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	worldStatus:SetPoint("CENTER", worldOverlay, "CENTER", 0, 0)
	worldStatus:SetTextColor(1, 0.35, 0.35)
	worldStatus:Hide()
	return worldOverlay, mapFrame, canvas
end

function QP.UpdateWorldMap()
	local overlay, mapFrame, canvas = EnsureWorldOverlay()
	if not overlay then
		return
	end
	if not mapFrame:IsShown() or not QP.target then
		ClearDashSpec(overlay)
		if worldStatus then
			worldStatus:Hide()
		end
		return
	end

	local width, height = canvas:GetWidth(), canvas:GetHeight()
	if not width or width <= 1 or not height or height <= 1 then
		ClearDashSpec(overlay)
		return
	end

	local displayMapID
	if type(mapFrame.GetMapID) == "function" then
		displayMapID = mapFrame:GetMapID()
	end
	local playerX, playerY, targetX, targetY, errorMessage = QP.GetRoutePositionsOnMap(displayMapID)
	if not playerX then
		ClearDashSpec(overlay)
		if worldStatus then
			worldStatus:SetText(errorMessage or "目标不在当前地图")
			worldStatus:Show()
		end
		return
	end
	if worldStatus then
		worldStatus:Hide()
	end
	local startX, startY = playerX * width, (1 - playerY) * height
	local endX, endY = targetX * width, (1 - targetY) * height
	-- 三层共用同一组虚线段（同相位同流速）：光晕 → 描边 → 主线，由宽到窄依次叠上去
	local spec = SetDashLine(overlay, startX, startY, endX, endY, WORLD_DASH_CYCLE)
	AddDashLayer(spec, WORLD_LINE_WIDTH * GLOW_WIDTH_FACTOR,
		{ GLOW_COLOR[1], GLOW_COLOR[2], GLOW_COLOR[3], WORLD_GLOW_ALPHA }, "OVERLAY", 0, GLOW_BLEND_MODE)
	-- 描边层：比主线略宽、普通混合，用深色把金线从土黄地图上"抠"出来
	AddDashLayer(spec, WORLD_LINE_WIDTH * OUTLINE_WIDTH_FACTOR,
		{ OUTLINE_COLOR[1], OUTLINE_COLOR[2], OUTLINE_COLOR[3], OUTLINE_ALPHA }, "OVERLAY", 1)
	AddDashLayer(spec, WORLD_LINE_WIDTH,
		{ MAIN_COLOR[1], MAIN_COLOR[2], MAIN_COLOR[3], MAIN_ALPHA }, "OVERLAY", 2)
end

-- 世界地图绘制层诊断：把 /qp debug 需要观察的状态拼成若干行文本
-- 世界地图从未打开、canvas 被重建、overlay 尚未创建时都要能安全调用：
-- 每一步先判空；overlay 可能随旧画布一起被销毁，读取它的成员时用 pcall 兜底
function QP.DescribeWorldOverlay()
	local lines = {}
	local function Add(text)
		lines[#lines + 1] = text
	end

	-- 框体名可能为 nil（匿名框），统一转成可读文字
	local function ParentName(parent)
		if not parent then
			return "无父级"
		end
		local name = parent:GetName()
		if not name or name == "" then
			return "(无名字)"
		end
		return name
	end

	-- 0：当前解析出的地图框（QuestMapFrame 优先，回退 WorldMapFrame）
	local mapFrame, canvas = GetActiveMapFrame()
	Add("世界地图 使用的框：" .. MapFrameName(mapFrame))

	-- 1、2：世界地图主框是否存在、是否显示
	local worldMap = WorldMapFrame
	Add("世界地图 WorldMapFrame：" .. (worldMap and "存在" or "不存在"))
	if mapFrame then
		Add("世界地图 IsShown：" .. tostring(mapFrame:IsShown()))
	else
		Add("世界地图 IsShown：不可用（没有可用的地图框）")
	end

	-- 3：世界地图 canvas 的尺寸、层级、缩放与父级
	if not canvas then
		Add("世界地图 canvas：不存在")
	else
		Add(string.format("世界地图 canvas：%.0f × %.0f，frameLevel %d，scale %.3f，parent %s",
			canvas:GetWidth(), canvas:GetHeight(), canvas:GetFrameLevel(), canvas:GetScale(),
			ParentName(canvas:GetParent())))
	end

	-- 4：绘制层本身的状态；旧画布销毁后 overlay 引用可能失效，整段用 pcall 兜底
	local overlay = worldOverlay
	if not overlay then
		Add("世界地图 overlay：不存在（尚未创建）")
	else
		local ok, err = pcall(function()
			local parent = overlay:GetParent()
			local parentMatches
			if not canvas then
				parentMatches = "canvas 不可用"
			elseif parent == canvas then
				parentMatches = "等于 canvas"
			else
				parentMatches = "不等于 canvas"
			end
			Add(string.format("世界地图 overlay：parent %s（%s），IsShown=%s，尺寸 %.0f × %.0f，frameLevel %d",
				ParentName(parent), parentMatches, tostring(overlay:IsShown()),
				overlay:GetWidth(), overlay:GetHeight(), overlay:GetFrameLevel()))
		end)
		if not ok then
			Add("世界地图 overlay：读取失败（" .. tostring(err) .. "）")
		end
	end

	-- 5：这条世界地图虚线有没有被登记要画
	local spec = overlay and dashSpecs[overlay]
	if spec then
		Add(string.format("dashSpecs[overlay]：已登记，cycle %.0f，线段 (%.1f, %.1f) → (%.1f, %.1f)",
			spec.cycle, spec.startX, spec.startY, spec.endX, spec.endY))
	else
		Add("dashSpecs[overlay]：未登记（世界地图这条虚线不会被画出）")
	end

	-- 6：纹理池与本次实际画出的纹理数
	local pool = overlay and dashPools[overlay]
	if pool then
		Add(string.format("dashPools[overlay]：存在，used=%d（本次画出的纹理数），池中共 %d 条",
			pool.used or 0, #(pool.textures or {})))
	else
		Add("dashPools[overlay]：不存在")
	end

	-- 7：当前目标与到达状态
	local target = QP.target
	if target then
		Add(string.format("QP.target：存在，uiMapID=%s；arrived=%s",
			tostring(target.uiMapID), tostring(QP.arrived)))
	else
		Add("QP.target：不存在；arrived=" .. tostring(QP.arrived))
	end

	-- 8：世界地图上玩家与目标的归一化坐标（绘制实际使用的两个点）
	local displayMapID
	if mapFrame and type(mapFrame.GetMapID) == "function" then
		displayMapID = mapFrame:GetMapID()
	end
	if not displayMapID then
		Add("GetRoutePositionsOnMap：地图不可用（世界地图未显示，或 GetMapID 返回 nil）")
	else
		local playerX, playerY, targetX, targetY, errorMessage = QP.GetRoutePositionsOnMap(displayMapID)
		if playerX then
			Add(string.format("GetRoutePositionsOnMap(%s)：玩家 %.4f, %.4f；目标 %.4f, %.4f",
				tostring(displayMapID), playerX, playerY, targetX, targetY))
		else
			Add(string.format("GetRoutePositionsOnMap(%s)：失败（%s）",
				tostring(displayMapID), tostring(errorMessage)))
		end
	end

	return lines
end

local arrowFrame

local function EnsureArrowFrame()
	if arrowFrame then
		return arrowFrame
	end
	arrowFrame = CreateFrame("Frame", "QuestPathArrowFrame", UIParent)
	arrowFrame:SetSize(90, 106)
	arrowFrame:SetPoint("CENTER", UIParent, "CENTER", 0, -110)
	arrowFrame:SetFrameStrata("MEDIUM")

	-- 贴图默认朝上（屏幕北方向）。SetRotation 正值在屏幕上是逆时针，
	-- 与下面 relativeAngle 的约定一致，所以角度直接传 relativeAngle
	-- 柔光层：同一张箭头贴图放大后垫在下面，加色混合让深色草地上也能看清
	arrowFrame.glow = arrowFrame:CreateTexture(nil, "ARTWORK")
	arrowFrame.glow:SetTexture(ARROW_TEXTURE)
	arrowFrame.glow:SetTexelSnappingBias(ARROW_TEXEL_SNAPPING_BIAS)
	arrowFrame.glow:SetSnapToPixelGrid(ARROW_SNAP_TO_PIXEL_GRID)
	arrowFrame.glow:SetSize(ARROW_SIZE * ARROW_GLOW_SCALE, ARROW_SIZE * ARROW_GLOW_SCALE)
	arrowFrame.glow:SetPoint("CENTER", arrowFrame, "CENTER", 0, ARROW_OFFSET_Y)
	arrowFrame.glow:SetDrawLayer("ARTWORK", 0)
	arrowFrame.glow:SetBlendMode(GLOW_BLEND_MODE)
	arrowFrame.glow:SetVertexColor(GLOW_COLOR[1], GLOW_COLOR[2], GLOW_COLOR[3], ARROW_GLOW_ALPHA)

	arrowFrame.arrow = arrowFrame:CreateTexture(nil, "ARTWORK")
	arrowFrame.arrow:SetTexture(ARROW_TEXTURE)
	arrowFrame.arrow:SetTexelSnappingBias(ARROW_TEXEL_SNAPPING_BIAS)
	arrowFrame.arrow:SetSnapToPixelGrid(ARROW_SNAP_TO_PIXEL_GRID)
	arrowFrame.arrow:SetSize(ARROW_SIZE, ARROW_SIZE)
	arrowFrame.arrow:SetPoint("CENTER", arrowFrame, "CENTER", 0, ARROW_OFFSET_Y)
	arrowFrame.arrow:SetDrawLayer("ARTWORK", 1)
	arrowFrame.arrow:SetVertexColor(ARROW_COLOR[1], ARROW_COLOR[2], ARROW_COLOR[3], ARROW_COLOR[4])

	arrowFrame.text = arrowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	arrowFrame.text:SetPoint("CENTER", arrowFrame, "CENTER", 0, -34)
	arrowFrame.text:SetTextColor(1, 0.9, 0.4)
	return arrowFrame
end

function QP.UpdateArrow()
	local frame = EnsureArrowFrame()
	if not QP.arrowEnabled or not QP.target then
		frame:Hide()
		return
	end

	local distance, bearingOrError = QP.GetRouteRelative()
	if not distance then
		frame.arrow:Hide()
		frame.glow:Hide()
		frame.text:SetText(bearingOrError or "当前地图不支持")
		frame:Show()
		return
	end
	local facing = GetPlayerFacing()
	if not facing then
		frame.arrow:Hide()
		frame.glow:Hide()
		frame.text:SetText("当前地图不支持")
		frame:Show()
		return
	end

	-- relativeAngle 为正表示目标在玩家朝向的逆时针一侧，与 SetRotation 的正方向一致
	local relativeAngle = bearingOrError - facing
	frame.arrow:SetRotation(relativeAngle)
	frame.glow:SetRotation(relativeAngle)
	frame.arrow:Show()
	frame.glow:Show()

	frame.text:SetText(string.format("%.0f 码", distance))
	frame:Show()
end

-- 到达目标附近时隐藏全部线路、状态文字与屏幕箭头
function QP.HideAllOverlays()
	ClearDashSpec(Minimap)
	if minimapStatus then
		minimapStatus:Hide()
	end
	if minimapDistance then
		minimapDistance:Hide()
	end
	if worldOverlay then
		ClearDashSpec(worldOverlay)
	end
	if worldStatus then
		worldStatus:Hide()
	end
	if arrowFrame then
		arrowFrame:Hide()
	end
end

function QP.RefreshAll()
	-- 已到达目标附近：不再计算线路，只保证全部叠加层隐藏
	if QP.arrived then
		QP.HideAllOverlays()
		return
	end
	QP.UpdateMinimap()
	QP.UpdateArrow()
	QP.UpdateWorldMap()
end
