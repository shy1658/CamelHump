import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { AppStore } from '../core/AppStore';
import { AppSettings, ModelEntry } from '../core/Types';
import { MAX_CONTEXT, MIN_CONTEXT, MIN_OUTPUT_CAP, SYSTEM_PROMPT_PRESETS, outputCapFor } from '../core/Config';
import { ContextHolder } from '../core/ContextHolder';
import { Fmt, Theme } from '../core/Theme';
import { Log, describeError } from '../core/Logger';

const PROJECT_URL: string = 'https://github.com/shy1658/CamelHump';
const SPONSOR_URL: string = 'https://afdian.com/a/shy1658?utm_source=copylink&utm_medium=link';

@Component
export struct SettingsView {
  @State contextLength: number = 2048;
  @State threads: number = 4;
  @State maxTokens: number = 512;
  @State temperature: number = 0.7;
  @State topP: number = 0.9;
  @State systemPrompt: string = '';
  @State useMmap: boolean = false;
  @State models: ModelEntry[] = [];
  @State usedLabel: string = '';
  @StorageLink('engineReady') engineReady: boolean = false;
  @StorageLink('activeModelName') modelName: string = '';

  private store: AppStore = AppStore.get();

  aboutToAppear(): void {
    this.pullFromStore();
  }

  onPageShow(): void {
    this.pullFromStore();
  }

  private pullFromStore(): void {
    const s = this.store.settings;
    this.contextLength = s.contextLength;
    this.threads = s.threads;
    this.maxTokens = s.maxTokens;
    this.temperature = s.temperature;
    this.topP = s.topP;
    this.systemPrompt = s.systemPrompt;
    this.useMmap = s.useMmap;
    this.models = this.store.models.slice();
    this.usedLabel = Fmt.size(this.store.totalModelBytes());
  }

  private async persist(): Promise<void> {
    const next: AppSettings = {
      contextLength: Math.round(this.contextLength),
      threads: Math.round(this.threads),
      threadsBatch: Math.max(1, Math.round(this.threads / 2)),
      temperature: this.temperature,
      topP: this.topP,
      topK: this.store.settings.topK,
      maxTokens: Math.round(this.maxTokens),
      repeatPenalty: this.store.settings.repeatPenalty,
      systemPrompt: this.systemPrompt,
      useMmap: this.useMmap
    };
    try {
      await this.store.saveSettings(next);
      // The store clamps illegal combinations (output cap vs context). Pull the
      // result back so the sliders show what is actually in effect.
      this.pullFromStore();
    } catch (e) {
      promptAction.showToast({ message: `保存失败：${describeError(e)}` });
    }
  }

  /**
   * Opens a link in the system browser. Falls back to the clipboard when no
   * browser can handle it -- a phone without one is rare, but silently doing
   * nothing on tap reads as a broken button.
   */
  private async openUrl(url: string): Promise<void> {
    try {
      await ContextHolder.get().openLink(url);
      return;
    } catch (e) {
      Log.warn(`openLink failed: ${describeError(e)}`);
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '打不开浏览器，链接已复制' });
    } catch (e) {
      promptAction.showToast({ message: url, duration: 6000 });
    }
  }

  private confirmRemove(entry: ModelEntry): void {
    const running = this.store.currentModelId === entry.id && this.store.engineReady;
    AlertDialog.show({
      title: '删除模型',
      message: `将删除应用内的 ${entry.displayName}，释放 ${Fmt.size(entry.sizeBytes)} 存储空间。\n\n`
        + '你下载目录里的原始 GGUF 文件不受影响。'
        + (running ? '\n\n该模型正在运行，会先卸载再删除。' : ''),
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.danger,
        action: () => {
          this.removeModel(entry);
        }
      }
    });
  }

  private async removeModel(entry: ModelEntry): Promise<void> {
    try {
      await this.store.deleteModel(entry.id);
      this.pullFromStore();
      promptAction.showToast({ message: `已删除 ${entry.displayName}，释放 ${Fmt.size(entry.sizeBytes)}` });
    } catch (e) {
      promptAction.showToast({ message: `删除失败：${describeError(e)}`, duration: 6000 });
    }
  }

  /**
   * What the engine actually turned on, as opposed to what was requested.
   * Both optimisations have fallbacks, so without this line "it feels slow"
   * has no way of being diagnosed from the UI.
   */
  private runtimeFlags(): string {
    const parts: string[] = [];
    parts.push(this.store.flashAttn ? 'FA 开' : 'FA 关');
    parts.push(this.store.kvQuantized ? 'KV Q8' : 'KV F16');
    parts.push(this.store.pinnedCores > 0 ? `绑核 ${this.store.pinnedCores}` : '未绑核');
    parts.push(`ctx ${Fmt.tokens(this.store.effectiveContext)}`);
    return parts.join(' · ');
  }

  /**
   * What the context slider actually costs. The KV cache grows linearly with
   * the window, so this is the number that decides whether a setting is usable
   * on a phone -- not the slider position.
   */
  private ctxHint(): string {
    const lines: string[] = [];
    lines.push('越大越能记住早期对话。KV 缓存按 token 线性占用内存，这是手机上最先撞的墙。');
    const kv: number = this.store.kvBytesPerToken;
    if (kv > 0) {
      lines.push(`当前设置约需 ${Fmt.size(kv * this.contextLength)} KV 缓存`
        + `（每 token ${Math.round(kv / 1024)} KB）。`);
    } else {
      lines.push('加载任意模型后，这里会显示实际的 KV 缓存占用。');
    }
    const train: number = this.store.modelTrainContext;
    if (train > 0 && this.contextLength > train) {
      lines.push(`该模型只训练到 ${Fmt.tokens(train)}，超出的位置靠外推，回答会开始重复。`
        + `加载时会自动按 ${Fmt.tokens(train)} 处理。`);
    }
    return lines.join('\n');
  }

  private setContext(v: number): void {
    this.contextLength = v;
    const cap: number = outputCapFor(v);
    if (this.maxTokens > cap) {
      this.maxTokens = cap;
    }
  }

  @Builder
  ctxPresets() {
    Row() {
      ForEach([4096, 8192, 16384, 32768, 65536, 131072], (v: number) => {
        Text(Fmt.tokens(v))
          .fontSize(11)
          .fontColor(this.contextLength === v ? Theme.bg : Theme.textDim)
          .backgroundColor(this.contextLength === v ? Theme.accent : Theme.surfaceAlt)
          .borderRadius(10)
          .padding({ left: 9, right: 9, top: 5, bottom: 5 })
          .margin({ right: 6 })
          .onClick(() => {
            this.setContext(v);
          })
      }, (v: number) => `${v}`)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.radius)
    .margin({ bottom: 10 })
  }

  /**
   * Thinking models burn most of the budget before the first visible token, so
   * the old ctx/2 ceiling truncated them mid-reasoning. The ceiling now has a
   * 4k floor, but a small context still can't physically hold that -- say so
   * instead of silently offering a number the window will cut short.
   */
  private outputHint(): string {
    const cap: number = outputCapFor(this.contextLength);
    if (cap < MIN_OUTPUT_CAP) {
      return `当前上下文只有 ${Fmt.tokens(this.contextLength)}，加上提问后放不下 4k 输出，`
        + `上限被压到 ${Fmt.tokens(cap)}。想给深度思考模型留足余量，先把上下文提到 8k 以上。`;
    }
    return `深度思考类模型在正式回答前会用掉几千 token，建议 4k 起步。`
      + `当前上限 ${Fmt.tokens(cap)}，上下文越大上限越高。`;
  }

  private outputStep(): number {
    const cap: number = outputCapFor(this.contextLength);
    if (cap <= 2048) {
      return 64;
    }
    return cap <= 8192 ? 128 : 256;
  }

  private applyField(field: string, v: number): void {
    if (field === 'ctx') {
      this.contextLength = v;
      // Shrinking the context can leave the output cap stranded above the new
      // ceiling, which is exactly the state that makes every prompt fail.
      const cap = outputCapFor(v);
      if (this.maxTokens > cap) {
        this.maxTokens = cap;
      }
    } else if (field === 'threads') {
      this.threads = v;
    } else if (field === 'maxTokens') {
      this.maxTokens = v;
    } else if (field === 'temperature') {
      this.temperature = v;
    } else if (field === 'topP') {
      this.topP = v;
    }
  }

  private readField(field: string): number {
    if (field === 'ctx') {
      return this.contextLength;
    }
    if (field === 'threads') {
      return this.threads;
    }
    if (field === 'maxTokens') {
      return this.maxTokens;
    }
    if (field === 'temperature') {
      return this.temperature;
    }
    return this.topP;
  }

  /** Token counts read in k; everything else keeps its own unit. */
  private fieldLabel(field: string, unit: string): string {
    const v = this.readField(field);
    if (field === 'ctx' || field === 'maxTokens') {
      return Fmt.tokens(v);
    }
    return `${Math.round(v * 100) / 100}${unit}`;
  }

  @Builder
  sliderRow(label: string, hint: string, field: string, min: number, max: number,
            step: number, unit: string) {
    Column() {
      Row() {
        Text(label)
          .fontSize(14)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Text(this.fieldLabel(field, unit))
          .fontSize(13)
          .fontColor(Theme.accent)
      }
      .width('100%')

      Slider({
        value: this.readField(field),
        min: min,
        max: max,
        step: step,
        style: SliderStyle.OutSet
      })
        .selectedColor(Theme.accent)
        .trackColor(Theme.surfaceAlt)
        .blockColor(Theme.accent)
        .width('100%')
        .margin({ top: 2 })
        .onChange((v: number) => {
          this.applyField(field, v);
        })

      if (hint.length > 0) {
        Text(hint)
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .width('100%')
          .lineHeight(16)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.radius)
    .margin({ bottom: 10 })
  }

  @Builder
  sectionLabel(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor(Theme.textDim)
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .margin({ top: 18, bottom: 10 })
  }

  @Builder
  linkRow(label: string, value: string, url: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.textDim)
        .width(64)
      Text(value)
        .fontSize(12)
        .fontColor(Theme.accent)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
    .onClick(() => {
      this.openUrl(url);
    })
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(Theme.textDim)
        .width(96)
      Text(value)
        .fontSize(12)
        .fontColor(Theme.text)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 7, bottom: 7 })
  }

  @Builder
  modelRow(entry: ModelEntry) {
    Row() {
      Column() {
        Row() {
          Text(entry.displayName)
            .fontSize(14)
            .fontColor(Theme.text)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.store.currentModelId === entry.id && this.store.engineReady) {
            Text('运行中')
              .fontSize(9)
              .fontColor(Theme.bg)
              .backgroundColor(Theme.accent)
              .borderRadius(4)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .margin({ left: 6 })
          }
        }
        .alignItems(VerticalAlign.Center)

        Text(`${Fmt.size(entry.sizeBytes)} · ${entry.architecture} ${entry.quant}`)
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button('删除')
        .fontSize(12)
        .fontColor(Theme.danger)
        .backgroundColor(Theme.surfaceAlt)
        .height(30)
        .padding({ left: 12, right: 12 })
        .onClick(() => {
          this.confirmRemove(entry);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    Column() {
      Row() {
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Button('保存')
          .fontSize(13)
          .fontColor(Theme.bg)
          .backgroundColor(Theme.accent)
          .height(34)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.persist().then(() => {
              promptAction.showToast({ message: '已保存' });
            });
          })
      }
      .width('100%')
      .padding({ left: Theme.pad, right: Theme.pad, top: 14, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          Row() {
            Column() {
              Text(this.engineReady ? '已加载' : '未加载')
                .fontSize(12)
                .fontColor(this.engineReady ? Theme.ok : Theme.textDim)
              Text(this.engineReady ? this.modelName : '在「模型」页选择')
                .fontSize(11)
                .fontColor(Theme.textFaint)
                .margin({ top: 3 })
              if (this.engineReady) {
                Text(this.runtimeFlags())
                  .fontSize(10)
                  .fontColor(Theme.textDim)
                  .margin({ top: 5 })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text('改动上下文与线程后需要重新加载模型才生效')
              .fontSize(10)
              .fontColor(Theme.textFaint)
              .width(150)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.radius)

          this.sectionLabel('推理')
          this.sliderRow('上下文长度', this.ctxHint(),
            'ctx', MIN_CONTEXT, MAX_CONTEXT, 512, ' tok')
          this.ctxPresets()
          this.sliderRow('解码线程', '4 线程通常刚好占满小核集群。拉满 8 线程会唤醒大核，换来短暂提速和明显发热。',
            'threads', 1, 8, 1, ' 核')
          // The upper bound follows the context: output can never claim more
          // than half the window, otherwise the prompt itself has nowhere to go
          // and every message fails.
          this.sliderRow('单轮最大输出', this.outputHint(),
            'maxTokens', 64, outputCapFor(this.contextLength), this.outputStep(), ' tok')

          this.sectionLabel('采样')
          this.sliderRow('温度', '越低越保守稳定，越高越发散。事实类问答建议 0.2-0.5，创意写作 0.8 以上。',
            'temperature', 0, 1.5, 0.05, '')
          this.sliderRow('Top-P', '只从累计概率前 P 的候选里采样，和温度配合控制多样性。',
            'topP', 0.1, 1.0, 0.05, '')

          this.sectionLabel('系统提示词')
          Column() {
            Text('默认留空。填了内容会作为 system 消息放在每轮对话最前面，用来固定语气或限定格式；'
              + '留空则完全按模型自己的默认行为回答。')
              .fontSize(11)
              .fontColor(Theme.textFaint)
              .lineHeight(16)
              .width('100%')
              .margin({ bottom: 10 })

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(Object.keys(SYSTEM_PROMPT_PRESETS), (key: string) => {
                Text(key)
                  .fontSize(12)
                  .fontColor(this.systemPrompt === SYSTEM_PROMPT_PRESETS[key] ? Theme.bg : Theme.textDim)
                  .backgroundColor(this.systemPrompt === SYSTEM_PROMPT_PRESETS[key]
                    ? Theme.accent : Theme.surfaceAlt)
                  .borderRadius(12)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .margin({ right: 8, bottom: 8 })
                  .onClick(() => {
                    this.systemPrompt = SYSTEM_PROMPT_PRESETS[key];
                  })
              }, (key: string) => key)
            }
            .width('100%')

            TextArea({ text: this.systemPrompt, placeholder: '留空（推荐）。需要固定语气或输出格式时再写。' })
              .fontSize(13)
              .fontColor(Theme.text)
              .placeholderColor(Theme.textFaint)
              .backgroundColor(Theme.surfaceAlt)
              .borderRadius(10)
              .constraintSize({ minHeight: 90 })
              .width('100%')
              .margin({ top: 4 })
              .onChange((v: string) => {
                this.systemPrompt = v;
              })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.radius)

          this.sectionLabel('高级')
          Column() {
            Row() {
              Column() {
                Text('使用 mmap 加载')
                  .fontSize(14)
                  .fontColor(Theme.text)
                Text('默认关闭。鸿蒙在麒麟芯片上 mmap 冷启动可长达数十秒，关掉后加载降到 2-3 秒。'
                  + '只在内存特别紧张、需要省常驻内存时才打开。')
                  .fontSize(11)
                  .fontColor(Theme.textFaint)
                  .lineHeight(16)
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.useMmap })
                .selectedColor(Theme.accent)
                .onChange((on: boolean) => {
                  this.useMmap = on;
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.radius)

          this.sectionLabel('模型文件')
          Column() {
            Text(`共 ${this.models.length} 个已导入 · 占用 ${this.usedLabel}`)
              .fontSize(12)
              .fontColor(Theme.textDim)
              .width('100%')
            Text('导入时文件已经复制到应用私有目录，这里删除只清掉那份副本，你下载目录里的原始 GGUF 不受影响。')
              .fontSize(11)
              .fontColor(Theme.textFaint)
              .lineHeight(16)
              .width('100%')
              .margin({ top: 4 })

            if (this.models.length === 0) {
              Text('还没有导入任何模型。到「模型」页点「导入 GGUF」选择文件。')
                .fontSize(12)
                .fontColor(Theme.textFaint)
                .lineHeight(18)
                .width('100%')
                .padding({ top: 12 })
            } else {
              ForEach(this.models, (item: ModelEntry) => {
                Divider()
                  .color(Theme.border)
                  .strokeWidth(1)
                  .margin({ top: 6 })
                this.modelRow(item)
              }, (item: ModelEntry) => item.id)
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.radius)

          this.sectionLabel('关于')
          Column() {
            Text('驼峰 1.1.0')
              .fontSize(14)
              .fontColor(Theme.text)
              .fontWeight(FontWeight.Medium)

            Text('手机鸿蒙上的本地大模型运行时。导入自己的 GGUF 模型，推理全部在手机 CPU 上完成，'
              + '不联网、不注册、对话内容不出设备。')
              .fontSize(11)
              .fontColor(Theme.textFaint)
              .lineHeight(17)
              .margin({ top: 6 })

            Text('基于 llama.cpp，支持 Q4/Q5/Q8 等量化格式；多轮对话复用 KV 缓存，'
              + 'KV 量化与 Flash Attention 自动降级，兼容不支持的模型架构。')
              .fontSize(11)
              .fontColor(Theme.textFaint)
              .lineHeight(17)
              .margin({ top: 6 })

            Divider()
              .color(Theme.border)
              .strokeWidth(1)
              .margin({ top: 14, bottom: 4 })

            this.linkRow('作者', 'shy1658', PROJECT_URL)
            this.linkRow('GitHub', 'shy1658/CamelHump', PROJECT_URL)
            this.linkRow('爱发电', 'afdian.com/a/shy1658', SPONSOR_URL)

            Divider()
              .color(Theme.border)
              .strokeWidth(1)
              .margin({ top: 10, bottom: 4 })

            this.infoRow('版本', '1.1.0 (1001000)')
            this.infoRow('最低支持系统', 'HarmonyOS API 18')
            this.infoRow('推理引擎', 'llama.cpp · CPU')
            this.infoRow('开源协议', 'Apache-2.0')

            Text('如果这个应用帮到了你，欢迎在爱发电支持后续开发。')
              .fontSize(11)
              .fontColor(Theme.textFaint)
              .lineHeight(16)
              .margin({ top: 10 })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .backgroundColor(Theme.surface)
          .borderRadius(Theme.radius)
          .margin({ bottom: 24 })
        }
        .width('100%')
        .padding({ left: Theme.pad, right: Theme.pad })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
