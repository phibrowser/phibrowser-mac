issue: PHI-507
based_on: PHI-507/test-plan.md@44bfc4eb0496ff0c7de868a656a3dde10f3afe68, Phi-TabClose.zip@sha256:205e51fd09427beeb9a24d813888f780efb1f5d16d4a8c63f280e34386575470

# 独立安装包测试报告 r1（阻断中止）

报告站：https://argus-phi.github.io/phi-ai-test-reports/PHI-507/r1/

结论：`blocked`。本轮为阻断中止的部分执行报告，未完成完整手册，不能判 TEST: pass。已安装并核对指定 OpenSource 二进制包；原手册512项：通过4、失败0、阻塞23、未完成/未执行485。额外诊断 DIAG-NET-01 失败，B1-1 阻断正常 HTTP/HTTPS 网页验收；文件副本仅支持有限诊断，不能代替正常网页和全量执行。27个语言×布局点全部未完成。含诊断共513项：通过4、失败1、阻塞23、未完成/未执行485。独立包任务没有PR，未给出放行结论；会话已归还。

## 构建与范围

- 本轮测试者 Ripley；被测包 TC-QA-20261030.1，版本 0.0.0 (1030.1)，OpenSource，Framework 156.0.8078.52。
- ZIP SHA-256：`205e51fd09427beeb9a24d813888f780efb1f5d16d4a8c63f280e34386575470`；DMG SHA-256：`6ffe2b797ea062ee00eed7dd0ea0bacbfdcf96643874fb1dd00ecb48f7590312`。
- 来源包含未提交修改；完整源头 SHA 不可得。base `d390230615c172c3a3f94132e0b36ce081dac0be` 不代表完整被测代码。
- 实际环境为 macOS 26.6.2 (25G83)、arm64、e2e02；不是 Intel、最低支持系统或官方 AI 的通过报告。
- 原手册 166 个基础用例展开 512 项（P0 272、P1 208、P2 32）；另有 1 项运行前置诊断。每项完整步骤、预期、实际、布局、语言、开关、集合及证据见 `report/report.json`。

## 阻断与缺陷

`B1-1`，severity `blocker`：指定包的正常 HTTP/HTTPS 导航不提交，阻断完整网页验收。

复现：安装并校验 TC-QA-20261030.1 (1030.1)，退出同身份或其他 Phi 实例后只运行本包；在原生地址栏打开公网手册 fixture 或本会话 HTTP 镜像。观察 Stop/进度状态持续、页面未提交。正常重启后先打开原 fixture 文件，再导航到 HTTP，旧打开编号仍保留。同会话 curl 与 Canary 能取得 HTTP fixture。

重启后 HTTP 页仍显示旧文件打开编号 `33168d93-245c-4d8d-bf2c-7b26e2301599`；同会话 Canary 真实提交 HTTP，`readyState=complete`，新编号 `a06e421a-53c2-4691-b672-19516a7e8394`。证据分别见 `qa-evidence/r1/fixture-http-after-restart.log`、`control-canary-http.json` 与截图。签名和 Gatekeeper 检查均 exit 0。

未取得配套旧构建，不能将此现象归因于本批关闭改动；也不能写成已证实的主机环境故障。需要提供能在相同隔离环境提交普通 HTTP/HTTPS 文档的修订包，或补充本包缺失的运行前提。此为唯一提交给任务的前置阻断。

## 未完成范围与过程偏差

27 个语言/布局点均未完成；Performance、Comfortable、双击、split、组、pin/书签、多选、确认、窗口/Profile/隐身、快捷键、恢复、大容量、辅助功能与媒体等完整场景未验收。没有以 Balanced 文件单项成功代替完整手册。缺少官方 AI/账号迁移、旧版配套包、真实设备或未定探索标准的项目分别列为 blocked；其他未执行项目列为 skipped，逐项注明原因。

前三次网络尝试失败与文件诊断成功分别分组；POS-03-BAL 的误命中和拖动失败两次无效尝试单独保留，第3次才获得可用结果。重启诊断的嵌套调用曾用 System Events 只读检查 Space 菜单，违背指定手段；不将该检查作为用例通过证据。随后通过 computer use 的 Space 删除及清理独立核对，未用其伪造任何产品状态。；若干嵌套调用做了只读本地记忆检索；未参与产品判定、未据此改变流程。；未严格按所有20秒时限返回截图；原始日志中约28秒的采集偏差保留。

## 范围外已知问题

没有通过配套旧版基线确认的既有问题，没有新建 PBL。Canary 是环境可用性对照，不是功能基线。没有调用产品 chat，因而没有产品 Langfuse trace。

## 清理与交付

已原生删除本轮 TC-QA-PHI507，正常退出 app；移除会话用户的临时 app；卸载 DMG/SMB。未改变布局、语言、两个开关或快捷键；未知 OpenSource profile 数据保留。证据收齐后已归还 lease `79785efb-9979-4356-993e-758924b1b81c`。发布前先归还，未在归还后再操作该会话。

## 全量用例结果

| 用例 | 优先级 | 布局/语言 | 结果 | 实际/未完成原因 | 证据 |
|---|---|---|---|---|---|
| ENV-01-COMMON | P0 | once/按本轮环境（已观察 app 为 en） | pass | ZIP CRC 校验无错；DMG SHA-256 与清单相同；嵌入信息、运行进程路径和 About 均为 Phi Tab Close QA 0.0.0 (1030.1)，Framework 156.0.8078.52。Advanced 第二卡片可见两个开关，off/on。 | qa-evidence/r1/ENV-01-COMMON-01.png、qa-evidence/r1/ENV-01-COMMON-02.png、qa-evidence/r1/zip-integrity.log、qa-evidence/r1/package-SHA256SUMS.txt、qa-evidence/r1/app-build-info.json、qa-evidence/r1/signature-verification.log |
| ENV-02-COMMON | P0 | once/按本轮环境（已观察 app 为 en） | skipped | 部分执行：已创建 TC-QA-PHI507，已观察初始 Balanced 与 off/on，未发现真实工作页面；没有记录原有全部快捷键。完整用例未完成。 | qa-evidence/r1/ENV-02-COMMON-01.png、qa-evidence/r1/ENV-02-COMMON-02.png、qa-evidence/r1/space-setup.log |
| ENV-03-COMMON | P0 | once/按本轮环境（已观察 app 为 en） | pass | 文件副本上建立并原生核对 A→B→C→D→E→F，六页同 run 且有独立打开编号。HTTP/HTTPS 尝试未提交；正常重启后文件 fixture 可加载，文件 A–F 序列验证完成。 | qa-evidence/r1/ENV-03-COMMON-attempt1-01.png、qa-evidence/r1/fixture-native-attempt1.log、qa-evidence/r1/ENV-03-COMMON-attempt2-02.png、qa-evidence/r1/fixture-local-attempt2.log、qa-evidence/r1/ENV-03-COMMON-attempt3-02.png、qa-evidence/r1/fixture-http-after-restart.log、qa-evidence/r1/ENV-03-COMMON-file-01.png、qa-evidence/r1/ENV-03-COMMON-file-02.png、qa-evidence/r1/ENV-03-COMMON-file-sequence.log、qa-evidence/r1/file-sequence-cdp-before.json |
| ENV-04-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | pass | 在六个文件 fixture 分别输入 KEEP-A-507 至 KEEP-F-507，再逐页切回；原生读取和 CDP 核对均显示编号、标记不变。F 的编号为 fa715f89-fec6-468a-897e-44a15878305a。 | qa-evidence/r1/ENV-04-COMMON-01.png、qa-evidence/r1/ENV-04-COMMON-02.png、qa-evidence/r1/ENV-03-COMMON-file-sequence.log、qa-evidence/r1/file-sequence-cdp-before.json |
| ENV-05-COMMON | P0 | once/按本轮环境（已观察 app 为 en） | blocked | 已记录 macOS 26.6.2 (25G83)、arm64、OpenSource 0.0.0 (1030.1)、Framework 156.0.8078.52；只有该单一环境。没有完整发布支持矩阵、Intel/最低系统或官方 AI 配套包；正常网页导航同时受 B1-1 阻断。 | qa-evidence/r1/environment.json、qa-evidence/r1/app-build-info.json |
| ENV-06-COMMON | P0 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-01-COMMON | P0 | once/按本轮环境（已观察 app 为 en） | skipped | 部分执行：观察到第一卡片及无标题的第二卡片，两个开关及说明可见；未执行小窗口缩放与滚动检查。 | qa-evidence/r1/ENV-01-COMMON-02.png |
| SET-02-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | blocked | 第一次观察到双击 off、位置 on；未在启动前证明该 macOS 用户从未设置过 OpenSource 偏好，不能据此判默认值测试通过。 | qa-evidence/r1/ENV-01-COMMON-02.png |
| SET-03-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-03-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-03-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-04-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-04-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-04-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-05-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-05-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-05-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-PER-off-off | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-PER-on-off | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-PER-off-on | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-PER-on-on | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-BAL-off-off | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-BAL-on-off | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-BAL-off-on | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-BAL-on-on | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-COM-off-off | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-COM-on-off | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-COM-off-on | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-06-COM-on-on | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-07-COMMON | P0 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-08-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-09-COMMON-off | P0 | once/按本轮环境（已观察 app 为 en） | blocked | 缺少已配置旧双击偏好的配套旧安装包与回退包；未执行升级。 | 无（未执行） |
| SET-09-COMMON-on | P0 | once/按本轮环境（已观察 app 为 en） | blocked | 缺少已配置旧双击偏好的配套旧安装包与回退包；未执行升级。 | 无（未执行） |
| SET-10-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-10-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SET-10-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-01-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-01-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-01-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-02-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-02-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-02-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-03-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-03-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-03-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-04-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-04-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-04-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-05-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-05-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-05-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-06-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-06-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-06-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-PER-command | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-PER-shift | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-PER-option | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-PER-control | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-BAL-command | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-BAL-shift | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-BAL-option | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-BAL-control | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-COM-command | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-COM-shift | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-COM-option | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-07-COM-control | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-08-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-08-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-08-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-09-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-09-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-09-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-10-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-10-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-10-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-11-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-11-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-11-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-12-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-12-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-12-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-13-PER-cancel | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-13-PER-leave | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-13-BAL-cancel | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-13-BAL-leave | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-13-COM-cancel | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-13-COM-leave | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-14-PER-cancel | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-14-PER-leave | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-14-BAL-cancel | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-14-BAL-leave | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-14-COM-cancel | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-14-COM-leave | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-15-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-15-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-15-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-16-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-16-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-16-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-PER-command | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-PER-shift | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-PER-option | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-PER-control | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-BAL-command | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-BAL-shift | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-BAL-option | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-BAL-control | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-COM-command | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-COM-shift | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-COM-option | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-17-COM-control | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-18-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-18-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-18-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-19-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-19-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-19-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-20-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-20-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-20-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-21-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-21-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-21-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-22-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-22-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-22-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-23-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-23-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| DBL-23-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-01-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-01-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-01-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-02-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-02-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-02-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-03-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-03-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | pass | 第3次使用全新文件 A–F，原生确认 F 活动；按最新 element_index 右键 C，再选择 Close Tabs Above。最终 C→D→E→F，A/B 已关闭；F 仍活动且打开编号 0cc7ff47-965d-4f38-b044-89e24fadf63f 不变。CDP 剩余目标精确为 C/D/E/F。 | qa-evidence/r1/POS-03-BAL-attempt1-01.png、qa-evidence/r1/POS-03-BAL-attempt1-02.png、qa-evidence/r1/POS-03-BAL-attempt1.log、qa-evidence/r1/POS-03-BAL-attempt2-01.png、qa-evidence/r1/POS-03-BAL-attempt2-02.png、qa-evidence/r1/POS-03-BAL-attempt2.log、qa-evidence/r1/POS-03-BAL-attempt3-01.png、qa-evidence/r1/POS-03-BAL-attempt3-02.png、qa-evidence/r1/POS-03-BAL-attempt3-03.png、qa-evidence/r1/POS-03-BAL-attempt3.log、qa-evidence/r1/POS-03-BAL-attempt3-setup.json、qa-evidence/r1/POS-03-BAL-attempt3-after.json |
| POS-03-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-04-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-04-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-04-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-05-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-05-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-05-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-06-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-06-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-06-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-07-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-08-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-08-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-08-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-09-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-09-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-09-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-10-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-10-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-10-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-11-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-11-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-11-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-12-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-12-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-12-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-13-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-13-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-13-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-14-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-14-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-14-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-15-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-15-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| POS-15-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-01-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-01-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-01-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-02-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-02-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-02-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-03-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-03-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-03-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-04-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-04-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-04-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-05-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-05-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-05-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-06-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-06-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-06-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-07-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-07-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-07-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-08-PER | P2 | performance/按本轮环境（已观察 app 为 en） | blocked | 本项未实际执行；手册同时明确其跨目标手势/恢复粒度/模态交错标准尚待产品确认。 | 无（未执行） |
| SPL-08-BAL | P2 | balanced/按本轮环境（已观察 app 为 en） | blocked | 本项未实际执行；手册同时明确其跨目标手势/恢复粒度/模态交错标准尚待产品确认。 | 无（未执行） |
| SPL-08-COM | P2 | comfortable/按本轮环境（已观察 app 为 en） | blocked | 本项未实际执行；手册同时明确其跨目标手势/恢复粒度/模态交错标准尚待产品确认。 | 无（未执行） |
| SPL-09-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-09-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-09-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-10-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-10-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-10-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-11-PER-cancel | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-11-PER-leave | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-11-BAL-cancel | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-11-BAL-leave | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-11-COM-cancel | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-11-COM-leave | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-12-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-12-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-12-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-13-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-13-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-13-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-14-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-14-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-14-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-15-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-15-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-15-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-16-PER | P2 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-16-BAL | P2 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SPL-16-COM | P2 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-01-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-01-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-01-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-02-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-02-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-02-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-03-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-03-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-03-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-04-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-04-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-04-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-05-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-05-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-05-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-06-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-06-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-07-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-07-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-07-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-08-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-08-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-08-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-09-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-09-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-09-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-10-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-10-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-10-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-11-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-11-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| PIN-11-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-01-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-01-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-01-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-02-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-02-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-02-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-03-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-03-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-03-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-04-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-04-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-04-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-05-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-05-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-05-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-06-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-06-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-06-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-07-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-07-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-07-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-08-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-08-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-09-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-10-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-10-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-10-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-11-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-11-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-11-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-12-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-12-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-12-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-13-PER-cancel | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-13-PER-leave | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-13-BAL-cancel | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-13-BAL-leave | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-13-COM-cancel | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-13-COM-leave | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-14-PER-cancel | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-14-PER-leave | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-14-BAL-cancel | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-14-BAL-leave | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-14-COM-cancel | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-14-COM-leave | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-15-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-15-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-15-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-16-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-16-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-16-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-17-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-17-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-17-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-18-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-18-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| GRP-18-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-01-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-01-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-02-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-02-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-03-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-03-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-03-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-04-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-05-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-06-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-06-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-06-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-07-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-07-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-08-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-08-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-09-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-09-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-09-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-10-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-10-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-11-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-11-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-12-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-12-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| BMK-12-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-01-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-01-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-01-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-02-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-02-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-02-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-03-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-03-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-03-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-04-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-04-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-04-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-05-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-06-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-06-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-06-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-07-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-07-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-07-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-08-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-08-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-08-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-09-PER | P2 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SEL-09-BAL | P2 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-01-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-01-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-01-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-02-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-02-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-02-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-03-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-03-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-04-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-04-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-04-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-05-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-05-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-05-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-06-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-06-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-07-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-07-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-08-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-08-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-09-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-09-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-09-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-10-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-10-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-10-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-11-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-11-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-11-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-12-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-12-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-12-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-13-PER-reader | P2 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-13-PER-peek | P2 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-13-PER-sidecar | P2 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-13-BAL-reader | P2 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-13-BAL-peek | P2 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-13-BAL-sidecar | P2 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-13-COM-reader | P2 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-13-COM-peek | P2 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-13-COM-sidecar | P2 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-14-PER-audio | P2 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-14-PER-download | P2 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-14-BAL-audio | P2 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-14-BAL-download | P2 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-14-COM-audio | P2 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| LIFE-14-COM-download | P2 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-01-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-01-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-01-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-02-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-02-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-02-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-03-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-04-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-05-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-06-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | blocked | 包内说明明确此 OpenSource 构建没有 Phi 登录、云同步、AI、Sentinel；本项所需官方 AI/账号迁移前置未具备，未执行。 | qa-evidence/r1/package-README.txt |
| SCOPE-07-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-07-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-08-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-09-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-09-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-09-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-10-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-10-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-10-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-11-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-11-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-11-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-12-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-12-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-12-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-13-PER-pin | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-13-PER-pin-split | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-13-PER-bookmark | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-13-PER-bookmark-split | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-13-BAL-pin | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-13-BAL-pin-split | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-13-BAL-bookmark | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-13-BAL-bookmark-split | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-14-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-14-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-14-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-15-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-15-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-15-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-16-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-16-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-16-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-17-COMMON | P2 | once/按本轮环境（已观察 app 为 en） | blocked | 包内说明明确此 OpenSource 构建没有 Phi 登录、云同步、AI、Sentinel；本项所需官方 AI/账号迁移前置未具备，未执行。 | qa-evidence/r1/package-README.txt |
| SCOPE-18-PER-cancel | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-18-PER-leave | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-18-BAL-cancel | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-18-BAL-leave | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-18-COM-cancel | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-18-COM-leave | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-19-COM-pin | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-19-COM-pin-split | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| SCOPE-20-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-01-PER | P0 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-01-BAL | P0 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-01-COM | P0 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-PER-en | P1 | performance/en | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-PER-zh-Hant | P1 | performance/zh-Hant | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-PER-ja | P1 | performance/ja | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-PER-ko | P1 | performance/ko | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-PER-de | P1 | performance/de | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-PER-fr | P1 | performance/fr | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-PER-es | P1 | performance/es | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-PER-nl | P1 | performance/nl | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-BAL-en | P1 | balanced/en | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-BAL-zh-Hant | P1 | balanced/zh-Hant | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-BAL-ja | P1 | balanced/ja | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-BAL-ko | P1 | balanced/ko | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-BAL-de | P1 | balanced/de | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-BAL-fr | P1 | balanced/fr | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-BAL-es | P1 | balanced/es | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-BAL-nl | P1 | balanced/nl | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-COM-en | P1 | comfortable/en | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-COM-zh-Hant | P1 | comfortable/zh-Hant | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-COM-ja | P1 | comfortable/ja | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-COM-ko | P1 | comfortable/ko | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-COM-de | P1 | comfortable/de | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-COM-fr | P1 | comfortable/fr | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-COM-es | P1 | comfortable/es | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-02-COM-nl | P1 | comfortable/nl | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-03-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-03-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-04-COMMON | P1 | once/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-05-COMMON | P0 | once/按本轮环境（已观察 app 为 en） | skipped | 部分执行：已输出独立 report.json、Markdown、证据与备份；已删除本轮 Space、正常退出并移除临时 app、卸载挂载并归还会话。未执行手册网页的导出按钮流程，完整用例未完成。 | qa-evidence/r1/CLEANUP-01.png、qa-evidence/r1/CLEANUP-02.png、qa-evidence/r1/CLEANUP.log、qa-evidence/r1/cleanup-filesystem.json、qa-evidence/r1/lane-release.json |
| VIS-06-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-06-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-06-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-07-PER-mouse | P1 | performance/按本轮环境（已观察 app 为 en） | blocked | 没有接入并核验本变体所需的真实物理鼠标/触控板与系统配置；未执行真实设备测试。 | 无（未执行） |
| VIS-07-PER-trackpad | P1 | performance/按本轮环境（已观察 app 为 en） | blocked | 没有接入并核验本变体所需的真实物理鼠标/触控板与系统配置；未执行真实设备测试。 | 无（未执行） |
| VIS-07-BAL-mouse | P1 | balanced/按本轮环境（已观察 app 为 en） | blocked | 没有接入并核验本变体所需的真实物理鼠标/触控板与系统配置；未执行真实设备测试。 | 无（未执行） |
| VIS-07-BAL-trackpad | P1 | balanced/按本轮环境（已观察 app 为 en） | blocked | 没有接入并核验本变体所需的真实物理鼠标/触控板与系统配置；未执行真实设备测试。 | 无（未执行） |
| VIS-07-COM-mouse | P1 | comfortable/按本轮环境（已观察 app 为 en） | blocked | 没有接入并核验本变体所需的真实物理鼠标/触控板与系统配置；未执行真实设备测试。 | 无（未执行） |
| VIS-07-COM-trackpad | P1 | comfortable/按本轮环境（已观察 app 为 en） | blocked | 没有接入并核验本变体所需的真实物理鼠标/触控板与系统配置；未执行真实设备测试。 | 无（未执行） |
| VIS-08-PER | P1 | performance/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-08-BAL | P1 | balanced/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| VIS-08-COM | P1 | comfortable/按本轮环境（已观察 app 为 en） | skipped | 未执行。本轮因 B1-1 正常 HTTP/HTTPS 网页导航异常中止完整验收，本项未执行。此记录不表示本项本身失败，也不表示它单独必然依赖 HTTP；没有以文件冒烟替代本项。 | 无（未执行） |
| EXP-01-PER | P2 | performance/按本轮环境（已观察 app 为 en） | blocked | 本项未实际执行；手册同时明确其跨目标手势/恢复粒度/模态交错标准尚待产品确认。 | 无（未执行） |
| EXP-01-BAL | P2 | balanced/按本轮环境（已观察 app 为 en） | blocked | 本项未实际执行；手册同时明确其跨目标手势/恢复粒度/模态交错标准尚待产品确认。 | 无（未执行） |
| EXP-01-COM | P2 | comfortable/按本轮环境（已观察 app 为 en） | blocked | 本项未实际执行；手册同时明确其跨目标手势/恢复粒度/模态交错标准尚待产品确认。 | 无（未执行） |
| EXP-02-PER | P2 | performance/按本轮环境（已观察 app 为 en） | blocked | 本项未实际执行；手册同时明确其跨目标手势/恢复粒度/模态交错标准尚待产品确认。 | 无（未执行） |
| EXP-02-BAL | P2 | balanced/按本轮环境（已观察 app 为 en） | blocked | 本项未实际执行；手册同时明确其跨目标手势/恢复粒度/模态交错标准尚待产品确认。 | 无（未执行） |
| EXP-02-COM | P2 | comfortable/按本轮环境（已观察 app 为 en） | blocked | 本项未实际执行；手册同时明确其跨目标手势/恢复粒度/模态交错标准尚待产品确认。 | 无（未执行） |
| EXP-03-COMMON | P2 | once/按本轮环境（已观察 app 为 en） | blocked | 本项未实际执行；手册同时明确其跨目标手势/恢复粒度/模态交错标准尚待产品确认。 | 无（未执行） |
| EXP-04-COMMON | P2 | once/按本轮环境（已观察 app 为 en） | blocked | 没有发布清单允许的配套旧 Framework 测试包；未执行旧接口兼容测试。 | 无（未执行） |
| DIAG-NET-01 | P0 | balanced/en | fail | 被测包公网 HTTPS 与本地 HTTP 都停留在 Stop/进度状态，无新测试文档；重启后文件可打开，转 HTTP 仍保留旧文件编号 33168d93-245c-4d8d-bf2c-7b26e2301599。命令行与服务正常；同会话 Canary 则真实提交 HTTP 文档，readyState=complete，fixturePresent=true，新编号 a06e421a-53c2-4691-b672-19516a7e8394。 | qa-evidence/r1/ENV-03-COMMON-attempt1-01.png、qa-evidence/r1/fixture-native-attempt1.log、qa-evidence/r1/ENV-03-COMMON-attempt2-02.png、qa-evidence/r1/fixture-local-attempt2.log、qa-evidence/r1/local-fixture-control.log、qa-evidence/r1/ENV-03-COMMON-attempt3-02.png、qa-evidence/r1/fixture-http-after-restart.log、qa-evidence/r1/CONTROL-HTTP-01.png、qa-evidence/r1/control-canary-http.json、qa-evidence/r1/control-canary-environment.log、qa-evidence/r1/signature-verification.log |
