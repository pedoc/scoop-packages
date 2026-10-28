# scoop-packages

A scoop warehouse, collecting various interesting and practical programs.

```powershell
scoop bucket add pedoc https://github.com/pedoc/scoop-packages.git
```

## 自动维护

这是个人维护的 bucket。版本检测复用 Scoop 官方工具，不要求仓库属于 Scoop 官方，也不需要 GitHub App、PAT 或其他额外 Secret。

自动化流程为：检测版本 → 每包一个 PR → 可信校验 → 对指定提交记录结果 → 校验通过后合并。不会直接向主分支提交软件更新。

| 工作流 | 职责 |
| --- | --- |
| [Scoop CI](.github/workflows/ci.yml) | 普通 PR / 主分支提交的只读检查、测试与覆盖率 |
| [Update Scoop manifests](.github/workflows/update-manifests.yml) | 每天 UTC 02:17、14:17 及手动检查，隔离生成候选、创建或复用 PR、派发校验 |
| [Validate and merge Scoop update](.github/workflows/validate-update.yml) | 默认分支可信代码验证指定 PR/head SHA，检查下载 SHA256，最后受控合并 |

**默认只检查，不创建 PR 或合并。** 更新生成发生在临时目录，可能下载软件以计算哈希，但不会安装、启动软件或修改主分支。普通贡献 CI 只有读取权限；发布、状态记录和合并分别使用受限的 job 权限。

### 首次启用

1. 将这些工作流与维护脚本合入仓库默认分支。定时任务不会因为文件只存在于本地或 feature 分支就开始运行。
2. 在仓库 **Settings → Actions → General → Workflow permissions** 中允许 **Allow GitHub Actions to create and approve pull requests**。默认工作流权限仍可保持只读；脚本不使用自我批准来满足审查要求。
3. 手动运行 **Update Scoop manifests**，分支必须选择仓库默认分支（当前 `master`），先保持 `publish=false`。可填写一个确切的清单名，例如 `spirula-studio`，也可留空检查所有符合条件的清单。
4. 查看 inventory / results artifacts 及 source-verdict。确认检查结果后，在仓库 **Settings → Secrets and variables → Actions → Variables** 添加仓库变量：

   ```text
   SCOOP_UPDATES_ENABLED=true
   ```

5. 再选择默认分支手动运行一次并选择 `publish=true`，确认单包 PR、校验结果和合并正常。之后定时任务会自动处理全部符合规则的包，无包名白名单。

手动发布必须同时满足显式 `publish=true` 和上述变量值严格为小写 `true`。发布、状态和合并路径都会独立检查权限开关。无需开启 GitHub 单独的 “Allow auto-merge” 功能：这里是在校验成功后调用匹配 head SHA 的 Merge API。

内置 `GITHUB_TOKEN` 创建的 PR 不保证自动触发普通 PR CI，或可能要求人工批准。维护工作流因此显式派发默认分支的校验，并把 `scoop/update-validation` 状态写到实际 PR head；不会把「已派发」当成「已经校验或合并」。

如果以后启用额外必需检查、审查或保护规则，自动合并仍需满足它们；不会管理员绕过。默认分支 dispatch 本身的检查不是普通 PR-head 检查，不能直接假定它满足任意 ruleset。

### 日常行为与失败恢复

- 使用固定 `automation/update-<app>` 分支和单包 PR；重复运行复用已有 PR，不为同一包不断开新 PR。机器人提交由 GitHub 签名，发布前会拒绝已检测到的人工提交。
- **自动管理分支仅供机器人写入。** 分支检查和第三方 Action 的后续更新不是针对检查时 head 的原子 CAS；若有仓库写权限的人在两者之间并发推送该分支，仍可能被覆盖。不要在这些分支追加人工提交；需要人工修复时使用独立分支。这项限制不同于最终合并使用的精确 head SHA 保护。
- 每批隔离检查 16 个包，并发受限，避免超过 GitHub matrix 限制。每轮最多发布 32 个候选，其余轮转到后续运行；这不是包名白名单。
- 单包网络、版本解析、下载或哈希失败不会把其他成功包一起丢弃。collector 必须完整核对每个选择的包；独立 source-verdict 可以令工作流显示失败，但不阻断已验证的健康候选。
- 每个包都有明确结果：`current`、`updated`、`unavailable`、`manual` 或 `failed`。`current` 只表示成功检测到的版本与清单相同，不代表程序已安装测试或旧下载链接仍有效；无输出/退出码 0 不会被直接认作已最新。
- 更新工作流成功仅代表生成/发布/派发阶段完成。最终合并以对应的校验工作流、当前 head 状态和 Merge API 结果为准。
- 临时故障修复后可再次运行更新工作流；已有但上次派发失败、取消或未通过验证的 PR 也会重新检查。重试整个校验流程，不沿用旧 head 的绿色状态。
- 版本回退、同版本替换二进制/只修哈希、改变安装脚本/依赖/来源规则等，不会自动合并。需要普通人工 PR 审核。
- 若要紧急停止发布/合并，先删除或关闭 `SCOOP_UPDATES_ENABLED`，再取消排队及正在执行的维护工作流。开关不能原子撤销已经发出的 API 请求。
- GitHub 可能延迟定时运行，也可能在公开仓库长期无活动后停用 schedule；可通过手动运行恢复/排查。

### 更新规则与维护例外

Scoop 对应的字段是 **`checkver` 与 `autoupdate`**，不是 `update`。

- GitHub release、供应商版本页面/API 及稳定下载模式都可以使用；字段存在不意味着规则目前可用。
- 所有声明的架构与 URL/hash 数组均须正确。版本化解压目录等必须能由既有模板确定地展开。
- 自动合并只接受严格递增版本及可信原模板解释的下载/哈希/路径变化，不允许自动改写更新规则、安装钩子、依赖、持久化或工作流。
- 不使用 `hash: skip` 掩盖失败。SHA256 校验的是下载字节，不等于证明软件发布者可信或应用行为/安装流程正确。
- 无可靠发布源、需要其他认证或尚不能自动处理的包记录在 [维护例外](.github/maintenance-exceptions.json) 的 `manual` 中，包含原因与来源；不会伪造版本、URL 或许可证。`warnings` 只提示历史下载/打包问题，不会永久禁用已经核实的后续版本检查。例外不豁免修改清单的 Schema 检查。
- 历史清单的遗留问题单独盘点；新建/修改清单严格校验，避免一个未修改的旧问题阻断所有软件维护。

## 本地开发与验证

需要 Git、Scoop 和 **PowerShell 7.2+**。依赖安装入口还需要 `Save-PSResource`，建议使用通常自带该命令的 **PowerShell 7.4+**。依赖只保存到忽略的 `.devtools/modules`，不修改系统模块或 PSGallery 信任设置。

```powershell
pwsh -NoLogo -NoProfile -File ./bin/install-test-tools.ps1
pwsh -NoLogo -NoProfile -File ./bin/test.ps1 -Coverage -Analyze
```

测试使用模拟网络/GitHub API 和临时 Git 仓库，不需要发布凭据，不创建线上 PR，不安装测试软件。生产维护代码要求至少 80% Pester command coverage；测试/依赖安装入口及固定的第三方源码不纳入生产逻辑覆盖率。CI 也运行 PowerShell 静态分析与工作流权限契约测试。工作流开发时另用固定版本 actionlint 手动检查；当前 YAML 未配置自动 actionlint job。

检查指定修改清单的严格 JSON、Scoop Schema、格式和维护规则：

```powershell
pwsh -NoLogo -NoProfile -File ./bin/test.ps1 -ManifestPathsJson '["bucket/spirula-studio.json"]'
```

盘点全库（仅统计字段与明显元数据问题，不联网，不冒充下载验证；显式指定 `-OutputDirectory` 时必须使用绝对文件系统路径）：

```powershell
pwsh -NoLogo -NoProfile -File ./bin/maintenance.ps1 -Mode Inventory
```

底层官方版本检查入口（会联网）：

```powershell
pwsh -NoLogo -NoProfile -File ./bin/checkver.ps1 -App spirula-studio
```

`checkver.ps1 -Update` 是显式修改本地清单的底层工具，不是 dry-run。自动化使用隔离副本与额外证据校验，不能只凭底层工具的退出码判断所有源均检查成功。

本地脚本默认使用安装的 Scoop，可通过 `-ScoopHome` 或 `SCOOP_HOME` 指定源码目录。CI 的 Scoop 核心与外部 Actions 均固定在已确认的提交，详见 [setup-scoop](.github/actions/setup-scoop/action.yml)；工具版本变化也需要测试与审查。

## 新增一个包

新增包的完整步骤与踩坑记录见 [docs/adding-a-package.md](docs/adding-a-package.md)，涵盖研究安装包格式、编写清单与回归测试、用 Scoop 自身函数做真实解包验证、提交推送、自动合并 PR 以及合并后的分支清理。
