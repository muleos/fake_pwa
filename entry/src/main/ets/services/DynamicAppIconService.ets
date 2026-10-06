import { appInfoManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 动态图标服务（参考 aira-browser 的 DynamicAppIconService 同构实现）。
 *
 * 底层为华为 AppGallery Kit 图标管理服务：
 * - appInfoManager.queryDynamicIcons()   查询可用动态图标
 * - appInfoManager.selectDynamicIcon(id) 切换图标（系统更新桌面图标）
 * - appInfoManager.disableDynamicIcon()  停用动态图标，恢复默认图标
 *
 * 前置条件（aira 同款）：
 * - 仅真机生效（不支持模拟器）；
 * - 图标需先在 AppGallery Connect「图标管理」创建并通过审核，审核通过后 query 才会返回。
 */
export interface DynamicAppIconMutationResult {
  ok: boolean;
  code: number;
  message: string;
}

export interface DynamicAppIconQueryResult {
  ok: boolean;
  icons: appInfoManager.DynamicIconInfo[];
  code: number;
  message: string;
}

// 当前正在使用自定义主题图标时切换动态图标的错误码（6.0.0(20)+）
const THEME_CONFLICT_CODE = 1006800013;

export class DynamicAppIconService {
  async queryIcons(): Promise<DynamicAppIconQueryResult> {
    try {
      const infos = await appInfoManager.queryDynamicIcons();
      return { ok: true, icons: infos, code: 0, message: '' };
    } catch (err) {
      const be = err as BusinessError;
      return { ok: false, icons: [], code: be.code, message: this.resolveFailureMessage(be.code) };
    }
  }

  async selectIcon(iconId: string): Promise<DynamicAppIconMutationResult> {
    try {
      await appInfoManager.selectDynamicIcon(iconId);
      return { ok: true, code: 0, message: '' };
    } catch (err) {
      const be = err as BusinessError;
      return { ok: false, code: be.code, message: this.resolveFailureMessage(be.code) };
    }
  }

  async restoreDefault(): Promise<DynamicAppIconMutationResult> {
    try {
      await appInfoManager.disableDynamicIcon();
      return { ok: true, code: 0, message: '' };
    } catch (err) {
      const be = err as BusinessError;
      return { ok: false, code: be.code, message: this.resolveFailureMessage(be.code) };
    }
  }

  private resolveFailureMessage(code: number): string {
    if (code === THEME_CONFLICT_CODE) {
      return '当前正在使用自定义主题图标，请先在系统主题设置中恢复默认图标后再切换。';
    }
    if (code > 0) {
      return `图标管理服务暂不可用，错误码 ${code}。请确认：真机环境、应用已上架应用市场且已在 AppGallery Connect「图标管理」创建图标并通过审核。`;
    }
    return '图标管理服务暂不可用。';
  }
}
