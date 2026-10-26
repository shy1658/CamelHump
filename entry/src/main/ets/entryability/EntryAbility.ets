import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ContextHolder } from '../core/ContextHolder';
import { AppStore } from '../core/AppStore';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Services need the context for filesDir, preferences and the file picker.
    // It is captured here, once, before any page is built.
    ContextHolder.set(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        return;
      }
      try {
        const main = windowStage.getMainWindowSync();
        main.setWindowSystemBarProperties({
          statusBarColor: '#0B0E14',
          statusBarContentColor: '#E8EAED',
          navigationBarColor: '#0B0E14',
          navigationBarContentColor: '#E8EAED'
        });
      } catch (e) {
        // Bar styling is cosmetic; never block startup on it.
      }
    });
  }

  onDestroy(): void {
    // Pages are gone at this point; releasing the session frees the weights and
    // KV cache immediately instead of waiting for the process to be killed.
    // Without this a model stays resident in the background task until the
    // OS reclaims it, which on a phone means the user loses several hundred
    // MB for no reason.
    try {
      AppStore.get().deactivate();
    } catch (e) {
      // Teardown must never throw: the ability is already going away.
    }
  }
}
