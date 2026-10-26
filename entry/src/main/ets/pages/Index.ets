import { ChatView } from '../view/ChatView';
import { ModelsView } from '../view/ModelsView';
import { SettingsView } from '../view/SettingsView';
import { AppStore } from '../core/AppStore';
import { Theme } from '../core/Theme';
import { describeError } from '../core/Logger';

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @State ready: boolean = false;
  @State bootError: string = '';

  private controller: TabsController = new TabsController();

  aboutToAppear(): void {
    AppStore.get().boot()
      .then(() => {
        this.ready = true;
      })
      .catch((e: Object) => {
        this.bootError = describeError(e);
        this.ready = true;
      });
  }

  @Builder
  tabItem(label: string, index: number) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.currentTab === index ? Theme.accent : Theme.textFaint)
      if (this.currentTab === index) {
        Divider()
          .width(18)
          .strokeWidth(2)
          .color(Theme.accent)
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  booting() {
    Column() {
      LoadingProgress()
        .width(38)
        .height(38)
        .color(Theme.accent)
      Text('正在启动')
        .fontSize(12)
        .fontColor(Theme.textDim)
        .margin({ top: 14 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(Theme.bg)
  }

  build() {
    Stack() {
      if (!this.ready) {
        this.booting()
      } else if (this.bootError.length > 0) {
        Column() {
          Text('启动失败')
            .fontSize(16)
            .fontColor(Theme.text)
          Text(this.bootError)
            .fontSize(12)
            .fontColor(Theme.danger)
            .margin({ top: 10 })
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.bg)
      } else {
        Tabs({ barPosition: BarPosition.End, controller: this.controller }) {
          TabContent() {
            ChatView()
          }
          .tabBar(this.tabItem('对话', 0))

          TabContent() {
            ModelsView({
              onActivated: () => {
                this.controller.changeIndex(0);
              }
            })
          }
          .tabBar(this.tabItem('模型', 1))

          TabContent() {
            SettingsView()
          }
          .tabBar(this.tabItem('设置', 2))
        }
        .barHeight(56)
        .barBackgroundColor(Theme.surface)
        .scrollable(false)
        .onChange((index: number) => {
          this.currentTab = index;
        })
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.bg)
  }
}
