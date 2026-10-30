issue: PHI-507
based_on: PHI-507/test-plan.md@64b693b75a9b0438f0862b7d6ec43d8c4f53ec3a

# 独立安装包 Computer Use 续测 r2

报告站：https://argus-phi.github.io/phi-ai-test-reports/PHI-507/r2/

结论：`blocked`。这是持续执行中的 Computer Use 阶段检查点，任务未完成、不给通过结论。512个执行点累计46通过、6部分执行、28条件阻塞、432待执行；网页将部分执行并入blocked，因此显示34 blocked、432 skipped，累计台账的pending保持不变。已有有效结果、无效尝试与中断证据全部保留；ENV-01漏执行的手册元数据填写已从过早的pass纠正为partial，后续补齐。r2已核对指定二进制、设置行为及部分双击/分屏场景；DBL-08尚缺有效重排和关闭按钮操作，不推断产品bug。已用CU恢复最初偏好、正常退出QA app、收齐证据并归还e2e02，随后进入r3续测全部剩余可执行手册场景。独立包任务无PR，不作PR放行。

## 构建与执行边界

- 已纳入Wood在触发评论中的补充；浏览器操作、状态读取、截图均通过e2e02的Computer Use，r1结果不继承。
- 构建与范围见 `report-r2/report.json`；可执行文件SHA-256为 `b30ef8b3acbc832ee3f1aaa8ce682ebb28289654ff3fdb84fbdf04151bb59d0b`；base commit不是完整被测源SHA。
- 真实环境仅macOS 26.6.2 arm64、OpenSource。没有声称源代码检查或未取得环境通过。
- 手册全部512项均保留；部分执行不标pass，未执行按具体原因列blocked/skipped。
- 重启后的首次导航延迟最终恢复；没有继承r1的B1-1为当前阻断或缺陷。

## 缺陷与范围外已知问题

没有已确认的当前产品缺陷。

无旧构建基线证实的范围外既有问题；没有建立PBL。独立包无PR，不作PR放行。

## 全量执行结果

| 用例 | 优先级 | 布局/语言 | 结果 | 实际/未完成原因 | 证据 |
|---|---|---|---|---|---|
| ENV-01-COMMON | P0 | once/本项未独立实读 | blocked | Computer Use 核对运行路径 /Applications/Phi Tab Close QA.app；About 为 0.0.0 (1030.1)、Chromium 156.0.8078.52。Advanced 第二张无标题卡片有两个开关及说明，Double-click off、Close by position on。 早期数值索引调用失败并有一次无依据(0,0)点击，未打开目标菜单；随后用完整app路径及字符串最新索引完成。未使用非Computer Use浏览器能力。；前序整例通过判定过早，当前按源步骤复核修正为部分执行；既有原始身份观察和证据全部保留。；原生 About、构建身份及 Advanced 第二卡片已实读；源步骤1的手册页面环境元数据填写未执行，留待续测以CU补齐。；部分执行，未判通过。 | qa-evidence/r2/ENV-01-COMMON-initial-about.png、qa-evidence/r2/ENV-01-COMMON-initial-advanced.png、qa-evidence/r2/ENV-01-COMMON.log、qa-evidence/r2/installed-identity.json、qa-evidence/r2/signature-verification.log |
| ENV-02-COMMON | P0 | once/本项未独立实读 | blocked | Computer Use 创建并切到 TC-QA-PHI507-r2，当前仅 New Tab；Balanced，双击off/位置on，保存区为空。Shortcuts All Shortcuts 搜索Close并检查列表，未找到Close Tabs to the Right和Close Other Tabs，不能确认原绑定。 隔离Space已建立；快捷键配置仍有缺口，暂不将整项判通过。没有关闭Default的Chrome Web Store或改动设置。；部分执行，未判通过。 | qa-evidence/r2/ENV-02-COMMON-initial-shortcuts-partial.png、qa-evidence/r2/ENV-02-COMMON-initial-empty-test-space.png、qa-evidence/r2/ENV-02-COMMON.log |
| ENV-03-COMMON | P0 | once/General 原生控件实读 System Default，浏览器菜单及 Settings 为英文；fixture 正文为中文。未切换语言，未出现语言重启提示。 | pass | TC-PHI507-r2-Recovery 内实际原生顺序 A → B → C → D → E → F；六页均实见相应 TC 标题、相同批次、各自打开编号、普通页说明和空输入框。A 位于最上。无需拖动；无多选、split 配对或组成员。 最初A–F实际成功；后因重启出现较长首次加载，再经CU诊断恢复，六页逐页读取身份。无手册SLA，不把约75秒延迟判作永久导航缺陷。 | qa-evidence/r2/ENV-03-COMMON-01.png、qa-evidence/r2/ENV-03-COMMON-03.png、qa-evidence/r2/ENV-03-COMMON-04.png、qa-evidence/r2/ENV-03-COMMON-02.png、qa-evidence/r2/ENV-03-COMMON-05.png、qa-evidence/r2/ENV-03-COMMON-06.png、qa-evidence/r2/ENV-03-COMMON-ENV-03-navigation-recovery-observation.json、qa-evidence/r2/ENV-03-COMMON.log、qa-evidence/r2/ENV-03-COMMON-initial-initial-F.png |
| ENV-04-COMMON | P1 | once/本项未独立实读 | pass | 本轮纯Computer Use在B输入KEEP-B-507-r2，切到C再回B；编号2a6e95cf-8074-4e05-b2ad-30972ab29ec8和标记均不变。  | qa-evidence/r2/ENV-04-COMMON-initial-B-before.png、qa-evidence/r2/ENV-04-COMMON-initial-B-after.png、qa-evidence/r2/ENV-04-COMMON.log |
| ENV-05-COMMON | P0 | once/本项未独立实读 | blocked | 本轮已实际核对macOS26.6.2 arm64、OpenSource、Framework156.0.8078.52及三种布局；没有发布方完整支持系统/芯片/渠道清单，也没有Intel、最低系统、官方AI和旧Framework配套包。只对实际环境报告，不扩展为全平台通过。 包内说明文本沿用此前取得版本，仅作能力说明；实际exeSHA在恢复后重新校验。；缺完整发布支持矩阵及对应测试构建/机器；本轮实际环境范围明确列出。 | qa-evidence/r2/installed-identity.json、qa-evidence/r2/resumed-identity.json、qa-evidence/r2/package-README-original.txt |
| ENV-06-COMMON | P0 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SET-01-COMMON | P0 | once/本项未独立实读 | blocked | 第一/第二卡片内容与说明已屏幕检查并实际滚动，原尺寸可读且第二无标题；三次原生边框拖动后尺寸未变，未得到小窗口，因此小尺寸部分未覆盖。 部分执行，未判通过。 | qa-evidence/r2/SET-01-COMMON-initial-advanced-before.png、qa-evidence/r2/SET-01-COMMON-initial-advanced-after-drag.png、qa-evidence/r2/SET-01-COMMON.log |
| SET-02-COMMON | P1 | once/本项未独立实读 | blocked | 本轮首次观察双击 off、位置 on；该会话已有 OpenSource 偏好与 Wood 安装包，未证明用户级偏好从未存在。未清除未知偏好，因此没有执行全新环境默认值验收。 缺可验证的全新 OpenSource 偏好环境；新 Space 不等于新用户默认值。 | qa-evidence/r2/installed-identity.json、qa-evidence/r2/ENV-01-COMMON-final.png |
| SET-03-PER | P0 | performance/本项未独立实读 | pass | 普通标签集合仍为 {A,B,C}，自上而下 A/B/C；无 split 配对，无标签组。B 右键菜单原生树和截图显示 Close、Close Other Tabs，两项均未标记 disabled；菜单未显示 Close Tabs Above、Close Tabs Below。没有点击菜单中的关闭动作。随后为下一执行点清理这些普通测试页并重建独立批次。  | qa-evidence/r2/SET-03-PER-01.png、qa-evidence/r2/SET-03-PER-04.png、qa-evidence/r2/SET-03-PER-05.png、qa-evidence/r2/SET-03-PER-02.png |
| SET-03-BAL | P0 | balanced/本项未独立实读 | pass | 普通标签集合仍为 {A,B,C}，自上而下 A/B/C；无 split 配对，无标签组。B 右键菜单显示 Close、Close Other Tabs，两项均未标记 disabled；未显示 Close Tabs Above、Close Tabs Below。没有点击菜单中的关闭动作。随后为 Comfortable 项清理普通测试页并重建独立批次。  | qa-evidence/r2/SET-03-BAL-01.png、qa-evidence/r2/SET-03-BAL-04.png、qa-evidence/r2/SET-03-BAL-05.png、qa-evidence/r2/SET-03-BAL-02.png |
| SET-03-COM | P0 | comfortable/本项未独立实读 | pass | 被测动作后集合仍为 {A,B,C}，从左到右 A/B/C；无 split 配对，无标签组。B 菜单显示 Close、Close Other Tabs，两项均未标记 disabled；未显示 Close Tabs to the Left、Close Tabs to the Right。未点击菜单中的关闭动作。菜单取证后执行 reset，新页打开编号与被测现场不同，未将重置页面作为保留证据。  | qa-evidence/r2/SET-03-COM-01.png、qa-evidence/r2/SET-03-COM-04.png、qa-evidence/r2/SET-03-COM-05.png、qa-evidence/r2/SET-03-COM-02.png |
| SET-04-PER | P0 | performance/本项未独立实读 | pass | 外部从上到下仍为 A、展开的 G[B,C]、D，四个测试页均保留，无 split。组标题菜单实际显示 New Tab in Group、Rename Group、Change Color、Collapse Group、Ungroup、Close Group。B 成员菜单实际显示 Pin、Duplicate、Copy Link、Open as Split、Add to Bookmark、Add to Folder、Move to New Group、Remove from Group、Move to Space、Close、Close Other Tabs。两个菜单均未见 Close Tabs Above、Close Tabs Below 或其他方向关闭项；记录后均用 Escape 收起。  | qa-evidence/r2/SET-04-PER-01.png、qa-evidence/r2/SET-04-PER-02.png |
| SET-04-BAL | P0 | balanced/本项未独立实读 | pass | 外部从上到下仍为 A、展开的 G[B,C]、D，四个测试页均保留，无 split。组标题菜单实际显示 New Tab in Group、Rename Group、Change Color、Collapse Group、Ungroup、Close Group。B 成员菜单实际显示 Pin、Duplicate、Copy Link、Open as Split、Add to Bookmark、Add to Folder、Move to New Group、Remove from Group、Move to Space、Close、Close Other Tabs。两个菜单均未见方向关闭项；记录后均用 Escape 收起。  | qa-evidence/r2/SET-04-BAL-01.png、qa-evidence/r2/SET-04-BAL-02.png |
| SET-04-COM | P0 | comfortable/本项未独立实读 | pass | 外部横向顺序仍为普通 A、展开的 G[B,C]、普通 D；G 标题显示成员数 2，B 活动，四个测试页均保留，无 split。组标题菜单实际显示 New Tab in Group、Rename Group、Change Color、Collapse Group、Ungroup、Close Group。B 成员菜单实际显示 Pin、Duplicate、Copy Link、Open as Split、Add to Bookmark Bar、Add to Folder、Move to New Group、Remove from Group、Move to Space、Close、Close Other Tabs。两个菜单均未见 Close Tabs to the Left、Close Tabs to the Right 或其他方向关闭项。最后收起菜单并保留实际结束状态。  | qa-evidence/r2/SET-04-COM-01.png、qa-evidence/r2/SET-04-COM-02.png |
| SET-05-PER | P0 | performance/General 实读 Display language=System Default；浏览器设置及菜单为英文。未切换语言。 | pass | 外部自上而下仍为普通 A、普通 B、普通 C、展开的 TC-PHI507-r2-SET-05-PER-G[D,E]。开启位置关闭后未重启，重新打开 B 菜单实见 Close Tabs Above、Close Tabs Below，两项均未标为 disabled；组标题菜单实见 Close Tabs Above Group，以及 disabled 的 Close Tabs Below Group。仅查看菜单，没有选择方向关闭项。结束取证后关闭菜单，页面集合与组成员未变。 首次打开 Settings 时，将一次 Computer Use 返回整体传给 text，导致工具图片编码被作为文本输出。随后改为仅输出原生文本块和真实 image；没有写文件。；清理旧测试组后，本应先处理删除确认，但预先编排的地址栏键盘序列继续执行；Return 确认了旧测试组删除，首次 A 导航未提交。已保存空白页现场并重新建立前置；未把该次导航当作页面已加载，也未在前置缺失时执行被测开关动作。 | qa-evidence/r2/SET-05-PER-01.png、qa-evidence/r2/SET-05-PER-02.png、qa-evidence/r2/SET-05-PER-03.png、qa-evidence/r2/SET-05-PER-SET-05-observation.json |
| SET-05-BAL | P0 | balanced/本项 General 重新实读 Display language=System Default；实际设置和菜单为英文。未切换语言。 | pass | 外部自上而下仍为普通 A、普通 B、普通 C、展开的 TC-PHI507-r2-SET-05-BAL-G[D,E]。开启位置关闭后未重启，B 菜单实见 Close Tabs Above、Close Tabs Below，两项均未标为 disabled；组标题菜单实见 Close Tabs Above Group，以及 disabled 的 Close Tabs Below Group。未选择任何方向关闭项。结束时菜单关闭，五个页面与组成员未变。 重命名组时，内存中的原生文本定位器同时匹配了元素行和工具附带的焦点描述，因多义主动抛错并在 set_value 调用前停止；未发生错误界面操作。已保存重命名对话框现场，随后仅匹配带数字索引的唯一原生元素行，继续完成尚未执行的重命名。 | qa-evidence/r2/SET-05-BAL-01.png、qa-evidence/r2/SET-05-BAL-02.png、qa-evidence/r2/SET-05-BAL-03.png、qa-evidence/r2/SET-05-BAL-SET-05-observation.json |
| SET-05-COM | P0 | comfortable/本项及收尾 General 均实读 Display language=System Default；浏览器界面及菜单为英文。未切换语言。 | pass | Comfortable 外部从左到右仍为普通 A、普通 B、普通 C、展开的 TC-PHI507-r2-SET-05-COM-G[D,E]，组标题显示 2。开启位置关闭后未重启，B 菜单实见 Close Tabs to the Left、Close Tabs to the Right，两项均未标为 disabled；组标题菜单实见 Close Tabs to the Left of Group，以及 disabled 的 Close Tabs to the Right of Group。没有选择方向关闭项。结束截图保存后仅恢复原始设置，没有再重建页面序列。  | qa-evidence/r2/SET-05-COM-01.png、qa-evidence/r2/SET-05-COM-02.png、qa-evidence/r2/SET-05-COM-SET-05-observation.json |
| SET-06-PER-off-off | P0 | performance/General 实读 Display language=System Default；设置与菜单为英文，符合当前 en。 | pass | 外部从上到下 A/B/C 均保留，无多选、无 split、无组。B 菜单显示 Close、Close Other Tabs，没有 Close Tabs Above 或 Close Tabs Below。  | qa-evidence/r2/SET-06-PER-off-off-03.png、qa-evidence/r2/SET-06-PER-off-off-01.png、qa-evidence/r2/SET-06-PER-off-off-02.png、qa-evidence/r2/SET-06-PER-off-off-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-PER-on-off | P0 | performance/System Default，实际设置及菜单英文。 | pass | C 关闭，外部从上到下保留 A/B；无多选、无 split、无组。B 菜单显示 Close、Close Other Tabs，没有 Above/Below 方向项。  | qa-evidence/r2/SET-06-PER-on-off-03.png、qa-evidence/r2/SET-06-PER-on-off-02.png、qa-evidence/r2/SET-06-PER-on-off-01.png、qa-evidence/r2/SET-06-PER-on-off-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-PER-off-on | P0 | performance/System Default，实际界面英文。 | pass | A/B/C 保留，外部顺序 A→B→C；无组、无 split。B 菜单出现 Close Tabs Above、Close Tabs Below，两项均可用；同时显示 Close 和 Close Other Tabs。  | qa-evidence/r2/SET-06-PER-off-on-03.png、qa-evidence/r2/SET-06-PER-off-on-02.png、qa-evidence/r2/SET-06-PER-off-on-01.png、qa-evidence/r2/SET-06-PER-off-on-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-PER-on-on | P0 | performance/System Default，实际界面英文。 | pass | C 关闭，外部从上到下 A/B。B 菜单有 Close Tabs Above（可用）、Close Tabs Below（disabled），以及 Close、Close Other Tabs；无组、无 split、无多选。  | qa-evidence/r2/SET-06-PER-on-on-03.png、qa-evidence/r2/SET-06-PER-on-on-02.png、qa-evidence/r2/SET-06-PER-on-on-01.png、qa-evidence/r2/SET-06-PER-on-on-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-BAL-off-off | P0 | balanced/System Default，设置和菜单英文。 | pass | A/B/C 全部保留，外部从上到下 A、B、C；B 菜单显示 Close 和 Close Other Tabs，没有 Above/Below 方向项；无组、无 split、无多选。  | qa-evidence/r2/SET-06-BAL-off-off-03.png、qa-evidence/r2/SET-06-BAL-off-off-02.png、qa-evidence/r2/SET-06-BAL-off-off-01.png、qa-evidence/r2/SET-06-BAL-off-off-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-BAL-on-off | P0 | balanced/System Default，实际界面英文。 | pass | C 关闭，外部从上到下保留 A/B；B 菜单没有 Above/Below 方向项，显示 Close、Close Other Tabs；无多选、无组、无 split。  | qa-evidence/r2/SET-06-BAL-on-off-03.png、qa-evidence/r2/SET-06-BAL-on-off-02.png、qa-evidence/r2/SET-06-BAL-on-off-01.png、qa-evidence/r2/SET-06-BAL-on-off-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-BAL-off-on | P0 | balanced/System Default，实际设置及菜单英文。 | pass | A/B/C 全部保留，外部顺序 A→B→C；B 菜单出现可用的 Close Tabs Above 和 Close Tabs Below，以及 Close、Close Other Tabs；无多选、无组、无 split。  | qa-evidence/r2/SET-06-BAL-off-on-03.png、qa-evidence/r2/SET-06-BAL-off-on-02.png、qa-evidence/r2/SET-06-BAL-off-on-01.png、qa-evidence/r2/SET-06-BAL-off-on-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-BAL-on-on | P0 | balanced/System Default，实际界面英文。 | pass | C 关闭，外部从上到下保留 A/B。B 菜单有 Close Tabs Above（可用）、Close Tabs Below（disabled），以及 Close、Close Other Tabs；无多选、无组、无 split。  | qa-evidence/r2/SET-06-BAL-on-on-03.png、qa-evidence/r2/SET-06-BAL-on-on-02.png、qa-evidence/r2/SET-06-BAL-on-on-01.png、qa-evidence/r2/SET-06-BAL-on-on-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-COM-off-off | P0 | comfortable/两次 General 均实读 System Default；实际界面英文。 | pass | 有效 attempt2 外部从左到右 A/B/C 全部保留，无多选、无组、无 split。B 菜单显示 Close、Close Other Tabs，没有 Close Tabs to the Left 或 Close Tabs to the Right。attempt1 的坐标双击不作为指定 C 动作的观察。 attempt1 查找原生描述 TC-C 的编排守卫停止，因为最新原生树仍为 New Tab；此时未发送双击。；随后坐标双击 (867,34) 未正确处理截图与点击坐标比例，实际落到 B；A/B/C 保留但 B 活动。此操作无效，保留 attempt1 before、原生树差异及 after，不作为 C 的双击结果。；识别同一坐标问题后，重新选择布局、设置 off/off、清理并重建 A/B/C，以最新原生第三个标签控件完成 attempt2；没有沿用无效现场作为有效前置。 | qa-evidence/r2/SET-06-COM-off-off-06.png、qa-evidence/r2/SET-06-COM-off-off-01.png、qa-evidence/r2/SET-06-COM-off-off-02.png、qa-evidence/r2/SET-06-COM-off-off-05.png、qa-evidence/r2/SET-06-COM-off-off-03.png、qa-evidence/r2/SET-06-COM-off-off-04.png、qa-evidence/r2/SET-06-COM-off-off-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-COM-on-off | P0 | comfortable/两次均实读 System Default，实际界面英文。 | pass | 有效 attempt2：C 关闭，外部从左到右保留 A/B，无多选、无组、无 split；B 菜单有 Close、Close Other Tabs，没有左右方向项。无效 attempt1 的实际结束集合为 A/C，未因 B 缺失而伪造其菜单。 attempt1 坐标双击 (867,34) 未正确处理截图与点击坐标比例，实际落在 B，导致 B 关闭、集合成为 A/C。；随后原生树中无法找到 B，编排守卫停止，没有打开错误对象菜单；保存 attempt1 failure 现场。；仅因上述无效操作重试；attempt2 重新选择 Comfortable、核对 on/off、清理并重建 A/B/C，改用最新原生第三个标签控件双击 C。 | qa-evidence/r2/SET-06-COM-on-off-06.png、qa-evidence/r2/SET-06-COM-on-off-01.png、qa-evidence/r2/SET-06-COM-on-off-02.png、qa-evidence/r2/SET-06-COM-on-off-05.png、qa-evidence/r2/SET-06-COM-on-off-03.png、qa-evidence/r2/SET-06-COM-on-off-04.png、qa-evidence/r2/SET-06-COM-on-off-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-COM-off-on | P0 | comfortable/General 实读 System Default；实际设置及菜单英文。 | pass | A/B/C 保留，外部从左到右 A、B、C；B 菜单有 Close Tabs to the Left、Close Tabs to the Right，两项均可用；同时显示 Close、Close Other Tabs。无多选、无组、无 split。  | qa-evidence/r2/SET-06-COM-off-on-03.png、qa-evidence/r2/SET-06-COM-off-on-01.png、qa-evidence/r2/SET-06-COM-off-on-02.png、qa-evidence/r2/SET-06-COM-off-on-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-06-COM-on-on | P0 | comfortable/本项 General 及收尾 General 均实读 Display language=System Default；实际浏览器、设置和菜单英文。 | pass | C 关闭，外部从左到右保留 A/B；B 菜单有 Close Tabs to the Left（可用）、Close Tabs to the Right（disabled），以及 Close、Close Other Tabs。无多选、无组、无 split。保存该结束证据后只恢复偏好，未重建序列。 收尾首次打开 Settings 后实际为 Guest 页，编排查找开关未找到即停止，没有发送错误点击；重读画面后原生选择 Advanced，随后完成恢复。此事发生在本项 after 证据保存之后。 | qa-evidence/r2/SET-06-COM-on-on-03.png、qa-evidence/r2/SET-06-COM-on-on-01.png、qa-evidence/r2/SET-06-COM-on-on-02.png、qa-evidence/r2/SET-06-COM-on-on-SET-06-observation.json、qa-evidence/r2/SET-06-toggle-transitions.log |
| SET-07-COMMON | P0 | once/重启前后 General 均显示 Display language=System Default；实际设置及菜单为英文；未切换语言。 | pass | 重启后 chrome 显示 A、B、G[C]，顺序及组计数 1 仍可见。Advanced 实读双击关闭 on、按位置关闭 off。普通 B 右键菜单显示 Close、Close Other Tabs；组菜单显示 New Tab in Group、Rename Group、Change Color、Collapse Group、Ungroup、Close Group；两者均未显示左右位置关闭项。C 在重启后至结束截图中内容区为空白且显示 Stop，未据标签标题推定页面已提交。 准备阶段查看 Window 菜单后，Escape 返回仍为菜单原生树；一次标记“attempt1 before”的 get_app_state 仅返回菜单树、无 image，未作为关键前截图使用。随后用该原生菜单明确暴露的 Cancel 动作关闭菜单，并补充 before-switch、before-restart 真图；未误点开关或重试被测动作。 | qa-evidence/r2/SET-07-COMMON-01.png、qa-evidence/r2/SET-07-COMMON-02.png、qa-evidence/r2/SET-07-COMMON-04.png、qa-evidence/r2/SET-07-COMMON-05.png、qa-evidence/r2/SET-07-COMMON-06.png、qa-evidence/r2/SET-07-COMMON-03.png、qa-evidence/r2/SET-07-COMMON-SET-07-observation.json |
| SET-08-COMMON | P1 | once/General 的 Display language 实读为 System Default；设置、窗口菜单和页签菜单实际为英文。本项未切换语言或重启。 | pass | 页签集合未被关闭或重排。重新开启位置功能后，S2 与 W2 的单页菜单均重新出现 disabled 的 Close Tabs Above/Below；W1/S1 的 F 菜单出现可用的 Close Tabs Above 和 disabled 的 Close Tabs Below。最终从 W2 打开的 Advanced 读到双击关闭 off、位置关闭 on。 复核关闭后W2/S2菜单均隐藏方向项，S2开启后各窗口重新显示；双击开关始终off。此前短时加载中止的尝试保留，未作为最终结果。 | qa-evidence/r2/SET-08-COMMON-01.png、qa-evidence/r2/SET-08-COMMON-02.png、qa-evidence/r2/SET-08-COMMON-03.png、qa-evidence/r2/SET-08-COMMON-SET-08-observation.json、qa-evidence/r2/SET-08-COMMON-04.png、qa-evidence/r2/SET-08-COMMON-05.png、qa-evidence/r2/SET-08-COMMON-06.png、qa-evidence/r2/SET-08-COMMON-07.png、qa-evidence/r2/SET-08-COMMON-08.png、qa-evidence/r2/SET-08-COMMON-09.png、qa-evidence/r2/SET-08-COMMON-10.png、qa-evidence/r2/SET-08-COMMON-11.png、qa-evidence/r2/SET-08-COMMON-SET-08-retry-observation.json |
| SET-09-COMMON-off | P0 | once/本项未独立实读 | blocked | 没有配套旧构建及其预置双击偏好，未执行升级测试。 缺配套旧构建，不能用当前值替代升级保留。 | 无（未执行） |
| SET-09-COMMON-on | P0 | once/本项未独立实读 | blocked | 没有配套旧构建及其预置双击偏好，未执行升级测试。 缺配套旧构建，不能用当前值替代升级保留。 | 无（未执行） |
| SET-10-PER | P0 | performance/General 为 System Default，浏览器菜单与设置实际显示英文；本项未切换语言或重启。 | pass | 本轮分段完成。原步骤：开启后：已有 B 消失，活动页转 C；新建普通 N 双击后消失，活动页转 C。关闭后：普通 A 保留并被选中；有效重试的组内 D 保留并高亮；新建 split[A,C] 双击 C 后两页仍在，焦点转 C；新建组内 split[D,E] 双击 E 后两页仍在，焦点转 E。最终顺序 split[A,C] → TC-G 内 split[D,E]，B/N 不在。；关闭后新建普通/组内普通补执行：两次双击后，真实集合均仍为普通 A、展开组 TC-PHI507-r2-SET10-fresh-PER[D,E]；无多选、无 split。A、D 的打开编号及输入标记前后一致；随后实见 E 原编号和标记。 本轮分段完成全部源步骤；既有B/新建N开启后关闭、关闭后两种新split见retry，关闭后新建普通和组内普通见fresh-surfaces。源执行点不是一次连续重跑；原无效尝试和补执行各自保留。 | qa-evidence/r2/SET-10-PER-01.png、qa-evidence/r2/SET-10-PER-SET-10-observation.json、qa-evidence/r2/SET-10-PER-02.png、qa-evidence/r2/SET-10-PER-03.png、qa-evidence/r2/SET-10-PER-04.png、qa-evidence/r2/SET-10-PER-05.png、qa-evidence/r2/SET-10-PER-06.png、qa-evidence/r2/SET-10-PER-07.png、qa-evidence/r2/SET-10-PER-08.png、qa-evidence/r2/SET-10-PER-09.png、qa-evidence/r2/SET-10-PER-10.png、qa-evidence/r2/SET-10-PER-11.png、qa-evidence/r2/SET-10-PER-12.png、qa-evidence/r2/SET-10-PER-13.png、qa-evidence/r2/SET-10-PER-14.png、qa-evidence/r2/SET-10-PER-15.png、qa-evidence/r2/SET-10-PER-16.png、qa-evidence/r2/SET-10-PER-17.png、qa-evidence/r2/SET-10-PER-SET-10-retry-observation.json、qa-evidence/r2/SET-10-PER-31.png、qa-evidence/r2/SET-10-PER-32.png、qa-evidence/r2/SET-10-PER-33.png、qa-evidence/r2/SET-10-PER-34.png、qa-evidence/r2/SET-10-PER-SET-10-fresh-surfaces-observation.json、qa-evidence/r2/SET-10-PER-18.png、qa-evidence/r2/SET-10-PER-19.png、qa-evidence/r2/SET-10-PER-20.png、qa-evidence/r2/SET-10-PER-21.png、qa-evidence/r2/SET-10-PER-22.png、qa-evidence/r2/SET-10-PER-23.png、qa-evidence/r2/SET-10-PER-24.png、qa-evidence/r2/SET-10-PER-25.png、qa-evidence/r2/SET-10-PER-26.png、qa-evidence/r2/SET-10-PER-27.png、qa-evidence/r2/SET-10-PER-28.png、qa-evidence/r2/SET-10-PER-29.png、qa-evidence/r2/SET-10-PER-30.png、qa-evidence/r2/SET-10-PER-SET-10-SET-10-PER-hit-diagnostic-observation.json |
| SET-10-BAL | P0 | balanced/System Default，浏览器设置与菜单英文；未切换语言或重启。 | pass | 本轮分段完成。原步骤：已有 B、新建 N 在开启后双击均从列表消失，活动页均转 C。关闭后双击 A、组内 D 均保留并切换高亮；原生建立普通 split[A,C] 后双击 C，两页保留、焦点转 C；建立组内 split[D,E] 后双击 E，两页和组保留、焦点转 E。最终顺序 split[A,C] → TC-G 内 split[D,E]。；关闭后新建普通/组内普通补执行：两次双击后均保留普通 A、展开组 TC-PHI507-r2-SET10-fresh-BAL[D,E]，顺序及成员未变；无多选、无 split。A、D 打开编号和输入标记前后一致，E 结束复核时也保持原身份。 本轮分段完成全部源步骤；既有B/新建N开启后关闭、关闭后两种新split见retry，关闭后新建普通和组内普通见fresh-surfaces。源执行点不是一次连续重跑；原无效尝试和补执行各自保留。 | qa-evidence/r2/SET-10-BAL-01.png、qa-evidence/r2/SET-10-BAL-02.png、qa-evidence/r2/SET-10-BAL-SET-10-observation.json、qa-evidence/r2/SET-10-BAL-03.png、qa-evidence/r2/SET-10-BAL-04.png、qa-evidence/r2/SET-10-BAL-05.png、qa-evidence/r2/SET-10-BAL-06.png、qa-evidence/r2/SET-10-BAL-07.png、qa-evidence/r2/SET-10-BAL-08.png、qa-evidence/r2/SET-10-BAL-09.png、qa-evidence/r2/SET-10-BAL-10.png、qa-evidence/r2/SET-10-BAL-11.png、qa-evidence/r2/SET-10-BAL-12.png、qa-evidence/r2/SET-10-BAL-13.png、qa-evidence/r2/SET-10-BAL-14.png、qa-evidence/r2/SET-10-BAL-15.png、qa-evidence/r2/SET-10-BAL-SET-10-retry-observation.json、qa-evidence/r2/SET-10-BAL-16.png、qa-evidence/r2/SET-10-BAL-17.png、qa-evidence/r2/SET-10-BAL-18.png、qa-evidence/r2/SET-10-BAL-19.png、qa-evidence/r2/SET-10-BAL-SET-10-fresh-surfaces-observation.json |
| SET-10-COM | P0 | comfortable/General 前后均实读 System Default，浏览器设置 UI 为英文；未切换语言、未重启。 | pass | 本轮分段完成。原步骤：开启后已有 B 消失并转 C；新建 N 双击后消失并转 C。关闭后普通 A、组内 D 双击均保留并被选中；新建普通 split[A,C] 双击 C 后配对保留、焦点转 C；新建组内 split[D,E] 双击 E 后配对和组保留、焦点转 E。结束集合为 split[A,C] → TC-G 内 split[D,E]。；关闭后新建普通A：普通 A 双击后仍保留相同编号和标记；当前集合为普通 A、展开组 TC-PHI507-r2-SET10-fresh-COM[D,E]，无多选、无 split。D/E 已逐页实见原编号和标记，但没有本项 D row 双击后的观察结果。；最后严格off/off的新建组内D续做：D 双击后仍存在，原编号及 KEEP 标记不变；随后逐页实见 E 原编号及标记。横向顺序仍为 A、组头、D、E，组计数仍为 2，无 split，未出现确认框。 源步骤在本轮分段完成，不是一次连续全例重跑。原步骤已完成既有B/新建N及关闭后新split；fresh完成关闭后新建普通A；两次COM续做分别为off/on条件偏差（不计严格条件通过）和正确off/off条件（已复核）。所有原记录保留。 | qa-evidence/r2/SET-10-COM-01.png、qa-evidence/r2/SET-10-COM-02.png、qa-evidence/r2/SET-10-COM-SET-10-observation.json、qa-evidence/r2/SET-10-COM-03.png、qa-evidence/r2/SET-10-COM-04.png、qa-evidence/r2/SET-10-COM-05.png、qa-evidence/r2/SET-10-COM-06.png、qa-evidence/r2/SET-10-COM-07.png、qa-evidence/r2/SET-10-COM-08.png、qa-evidence/r2/SET-10-COM-09.png、qa-evidence/r2/SET-10-COM-10.png、qa-evidence/r2/SET-10-COM-11.png、qa-evidence/r2/SET-10-COM-12.png、qa-evidence/r2/SET-10-COM-13.png、qa-evidence/r2/SET-10-COM-14.png、qa-evidence/r2/SET-10-COM-15.png、qa-evidence/r2/SET-10-COM-SET-10-retry-observation.json、qa-evidence/r2/SET-10-COM-16.png、qa-evidence/r2/SET-10-COM-17.png、qa-evidence/r2/SET-10-COM-SET-10-fresh-surfaces-observation.json、qa-evidence/r2/SET-10-COM-18.png、qa-evidence/r2/SET-10-COM-19.png、qa-evidence/r2/SET-10-COM-20.png、qa-evidence/r2/SET-10-COM-21.png、qa-evidence/r2/SET-10-COM-22.png、qa-evidence/r2/SET-10-COM-SET-10-SET-10-COM-complete-observation.json、qa-evidence/r2/SET-10-COM-23.png、qa-evidence/r2/SET-10-COM-24.png、qa-evidence/r2/SET-10-COM-25.png、qa-evidence/r2/SET-10-COM-26.png、qa-evidence/r2/SET-10-COM-SET-10-SET-10-COM-both-off-observation.json |
| DBL-01-PER | P0 | performance/General 实读 System Default，Settings 与浏览器菜单为英文；未切换语言。 | pass | attempt2 两步结束均为 A、B、C，B 单选且活动，无标签消失，无组或 split。attempt1 误操作后为 A 活动，A/B/C 仍在。 已核对三布局标题区与图标区真实前后截图及完整动作；PER的not_executed_reason只是说明第一次误命中后已重建重试、无最终遗漏，不是缺步骤。未关闭任何标签，B按预期活动；无效首次尝试独立保留。 | qa-evidence/r2/DBL-01-PER-01.png、qa-evidence/r2/DBL-01-PER-02.png、qa-evidence/r2/DBL-01-PER-03.png、qa-evidence/r2/DBL-01-PER-04.png、qa-evidence/r2/DBL-01-PER-05.png、qa-evidence/r2/DBL-01-PER-06.png、qa-evidence/r2/DBL-01-PER-07.png、qa-evidence/r2/DBL-01-PER-DBL-01-observation.json |
| DBL-01-BAL | P0 | balanced/General 实读 System Default，界面英文，未切换语言。 | pass | 两步后实际顺序均为 A、B、C，B 单选且活动，未见标签消失；无组、多选或 split。 已核对三布局标题区与图标区真实前后截图及完整动作；PER的not_executed_reason只是说明第一次误命中后已重建重试、无最终遗漏，不是缺步骤。未关闭任何标签，B按预期活动；无效首次尝试独立保留。 | qa-evidence/r2/DBL-01-BAL-01.png、qa-evidence/r2/DBL-01-BAL-02.png、qa-evidence/r2/DBL-01-BAL-03.png、qa-evidence/r2/DBL-01-BAL-04.png、qa-evidence/r2/DBL-01-BAL-DBL-01-observation.json |
| DBL-01-COM | P0 | comfortable/General 实读 System Default，界面英文，未切换语言；收尾值相同。 | pass | Comfortable 下两步后实际横向顺序均为 A、B、C，B 活动，无标签消失，无组、多选或 split。收尾恢复 Balanced 后同一 A/B/C 保留，B 单选。 已核对三布局标题区与图标区真实前后截图及完整动作；PER的not_executed_reason只是说明第一次误命中后已重建重试、无最终遗漏，不是缺步骤。未关闭任何标签，B按预期活动；无效首次尝试独立保留。 | qa-evidence/r2/DBL-01-COM-01.png、qa-evidence/r2/DBL-01-COM-02.png、qa-evidence/r2/DBL-01-COM-03.png、qa-evidence/r2/DBL-01-COM-04.png、qa-evidence/r2/DBL-01-COM-DBL-01-observation.json |
| DBL-02-PER | P0 | performance/General 实读 System Default，浏览器及设置界面为英文。 | pass | 稳定后的普通页顺序 A→C；B 标签行和容器不再出现。活动正文为 TC-C，编号与动作前相同；随后逐页核对 A 的编号也相同。无组、多选或 split。 三布局均已核对B活动的前置、B双击后仅A/C的真实集合及TC-C正文；A/C逐页编号保持，PID57596前后相同，无残留B容器。 | qa-evidence/r2/DBL-02-PER-01.png、qa-evidence/r2/DBL-02-PER-02.png、qa-evidence/r2/DBL-02-PER-DBL-02-observation.json |
| DBL-02-BAL | P0 | balanced/General 再读 System Default，界面为英文。 | pass | 稳定后的普通页顺序 A→C；B 标签行和容器不再出现。活动正文为 TC-C，编号与动作前相同；随后 A 的正文及编号也保持。无组、多选或 split。 三布局均已核对B活动的前置、B双击后仅A/C的真实集合及TC-C正文；A/C逐页编号保持，PID57596前后相同，无残留B容器。 | qa-evidence/r2/DBL-02-BAL-01.png、qa-evidence/r2/DBL-02-BAL-02.png、qa-evidence/r2/DBL-02-BAL-DBL-02-observation.json |
| DBL-02-COM | P0 | comfortable/General 再读 System Default，界面为英文；收尾仍为该值。 | pass | 稳定后的普通页顺序 A→C；B 的 tabStripTab 容器及标题不再出现。活动正文为 TC-C，A/C 的打开编号均与动作前相同。最终保留此两页，无组、多选或 split。 三布局均已核对B活动的前置、B双击后仅A/C的真实集合及TC-C正文；A/C逐页编号保持，PID57596前后相同，无残留B容器。 | qa-evidence/r2/DBL-02-COM-01.png、qa-evidence/r2/DBL-02-COM-02.png、qa-evidence/r2/DBL-02-COM-DBL-02-observation.json |
| DBL-03-PER | P0 | performance/General 实读 System Default；浏览器和设置界面为英文，未切换语言。 | pass | 两个变体的原生列表均为 A→C，B 不再出现；A/C 的打开编号与动作前一致，输入框仍为空。 三布局标题与图标两个变体均重建前置；B为非活动页，六次双击均仅移除B，逐页A/C编号保持，原图正文为仍存在的TC-C。COM收尾打开Guest后的定位守卫错误发生在被测动作之后，已保留现场且未点击错误开关。 | qa-evidence/r2/DBL-03-PER-01.png、qa-evidence/r2/DBL-03-PER-02.png、qa-evidence/r2/DBL-03-PER-03.png、qa-evidence/r2/DBL-03-PER-04.png、qa-evidence/r2/DBL-03-PER-DBL-03-observation.json |
| DBL-03-BAL | P0 | balanced/General 实读 System Default；浏览器和设置界面为英文。 | pass | 两个变体的原生列表均为 A→C，B 不再出现；A/C 的打开编号与动作前一致，输入框仍为空。 三布局标题与图标两个变体均重建前置；B为非活动页，六次双击均仅移除B，逐页A/C编号保持，原图正文为仍存在的TC-C。COM收尾打开Guest后的定位守卫错误发生在被测动作之后，已保留现场且未点击错误开关。 | qa-evidence/r2/DBL-03-BAL-01.png、qa-evidence/r2/DBL-03-BAL-02.png、qa-evidence/r2/DBL-03-BAL-03.png、qa-evidence/r2/DBL-03-BAL-04.png、qa-evidence/r2/DBL-03-BAL-DBL-03-observation.json |
| DBL-03-COM | P0 | comfortable/本项及收尾 General 均实读 System Default，界面为英文；未切换语言。 | pass | 两个变体的横向标签集合均为 A→C，B 不再出现；A/C 的打开编号与动作前一致，输入框仍为空。最后保留 icon 批次 A/C。 三布局标题与图标两个变体均重建前置；B为非活动页，六次双击均仅移除B，逐页A/C编号保持，原图正文为仍存在的TC-C。COM收尾打开Guest后的定位守卫错误发生在被测动作之后，已保留现场且未点击错误开关。 | qa-evidence/r2/DBL-03-COM-01.png、qa-evidence/r2/DBL-03-COM-02.png、qa-evidence/r2/DBL-03-COM-03.png、qa-evidence/r2/DBL-03-COM-04.png、qa-evidence/r2/DBL-03-COM-05.png、qa-evidence/r2/DBL-03-COM-DBL-03-observation.json |
| DBL-04-PER | P0 | performance/General 显示 System Default；浏览器设置与菜单为英文。 | pass | 原生顺序 A/C/D；B 不再列出，split 配对消失，C 以单页显示。A、C、D 的正文和原打开编号仍可见；未出现批量关闭界面。 已查看三个布局的真实分屏前图和单页后图，B半格双击仅移除B，原split容器消失，C成为单页；A/C/D逐页原编号保持，关键前后PID71817相同。 | qa-evidence/r2/DBL-04-PER-01.png、qa-evidence/r2/DBL-04-PER-02.png、qa-evidence/r2/DBL-04-PER-DBL-04-observation.json |
| DBL-04-BAL | P0 | balanced/General 显示 System Default；英文界面。 | pass | 原生顺序 A/C/D；B 不再列出，C 为独立单页，split 配对消失。A、C、D 原打开编号继续可见；未出现批量关闭界面。 已查看三个布局的真实分屏前图和单页后图，B半格双击仅移除B，原split容器消失，C成为单页；A/C/D逐页原编号保持，关键前后PID71817相同。 | qa-evidence/r2/DBL-04-BAL-01.png、qa-evidence/r2/DBL-04-BAL-02.png、qa-evidence/r2/DBL-04-BAL-DBL-04-observation.json |
| DBL-04-COM | P0 | comfortable/General 显示 System Default；英文界面。 | pass | 横向标签顺序 A/C/D；B 不再列出，原 splitPair 容器已成为 C 的普通 tabStripTab。C 为单页，A/C/D 原打开编号均继续可见；未出现批量关闭界面。 已查看三个布局的真实分屏前图和单页后图，B半格双击仅移除B，原split容器消失，C成为单页；A/C/D逐页原编号保持，关键前后PID71817相同。 | qa-evidence/r2/DBL-04-COM-01.png、qa-evidence/r2/DBL-04-COM-02.png、qa-evidence/r2/DBL-04-COM-DBL-04-observation.json |
| DBL-05-PER | P0 | performance/General 为 System Default，原生界面及菜单为英文；未切换语言。 | pass | 两次被测双击后均为 A/B/D，C 不再出现在原生列表，split 消失，B 成为独立普通页；无组、无多选。 已逐布局查看first/swap两分支前后完整截图及first-B-identity；B保持活动时点击非焦点C，Reverse Panes后改点另一侧C，两次均仅移除C且B变单页，B的原编号/KEEP标记及A/D编号保持。PER setup的仅modifier调用报错单独保留，不计产品缺陷。 | qa-evidence/r2/DBL-05-PER-01.png、qa-evidence/r2/DBL-05-PER-02.png、qa-evidence/r2/DBL-05-PER-03.png、qa-evidence/r2/DBL-05-PER-06.png、qa-evidence/r2/DBL-05-PER-04.png、qa-evidence/r2/DBL-05-PER-05.png、qa-evidence/r2/DBL-05-PER-DBL-05-observation.json |
| DBL-05-BAL | P0 | balanced/General 仍为 System Default，原生英文界面。 | pass | 两次双击后原生列表均为 A/B/D，C 消失、split 消失，B 为独立普通页；无组、无多选。 已逐布局查看first/swap两分支前后完整截图及first-B-identity；B保持活动时点击非焦点C，Reverse Panes后改点另一侧C，两次均仅移除C且B变单页，B的原编号/KEEP标记及A/D编号保持。PER setup的仅modifier调用报错单独保留，不计产品缺陷。 | qa-evidence/r2/DBL-05-BAL-01.png、qa-evidence/r2/DBL-05-BAL-02.png、qa-evidence/r2/DBL-05-BAL-05.png、qa-evidence/r2/DBL-05-BAL-03.png、qa-evidence/r2/DBL-05-BAL-04.png、qa-evidence/r2/DBL-05-BAL-DBL-05-observation.json |
| DBL-05-COM | P0 | comfortable/General 为 System Default，原生英文界面；本轮未更改语言。 | pass | 两次双击后横向标签从左到右均为 A/B/D，C 消失、split 消失，B 为独立普通页；无组、无多选。最后保留第二分支实际结束集合。 已逐布局查看first/swap两分支前后完整截图及first-B-identity；B保持活动时点击非焦点C，Reverse Panes后改点另一侧C，两次均仅移除C且B变单页，B的原编号/KEEP标记及A/D编号保持。PER setup的仅modifier调用报错单独保留，不计产品缺陷。 | qa-evidence/r2/DBL-05-COM-01.png、qa-evidence/r2/DBL-05-COM-02.png、qa-evidence/r2/DBL-05-COM-05.png、qa-evidence/r2/DBL-05-COM-03.png、qa-evidence/r2/DBL-05-COM-04.png、qa-evidence/r2/DBL-05-COM-DBL-05-observation.json |
| DBL-06-PER | P0 | performance/System Default；浏览器设置与菜单为英文，未切换语言。 | pass | B 分支：G[A,C,D]，B 消失，B/C 分屏解除，A/C/D 仍在原组。C 分支：G[A,B,D]，C 消失，分屏解除，A/B/D 仍在原组。两次双击后的首次状态读取均只少一个目标页。 Ripley 已逐张复核三布局 B/C 两独立分支的关键前后截图，并核对原生观察中的 PID、组成员、页面打开编号与 KEEP 标记。B 目标关闭后为 G[A,C,D]，C 目标关闭后为 G[A,B,D]，分屏解除而组和存活页状态保留。前置拖组失败、空 Space 和匹配守卫中止均保留为准备过程，不计被测双击结果。 | qa-evidence/r2/DBL-06-PER-01.png、qa-evidence/r2/DBL-06-PER-02.png、qa-evidence/r2/DBL-06-PER-03.png、qa-evidence/r2/DBL-06-PER-04.png、qa-evidence/r2/DBL-06-PER-05.png、qa-evidence/r2/DBL-06-PER-DBL-06-observation.json |
| DBL-06-BAL | P0 | balanced/System Default，实际英文 chrome；未切换语言。 | pass | B 分支：G[A,C,D]，B 消失，分屏解除，A/C/D 保留组关系。C 分支：G[A,B,D]，C 消失，分屏解除，A/B/D 保留组关系。两次双击后的首次状态读取均只少一个目标页。 Ripley 已逐张复核三布局 B/C 两独立分支的关键前后截图，并核对原生观察中的 PID、组成员、页面打开编号与 KEEP 标记。B 目标关闭后为 G[A,C,D]，C 目标关闭后为 G[A,B,D]，分屏解除而组和存活页状态保留。前置拖组失败、空 Space 和匹配守卫中止均保留为准备过程，不计被测双击结果。 | qa-evidence/r2/DBL-06-BAL-01.png、qa-evidence/r2/DBL-06-BAL-02.png、qa-evidence/r2/DBL-06-BAL-03.png、qa-evidence/r2/DBL-06-BAL-04.png、qa-evidence/r2/DBL-06-BAL-DBL-06-observation.json |
| DBL-06-COM | P0 | comfortable/General 起始及最终实读 System Default，实际界面英文；未切换语言、未触发重启。 | pass | B 分支：组 TC-PHI507-r2-DBL-06-COM-B-G 中顺序 A/C/D，B 消失，splitPair 解除。C 分支：组 TC-PHI507-r2-DBL-06-COM-C-G 中顺序 A/B/D，C 消失，splitPair 解除。两次首次结束读取均只少一个目标页，余下三页仍在原组。 Ripley 已逐张复核三布局 B/C 两独立分支的关键前后截图，并核对原生观察中的 PID、组成员、页面打开编号与 KEEP 标记。B 目标关闭后为 G[A,C,D]，C 目标关闭后为 G[A,B,D]，分屏解除而组和存活页状态保留。前置拖组失败、空 Space 和匹配守卫中止均保留为准备过程，不计被测双击结果。 | qa-evidence/r2/DBL-06-COM-01.png、qa-evidence/r2/DBL-06-COM-02.png、qa-evidence/r2/DBL-06-COM-03.png、qa-evidence/r2/DBL-06-COM-04.png、qa-evidence/r2/DBL-06-COM-05.png、qa-evidence/r2/DBL-06-COM-DBL-06-observation.json |
| DBL-07-PER-command | P1 | performance/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-PER-shift | P1 | performance/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-PER-option | P1 | performance/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-PER-control | P1 | performance/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-BAL-command | P1 | balanced/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-BAL-shift | P1 | balanced/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-BAL-option | P1 | balanced/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-BAL-control | P1 | balanced/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-COM-command | P1 | comfortable/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-COM-shift | P1 | comfortable/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-COM-option | P1 | comfortable/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-07-COM-control | P1 | comfortable/本项未独立实读 | blocked | 源步骤明确要求按住修饰键并使用真实鼠标/触控板。本轮只能使用Computer Use，其click接口没有modifier-hold字段，未取得真实设备事件；没有用按下再松开修饰键后双击伪造覆盖。 仅记录工具接口和环境能力限制，未实际执行本执行点动作；不把它记成产品失败。；本变体缺手册要求的真实修饰键+物理设备双击输入能力。 | 无（未执行） |
| DBL-08-PER | P1 | performance/General 为 System Default；浏览器与设置界面英文，未切换语言。 | blocked | attempt1 拖动后即时实读 A/B/C，B 仍存在，未确认重排；随后作为无效操作重建。attempt2 最终为 A/B/C，三页独立，无 split、无组、无多选，活动页 C；C 关闭按钮动作未执行。 Ripley 已复核三布局14张完整关键/无效现场图和原生身份观察。单击后的 B 存活；指定拖动未建立重排，Performance 两次尝试均保留 A/B/C，Balanced 在随后额外内容点击后出现 New Tab/B 分屏，Comfortable 拖动调用后出现 B/New Tab 分屏；不能据此确认有效的重排手势或产品缺陷。C 关闭控件未可靠定位，按钮步骤未执行，不用菜单/快捷键替代。本项保留部分执行，后续先核查 CU 拖动返回与动态投放位置后再定向补测。；未执行“只点击 C 的关闭按钮一次”：选中 C，并尝试通过其右侧原生上下文菜单及取消使控件可见后，画面仍未确认到 C 的关闭图标，原生树也未暴露标签关闭按钮。没有以菜单 Close、快捷键或中键替代。拖动调用已执行，但未确认 B 到达另一页序位置。；部分执行，未判通过。 | qa-evidence/r2/DBL-08-PER-01.png、qa-evidence/r2/DBL-08-PER-02.png、qa-evidence/r2/DBL-08-PER-03.png、qa-evidence/r2/DBL-08-PER-04.png、qa-evidence/r2/DBL-08-PER-05.png、qa-evidence/r2/DBL-08-PER-06.png、qa-evidence/r2/DBL-08-PER-DBL-08-observation.json |
| DBL-08-BAL | P1 | balanced/General 实读 System Default；设置及浏览器界面英文，未切换语言。 | blocked | 外部纵向顺序为 A /（New Tab + B 分屏配对）/ C；A、B、C 均仍列出，C 为独立普通页且未关闭。额外内容区点击后的分屏现场中，New Tab 在左、B 在右，B 的编号未变。 Ripley 已复核三布局14张完整关键/无效现场图和原生身份观察。单击后的 B 存活；指定拖动未建立重排，Performance 两次尝试均保留 A/B/C，Balanced 在随后额外内容点击后出现 New Tab/B 分屏，Comfortable 拖动调用后出现 B/New Tab 分屏；不能据此确认有效的重排手势或产品缺陷。C 关闭控件未可靠定位，按钮步骤未执行，不用菜单/快捷键替代。本项保留部分执行，后续先核查 CU 拖动返回与动态投放位置后再定向补测。；未执行 C 关闭按钮单击：独立选中 C 后，画面未确认到标签关闭图标，原生树未暴露 C 的关闭按钮。没有以其他关闭方式替代。B 拖动调用已执行，但未观察到预定的页序移动。；部分执行，未判通过。 | qa-evidence/r2/DBL-08-BAL-01.png、qa-evidence/r2/DBL-08-BAL-02.png、qa-evidence/r2/DBL-08-BAL-03.png、qa-evidence/r2/DBL-08-BAL-04.png、qa-evidence/r2/DBL-08-BAL-DBL-08-observation.json |
| DBL-08-COM | P1 | comfortable/General 实读 System Default；浏览器及设置界面英文，未切换语言。 | blocked | 外部横向顺序为 A /（B + New Tab splitPair）/ C；分屏现场中 B 在左、New Tab 在右。B 仍存在且打开编号未变；A、C 为独立普通页。结束活动页 C，C 未关闭，无组、无多选。 Ripley 已复核三布局14张完整关键/无效现场图和原生身份观察。单击后的 B 存活；指定拖动未建立重排，Performance 两次尝试均保留 A/B/C，Balanced 在随后额外内容点击后出现 New Tab/B 分屏，Comfortable 拖动调用后出现 B/New Tab 分屏；不能据此确认有效的重排手势或产品缺陷。C 关闭控件未可靠定位，按钮步骤未执行，不用菜单/快捷键替代。本项保留部分执行，后续先核查 CU 拖动返回与动态投放位置后再定向补测。；未执行 C 关闭按钮单击：C 已独立选中，但画面未确认到 C 的关闭图标，原生树仅暴露其 tabStripTab 容器，没有标签关闭按钮。未用菜单或快捷键替代。B 拖动调用已执行，实际产生 splitPair，未观察到目标页序移动。；部分执行，未判通过。 | qa-evidence/r2/DBL-08-COM-01.png、qa-evidence/r2/DBL-08-COM-02.png、qa-evidence/r2/DBL-08-COM-03.png、qa-evidence/r2/DBL-08-COM-04.png、qa-evidence/r2/DBL-08-COM-DBL-08-observation.json |
| DBL-09-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-09-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-09-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-10-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-10-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-10-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-11-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-11-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-11-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-12-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-12-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-12-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-13-PER-cancel | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-13-PER-leave | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-13-BAL-cancel | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-13-BAL-leave | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-13-COM-cancel | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-13-COM-leave | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-14-PER-cancel | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-14-PER-leave | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-14-BAL-cancel | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-14-BAL-leave | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-14-COM-cancel | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-14-COM-leave | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-15-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-15-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-15-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-16-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-16-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-16-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-PER-command | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-PER-shift | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-PER-option | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-PER-control | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-BAL-command | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-BAL-shift | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-BAL-option | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-BAL-control | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-COM-command | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-COM-shift | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-COM-option | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-17-COM-control | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-18-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-18-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-18-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-19-PER | P0 | performance/本项未独立实读 | skipped | 验收双击尚未完成。上次中断前做过普通/分屏/组内分屏准备和音频控件定位，未发现保存动作中的click_count2/3请求；恢复后补做CU悬停能力诊断，仍未确认Close控件。该诊断不计源用例通过，后续独立分支继续执行。 上次完整结构化结果未返回，77幅原图及动作记录已恢复，未丢弃；能力诊断详见diagnostics，验收结果仍pending。；本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | qa-evidence/r2/DBL-19-PER-01.png、qa-evidence/r2/DBL-19-PER-02.png、qa-evidence/r2/DBL-19-PER-03.png、qa-evidence/r2/DBL-19-PER-04.png、qa-evidence/r2/DBL-19-PER-05.png、qa-evidence/r2/DBL-19-PER-DBL-19-DBL-19-PER-visibility-probe-observation.json |
| DBL-19-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-19-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-20-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-20-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-20-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-21-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-21-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-21-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-22-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-22-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-22-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-23-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-23-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| DBL-23-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-01-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-01-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-01-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-02-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-02-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-02-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-03-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-03-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-03-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-04-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-04-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-04-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-05-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-05-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-05-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-06-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-06-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-06-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-07-COMMON | P1 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-08-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-08-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-08-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-09-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-09-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-09-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-10-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-10-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-10-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-11-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-11-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-11-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-12-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-12-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-12-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-13-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-13-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-13-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-14-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-14-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-14-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-15-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-15-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| POS-15-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-01-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-01-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-01-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-02-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-02-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-02-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-03-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-03-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-03-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-04-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-04-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-04-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-05-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-05-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-05-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-06-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-06-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-06-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-07-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-07-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-07-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-08-PER | P2 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-08-BAL | P2 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-08-COM | P2 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-09-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-09-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-09-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-10-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-10-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-10-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-11-PER-cancel | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-11-PER-leave | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-11-BAL-cancel | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-11-BAL-leave | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-11-COM-cancel | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-11-COM-leave | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-12-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-12-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-12-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-13-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-13-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-13-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-14-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-14-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-14-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-15-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-15-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-15-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-16-PER | P2 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-16-BAL | P2 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SPL-16-COM | P2 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-01-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-01-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-01-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-02-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-02-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-02-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-03-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-03-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-03-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-04-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-04-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-04-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-05-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-05-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-05-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-06-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-06-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-07-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-07-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-07-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-08-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-08-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-08-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-09-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-09-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-09-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-10-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-10-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-10-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-11-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-11-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| PIN-11-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-01-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-01-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-01-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-02-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-02-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-02-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-03-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-03-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-03-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-04-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-04-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-04-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-05-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-05-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-05-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-06-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-06-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-06-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-07-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-07-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-07-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-08-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-08-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-09-COMMON | P1 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-10-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-10-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-10-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-11-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-11-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-11-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-12-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-12-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-12-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-13-PER-cancel | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-13-PER-leave | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-13-BAL-cancel | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-13-BAL-leave | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-13-COM-cancel | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-13-COM-leave | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-14-PER-cancel | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-14-PER-leave | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-14-BAL-cancel | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-14-BAL-leave | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-14-COM-cancel | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-14-COM-leave | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-15-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-15-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-15-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-16-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-16-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-16-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-17-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-17-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-17-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-18-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-18-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| GRP-18-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-01-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-01-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-02-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-02-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-03-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-03-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-03-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-04-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-05-COMMON | P1 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-06-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-06-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-06-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-07-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-07-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-08-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-08-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-09-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-09-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-09-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-10-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-10-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-11-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-11-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-12-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-12-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| BMK-12-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-01-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-01-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-01-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-02-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-02-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-02-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-03-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-03-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-03-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-04-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-04-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-04-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-05-COMMON | P1 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-06-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-06-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-06-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-07-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-07-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-07-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-08-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-08-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-08-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-09-PER | P2 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SEL-09-BAL | P2 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-01-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-01-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-01-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-02-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-02-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-02-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-03-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-03-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-04-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-04-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-04-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-05-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-05-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-05-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-06-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-06-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-07-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-07-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-08-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-08-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-09-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-09-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-09-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-10-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-10-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-10-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-11-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-11-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-11-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-12-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-12-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-12-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-13-PER-reader | P2 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-13-PER-peek | P2 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-13-PER-sidecar | P2 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-13-BAL-reader | P2 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-13-BAL-peek | P2 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-13-BAL-sidecar | P2 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-13-COM-reader | P2 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-13-COM-peek | P2 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-13-COM-sidecar | P2 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-14-PER-audio | P2 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-14-PER-download | P2 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-14-BAL-audio | P2 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-14-BAL-download | P2 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-14-COM-audio | P2 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| LIFE-14-COM-download | P2 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-01-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-01-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-01-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-02-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-02-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-02-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-03-COMMON | P1 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-04-COMMON | P1 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-05-COMMON | P1 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-06-COMMON | P1 | once/本项未独立实读 | blocked | 本包为 OpenSource；说明明确没有 Phi 登录、AI、Sentinel 与自动升级。本执行点的官方功能不可用，未执行。 包内说明文本在r1取得，本轮沿用文档，不沿用r1测试结果；本轮实际包身份另见installed-identity.json。；缺官方 AI/账号迁移配套构建；本轮不登录真实账户。 | qa-evidence/r2/package-README-original.txt、qa-evidence/r2/installed-identity.json |
| SCOPE-07-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-07-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-08-COMMON | P1 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-09-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-09-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-09-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-10-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-10-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-10-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-11-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-11-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-11-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-12-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-12-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-12-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-13-PER-pin | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-13-PER-pin-split | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-13-PER-bookmark | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-13-PER-bookmark-split | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-13-BAL-pin | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-13-BAL-pin-split | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-13-BAL-bookmark | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-13-BAL-bookmark-split | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-14-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-14-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-14-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-15-PER | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-15-BAL | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-15-COM | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-16-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-16-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-16-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-17-COMMON | P2 | once/本项未独立实读 | blocked | 本包为 OpenSource；说明明确没有 Phi 登录、AI、Sentinel 与自动升级。本执行点的官方功能不可用，未执行。 包内说明文本在r1取得，本轮沿用文档，不沿用r1测试结果；本轮实际包身份另见installed-identity.json。；缺官方 AI/账号迁移配套构建；本轮不登录真实账户。 | qa-evidence/r2/package-README-original.txt、qa-evidence/r2/installed-identity.json |
| SCOPE-18-PER-cancel | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-18-PER-leave | P0 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-18-BAL-cancel | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-18-BAL-leave | P0 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-18-COM-cancel | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-18-COM-leave | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-19-COM-pin | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-19-COM-pin-split | P0 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| SCOPE-20-COMMON | P1 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-01-PER | P0 | performance/zh-Hans | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-01-BAL | P0 | balanced/zh-Hans | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-01-COM | P0 | comfortable/zh-Hans | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-PER-en | P1 | performance/en | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-PER-zh-Hant | P1 | performance/zh-Hant | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-PER-ja | P1 | performance/ja | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-PER-ko | P1 | performance/ko | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-PER-de | P1 | performance/de | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-PER-fr | P1 | performance/fr | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-PER-es | P1 | performance/es | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-PER-nl | P1 | performance/nl | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-BAL-en | P1 | balanced/en | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-BAL-zh-Hant | P1 | balanced/zh-Hant | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-BAL-ja | P1 | balanced/ja | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-BAL-ko | P1 | balanced/ko | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-BAL-de | P1 | balanced/de | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-BAL-fr | P1 | balanced/fr | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-BAL-es | P1 | balanced/es | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-BAL-nl | P1 | balanced/nl | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-COM-en | P1 | comfortable/en | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-COM-zh-Hant | P1 | comfortable/zh-Hant | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-COM-ja | P1 | comfortable/ja | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-COM-ko | P1 | comfortable/ko | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-COM-de | P1 | comfortable/de | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-COM-fr | P1 | comfortable/fr | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-COM-es | P1 | comfortable/es | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-02-COM-nl | P1 | comfortable/nl | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-03-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-03-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-04-COMMON | P1 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-05-COMMON | P0 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | qa-evidence/r2/VIS-05-COMMON-01.png、qa-evidence/r2/VIS-05-COMMON-02.png、qa-evidence/r2/VIS-05-COMMON-03.png、qa-evidence/r2/VIS-05-COMMON-VIS-05-checkpoint-cleanup-observation.json |
| VIS-06-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-06-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-06-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-07-PER-mouse | P1 | performance/本项未独立实读 | blocked | 本轮使用 Computer Use 注入原生点击，未取得可区分并核验的真实物理鼠标/触控板操作，未执行本变体硬件验收。 Computer Use 注入点击不能证明真实鼠标/触控板覆盖。 | 无（未执行） |
| VIS-07-PER-trackpad | P1 | performance/本项未独立实读 | blocked | 本轮使用 Computer Use 注入原生点击，未取得可区分并核验的真实物理鼠标/触控板操作，未执行本变体硬件验收。 Computer Use 注入点击不能证明真实鼠标/触控板覆盖。 | 无（未执行） |
| VIS-07-BAL-mouse | P1 | balanced/本项未独立实读 | blocked | 本轮使用 Computer Use 注入原生点击，未取得可区分并核验的真实物理鼠标/触控板操作，未执行本变体硬件验收。 Computer Use 注入点击不能证明真实鼠标/触控板覆盖。 | 无（未执行） |
| VIS-07-BAL-trackpad | P1 | balanced/本项未独立实读 | blocked | 本轮使用 Computer Use 注入原生点击，未取得可区分并核验的真实物理鼠标/触控板操作，未执行本变体硬件验收。 Computer Use 注入点击不能证明真实鼠标/触控板覆盖。 | 无（未执行） |
| VIS-07-COM-mouse | P1 | comfortable/本项未独立实读 | blocked | 本轮使用 Computer Use 注入原生点击，未取得可区分并核验的真实物理鼠标/触控板操作，未执行本变体硬件验收。 Computer Use 注入点击不能证明真实鼠标/触控板覆盖。 | 无（未执行） |
| VIS-07-COM-trackpad | P1 | comfortable/本项未独立实读 | blocked | 本轮使用 Computer Use 注入原生点击，未取得可区分并核验的真实物理鼠标/触控板操作，未执行本变体硬件验收。 Computer Use 注入点击不能证明真实鼠标/触控板覆盖。 | 无（未执行） |
| VIS-08-PER | P1 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-08-BAL | P1 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| VIS-08-COM | P1 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| EXP-01-PER | P2 | performance/本项未独立实读 | blocked | 原步骤要求真实设备跨目标快速点击，并记录系统click-count；本轮只有Computer Use注入输入，不能证明真实鼠标/触控板事件。产品跨目标手势的期望在手册中也仍待确认。未执行，未以注入点击冒充物理设备覆盖。 缺手册要求的真实输入设备与已确定的跨目标手势判定标准。 | qa-evidence/r2/computer-use-tool-contract.json |
| EXP-01-BAL | P2 | balanced/本项未独立实读 | blocked | 原步骤要求真实设备跨目标快速点击，并记录系统click-count；本轮只有Computer Use注入输入，不能证明真实鼠标/触控板事件。产品跨目标手势的期望在手册中也仍待确认。未执行，未以注入点击冒充物理设备覆盖。 缺手册要求的真实输入设备与已确定的跨目标手势判定标准。 | qa-evidence/r2/computer-use-tool-contract.json |
| EXP-01-COM | P2 | comfortable/本项未独立实读 | blocked | 原步骤要求真实设备跨目标快速点击，并记录系统click-count；本轮只有Computer Use注入输入，不能证明真实鼠标/触控板事件。产品跨目标手势的期望在手册中也仍待确认。未执行，未以注入点击冒充物理设备覆盖。 缺手册要求的真实输入设备与已确定的跨目标手势判定标准。 | qa-evidence/r2/computer-use-tool-contract.json |
| EXP-02-PER | P2 | performance/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| EXP-02-BAL | P2 | balanced/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| EXP-02-COM | P2 | comfortable/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| EXP-03-COMMON | P2 | once/本项未独立实读 | skipped | 本轮检查点尚未执行，继续进入后续执行轮；不表示产品失败或永久阻断。 本轮尚未执行，任务继续；检查点中的skipped不改变累计台账的pending。 | 无（未执行） |
| EXP-04-COMMON | P2 | once/本项未独立实读 | blocked | 仅有 Framework 156.0.8078.52 本包，未取得配套旧 Framework 构建，未混换 Framework。 缺受支持的配套旧 Framework 二进制包。 | qa-evidence/r2/installed-identity.json |
