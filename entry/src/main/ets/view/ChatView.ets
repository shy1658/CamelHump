import { AppStore } from '../core/AppStore';
import { ChatMsg, GenStatsLite } from '../core/Types';
import { Theme, Fmt } from '../core/Theme';
import { describeError } from '../core/Logger';

@Component
export struct ChatView {
  @State messages: ChatMsg[] = [];
  @State inputText: string = '';
  @State generating: boolean = false;
  @State lastSpeed: number = 0;
  @State lastFirstToken: number = 0;
  @State errorBanner: string = '';
  // Bound to AppStore via AppStorage: activating a model happens on another tab,
  // and tab switches do not fire onPageShow.
  @StorageLink('engineReady') engineReady: boolean = false;
  @StorageLink('activeModelName') modelName: string = '';

  private store: AppStore = AppStore.get();
  private scroller: Scroller = new Scroller();
  private buffer: string = '';
  private ticker: number = -1;
  private seq: number = 0;

  aboutToDisappear(): void {
    this.stopTicker();
  }

  private nextId(): string {
    this.seq++;
    return `m${Date.now()}_${this.seq}`;
  }

  // ------------------------------------------------------------------ streaming
  private startTicker(): void {
    this.stopTicker();
    this.buffer = '';
    // Native pushes one callback per token; rebuilding the list at that rate
    // drops frames. Coalescing into a 40 ms tick keeps the UI at ~25 fps while
    // the token stream stays intact.
    this.ticker = setInterval(() => {
      if (this.buffer.length === 0) {
        return;
      }
      const last = this.messages.length - 1;
      if (last < 0) {
        return;
      }
      this.messages[last].content += this.buffer;
      // ForEach keys off `rev`: bumping it is what actually makes the bubble
      // redraw. Mutating `content` alone leaves the key untouched, so ArkUI
      // reuses the existing node and the text on screen never changes.
      this.messages[last].rev++;
      this.buffer = '';
      this.messages = this.messages.slice();
      this.scroller.scrollEdge(Edge.Bottom);
    }, 40);
  }

  private stopTicker(): void {
    if (this.ticker !== -1) {
      clearInterval(this.ticker);
      this.ticker = -1;
    }
  }

  private flushBuffer(): void {
    if (this.buffer.length > 0 && this.messages.length > 0) {
      const last = this.messages.length - 1;
      this.messages[last].content += this.buffer;
      this.messages[last].rev++;
      this.buffer = '';
      this.messages = this.messages.slice();
    }
  }

  // -------------------------------------------------------------------- actions
  private async send(): Promise<void> {
    const text = this.inputText.trim();
    if (text.length === 0 || this.generating) {
      return;
    }
    if (!this.store.engineReady) {
      this.errorBanner = '还没有加载模型。请先到「模型」页选择一个并加载。';
      return;
    }

    this.errorBanner = '';
    this.inputText = '';

    const userMsg = new ChatMsg(this.nextId(), 'user', text, Date.now());
    const reply = new ChatMsg(this.nextId(), 'assistant', '', Date.now());
    reply.pending = true;
    this.messages = this.messages.concat([userMsg, reply]);
    this.generating = true;
    this.scroller.scrollEdge(Edge.Bottom);

    const history = this.store.buildMessages(this.messages.slice(0, this.messages.length - 1));
    this.startTicker();

    try {
      const stats: GenStatsLite = await this.store.engine.chat(
        history,
        this.store.settings,
        (token: string) => {
          this.buffer += token;
        }
      );
      this.stopTicker();
      this.flushBuffer();

      // The user may have cleared the chat while the model was still
      // generating, so the list can legitimately be empty by now.
      const last = this.messages.length - 1;
      if (last >= 0) {
        this.messages[last].pending = false;
        this.messages[last].stats = stats;
        if (this.messages[last].content.length === 0) {
          this.messages[last].content = this.emptyReason(stats);
        }
        this.messages[last].rev++;
        this.messages = this.messages.slice();
      }
      this.lastSpeed = stats.tokensPerSecond;
      this.lastFirstToken = stats.firstTokenMs;
    } catch (e) {
      this.stopTicker();
      this.flushBuffer();
      const last = this.messages.length - 1;
      if (last >= 0) {
        this.messages[last].pending = false;
        this.messages[last].failed = true;
        this.messages[last].content = describeError(e);
        this.messages[last].rev++;
        this.messages = this.messages.slice();
      }
    } finally {
      this.generating = false;
      this.scroller.scrollEdge(Edge.Bottom);
    }
  }

  /** Turns a "no text came back" turn into something the user can act on. */
  private emptyReason(stats: GenStatsLite): string {
    if (stats.cancelled) {
      return '（已停止）';
    }
    if (stats.finish === 'max_tokens') {
      return '（达到长度上限，未产生可见内容。把「最大输出」调大再试）';
    }
    if (stats.finish === 'decode_error') {
      return '（引擎在生成中途失败，通常是内存不足）';
    }
    return '（模型没有输出内容）';
  }

  private stop(): void {
    this.store.engine.cancel();
  }

  /**
   * Frees the model without leaving the chat tab. Unloading is what the user
   * actually needs when swapping models: the weights plus KV cache can be well
   * over a gigabyte, and keeping them resident while another model loads is how
   * the process gets killed for exceeding the memory quota.
   */
  private unload(): void {
    if (this.generating) {
      this.store.engine.cancel();
      this.generating = false;
    }
    this.stopTicker();
    this.buffer = '';
    this.store.deactivate();
    this.lastSpeed = 0;
    this.lastFirstToken = 0;
  }

  private clearChat(): void {
    if (this.generating) {
      this.store.engine.cancel();
    }
    this.messages = [];
  }

  // ---------------------------------------------------------------------- view
  @Builder
  topBar() {
    Row() {
      Column() {
        Text('驼峰')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
        Text(this.engineReady ? this.modelName : '未加载模型')
          .fontSize(12)
          .fontColor(this.engineReady ? Theme.textDim : Theme.danger)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.lastSpeed > 0) {
        Column() {
          Text(Fmt.speed(this.lastSpeed))
            .fontSize(12)
            .fontColor(Theme.accent)
          Text(`首字 ${Fmt.ms(this.lastFirstToken)}`)
            .fontSize(10)
            .fontColor(Theme.textFaint)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.End)
        .margin({ right: 12 })
      }

      if (this.engineReady) {
        Button('卸载')
          .fontSize(12)
          .fontColor(Theme.textDim)
          .backgroundColor(Theme.surfaceAlt)
          .height(30)
          .padding({ left: 12, right: 12 })
          .margin({ right: 8 })
          .onClick(() => this.unload())
      }

      Button('清空')
        .fontSize(12)
        .fontColor(Theme.textDim)
        .backgroundColor(Theme.surfaceAlt)
        .height(30)
        .padding({ left: 12, right: 12 })
        .onClick(() => this.clearChat())
    }
    .width('100%')
    .padding({ left: Theme.pad, right: Theme.pad, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  emptyState() {
    Column() {
      Text(this.engineReady ? '问点什么' : '先挑一个模型')
        .fontSize(17)
        .fontColor(Theme.text)
        .margin({ bottom: 10 })
      Text(this.engineReady
        ? '全部推理在本机完成，对话内容不会离开这台设备。'
        : '到「模型」页选择已导入的模型，或从文件导入你自己的 GGUF。')
        .fontSize(13)
        .fontColor(Theme.textDim)
        .textAlign(TextAlign.Center)
        .padding({ left: 40, right: 40 })

      Text('回复内容由本机模型生成，可能存在错误，请勿直接作为事实依据')
        .fontSize(11)
        .fontColor(Theme.textFaint)
        .textAlign(TextAlign.Center)
        .padding({ left: 40, right: 40 })
        .margin({ top: 12 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** An empty pending bubble reads as a bug; say what is happening instead. */
  private bubbleText(msg: ChatMsg): string {
    if (msg.content.length > 0) {
      return msg.content;
    }
    if (msg.pending) {
      return '正在生成…';
    }
    return ' ';
  }

  @Builder
  messageRow(msg: ChatMsg) {
    Row() {
      if (msg.role === 'user') {
        Blank()
      }

      Column() {
        // 《人工智能生成合成内容标识办法》要求对 AI 生成内容做显式标识。
        // 审核会索取这张截图，所以标识必须真的出现在界面上，而不是只写在文档里。
        if (msg.role === 'assistant' && !msg.failed) {
          Row() {
            Text('AI 生成')
              .fontSize(9)
              .fontColor(Theme.textFaint)
              .border({ width: 1, color: Theme.border })
              .borderRadius(3)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          }
          .margin({ bottom: 5 })
        }

        Text(this.bubbleText(msg))
          .fontSize(15)
          .lineHeight(23)
          .fontColor(msg.failed ? Theme.danger
            : (msg.pending && msg.content.length === 0 ? Theme.textFaint : Theme.text))
          .textAlign(TextAlign.Start)
          .width('100%')

        if (msg.stats !== undefined && msg.role === 'assistant') {
          Row() {
            Text(`${msg.stats.decodedTokens} tok`)
              .fontSize(10)
              .fontColor(Theme.textFaint)
            Text(`· ${Fmt.speed(msg.stats.tokensPerSecond)}`)
              .fontSize(10)
              .fontColor(Theme.textFaint)
              .margin({ left: 6 })
            if (msg.stats.reusedTokens > 0) {
              // Proof the prompt cache hit: this many prompt tokens were not
              // re-prefilled for this turn.
              Text(`· 复用 ${Fmt.tokens(msg.stats.reusedTokens)}`)
                .fontSize(10)
                .fontColor(Theme.textFaint)
                .margin({ left: 6 })
            }
            if (msg.stats.cancelled) {
              Text('· 已停止')
                .fontSize(10)
                .fontColor(Theme.textFaint)
                .margin({ left: 6 })
            }
          }
          .margin({ top: 6 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor(msg.role === 'user' ? Theme.userBubble : Theme.surface)
      .borderRadius(Theme.radius)
      .constraintSize({ maxWidth: '80%' })

      if (msg.role !== 'user') {
        Blank()
      }
    }
    .width('100%')
    .padding({ left: Theme.pad, right: Theme.pad, top: 6, bottom: 6 })
  }

  @Builder
  composer() {
    Column() {
      if (this.errorBanner.length > 0) {
        Text(this.errorBanner)
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 8 })
      }

      Row() {
        TextArea({ text: this.inputText, placeholder: this.engineReady ? '输入内容…' : '请先加载模型' })
          .placeholderColor(Theme.textFaint)
          .fontColor(Theme.text)
          .fontSize(15)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.radius)
          .constraintSize({ minHeight: 44, maxHeight: 120 })
          .padding({ left: 14, right: 14, top: 11, bottom: 11 })
          .layoutWeight(1)
          .enabled(this.engineReady)
          .onChange((v: string) => {
            this.inputText = v;
          })

        if (this.generating) {
          Button() {
            Text('停止')
              .fontSize(14)
              .fontColor(Theme.bg)
          }
          .width(60)
          .height(44)
          .backgroundColor(Theme.accent)
          .borderRadius(Theme.radius)
          .margin({ left: 8 })
          .onClick(() => this.stop())
        } else {
          Button() {
            Text('发送')
              .fontSize(14)
              .fontColor(this.engineReady && this.inputText.trim().length > 0 ? Theme.bg : Theme.textFaint)
          }
          .width(60)
          .height(44)
          .backgroundColor(this.engineReady && this.inputText.trim().length > 0
            ? Theme.accent : Theme.surface)
          .borderRadius(Theme.radius)
          .margin({ left: 8 })
          .onClick(() => {
            this.send();
          })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .padding({ left: Theme.pad, right: Theme.pad, top: 8, bottom: 12 })
  }

  build() {
    Column() {
      this.topBar()
      Divider().color(Theme.border).strokeWidth(1)

      if (this.messages.length === 0) {
        Stack() {
          this.emptyState()
        }
        .layoutWeight(1)
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.messages, (item: ChatMsg) => {
            ListItem() {
              this.messageRow(item)
            }
          }, (item: ChatMsg) => `${item.id}#${item.rev}`)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }

      this.composer()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
