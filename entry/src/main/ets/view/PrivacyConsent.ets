import { PRIVACY_URL } from '../core/Config';
import { ContextHolder } from '../core/ContextHolder';
import { Theme } from '../core/Theme';

/**
 * 首次运行的隐私政策授权弹窗。
 *
 * 华为应用市场要求（见《应用审核指南》与审核 FAQ）：
 *   · 应用首次运行时须通过弹窗向用户申请授权展示隐私政策
 *   · 用户同意前不得有任何调用权限 API 或获取个人信息的行为
 *   · 不得默认勾选同意项，须提供「不同意」选项
 *   · 弹窗不得遮挡隐私政策的勾选状态，审核员要能看清是否默认勾选
 *
 * 因此这里用一个自绘的全屏遮罩层，而不是系统 AlertDialog：
 * 系统弹窗无法展示复选框与完整条款链接，容易被判为「默认勾选」。
 */
@Component
export struct PrivacyConsent {
  /** 勾选框状态。初始为 false —— 严禁默认勾选。 */
  @State private agreed: boolean = false;
  /** 用户点击「同意」后回调。 */
  onAccept: () => void = () => {};
  /** 用户点击「不同意」后回调。 */
  onDecline: () => void = () => {};

  private openPolicy(): void {
    try {
      // 隐私政策托管在 GitHub Pages，需要联网打开。
      // 应用本身不联网，这一步由系统浏览器完成，不经过应用进程。
      ContextHolder.get().openLink(PRIVACY_URL);
    } catch (e) {
      // 打不开链接不该让用户卡在弹窗里，勾选后仍可继续。
    }
  }

  build() {
    Stack() {
      // 遮罩：阻止底层界面交互，用户必须做出选择
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => {})   // 吞掉点击，避免穿透

      Column() {
        Scroll() {
          Column() {
            Text('隐私政策')
              .fontSize(19)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.text)
              .margin({ bottom: 14 })

            Text('驼峰 CamelHump 是一款完全离线的本地大模型运行时。'
              + '在你同意本政策之前，我们不会获取任何个人信息。')
              .fontSize(13)
              .fontColor(Theme.text)
              .lineHeight(21)
              .margin({ bottom: 14 })

            Text('本应用不包含任何网络通信代码，不申请任何系统权限（包括网络权限），'
              + '不读取设备标识、位置、通讯录等个人信息，不含埋点统计与崩溃上报组件。')
              .fontSize(13)
              .fontColor(Theme.textDim)
              .lineHeight(21)
              .margin({ bottom: 14 })

            Text('你导入的模型文件、对话记录与参数偏好，仅保存在本应用私有沙箱目录内，'
              + '不会上传至任何服务器；卸载应用即一并清除。'
              + 'AI 生成的回复在界面上有明确的「AI 生成」标识。')
              .fontSize(13)
              .fontColor(Theme.textDim)
              .lineHeight(21)
              .margin({ bottom: 16 })

            Row() {
              Text('《隐私政策》')
                .fontSize(13)
                .fontColor(Theme.accent)
                .onClick(() => {
                  this.openPolicy();
                })
              Blank()
              Text('在浏览器中查看完整条款')
                .fontSize(11)
                .fontColor(Theme.textFaint)
            }
            .width('100%')
            .padding({ bottom: 16 })
            .border({ width: { bottom: 1 }, color: Theme.border })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)

        // 勾选项：默认不勾选
        Row() {
          Checkbox({ name: 'privacy_agree', group: 'privacy' })
            .width(18)
            .height(18)
            .select(this.agreed)
            .selectedColor(Theme.accent)
            .onChange((checked: boolean) => {
              this.agreed = checked;
            })
          Text('我已阅读并同意《隐私政策》')
            .fontSize(13)
            .fontColor(Theme.text)
            .margin({ left: 10 })
        }
        .width('100%')
        .padding({ top: 14, bottom: 14 })

        Row() {
          // 「不同意」必须有 —— 只给「同意」是驳回高发项
          Button('不同意并退出')
            .fontSize(14)
            .fontColor(Theme.textDim)
            .backgroundColor(Theme.surfaceAlt)
            .height(44)
            .layoutWeight(1)
            .onClick(() => {
              this.onDecline();
            })

          Button('同意并继续')
            .fontSize(14)
            .fontColor(this.agreed ? Theme.bg : Theme.textFaint)
            .backgroundColor(this.agreed ? Theme.accent : Theme.surfaceAlt)
            .height(44)
            .layoutWeight(1)
            .margin({ left: 10 })
            .onClick(() => {
              // 未勾选时不响应，避免「默认勾选」的观感
              if (!this.agreed) {
                return;
              }
              this.onAccept();
            })
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding({ left: 20, right: 20, top: 24, bottom: 20 })
      .backgroundColor(Theme.surface)
      .borderRadius(Theme.radius)
      .margin({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Center)
  }
}
