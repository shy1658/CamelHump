import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x3200;
const TAG = 'CamelHump';

export class Log {
  static info(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
  }

  static warn(msg: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', msg);
  }

  static error(msg: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }
}

/** Turns an unknown thrown value into a sentence fit for the UI. */
export function describeError(e: Object | undefined): string {
  if (e === undefined || e === null) {
    return '未知错误';
  }
  const anyErr = e as Record<string, Object>;
  const msg = anyErr['message'];
  if (typeof msg === 'string' && msg.length > 0) {
    return msg;
  }
  const code = anyErr['code'];
  if (typeof code === 'number') {
    return `错误码 ${code}`;
  }
  return String(e);
}
