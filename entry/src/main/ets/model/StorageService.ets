import preferences from '@ohos.data.preferences';

let prefs: preferences.Preferences;

async function getPreferences() {
  if (!prefs) {
    prefs = await preferences.getPreferences(globalThis.getContext(), 'app_config');
  }
  return prefs;
}

// 目标网页（"假装"的站点，设置面板可存/改）
export async function saveTargetUrl(page_url: string) {
  const store = await getPreferences();
  await store.put('target_url', page_url);
  await store.flush();
}

export async function getTargetUrl(): Promise<string> {
  const store = await getPreferences();
  return String(await store.get('target_url', ''));
}
