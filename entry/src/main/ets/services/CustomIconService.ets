import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { common } from '@kit.AbilityKit';
import preferences from '@ohos.data.preferences';

/**
 * 自定义应用图标（应用内展示）：
 * WeiboPura 分类封面更换同构——PhotoViewPicker 选图 → 拷贝沙箱 filesDir → 持久化裸绝对路径 →
 * UI 用 file:// 前缀展示。用户自行上传图片作为应用内图标预览。
 *
 * 🔴 平台限制说明：鸿蒙桌面图标运行时更换仅有 AGC 动态图标一条公开通道
 * （图标须先在 AppGallery Connect 创建并过审，应用内无法把任意用户图片直接设为桌面图标）。
 * 因此本服务承载"用户自行上传图标"链路（应用内生效），桌面更换仍走 DynamicAppIconService（AGC）。
 */

const PREF_NAME: string = 'app_config';
const KEY_CUSTOM_ICON: string = 'custom_icon_path';

async function getPreferences() {
  return preferences.getPreferences(globalThis.getContext(), PREF_NAME);
}

export class CustomIconService {
  /**
   * 选图并落沙箱：拉起系统图库单选图片（正方形图标素材建议），
   * 拷贝到 filesDir/custom_icon_<ts>.png 后持久化路径。
   * 返回沙箱路径；用户取消/失败返回空串。
   */
  async pickAndSave(context: common.UIAbilityContext): Promise<string> {
    // 1) 系统图库单选
    const selectOptions = new photoAccessHelper.PhotoSelectOptions();
    selectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    selectOptions.maxSelectNumber = 1;
    const picker = new photoAccessHelper.PhotoViewPicker();
    const result = await picker.select(selectOptions);
    if (!result.photoUris || result.photoUris.length === 0) {
      return ''; // 用户取消
    }
    const srcUri: string = result.photoUris[0];
    // 2) 拷贝沙箱（picker URI 仅本次临时可读，必须立即落盘）
    const dstPath: string = context.filesDir + '/custom_icon_' + Date.now() + '.png';
    let srcFd: number = -1;
    try {
      const src = fileIo.openSync(srcUri, fileIo.OpenMode.READ_ONLY);
      srcFd = src.fd;
      const dst = fileIo.openSync(dstPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.READ_WRITE);
      try {
        await fileIo.copyFile(srcFd, dst.fd);
      } finally {
        fileIo.closeSync(dst);
      }
      fileIo.closeSync(src);
    } catch (err) {
      return '';
    }
    // 3) 持久化路径（裸绝对路径，UI 展示时补 file:// 前缀）
    const old: string = await this.getCustomIconPath();
    const store = await getPreferences();
    await store.put(KEY_CUSTOM_ICON, dstPath);
    await store.flush();
    // 4) 清理旧图标文件（路径不同才删）
    if (old !== '' && old !== dstPath) {
      try {
        fileIo.unlinkSync(old);
      } catch (e) {
      }
    }
    return dstPath;
  }

  /** 读取自定义图标沙箱路径（未设置返回空串） */
  async getCustomIconPath(): Promise<string> {
    const store = await getPreferences();
    return String(await store.get(KEY_CUSTOM_ICON, ''));
  }

  /** 移除自定义图标：清偏好 + 删沙箱文件 */
  async clearCustomIcon(): Promise<void> {
    const old: string = await this.getCustomIconPath();
    const store = await getPreferences();
    await store.put(KEY_CUSTOM_ICON, '');
    await store.flush();
    if (old !== '') {
      try {
        fileIo.unlinkSync(old);
      } catch (e) {
      }
    }
  }
}
