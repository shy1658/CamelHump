import { AppSettings, CuratedModel } from './Types';

/**
 * Tuning constants. These defaults are the ones that survived real-device
 * testing on a Kirin 9000s class phone: 1.5B Q4_K_M, 2048 context, 4 threads.
 * Raising threads raises throughput until the thermal governor clamps the clock,
 * after which it only adds heat and costs battery.
 */
export const DEFAULT_SETTINGS: AppSettings = {
  contextLength: 2048,
  threads: 4,
  threadsBatch: 2,
  temperature: 0.7,
  topP: 0.9,
  topK: 40,
  maxTokens: 512,
  repeatPenalty: 1.1,
  // Empty by default: the app should not put words in the user's mouth. A
  // canned persona also measurably hurts small models, which follow the system
  // message far more literally than a 70B does.
  systemPrompt: '',
  useMmap: false
};

/**
 * The prompt that used to ship as the default. Settings are persisted, so an
 * existing install still holds this exact string; treating it as "unset" once,
 * at load time, is what actually empties the field after the upgrade.
 *
 * This is deliberately NOT applied inside normalizeSettings(): that runs on
 * every save, and the same sentence is still offered as the「通用助手」preset --
 * a user who picks it on purpose would see it silently wiped.
 */
export const LEGACY_DEFAULT_SYSTEM_PROMPT =
  '你是一个离线运行的本地助手。回答简洁、准确，不确定时直接说明。';

export const SETTINGS_KEY = 'camelhump.settings.v1';
export const MODELS_DIR = 'models';
export const MODEL_FILE = 'model.gguf';
export const META_FILE = 'meta.json';

/**
 * 隐私政策同意状态的存储键。
 *
 * 华为应用市场要求：应用首次运行时须以弹窗向用户申请授权展示隐私政策，
 * 用户同意前不得有任何收集个人信息或调用权限 API 的行为。
 * 审核会实测这一步 —— 未同意时直接抓包/看日志，出现数据获取即驳回。
 */
export const PRIVACY_CONSENT_KEY = 'camelhump.privacy.consent.v1';

/** 隐私政策线上地址，需可公开访问。 */
export const PRIVACY_URL = 'https://shy1658.github.io/CamelHump/privacy.html';

export const MIN_CONTEXT = 512;
/**
 * Upper bound offered in the UI, not a promise. What a device can actually
 * allocate is decided by the model's KV layout: a 3B GQA model needs roughly
 * 28 KB per token, so 128k is ~3.6 GB of cache alone. The engine clamps n_ctx
 * to the model's training length and reports the allocation failure with a
 * concrete number instead of crashing.
 */
export const MAX_CONTEXT = 131072;

/** Output tokens may never claim more than this share of the context window. */
export const OUTPUT_CAP_RATIO = 0.5;
export const MIN_OUTPUT = 64;
/**
 * Thinking models spend most of their budget before writing a single visible
 * word -- Qwen3 / R1-distill class models routinely need 2-3k reasoning tokens
 * for a non-trivial question. A cap of ctx/2 is generous at 32k and useless at
 * 8k, where it lands on 4k of *total* budget shared with the prompt. This floor
 * guarantees the slider can always reach 4k, and the engine clamps whatever is
 * left of the window at run time anyway.
 */
export const MIN_OUTPUT_CAP = 4096;
/** Kept below the window: the prompt still has to fit alongside the answer. */
export const OUTPUT_PROMPT_RESERVE = 512;

/** Largest output budget the current context can support. */
export function outputCapFor(contextLength: number): number {
  // Half the window for growth, but never less than 4k unless the window itself
  // is too small to hold that plus a prompt.
  const generous: number = Math.max(MIN_OUTPUT_CAP, Math.floor(contextLength * OUTPUT_CAP_RATIO));
  const usable: number = Math.max(MIN_OUTPUT, contextLength - OUTPUT_PROMPT_RESERVE);
  return Math.max(MIN_OUTPUT, Math.min(generous, usable));
}

/**
 * Clamps a settings object into a combination the engine can actually run.
 *
 * Settings are persisted, so a value saved by an older build survives upgrades.
 * The particular trap this guards against: context and output cap set to the
 * same number, which leaves zero room for the prompt and makes every message
 * fail with "this model allows 0 tokens".
 */
export function normalizeSettings(input: AppSettings): AppSettings {
  let ctx: number = Math.round(input.contextLength);
  if (!Number.isFinite(ctx)) {
    ctx = DEFAULT_SETTINGS.contextLength;
  }
  ctx = Math.min(MAX_CONTEXT, Math.max(MIN_CONTEXT, ctx));

  const cap: number = outputCapFor(ctx);
  let out: number = Math.round(input.maxTokens);
  if (!Number.isFinite(out) || out < 1) {
    out = DEFAULT_SETTINGS.maxTokens;
  }
  if (out > cap) {
    out = cap;
  }

  let threads: number = Math.round(input.threads);
  if (!Number.isFinite(threads) || threads < 1) {
    threads = DEFAULT_SETTINGS.threads;
  }
  threads = Math.min(8, threads);

  let threadsBatch: number = Math.round(input.threadsBatch);
  if (!Number.isFinite(threadsBatch) || threadsBatch < 1) {
    threadsBatch = DEFAULT_SETTINGS.threadsBatch;
  }
  threadsBatch = Math.min(8, threadsBatch);

  // Drop the old built-in persona so the field really is user-authored.
  const prompt: string = input.systemPrompt ?? '';

  const out2: AppSettings = {
    contextLength: ctx,
    threads: threads,
    threadsBatch: threadsBatch,
    temperature: input.temperature,
    topP: input.topP,
    topK: input.topK,
    maxTokens: out,
    repeatPenalty: input.repeatPenalty,
    systemPrompt: prompt,
    useMmap: input.useMmap
  };
  return out2;
}

/** Refuse imports that would fill the sandbox and fail at 99%. */
export const STORAGE_HEADROOM_RATIO = 1.1;

/**
 * Curated list. Kept small on purpose: every entry must be a GGUF that a
 * 8 GB phone can actually run. Anything above 4B is deliberately absent.
 *
 * URLs point at ModelScope mirrors because they are reachable from mainland
 * networks without a proxy. Replace with your own mirror before shipping.
 */
export const CURATED_MODELS: CuratedModel[] = [
  {
    id: 'qwen2.5-1.5b-instruct-q4km',
    name: 'Qwen2.5 1.5B Instruct',
    params: '1.5B',
    quant: 'Q4_K_M',
    sizeMb: 1060,
    url: 'https://modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    sha256: '',
    note: '默认推荐。中文表达自然，1GB 左右，6GB 内存机型可跑。',
    minRamGb: 6
  },
  {
    id: 'qwen2.5-0.5b-instruct-q4km',
    name: 'Qwen2.5 0.5B Instruct',
    params: '0.5B',
    quant: 'Q4_K_M',
    sizeMb: 400,
    url: 'https://modelscope.cn/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/master/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    sha256: '',
    note: '老机型与 4GB 内存设备的兜底选择，速度快，深度推理弱。',
    minRamGb: 4
  },
  {
    id: 'qwen2.5-3b-instruct-q4km',
    name: 'Qwen2.5 3B Instruct',
    params: '3B',
    quant: 'Q4_K_M',
    sizeMb: 1980,
    url: 'https://modelscope.cn/models/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/master/qwen2.5-3b-instruct-q4_k_m.gguf',
    sha256: '',
    note: '质量明显更好，但解码约 7-12 tok/s，长回答需要等待。',
    minRamGb: 8
  }
];

export const SYSTEM_PROMPT_PRESETS: Record<string, string> = {
  '通用助手': '你是一个离线运行的本地助手。回答简洁、准确，不确定时直接说明。',
  '翻译': '你是翻译引擎。只输出译文，不解释、不加注。保持原文格式。',
  '润色': '你是文字编辑。在不改变原意的前提下让表达更通顺，只输出改写后的文本。',
  '摘要': '你是摘要工具。用三句话概括要点，不要展开，不要评价。',
  '代码': '你是编程助手。给出可直接运行的代码，注释用中文，先给代码再给一句说明。'
};
