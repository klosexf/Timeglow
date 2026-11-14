# Timeglow 开发约定

Timeglow 是使用 SwiftUI / AppKit 开发的 macOS 应用与网站用时工具。以下路径以本仓库为基准。

## 项目入口

- `Timeglow/`：原生界面；`Timeglow/Monitoring/`：采集与权限；`Timeglow/MonitoringCore/`：计时、统计、提醒与存储。
- `README.md`：产品行为与运行方式；`DESIGN.md`：当前设计规范。只按任务需要查阅相关内容。
- `../outputs/timeglow-prototype.html`：交互原型；`../docs/timeglow-overview.md`：产品说明；`verification/`：验证与排查记录。

## 常用命令

在本仓库目录执行：

```sh
bash scripts/build-development.sh    # 构建、验签并整理启动注册
bash scripts/test-core.sh            # 计时、统计、提醒与数据库测试
bash scripts/test-website-icons.sh   # 网站图标获取与缓存检查
```

## 修改原则

- 先检查 Git 状态，保留已有未提交工作，只改本次任务需要的内容。提交、推送按用户授权执行。
- 界面沿用 `DESIGN.md` 与用户最新确认的方案；同步受影响的原型、效果图和说明，具体视觉参数只在设计文档维护。
- Debug 与 Release 数据保持隔离。验证不覆盖真实记录；临时修改的设置在验证后恢复。
- 按改动选择验证：逻辑改动跑相关测试，原生代码改动完成构建，界面改动检查实际窗口。纯文档修改无需重建应用。
- 不自动读取或同步 Notion 项目；项目接续仅在用户明确调用对应 Skill 时执行，直接读写请求按其范围处理。

## 更新应用时，确认运行的是最新包

1. 正常退出待替换的实例，再执行构建脚本。常用开发包固定为 `../outputs/native/Timeglow.app`；脚本负责清理历史包注册，直接用 Xcode 构建时也需完成同样的交付步骤。
2. 使用常用开发包的完整路径启动，随后核对真实进程及加载路径。常用开发版应只有一个实例，主程序和 `Timeglow.debug.dylib` 均须来自该包。
3. 将主程序和 Debug 模块分别与本次构建产物比较 SHA-256 或逐字节比较。不能只凭应用名、版本号或“启动成功”判断代码最新。
4. 确认运行版本后再检查实际界面。构建、运行版本与视觉检查分别报告；工具受阻就明确标注未验证，重要结果记录到 `verification/`。

独立测试包使用不同 bundle ID 并隔离数据；历史包保留作备份，不作为日常启动入口。若已修好的界面再次出现旧样式，先查运行路径、构建指纹和重复注册，再决定是否改源码。详见 [旧包误启动排查](verification/2026-11-14-version-routing.md)。
