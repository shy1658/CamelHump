/** One palette, referenced everywhere. Mirrors the app icon. */
export class Theme {
  static readonly bg: string = '#0B0E14';
  static readonly surface: string = '#151A23';
  static readonly surfaceAlt: string = '#1C222D';
  static readonly border: string = '#252C39';
  static readonly accent: string = '#F2C14E';
  static readonly accentDim: string = '#8A6E28';
  static readonly text: string = '#E8EAED';
  static readonly textDim: string = '#8B93A1';
  static readonly textFaint: string = '#5A6272';
  static readonly danger: string = '#F87171';
  static readonly ok: string = '#4ADE80';
  static readonly userBubble: string = '#2A2213';
  static readonly radius: number = 16;
  static readonly gap: number = 12;
  static readonly pad: number = 16;
}

export class Fmt {
  static size(bytes: number): string {
    if (bytes >= 1024 * 1024 * 1024) {
      return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
    }
    if (bytes >= 1024 * 1024) {
      return `${Math.round(bytes / (1024 * 1024))} MB`;
    }
    if (bytes >= 1024) {
      return `${Math.round(bytes / 1024)} KB`;
    }
    return `${bytes} B`;
  }

  static speed(tps: number): string {
    return `${tps.toFixed(1)} tok/s`;
  }

  /**
   * Token counts read as thousands once they get big: "128k" beats "131072 tok"
   * on a slider label. Below 1024 the plain count stays, because 512 tok is
   * clearer than 0.5k.
   */
  static tokens(n: number): string {
    if (n < 1024) {
      return `${Math.round(n)} tok`;
    }
    const k = Math.round((n / 1024) * 10) / 10;
    return Number.isInteger(k) ? `${k}k` : `${k.toFixed(1)}k`;
  }

  static ms(ms: number): string {
    return ms >= 1000 ? `${(ms / 1000).toFixed(1)}s` : `${ms}ms`;
  }

  static time(ts: number): string {
    const d = new Date(ts);
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    return `${hh}:${mm}`;
  }
}
