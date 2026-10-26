import { common } from '@kit.AbilityKit';

/**
 * The document picker needs a UIAbilityContext. Services are constructed before
 * any page exists, so EntryAbility hands the context over once at startup.
 */
export class ContextHolder {
  private static ctx: common.UIAbilityContext | undefined = undefined;

  static set(context: common.UIAbilityContext): void {
    ContextHolder.ctx = context;
  }

  static get(): common.UIAbilityContext {
    if (ContextHolder.ctx === undefined) {
      throw new Error('应用上下文尚未就绪');
    }
    return ContextHolder.ctx;
  }

  static filesDir(): string {
    return ContextHolder.get().filesDir;
  }

  static cacheDir(): string {
    return ContextHolder.get().cacheDir;
  }
}
