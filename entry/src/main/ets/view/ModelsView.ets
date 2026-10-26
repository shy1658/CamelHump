import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { AppStore } from '../core/AppStore';
import { CuratedModel, ModelEntry } from '../core/Types';
import { Fmt, Theme } from '../core/Theme';
import { pickGgufFile } from '../core/ModelRepository';
import { describeError, Log } from '../core/Logger';

@Component
export struct ModelsView {
  @State models: ModelEntry[] = [];
  @State importing: boolean = false;
  @State progress: number = 0;
  @State busyId: string = '';
  @State enginePresent: boolean = true;
  @State freeLabel: string = '';
  @State usedLabel: string = '';
  // Deleting a model from the settings tab happens on another page, and tab
  // switches do not fire onPageShow, so the list has to follow the store's
  // version counter instead.
  @StorageLink('modelsVersion') @Watch('onModelsVersion') modelsVersion: number = 0;

  private store: AppStore = AppStore.get();

  onActivated: () => void = () => {};

  aboutToAppear(): void {
    this.refresh();
  }

  onPageShow(): void {
    this.refresh();
  }

  onModelsVersion(): void {
    this.refresh();
  }

  private refresh(): void {
    this.models = this.store.models.slice();
    this.enginePresent = this.store.enginePresent;
    this.usedLabel = Fmt.size(this.store.totalModelBytes());
    const free = this.store.freeBytes();
    this.freeLabel = free > 0 ? Fmt.size(free) : '未知';
  }

  private async doImport(): Promise<void> {
    if (this.importing) {
      return;
    }
    let uri = '';
    try {
      uri = await pickGgufFile();
    } catch (e) {
      promptAction.showToast({ message: `打开文件选择器失败：${describeError(e)}` });
      return;
    }
    if (uri.length === 0) {
      return;
    }

    this.importing = true;
    this.progress = 0;
    try {
      const result = await this.store.importFile(uri, '', (r: number) => {
        this.progress = r;
      });
      const info = result.info;
      promptAction.showToast({
        message: `已导入 ${result.entry.displayName}（${info.architecture} ${info.quant}）。`
          + `文件已复制到应用内，下载目录里的原文件可以删了。`,
        duration: 5000
      });
      this.refresh();
      // First successful import is the moment to prove the file actually runs.
      this.activate(result.entry);
    } catch (e) {
      promptAction.showToast({ message: describeError(e), duration: 6000 });
      Log.error(`import failed: ${describeError(e)}`);
    } finally {
      this.importing = false;
      this.progress = 0;
    }
  }

  private async activate(entry: ModelEntry): Promise<void> {
    if (this.busyId.length > 0) {
      return;
    }
    this.busyId = entry.id;
    try {
      await this.store.activate(entry);
      promptAction.showToast({ message: `${entry.displayName} 已加载` });
      this.onActivated();
    } catch (e) {
      promptAction.showToast({ message: `加载失败：${describeError(e)}`, duration: 6000 });
    } finally {
      this.busyId = '';
    }
  }

  /**
   * Unloads the running model and keeps the file on disk. Users switch models
   * far more often than they delete them, and holding one model's weights while
   * another loads is the fastest way to hit the process memory cap.
   */
  private deactivate(entry: ModelEntry): void {
    try {
      this.store.deactivate();
      promptAction.showToast({
        message: `已停止 ${entry.displayName}，释放约 ${Fmt.size(entry.sizeBytes)} 内存`
      });
      this.refresh();
    } catch (e) {
      promptAction.showToast({ message: `停止失败：${describeError(e)}` });
    }
  }

  private confirmDelete(entry: ModelEntry): void {
    AlertDialog.show({
      title: '删除模型',
      message: `将从设备移除 ${entry.displayName}，释放 ${Fmt.size(entry.sizeBytes)}。此操作不可撤销。`,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '删除',
        fontColor: Theme.danger,
        action: () => {
          this.remove(entry);
        }
      }
    });
  }

  private async remove(entry: ModelEntry): Promise<void> {
    try {
      await this.store.deleteModel(entry.id);
      this.refresh();
    } catch (e) {
      promptAction.showToast({ message: `删除失败：${describeError(e)}` });
    }
  }

  private copyLink(item: CuratedModel): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.url);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({
          message: '下载链接已复制。用浏览器下载后再回到这里「导入 GGUF」即可。',
          duration: 4000
        });
      });
    } catch (e) {
      promptAction.showToast({ message: `复制失败：${describeError(e)}` });
    }
  }

  @Builder
  storageBar() {
    Row() {
      Column() {
        Text('已用')
          .fontSize(10)
          .fontColor(Theme.textFaint)
        Text(this.usedLabel)
          .fontSize(13)
          .fontColor(Theme.text)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column() {
        Text('可用')
          .fontSize(10)
          .fontColor(Theme.textFaint)
        Text(this.freeLabel)
          .fontSize(13)
          .fontColor(Theme.text)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Column() {
        Text('已装模型')
          .fontSize(10)
          .fontColor(Theme.textFaint)
        Text(`${this.models.length}`)
          .fontSize(13)
          .fontColor(Theme.text)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.radius)
  }

  @Builder
  modelCard(entry: ModelEntry) {
    Column() {
      Row() {
        Column() {
          Row() {
            Text(entry.displayName)
              .fontSize(15)
              .fontColor(Theme.text)
              .fontWeight(FontWeight.Medium)
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

          Text(`${entry.architecture} · ${entry.quant}${entry.hasChatTemplate ? ' · 含对话模板' : ''}`)
            .fontSize(11)
            .fontColor(Theme.textDim)
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(`${Fmt.size(entry.sizeBytes)} · 上下文 ${entry.contextLength > 0 ? entry.contextLength : '未知'}`)
            .fontSize(11)
            .fontColor(Theme.textFaint)
            .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.store.currentModelId === entry.id && this.store.engineReady) {
          Button('停止')
            .fontSize(13)
            .fontColor(Theme.danger)
            .backgroundColor(Theme.surfaceAlt)
            .height(34)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.deactivate(entry);
            })
        } else {
          Button(this.busyId === entry.id ? '加载中' : '使用')
            .fontSize(13)
            .fontColor(Theme.bg)
            .backgroundColor(Theme.accent)
            .height(34)
            .padding({ left: 16, right: 16 })
            .enabled(this.busyId.length === 0)
            .onClick(() => {
              this.activate(entry);
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.radius)
    .onClick(() => {
      if (this.busyId.length > 0) {
        return;
      }
      AlertDialog.show({
        title: entry.displayName,
        message: `架构 ${entry.architecture}\n量化 ${entry.quant}\n大小 ${Fmt.size(entry.sizeBytes)}\n`
          + `层数 ${entry.blockCount}\n上下文 ${entry.contextLength}\n`
          + `文件${entry.complete ? '完整' : '可能不完整'}`,
        primaryButton: {
          value: '关闭',
          action: () => {}
        },
        secondaryButton: {
          value: '删除',
          fontColor: Theme.danger,
          action: () => this.remove(entry)
        }
      });
    })
  }

  @Builder
  curatedRow(item: CuratedModel) {
    Column() {
      Row() {
        Column() {
          Text(item.name)
            .fontSize(14)
            .fontColor(Theme.text)
          Text(`${item.params} · ${item.quant} · ${item.sizeMb} MB · 建议 ${item.minRamGb}GB 内存起`)
            .fontSize(11)
            .fontColor(Theme.textDim)
            .margin({ top: 3 })
          Text(item.note)
            .fontSize(11)
            .fontColor(Theme.textFaint)
            .margin({ top: 4 })
            .maxLines(2)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('取链接')
          .fontSize(12)
          .fontColor(Theme.accent)
          .backgroundColor(Theme.surfaceAlt)
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick(() => this.copyLink(item))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Theme.surface)
    .borderRadius(Theme.radius)
  }

  @Builder
  sectionTitle(text: string, hint: string) {
    Column() {
      Text(text)
        .fontSize(13)
        .fontColor(Theme.textDim)
        .fontWeight(FontWeight.Medium)
      if (hint.length > 0) {
        Text(hint)
          .fontSize(11)
          .fontColor(Theme.textFaint)
          .margin({ top: 3 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ top: 20, bottom: 10 })
  }

  build() {
    Column() {
      Row() {
        Text('模型')
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text)
          .layoutWeight(1)
        Button(this.importing ? '导入中…' : '导入 GGUF')
          .fontSize(13)
          .fontColor(Theme.bg)
          .backgroundColor(Theme.accent)
          .height(34)
          .padding({ left: 14, right: 14 })
          .enabled(!this.importing)
          .onClick(() => {
            this.doImport();
          })
      }
      .width('100%')
      .padding({ left: Theme.pad, right: Theme.pad, top: 14, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      if (!this.enginePresent) {
        Text('本次构建未包含推理引擎。界面可用，但无法加载模型 —— 需要先拉取 llama.cpp 子模块再重新编译。')
          .fontSize(12)
          .fontColor(Theme.danger)
          .width('100%')
          .padding(14)
          .backgroundColor('#2A1518')
          .borderRadius(Theme.radius)
          .margin({ left: Theme.pad, right: Theme.pad, bottom: 12 })
      }

      Scroll() {
        Column() {
          this.storageBar()

          if (this.importing) {
            Column() {
              Row() {
                Text('正在复制并校验模型文件')
                  .fontSize(12)
                  .fontColor(Theme.text)
                  .layoutWeight(1)
                Text(`${Math.round(this.progress * 100)}%`)
                  .fontSize(12)
                  .fontColor(Theme.accent)
              }
              .width('100%')

              Progress({ value: this.progress * 100, total: 100, type: ProgressType.Linear })
                .color(Theme.accent)
                .backgroundColor(Theme.surfaceAlt)
                .width('100%')
                .height(4)
                .margin({ top: 10 })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.radius)
            .margin({ top: 12 })
          }

          this.sectionTitle('已导入', this.models.length > 0
            ? '导入时已复制一份到应用私有目录，下载目录里的原文件可以删掉，随时能在这里删除副本。'
            : '还没有模型。点右上角「导入 GGUF」，选择你下载好的模型文件。导入后会复制到应用内，原文件可以删。')

          if (this.models.length === 0) {
            Column() {
              Text('GGUF 文件通常以 .gguf 结尾')
                .fontSize(12)
                .fontColor(Theme.textDim)
              Text('例：Qwen2.5-1.5B-Instruct-Q4_K_M.gguf')
                .fontSize(11)
                .fontColor(Theme.textFaint)
                .margin({ top: 6 })
            }
            .width('100%')
            .padding(20)
            .backgroundColor(Theme.surface)
            .borderRadius(Theme.radius)
            .alignItems(HorizontalAlign.Start)
          } else {
            ForEach(this.models, (item: ModelEntry) => {
              Column() {
                this.modelCard(item)
              }
              .margin({ bottom: 10 })
            }, (item: ModelEntry) => item.id)
          }

          this.sectionTitle('推荐模型', '复制链接后用浏览器下载，再回到本页导入。手机端建议不超过 3B。')

          ForEach(this.store.curated(), (item: CuratedModel) => {
            Column() {
              this.curatedRow(item)
            }
            .margin({ bottom: 10 })
          }, (item: CuratedModel) => item.id)

          Text('为什么不做应用内直连下载：模型分发涉及 CDN、配额与合规审核，属于运营决策。'
            + '第一版把「导入」这条链路做扎实，下载入口留到有稳定源之后再接。')
            .fontSize(11)
            .fontColor(Theme.textFaint)
            .lineHeight(17)
            .width('100%')
            .margin({ top: 16, bottom: 24 })
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
