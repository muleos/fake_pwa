import { wallpaper } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';

/**
 * 桌面壁纸读取服务。
 *
 * 平台限制（实锤）：
 * - wallpaper.getPixelMap / wallpaper.getImage 均标注 @systemapi（公开 SDK 不可见、运行时 202 拦截三方调用）；
 * - 公开且仍可编译的读取入口仅剩 wallpaper.getFile（API 8，since 9 标记 deprecated），需 ohos.permission.GET_WALLPAPER
 *   —— 该权限为 system_basic，三方应用拿不到授权，真机调用通常抛 201/202。
 *
 * 因此本服务按"尽力读取"实现：能读到 PixelMap 就返回；任何一步失败都返回 null，
 * 由首页回退空白底（浅色白 / 深色黑）。若后续系统开放壁纸读取，本入口无需改动即可生效。
 */
export async function loadSystemWallpaper(): Promise<image.PixelMap | null> {
  let fd: number = -1;
  try {
    fd = await wallpaper.getFile(wallpaper.WallpaperType.WALLPAPER_SYSTEM);
    const source = image.createImageSource(fd);
    if (!source) {
      fileIo.closeSync(fd);
      return null;
    }
    const pm = await source.createPixelMap();
    await source.release();
    fileIo.closeSync(fd);
    return pm;
  } catch (err) {
    try {
      if (fd >= 0) {
        fileIo.closeSync(fd);
      }
    } catch (e) {
    }
    return null;
  }
}
