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
| 存档 | `_forever_\WTF\Account\<账号>\SavedVariables\` 下的 `QuestPath.lua` 与 `WuXianAutoSell.lua` |
| 本机 Lua 工具链 | **未装** `lua`/`luacheck`（用户要求非必要不安装）；有 `node`/`npm`、`git` |

## 插件结构

| 文件 | 职责 |
|---|---|
| `PathCore.lua` | 寻路：斜杠命令、目标状态、任务点解析、自动追踪、存档 |
| `PathMap.lua` | 寻路：坐标换算（地图归一化 ↔ 世界坐标、距离、方位角） |
| `PathOverlay.lua` | 寻路：绘制小地图/世界地图虚线、屏幕箭头 |
| `PathMain.lua` | 寻路：事件注册、0.1 秒刷新节流、自动追踪轮询 |
| `SellCore.lua` | 卖垃圾：商人事件、背包扫描、出售流程、`/xsell` 与 `/wjw` 命令、存档 |
| `SellOptions.lua` | 卖垃圾：设置面板（永不卖出名单） |
| `Options.lua` | 寻路设置页（自动跟随 / 屏幕箭头 / 静默模式三个开关） |
| `wjw_Toolkit.toc` | Interface 16001、SavedVariables: QuestPathDB, WuXianAutoSellDB、加载顺序 |

## 命令

寻路（`/qp`）：

| 命令 | 说明 |
|---|---|
| `/qp` | 查看当前目标与距离 |
| `/qp <x> <y>` | 按地图百分比设定目标（0–1 小数或 0–100 百分数） |
| `/qp quest` | 用当前选中/追踪的任务设定目标 |
| `/qp clear` | 清除目标 |
| `/qp auto on\|off` | 自动跟随追踪/选中任务（默认开启） |
| `/qp arrow on\|off` | 屏幕箭头开关 |
| `/qp quiet on\|off` | 静默模式（自动过程提示不再刷屏） |
| `/qp debug` | 打印目标解析链路、坐标、绘制层状态（排障首选） |

自动卖垃圾（`/xsell`，别名 `/无限卖垃圾`）：

| 命令 | 说明 |
|---|---|
| `/xsell` | 开 / 关自动卖出（等同于 toggle） |
| `/xsell on \| off \| toggle` | 开启 / 关闭 / 切换自动卖出 |
| `/xsell status` | 查看开关状态与名单数量 |
| `/xsell add` | 把鼠标指向（或拾起到光标）的物品加入永不卖出名单 |
| `/xsell remove [ID或名字]` | 从名单移除，不填参数则取光标上的物品 |
| `/xsell list` | 查看永不卖出名单 |
| `/xsell clear` | 清空永不卖出名单 |
| `/xsell config` | 打开设置面板 |
| `/xsell help` | 显示卖垃圾帮助 |

总帮助：

| 命令 | 说明 |
|---|---|
| `/wjw` | 一次列出两个功能的全部常用命令与设置页位置 |

## 设置页

游戏「选项 → 插件」下有两个分类：`wjw_工具箱 · 任务寻路`、`wjw_工具箱 · 自动卖垃圾`。

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

## 已知限制

- 寻路连线是直线，不是寻路；只有游戏给出路点时才会分段指向。
- 部分任务游戏不提供 POI，此时显示“读不到目标点”，不会乱画。
- 到达判定：距最终目标 ≤ 15 码时隐藏全部绘制。
- 官方黄箭头显示同一任务时，自动隐藏小地图连线（屏幕箭头保留）。
- 自动卖垃圾只处理品质 0 物品，永不卖出名单内的物品会被跳过；商人不收购或被锁定的物品会跳过并提示。
- 自动卖垃圾的“获得金币”按会话前后钱数差值计算，期间修理/手动买卖会影响该数字。

## 开发约定

- 改完 `/reload` 生效；新增插件才需要退回角色选择界面重新扫描。
- 本机没有 Lua 解释器，交付前必须做静态自检：`end` 配对、UTF-8 无 BOM、API 存在性核对。
- 新用到的 API 必须先在 `warcraft.wiki.gg` 或 Gethe/wow-ui-source（`forever` 分支）核实。
- 排障三步：`/console scriptErrors 1` → `/reload` → `/qp debug`。
- git 提交不得添加 Co-Authored-By 签名。
- `legacy/` 内文件不得修改，除非要做回退。
