# AGENTS.md - 假装PWA 工程规范

## 工程约定

- 提交信息：中文，形如 `v<版本>: ①②③`（要点罗列）。
- 发版必须递增 `AppScope/app.json5` 的 `versionCode`/`versionName`。
- ArkTS 严格模式：不写未类型化对象字面量；三方 API 以官方文档为准，改动前先核对 SDK 可用性。
- 未经授权不 push。

## 平台事实（考古结论，勿凭印象改）

- **换图标** = AppGallery Kit 图标管理服务（`@kit.AppGalleryKit` → `appInfoManager.queryDynamicIcons/selectDynamicIcon/disableDynamicIcon`，5.0.3(15)+）。参考实现：aira-browser `entry/src/main/ets/services/appicon/DynamicAppIconService.ets`。图标必须在 AGC「图标管理」创建并过审后才会被查询到；真机限定。
- **桌面壁纸**：`getImage/getPixelMap` 是 @systemapi，三方读不到；唯一公开入口 `getFile` 需 system_basic 权限 `ohos.permission.GET_WALLPAPER`（三方无授权）。首页按"尽力读取 + 失败回退空白（浅白/深黑）"实现。
- **应用分身**：`AppScope/app.json5` → `multiAppMode: { multiAppModeType: "appClone", maxCount: N }`。文档标称 appClone 范围 1~5；本工程配 10（打包工具不校验范围，系统行为以真机为准）。

## 迭代基线

- 以仓库最新形态为基线迭代，不要回退 TA 已验收的行为。
- 深浅色判定为双源（config.colorMode 优先 + mediaquery 兜底），修复相关 bug 前先读 `pages/Index.ets` 的 `detectDark()`。
