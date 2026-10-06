import { AbilityConstant, ConfigurationConstant, UIAbility, Want, Configuration } from '@kit.AbilityKit';
import { EmitterUtil } from '../utiles/EmitterUtil'
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { preferences } from '@kit.ArkData';

const DOMAIN = 0x0000;
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    // 启动性能：最早时机预热 WebView 内核；已设置目标网页时预连接，压缩首屏白屏时间
    try {
      webview.WebviewController.initializeWebEngine();
      const pref = preferences.getPreferencesSync(this.context, { name: 'app_config' });
      const home = String(pref.getSync('target_url', ''));
      if (home !== '') {
        webview.WebviewController.prepareForPageLoad(home, true, 2);
      }
    } catch (err) {
    }
    hilog.info(DOMAIN, 'FakePWA', '%{public}s', 'Ability onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'FakePWA', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'FakePWA', 'Succeeded in loading the content.');
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 系统深浅色切换：通知首页重算空白底色（浅色白/深色黑）
    EmitterUtil.post('pwa_color_mode_changed', newConfig.colorMode);
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'FakePWA', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'FakePWA', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'FakePWA', '%{public}s', 'Ability onBackground');
  }
}
