# Lexington：查询某个站点的 Memory 采集开关

开关保存在 Phi 侧，按账号和 Chromium Profile 隔离。
Lexington 通过 `memory.getSiteCollectionEnabled` 查询。

## 直接运行

使用已包含此 API 的 Phi 版本，在 Lexington 的后台 / Service Worker
DevTools 控制台中运行下面的代码，将示例 URL 换成目标页面。
接口仅允许 Lexington 的固定扩展 ID `pjgdkljlcbjgedgeppodjijjphfcplno` 调用，
不能在普通网页控制台中直接查询。

```javascript
const profile = await chrome.phinomenonPrivate.getProfileInfo();
const raw = await chrome.phinomenonPrivate.sendMessageToApp(
  "memory.getSiteCollectionEnabled",
  {
    profileId: profile.id,
    host: new URL("https://www.example.com/article").hostname,
  }
);
const result = JSON.parse(raw);
console.log(result);
```

采集开关关闭时的返回示例：

```json
{"profileId":"Default","host":"www.example.com","enabled":false}
```

| 字段 | 含义 |
| --- | --- |
| `profileId` | 使用 `getProfileInfo().id`，例如 `Default` 或 `Profile 2`。不要传 Space ID 或 Profile 的显示名称。 |
| `host` | 仅传 ASCII / Punycode 主机名。用 `URL.hostname` 提取，不包含协议、端口、路径或通配符。 |
| `enabled` | `true` 表示该站点的采集开关开启，`false` 表示关闭。 |

请求参数直接传对象；返回值是 JSON **字符串**，需要调用一次 `JSON.parse`。
返回的 `host` 会转为小写，并去掉末尾的一个点。

## 接入注意事项

- **默认开启**：没有保存覆盖设置时，返回 `enabled: true`。查询使用 Phi 当前账号和传入的 Profile ID，各账号、Profile 的设置相互独立。
- **域名匹配**：可注册域名及其 `www.` 形式共用开关，例如 `example.com` 和 `www.example.com`；`news.example.com` 等其他子域名保持独立。传入页面的实际 hostname 即可，由 Phi 处理匹配。不支持域名比较的旧版 Framework 使用精确 hostname 匹配。
- **失败不等于开启**：Promise 被拒绝、API 不可用或返回格式错误时，状态为未知，不要默认当作 `true`。应暂停采集，直到查询成功且 `enabled` 是有效布尔值。
- **保留其他采集条件**：这个接口只读取站点开关，仍需执行 Lexington 现有的全局 AI、无痕模式和页面是否允许采集等检查。
- **及时重新查询**：启动、页面激活时查询，开始或恢复采集前再次查询。原生开关变化目前没有自动通知，缓存结果可能过期。Lexington 现有的 `observationDisabledHosts` 存储尚未与此设置同步。
