import { preferences } from '@kit.ArkData';
import { AppSettings, ChatMsg, CuratedModel, EngineInfo, ModelEntry } from './Types';
import { CURATED_MODELS, DEFAULT_SETTINGS, LEGACY_DEFAULT_SYSTEM_PROMPT, PRIVACY_CONSENT_KEY, SETTINGS_KEY, normalizeSettings } from './Config';
import { ContextHolder } from './ContextHolder';
import { InferenceEngine } from './InferenceEngine';
import { ImportResult, ModelRepository } from './ModelRepository';
import { Log, describeError } from './Logger';

/**
 * Single source of truth for the whole app. Pages read from here and re-render
 * on the counters below; nothing keeps its own copy of model state.
 */
@Observed
export class AppStore {
  private static instance: AppStore | undefined = undefined;

  models: ModelEntry[] = [];
  settings: AppSettings = DEFAULT_SETTINGS;
  currentModelId: string = '';
  activeModelName: string = '';
  engineReady: boolean = false;
  enginePresent: boolean = false;
  /** Context the engine actually allocated for the loaded model. */
  effectiveContext: number = 0;
  /** Training context of the loaded model, 0 when unknown. */
  modelTrainContext: number = 0;
  /** KV cache cost of one token with the loaded model, in bytes. */
  kvBytesPerToken: number = 0;
  /** Runtime optimisations actually applied to the loaded context. */
  flashAttn: boolean = false;
  kvQuantized: boolean = false;
  pinnedCores: number = 0;
  /** Bumped whenever `models` is replaced, so views can subscribe. */
  modelsVersion: number = 0;
  /**
   * Whether the user has accepted the privacy policy.
   *
   * Huawei's review flow requires a first-run consent dialog, and the reviewer
   * checks that nothing touches personal data before the user agrees. This app
   * has no accounts, no network calls and no permissions, so "collecting
   * nothing" is the default -- but the agreement itself still has to be
   * recorded, otherwise the app looks like it skipped the consent step.
   */
  privacyAccepted: boolean = false;

  readonly engine: InferenceEngine = new InferenceEngine();
  readonly repo: ModelRepository = new ModelRepository();

  static get(): AppStore {
    if (AppStore.instance === undefined) {
      AppStore.instance = new AppStore();
    }
    return AppStore.instance;
  }

  /**
   * Mirrors the fields pages bind to into AppStorage. Tab switches do not fire
   * onPageShow, so @StorageLink is the only reliable way to keep the chat header
   * in step with a model activation triggered from the models tab.
   */
  private syncStorage(): void {
    AppStorage.setOrCreate('engineReady', this.engineReady);
    AppStorage.setOrCreate('activeModelName', this.activeModelName);
    AppStorage.setOrCreate('currentModelId', this.currentModelId);
    AppStorage.setOrCreate('modelsVersion', this.modelsVersion);
    AppStorage.setOrCreate('enginePresent', this.enginePresent);
  }

  async boot(): Promise<void> {
    this.enginePresent = this.engine.enginePresent();
    await this.loadPrivacyConsent();

    // 用户同意隐私政策之前，不读取任何本地数据。
    //
    // 审核要求「用户同意前应用不应该有任何调用权限 API 的行为」，
    // 审核员会在未点击同意的情况下实测。虽然本应用不采集任何个人信息，
    // 但提前读取设置与模型清单仍属于「用户同意前访问本地数据」，
    // 保守起见先只读取同意状态本身。
    if (!this.privacyAccepted) {
      this.syncStorage();
      Log.info('boot: awaiting privacy consent, no local data read');
      return;
    }

    await this.loadSettings();
    await this.refreshModels();
    this.syncStorage();
    Log.info(`boot: ${this.models.length} model(s), engine=${this.enginePresent}, `
      + `privacyAccepted=${this.privacyAccepted}`);
  }

  /**
   * Reads settings and the model list. Called once the user has accepted the
   * privacy policy -- until then the app touches nothing but the consent flag.
   */
  async loadAfterConsent(): Promise<void> {
    await this.loadSettings();
    await this.refreshModels();
    this.syncStorage();
  }

  // ----------------------------------------------------------- privacy consent
  /**
   * Reads the stored consent flag. A missing record means "not yet agreed",
   * which is what drives the first-run dialog.
   */
  async loadPrivacyConsent(): Promise<void> {
    try {
      const store = await preferences.getPreferences(ContextHolder.get(), 'camelhump');
      const raw = await store.get(PRIVACY_CONSENT_KEY, '') as string;
      this.privacyAccepted = raw === 'accepted';
    } catch (e) {
      Log.warn(`load privacy consent failed: ${describeError(e)}`);
      this.privacyAccepted = false;
    }
  }

  /** Records the user's acceptance. Called only from an explicit user action. */
  async acceptPrivacyPolicy(): Promise<void> {
    this.privacyAccepted = true;
    try {
      const store = await preferences.getPreferences(ContextHolder.get(), 'camelhump');
      await store.put(PRIVACY_CONSENT_KEY, 'accepted');
      await store.flush();
    } catch (e) {
      Log.warn(`save privacy consent failed: ${describeError(e)}`);
    }
  }

  // ---------------------------------------------------------------- settings
  async loadSettings(): Promise<void> {
    try {
      const store = await preferences.getPreferences(ContextHolder.get(), 'camelhump');
      const raw = await store.get(SETTINGS_KEY, '') as string;
      if (raw.length > 0) {
        const saved = JSON.parse(raw) as AppSettings;
        // One-time migration: builds before 1.0.6 wrote a canned persona into
        // the settings blob. The field is supposed to be empty unless the user
        // typed something, so an untouched default is dropped here -- and only
        // here, so choosing that same sentence from the presets still sticks.
        if (saved.systemPrompt === LEGACY_DEFAULT_SYSTEM_PROMPT) {
          saved.systemPrompt = '';
        }
        this.settings = this.mergeSettings(saved);
      }
    } catch (e) {
      Log.warn(`load settings failed: ${describeError(e)}`);
    }
  }

  async saveSettings(next: AppSettings): Promise<void> {
    // Normalise before storing: a persisted context/output pair of 2048/2048
    // makes every prompt fail, and it would survive the next launch too.
    const clean: AppSettings = normalizeSettings(next);
    this.settings = clean;
    try {
      const store = await preferences.getPreferences(ContextHolder.get(), 'camelhump');
      await store.put(SETTINGS_KEY, JSON.stringify(clean));
      await store.flush();
    } catch (e) {
      Log.warn(`save settings failed: ${describeError(e)}`);
    }
  }

  /** Fills in fields added after a user's settings were first written. */
  private mergeSettings(saved: AppSettings): AppSettings {
    const out: AppSettings = {
      contextLength: saved.contextLength ?? DEFAULT_SETTINGS.contextLength,
      threads: saved.threads ?? DEFAULT_SETTINGS.threads,
      threadsBatch: saved.threadsBatch ?? DEFAULT_SETTINGS.threadsBatch,
      temperature: saved.temperature ?? DEFAULT_SETTINGS.temperature,
      topP: saved.topP ?? DEFAULT_SETTINGS.topP,
      topK: saved.topK ?? DEFAULT_SETTINGS.topK,
      maxTokens: saved.maxTokens ?? DEFAULT_SETTINGS.maxTokens,
      repeatPenalty: saved.repeatPenalty ?? DEFAULT_SETTINGS.repeatPenalty,
      systemPrompt: saved.systemPrompt ?? DEFAULT_SETTINGS.systemPrompt,
      useMmap: saved.useMmap ?? DEFAULT_SETTINGS.useMmap
    };
    return normalizeSettings(out);
  }

  // ------------------------------------------------------------------ models
  async refreshModels(): Promise<void> {
    this.models = await this.repo.list();
    this.modelsVersion++;
    if (this.currentModelId.length > 0) {
      const still = this.models.find((m: ModelEntry) => m.id === this.currentModelId);
      if (still === undefined) {
        this.engine.release();
        this.currentModelId = '';
        this.activeModelName = '';
        this.engineReady = false;
      }
    }
    this.syncStorage();
  }

  async importFile(uri: string, name: string, onProgress?: (r: number) => void): Promise<ImportResult> {
    const result = await this.repo.importFromUri(uri, name, onProgress);
    await this.refreshModels();
    return result;
  }

  async deleteModel(id: string): Promise<void> {
    if (this.currentModelId === id) {
      this.engine.release();
      this.currentModelId = '';
      this.activeModelName = '';
      this.engineReady = false;
    }
    await this.repo.remove(id);
    await this.refreshModels();
  }

  /**
   * Loads a model into memory. Reloading an already-active model is a no-op
   * unless settings that change the graph (context length) have moved.
   */
  async activate(entry: ModelEntry): Promise<void> {
    this.engineReady = false;
    this.syncStorage();
    try {
      const info: string = await this.engine.load(entry, this.settings);
      this.applyEngineInfo(info);
    } catch (e) {
      // A failed load must not leave the previous model's identity behind:
      // the UI would claim a model is active while the engine holds nothing.
      this.engineReady = false;
      this.currentModelId = '';
      this.activeModelName = '';
      this.syncStorage();
      // ArkTS only allows Error objects to be thrown.
      throw new Error(describeError(e));
    }
    this.currentModelId = entry.id;
    this.activeModelName = entry.displayName;
    this.engineReady = true;
    this.syncStorage();
  }

  /**
   * Pulls the engine's own numbers out of `describe()`. The context actually in
   * use can be smaller than what the user asked for -- a model trained on 32k
   * will not run at 128k -- and the KV cost is what makes that visible.
   */
  private applyEngineInfo(raw: string): void {
    try {
      const info = JSON.parse(raw) as EngineInfo;
      this.effectiveContext = info.nCtx ?? 0;
      this.modelTrainContext = info.nCtxTrain ?? 0;
      this.kvBytesPerToken = info.kvBytesPerToken ?? 0;
      this.flashAttn = info.flashAttn ?? false;
      this.kvQuantized = info.kvQuantized ?? false;
      this.pinnedCores = info.pinnedCores ?? 0;
    } catch (e) {
      Log.warn(`describe parse failed: ${describeError(e)}`);
      this.effectiveContext = 0;
      this.modelTrainContext = 0;
      this.kvBytesPerToken = 0;
      this.flashAttn = false;
      this.kvQuantized = false;
      this.pinnedCores = 0;
    }
  }

  deactivate(): void {
    // A release while the worker thread is still decoding would leave the
    // session's KV work racing the destructor, so ask it to stop first.
    if (this.engine.isBusy()) {
      this.engine.cancel();
    }
    this.engine.release();
    this.engineReady = false;
    this.currentModelId = '';
    this.activeModelName = '';
    this.effectiveContext = 0;
    this.modelTrainContext = 0;
    this.kvBytesPerToken = 0;
    this.flashAttn = false;
    this.kvQuantized = false;
    this.pinnedCores = 0;
    this.syncStorage();
  }

  // -------------------------------------------------------------------- chat
  buildMessages(history: ChatMsg[]): ChatMsg[] {
    const out: ChatMsg[] = [];
    const sys = new ChatMsg('sys', 'system', this.settings.systemPrompt, 0);
    if (this.settings.systemPrompt.trim().length > 0) {
      out.push(sys);
    }
    for (const m of history) {
      if (m.role === 'system') {
        continue;
      }
      out.push(m);
    }
    return out;
  }

  curated(): CuratedModel[] {
    return CURATED_MODELS;
  }

  totalModelBytes(): number {
    return this.repo.usedBytes(this.models);
  }

  freeBytes(): number {
    return this.repo.freeBytes();
  }
}
