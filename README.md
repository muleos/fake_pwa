# 假装PWA

HarmonyOS 网页套壳应用：一个可以"假装"成任意网站 App 的壳子。基于 soutu_ohos 壳工程同构演化。

- 包名：`com.hmos.pwa`
- 应用名：假装PWA
- 当前版本：v1.0.0 (100001)
- 兼容版本：compatibleSdkVersion `6.0.0(20)`

## 功能

### 首页（默认为空）
- 首页显示**桌面壁纸**（能读取到时全屏铺底）；
- 读取失败（平台受限，见下）则显示空白：浅色模式白色、深色模式黑色；
- 右下角半透明齿轮按钮进入设置。

### 设置
- **目标网页**：输入网址 → 保存（持久化）/ 打开（进入 WebView 网页层）；
- **更换图标**：查询华为图标管理服务的动态图标列表，点选即切换应用桌面图标，支持恢复默认。

### 应用分身
`AppScope/app.json5` 中配置：

```json5
"multiAppMode": {
  "multiAppModeType": "appClone",
  "maxCount": 10
}
```

> 注：官方文档（OpenHarmony app.json5 配置）标注 appClone 模式 `maxCount` 范围 1~5（multiInstance 模式才到 10）；打包工具不做范围校验。若目标系统按 5 截断，属平台限制，此处配置值仍保留 10。

## 换图标的前置条件（重要）

换图标功能与 aira-browser 同构，底层为 **AppGallery Kit 图标管理服务**（`@kit.AppGalleryKit` 的 `appInfoManager`，起始版本 5.0.3(15)）：

1. 仅**真机**生效（不支持模拟器）；
2. 需先在 **AppGallery Connect → 图标管理** 创建图标（iconId + 图标）并**通过审核**；
3. 审核通过后，应用内 `queryDynamicIcons()` 才能查到，`selectDynamicIcon()` 切换后由系统更新桌面图标。

典型用法：给每个常用网站在 AGC 上传对应图标（iconId 即网站名），每个应用分身选择不同网页与图标，即可"假装"出多个网站 App。

## 桌面壁纸的平台限制

- `wallpaper.getPixelMap/getImage` 均为 `@systemapi`（三方不可见、运行时 202 拦截）；
- 公开可编译的读取入口仅剩 `wallpaper.getFile()`（API 8，已 deprecated），需 `ohos.permission.GET_WALLPAPER`（system_basic，三方拿不到授权）。

因此代码按"尽力读取"实现（`services/WallpaperService.ets`）：任何一步失败即回退空白底（浅色白/深色黑）。若后续系统开放壁纸读取，无需改动。

## 工程结构

```
AppScope/app.json5                        包名/版本/分身(multiAppMode)
entry/src/main/ets/
  entryability/EntryAbility.ets           入口：内核预热+目标页预连接、深浅色事件
  model/StorageService.ets                目标网页持久化
  services/WallpaperService.ets           桌面壁纸尽力读取（失败回退空白）
  services/DynamicAppIconService.ets      AGC 动态图标查询/切换/恢复（aira 同构）
  utiles/EmitterUtil.ets                  事件工具
  pages/Index.ets                         单页分层壳：首页(壁纸/空白)+网页层+设置+换图标
```

## 壳能力（继承 soutu_ohos）

- 沉浸式全屏 + 安全区避让（网页层避状态栏）
- 深浅色双源判定（配置色模式优先，mediaquery 兜底）
- 默认安卓手机 UA；外部 scheme 交系统分发（openLink → Want 兜底）
- `<input type=file>` 拉起系统图库选图
- 返回键层级处理：图标面板 → 设置面板 → 网页历史 → 关网页层 → 退出
