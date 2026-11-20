# CLAUDE.md

本文件为 Claude Code 在本目录工作时的指引。

## 项目概述

本目录是《魔兽世界》正式服插件 **wjw_工具箱** 的开发目录，由两个插件合并而成：

- 任务寻路（原 QuestPath）：选中/追踪任务后，在小地图、屏幕和世界地图上画出从玩家到任务目的地的连线。
- 自动卖垃圾（原 WuXianAutoSell）：打开商人界面时，自动卖出背包中的灰色（品质 0）物品，支持永不卖出名单。

## 仓库与部署

| 项 | 值 |
|---|---|
| 插件目录 | `wjw_Toolkit/` |
| 游戏内名称 | wjw_工具箱 |
| 远程仓库 | https://github.com/weijingwei/wow_addons |
| 部署 | `_forever_\Interface\AddOns\wjw_Toolkit`（Junction → `D:\claudeProjects\wow\wjw_Toolkit`） |
| 旧版源码 | `legacy/QuestPath`、`legacy/WuXianAutoSell`（仅回退用，不发布） |

## 本机环境（实测）

| 项 | 值 |
|---|---|
| 游戏安装目录 | `D:\Program Files (x86)\World of Warcraft` |
| 客户端 | `_forever_`，版本 `1.60.1.70938`，分支 `cn`（网易国服，**正式服 Retail**） |
| Interface 号 | **16001**（游戏内 `/dump select(4, GetBuildInfo())` 实测） |
| 插件安装目录 | `_forever_\Interface\AddOns\` |
| 存档 | `_forever_\WTF\Account\<账号>\SavedVariables\` 下的 `QuestPath.lua`、`WuXianAutoSell.lua` 与 `wjwCraftDB.lua` |
| 本机 Lua 工具链 | **未装** `lua`/`luacheck`（用户要求非必要不安装）；有 `node`/`npm`、`git` |

## 插件结构

| 文件 | 职责 |
|---|---|
| `PathCore.lua` | 寻路：斜杠命令、目标状态、任务点解析、自动追踪、存档 |
| `PathMap.lua` | 寻路：坐标换算（地图归一化 ↔ 世界坐标、距离、方位角） |
| `PathOverlay.lua` | 寻路：绘制小地图/世界地图虚线、屏幕箭头 |
| `PathMain.lua` | 寻路：事件注册、0.1 秒刷新节流、自动追踪轮询 |
| `SellCore.lua` | 卖垃圾：商人事件、背包扫描、出售流程、`/wjw sell` 命令、存档 |
| `SellOptions.lua` | 卖垃圾：设置面板（永不卖出名单） |
| `Options.lua` | 寻路设置页（自动跟随 / 屏幕箭头 / 静默模式三个开关） |
| `CraftTrainerData.lua` | 专业技能：训练师坐标数据（来源 QuestieDB） |
| `CraftCore.lua` | 专业技能：专业与配方数据读取、升级路径算法、输出格式化 |
| `CraftCommand.lua` | 专业技能：`/wjw craft` 命令与聊天输出、存档初始化 |
| `CraftAutoSelect.lua` | 专业技能：打开专业窗口时自动选中推荐配方 |
| `CraftOptions.lua` | 专业技能：设置页（专业与等级、目标等级、跳过名单、开关） |
| `CraftPanel.lua` | 专业技能：制作队列浮动面板 |
| `CraftHighlight.lua` | 专业技能：配方列表行内推荐高亮（实验性） |
| `wjw_Toolkit.toc` | Interface 16001、SavedVariables: QuestPathDB, WuXianAutoSellDB, wjwCraftDB、加载顺序 |

## 命令

一级入口统一为 `/wjw`：`/wjw qp <参数>` 与 `/wjw sell <参数>`；**旧的 `/qp`、`/xsell` 已移除**。

短写别名：`s` = `sell`、`c` = `craft`、`t` = `trainer`（即 `/wjw s ...` 等同 `/wjw sell ...`、`/wjw c t ...` 等同 `/wjw craft trainer ...`），长短写法等价。

寻路（`/wjw qp ...`）：

| 命令 | 说明 |
|---|---|
| `/wjw qp` | 查看当前目标与距离 |
| `/wjw qp <x> <y>` | 按地图百分比设定目标（0–1 小数或 0–100 百分数） |
| `/wjw qp quest` | 用当前选中/追踪的任务设定目标 |
| `/wjw qp clear` | 清除目标 |
| `/wjw qp auto on\|off` | 自动跟随追踪/选中任务（默认开启） |
| `/wjw qp arrow on\|off` | 屏幕箭头开关 |
| `/wjw qp quiet on\|off` | 静默模式（自动过程提示不再刷屏） |
| `/wjw qp debug` | 打印目标解析链路、坐标、绘制层状态（排障首选） |

自动卖垃圾（`/wjw sell ...`）：

| 命令 | 说明 |
|---|---|
| `/wjw sell` | 开 / 关自动卖出（等同于 toggle） |
| `/wjw sell on \| off \| toggle` | 开启 / 关闭 / 切换自动卖出 |
| `/wjw sell status` | 查看开关状态与名单数量 |
| `/wjw sell add` | 把鼠标指向（或拾起到光标）的物品加入永不卖出名单 |
| `/wjw sell remove [ID或名字]` | 从名单移除，不填参数则取光标上的物品 |
| `/wjw sell list` | 查看永不卖出名单 |
| `/wjw sell clear` | 清空永不卖出名单 |
| `/wjw sell config` | 打开设置面板 |
| `/wjw sell help` | 显示卖垃圾帮助 |

专业技能（`/wjw craft ...`）：

| 命令 | 说明 |
|---|---|
| `/wjw craft` | 规划当前打开（或上次使用）的专业，到现有配方断点为止 |
| `/wjw craft <目标等级>` | 规划到指定等级 |
| `/wjw craft <专业名> [目标等级]` | 指定专业（和目标）后规划 |
| `/wjw craft skip <材料名>` | 把材料加入跳过名单（规划时排除） |
| `/wjw craft skiprecipe <配方名>` | 把配方加入跳过名单 |
| `/wjw craft unskip <名称>` | 从两个跳过名单中移除 |
| `/wjw craft list` | 查看两个跳过名单 |
| `/wjw craft reset` | 清空跳过名单与目标等级 |
| `/wjw craft trainer [类型] [all]` | 查询训练师位置（无参时只显示当前地图上距离最近的一个：专业窗口打开时查该专业，关闭时查本职业；指定类型时列出当前地图该类型全部并按距离排序；`all` 列出全部地图。当前地图查不到时给出同大陆直线距离最近的一个） |
| `/wjw craft help` | 显示专业技能帮助 |

总帮助：

| 命令 | 说明 |
|---|---|
| `/wjw` | 列出全部命令与设置页位置 |

## 设置页

游戏「选项 → 插件」下有三个分类：`wjw_工具箱 · 任务寻路`、`wjw_工具箱 · 自动卖垃圾`、`wjw_工具箱 · 专业技能`。

## 关键技术事实（已核实，勿再重复验证）

寻路部分：

- 插件拿不到地形/寻路数据：`C_Navigation` 只提供单点路点，没有路径序列；`C_TaskQuest` / `C_QuestLog` 只给静态 POI。
- 插件没有网络、文件、进程能力：游戏内实测 `type(io/os/require/dofile/loadfile)` 全为 `nil`。
- 世界地图框：该版本仍是 `WorldMapFrame`；`QuestMapFrame` 只是任务日志侧栏，没有 canvas。
- 坐标轴：世界坐标 **X 轴为南北（北为正）、Y 轴为东西（西为正）**。
- `Texture:SetRotation` 正值在屏幕上为逆时针。
- 绘制必须挂在 `WorldMapFrame:GetCanvas()` 上，且每次核对父级（地图关闭再打开时画布可能被重建）。

卖垃圾部分：

- `C_Container.GetContainerNumSlots` / `GetContainerItemInfo` / `GetContainerItemLink` / `UseContainerItem` 在正式服均存在；`GetContainerItemInfo` 返回字段含 `iconFileID`、`stackCount`、`quality`、`itemID`、`hyperlink`、`isLocked`、`hasNoValue`。
- `C_Container.UseContainerItem` 没有返回值；商人界面打开时调用即为出售。不能用 pcall 成功来判断已卖出。
- `C_Cursor.GetCursorItem` 返回 ItemLocation 表，不是 itemID，禁止当数字使用；取光标物品用 `GetCursorInfo()`（返回 type, id, link）。
- `GetMouseFocus` 在 11.0.0 已移除（由 `GetMouseFoci` 取代）。
- 旧全局 `GetContainerItemInfo` / `GetContainerNumSlots` / `GetContainerItemLink` / `UseContainerItem` 在正式服已移除（代码中的回退分支是死代码，保留无害）。
- `Settings.OpenToCategory` 只接受数字分类 ID；不要手工覆盖 Settings 分类对象的 ID 字段。
- 背包容器索引 0–4 是背包与已装备背包，索引 5 是材料包（当前不扫描）。

专业技能部分：

- `C_TradeSkillUI.GetAllRecipeIDs` 返回当前专业**全部**配方（含未学），前提是该专业窗口打开过一次。
- `C_TradeSkillUI.GetRecipeInfo` 提供 `canSkillUp / numSkillUps / maxTrivialLevel / relativeDifficulty`，但没有橙/黄/绿分界。
- `C_TradeSkillUI.GetRecipeSchematic(recipeID, false)` 的 `reagentSlotSchematics[].reagents` 是每个槽位的**备选**材料列表，插件按每槽第一项估算。
- `C_AreaPoiInfo.GetAreaPOIForMap` 在本客户端实测返回空表（训练师位置无法从游戏 API 获取），训练师坐标来自 QuestieDB 内置数据。
- 官方没有训练师列表/位置 API；`C_Trainer` 只有 3 个界面函数。
- `C_TradeSkillUI.OpenRecipe(recipeID)` 可打开并选中配方。
- 专业界面为 `Blizzard_Professions`，主框架 `ProfessionsFrame`，配方行由 ScrollBox 池化复用，行绑定入口是 `ProfessionsRecipeListRecipeMixin.Init`（行内高亮依赖此内部结构，有版本风险）。

## 已知限制

- 寻路连线是直线，不是寻路；只有游戏给出路点时才会分段指向。
- 部分任务游戏不提供 POI，此时显示“读不到目标点”，不会乱画。
- 到达判定：距最终目标 ≤ 15 码时隐藏全部绘制。
- 官方黄箭头显示同一任务时，自动隐藏小地图连线（屏幕箭头保留）。
- 自动卖垃圾只处理品质 0 物品，永不卖出名单内的物品会被跳过；商人不收购或被锁定的物品会跳过并提示。
- 自动卖垃圾的“获得金币”按会话前后钱数差值计算，期间修理/手动买卖会影响该数字。
- 专业技能涨点概率与难度分界为社区经验估算（橙 100% / 黄 60% / 绿 25%），非官方数据。
- 专业技能只规划**已学**配方；到现有配方断点为止，后续需找训练师学习新配方。
- 训练师数据（QuestieDB）不含珠宝加工、铭文、考古学。
- 地图训练师标记的类型判定顺序：专业窗口可见时的专业 → 显式指定过的类型 → 上次规划的专业；都取不到时不显示标记（不再猜测）。
- 配方行内高亮为实验性功能，依赖暴雪界面内部结构，游戏大版本更新后可能失效，可在设置页关闭。

## 开发约定

- 改完 `/reload` 生效；新增插件才需要退回角色选择界面重新扫描。
- 本机没有 Lua 解释器，交付前必须做静态自检：`end` 配对、UTF-8 无 BOM、API 存在性核对。
- 新用到的 API 必须先在 `warcraft.wiki.gg` 或 Gethe/wow-ui-source（`forever` 分支）核实。
- 排障三步：`/console scriptErrors 1` → `/reload` → `/wjw qp debug`。
- git 提交不得添加 Co-Authored-By 签名。
- `legacy/` 内文件不得修改，除非要做回退。
