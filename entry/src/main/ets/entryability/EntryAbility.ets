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
    // 启动性能：最早时机预热 WebView 内核；已设置首页时预连接，压缩首屏白屏时间
    // （首页默认为空，由用户在设置面板手动填写，无默认 URL 不预连接）
    try {
      webview.WebviewController.initializeWebEngine();
      const pref = preferences.getPreferencesSync(this.context, { name: 'app_config' });
      const home = String(pref.getSync('homepage_url', ''));
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
    // 系统深浅色切换：通知页面重设系统栏背景 / 空白首页底色（浅色白/深色黑）
    EmitterUtil.post('stq_color_mode_changed', newConfig.colorMode);
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
