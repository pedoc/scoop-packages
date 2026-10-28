# 新增一个 Scoop 包

本文记录在本仓库新增一个包的完整流程、必须遵守的约束，以及实测下来的经验教训。

## 硬性约束

- **禁止直接推 `master`**，也不要在 `master` 上开发。先开 `feat/<app>` 分支。
- **禁止 `hash: skip`**。每个资产必须是具体 SHA256，`bin/manifest-policy.psm1` 会强制校验。
- 清单必须同时声明 `checkver` 与 `autoupdate`，否则 `bin/test.ps1` 会拒绝该清单。
- 清单必须是严格 JSON、UTF-8 无 BOM，且与 Scoop `ConvertToPrettyJson` 的输出逐字节相同（含结尾 CRLF）。
  用仓库的格式化函数规范化，不要用普通 JSON 格式化工具。
- 桌面应用与同名 CLI 的许可可能不同。MiniMax Code 的 CLI 是 MIT，桌面应用是专有许可；
  必须以应用本身的许可证为准，不能套用 CLI 的开源协议。

## 步骤

### 1. 研究上游

```bash
gh api repos/<owner>/<repo>            # license、默认分支、是否归档
gh api repos/<owner>/<repo>/releases   # 资产命名、是否有 .sha256 边车、是否签名、预发布/草稿
```

**必须下载真实安装包做静态分析**，不要凭文件名猜格式：

- 7-Zip 可解 NSIS / Electron：`7z l -slt <file>` 查看内部结构。
- Inno Setup 用 Scoop 自带的 `innounp`（`scoop/apps/innounp/current/innounp.exe`）。
  `innoextract` 1.9 不支持 Inno Setup 6.7，会报 `Unexpected setup loader revision`。
- PE 架构：读 PE header 偏移 0x3C 处的 Machine 字段（`0x8664` = x64，`0xAA64` = ARM64，
  `0x014C` = x86 存根）。x86 存根不代表应用只支持 32 位。
- Electron 应用要读 ASAR 内的 `package.json`，其中的 `version` 才是权威版本。

### 2. 决定内置更新怎么处理

桌面应用常自带自动更新，会静默运行官方安装器覆盖 Scoop 管理的副本，必须阻断：

- **Electron**：删除 `resources/app-update.yml`。
  `electron-updater` 即便运行时调用了 `setFeedURL`，在下载安装器前仍会
  `await configOnDisk.value`（`getOrCreateDownloadHelper`），删掉该配置即阻断原生下载与安装。
- **带独立更新器的应用**：删除更新器可执行文件（例如 `DeskBox.Updater.exe`）。
  DeskBox 的更新器会以 `/SILENT /DIR=... /CURRENTUSER` 运行官方安装器；删掉后安装动作会直接报错，
  但后台检查与下载仍会继续。

阻断后要核实哪些功能受影响（例如应用内"重启"复用同一个更新器），并在 `notes` 中如实写明。
`notes` 不要写成"更新已完全禁用"，准确表述是"更新**安装**被阻断"。

### 3. 用户数据与 `persist`

用户数据若在安装目录**之外**（例如 `%LOCALAPPDATA%\<App>`），就不要声明 `persist`，
否则会把用户数据搬进版本目录。若确实在安装目录内，再按需声明。

### 4. 写清单

- 双架构各用官方独立安装器时，两个架构的 `url` 与 `hash` 必须分别声明。
- hash 来源优先用官方 `.sha256` 边车文件：

  ```json
  "hash": {
      "url": "https://github.com/<owner>/<repo>/releases/download/v$version/<file>.exe.sha256",
      "regex": "([A-Fa-f0-9]{64})"
  }
  ```

  这比 `"mode": "download"` 省一次几十 MB 的安装包下载。
  不要依赖 Scoop 的 `github` hash 模式：它依赖匿名 `api.github.com`，会撞限流返回 403。
- 快捷方式的第 4 项是图标路径（相对安装目录）。

### 5. 验证

```powershell
pwsh -NoLogo -NoProfile -File ./bin/install-test-tools.ps1   # 首次：Pester 5.7.1 / PSScriptAnalyzer 1.24.0
pwsh -NoLogo -NoProfile -File ./bin/test.ps1 -Coverage -Analyze -ManifestPathsJson '["bucket/<app>.json"]'
```

- 局部快速迭代：`-Path ./tests/ForwardManifest.Tests.ps1`。
- 在线版本规则：`pwsh -NoLogo -NoProfile -File ./bin/checkver.ps1 -App <app> -ThrowError`。
- **用 Scoop 自身的函数做真实解包验证**（最容易被跳过、也最有价值的一步）：
  dot-source `lib/core.ps1`、`lib/manifest.ps1`、`lib/autoupdate.ps1`、`lib/download.ps1`、
  `lib/decompress.ps1` 后调用 `Invoke-Extraction`，再把 `$dir` 指向安装目录执行清单里的 `post_install`。
  这样能真正验证架构分流、文件落位、`extract_dir` 语义与清理钩子，而不只是验证 JSON。
- 再用 `Update-ManifestProperty` 验证 `autoupdate` 模板能解析出未来的 url 与 hash。
- 检查改动范围时注意仓库用 CRLF：`git -c core.whitespace=cr-at-eol diff --cached --check`。

### 6. 写回归测试

在 `tests/ForwardManifest.Tests.ps1` 追加包级契约测试，先 RED 后 GREEN。

- 断言要**离线**，不要锁定当前版本号与哈希值，否则自动升级会失败。
- 需要覆盖：双架构各自的 url/hash 模板、清理钩子边界（安装目录外的数据不受影响）、
  真实 `Get-ManifestUpdateDecision` 接受未来版本、边车 URL 与安装器 URL **架构绑定**
  （两个架构对调时必须能被抓到）。

### 7. 提交、变基与 PR

```bash
git switch -c feat/<app>
git add -- bucket/<app>.json tests/ForwardManifest.Tests.ps1
git -c core.whitespace=cr-at-eol diff --cached --check
git commit -m "feat: add <App> Scoop package" -m "<body>"
git push -u origin feat/<app>
```

**建 PR 之前先变基**：

```bash
git fetch origin master
git rebase origin/master          # 已 squash 合并的旧提交会自动跳过
git push --force-with-lease origin feat/<app>
```

变基后重跑全库测试再推送。PR body 要写清做了什么、**验证了什么**、**没验证什么**
（例如"应用从未启动过"）、以及已知限制。

### 8. 自动合并

```bash
gh pr checks <n> --watch --fail-fast --interval 20
# 确认全部 bucket == "pass" 后再合并
gh pr merge <n> --squash --match-head-commit <head-sha> --subject "..." --body "..."
```

`--match-head-commit` 锁定已验证的那个提交，避免合并到未验证的新 head。
不要用 `gh pr merge --auto`：本仓库是管理员权限，自动合并会绕过"校验通过后才合并"的流程。

### 9. 收尾

```bash
git switch master && git pull --ff-only
git branch -d feat/<app>                # PR 已合并后本地分支可删
git push origin --delete feat/<app>     # 远端分支也可删
```

## 经验教训

1. **变基要放在建 PR 之前**。否则 PR 会把已合并的旧提交与新提交混在一起，
   `git diff origin/master...HEAD` 会多出十几个无关清单的落后差异。
2. **`git diff A...B`（三点）与 `A..B`（两点）含义不同**。三点从共同祖先算起，
   在 `master` 前进后会把 `master` 的新提交算成"你的改动"。
   核对 PR 内容要同时看 `git diff origin/master...HEAD` 和 `git log --oneline origin/master..HEAD`，两者必须一致。
3. **GitHub 直连不稳**，`curl` 下载 release 资产经常 timeout 或连接重置。
   改用 `gh api repos/<o>/<r>/releases/assets/<id> -H 'Accept: application/octet-stream'` 更可靠，
   而且 `gh` 带 token 不会撞 API 限流。
4. **不能只看版本号猜架构**。安装包可能把 x64 和 arm64 放在同一个文件里（MiniMax Code），
   也可能拆成两个文件（DeskBox）。必须解包看实际结构。
5. **notes 要精确，不要夸大**。删除更新器后，应用内检查和下载仍在继续，
   只有"安装"被阻断；文案要区分这两件事。
6. **测试要能抓住"对调"这类错误**。只断言模板非空的测试太弱。
7. **已知的偶发失败用例**：`tests/UpdateWorker.Tests.ps1` 中
   "kills the timed-out process tree and keeps diagnostics" 依赖 3 秒超时窗口，
   负载高时可能因 `child.pid` 未生成而失败。**不要为此改测试**，重跑通常会通过；
   但要在 PR body 里如实说明这次的情况。
8. **PR body 要主动写出未验证项**，例如"应用从未启动"、"官方安装器未签名"。
   本仓库要求区分"检测到版本"与"实际安装测试过"。
