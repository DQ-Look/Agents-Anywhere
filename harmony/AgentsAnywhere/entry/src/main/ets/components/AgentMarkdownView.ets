import { pasteboard } from '@kit.BasicServicesKit';
import { MdBlock, MdSpan, mdTextHash } from '../common/Markdown';

function mdBlockKey(block: MdBlock, index: number): string {
  let content = `${block.kind}|${block.language}|${block.codeText}`;
  for (const span of block.spans) {
    content += span.text;
    if (span.linkUrl !== null) {
      content += span.linkUrl;
    }
  }
  return `${index}_${mdTextHash(content)}`;
}

function mdSpanKey(span: MdSpan, index: number): string {
  let content = span.text;
  if (span.linkUrl !== null) {
    content += span.linkUrl;
  }
  return `${index}_${mdTextHash(content)}`;
}

@Component
export struct AgentMarkdownView {
  @Prop blocks: MdBlock[] = [];
  @Prop textColor: string = '#1F2937';
  @Prop linkColor: string = '#2563EB';
  @Prop inlineCodeColor: string = '#C2410C';
  @Prop codePanelColor: string = '#1F2937';
  @Prop codePanelTextColor: string = '#E5E7EB';
  @Prop fontSize: number = 15;

  private headingFontSize(level: number): number {
    if (level <= 1) {
      return 22;
    }
    if (level === 2) {
      return 20;
    }
    if (level === 3) {
      return 18;
    }
    if (level === 4) {
      return 16;
    }
    return 15;
  }

  private listMarkerText(block: MdBlock): string {
    if (block.ordered) {
      return `${block.itemNumber}.`;
    }
    return '•';
  }

  private spanFontWeight(span: MdSpan): FontWeight {
    return span.bold ? FontWeight.Bold : FontWeight.Normal;
  }

  private spanFontColor(span: MdSpan): string {
    if (span.linkUrl !== null) {
      return this.linkColor;
    }
    if (span.code) {
      return this.inlineCodeColor;
    }
    return this.textColor;
  }

  private spanFontStyle(span: MdSpan): FontStyle {
    return span.italic ? FontStyle.Italic : FontStyle.Normal;
  }

  private spanDecorationType(span: MdSpan): TextDecorationType {
    if (span.strike) {
      return TextDecorationType.LineThrough;
    }
    if (span.linkUrl !== null) {
      return TextDecorationType.Underline;
    }
    return TextDecorationType.None;
  }

  private spanFontFamily(span: MdSpan): string {
    if (span.code) {
      return 'monospace';
    }
    return '';
  }

  @Builder
  spanContent(spans: MdSpan[]) {
    ForEach(spans, (span: MdSpan, index: number) => {
      Span(span.text)
        .fontWeight(this.spanFontWeight(span))
        .fontColor(this.spanFontColor(span))
        .fontStyle(this.spanFontStyle(span))
        .decoration({ type: this.spanDecorationType(span) })
        .fontFamily(this.spanFontFamily(span))
    }, (span: MdSpan, index: number) => mdSpanKey(span, index))
  }

  @Builder
  blockView(block: MdBlock, index: number) {
    if (block.kind === 'code') {
      MdCodePanelView({
        codeText: block.codeText,
        language: block.language,
        panelColor: this.codePanelColor,
        panelTextColor: this.codePanelTextColor
      })
    } else if (block.kind === 'heading') {
      Text() {
        this.spanContent(block.spans)
      }
      .fontSize(this.headingFontSize(block.level))
      .width('100%')
    } else if (block.kind === 'quote') {
      Column() {
        AgentMarkdownView({
          blocks: block.children,
          textColor: this.textColor,
          linkColor: this.linkColor,
          inlineCodeColor: this.inlineCodeColor,
          codePanelColor: this.codePanelColor,
          codePanelTextColor: this.codePanelTextColor,
          fontSize: this.fontSize
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 10, top: 2, bottom: 2 })
      .border({ width: { left: 3 }, color: '#D1D5DB' })
    } else if (block.kind === 'listItem') {
      Row({ space: 6 }) {
        Text(this.listMarkerText(block))
          .fontSize(this.fontSize)
          .fontColor(this.textColor)
        Text() {
          this.spanContent(block.spans)
        }
        .fontSize(this.fontSize)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else if (block.kind === 'rule') {
      Divider()
        .color('#E5E7EB')
        .width('100%')
    } else {
      Text() {
        this.spanContent(block.spans)
      }
      .fontSize(this.fontSize)
      .width('100%')
    }
  }

  build() {
    Column({ space: 6 }) {
      ForEach(this.blocks, (block: MdBlock, index: number) => {
        this.blockView(block, index)
      }, (block: MdBlock, index: number) => mdBlockKey(block, index))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct MdCodePanelView {
  @Prop codeText: string = '';
  @Prop language: string = '';
  @Prop panelColor: string = '#1F2937';
  @Prop panelTextColor: string = '#E5E7EB';
  @State copied: boolean = false;

  private codeLabel(): string {
    if (this.language.length > 0) {
      return this.language;
    }
    return 'code';
  }

  private copyLabel(): string {
    return this.copied ? 'Copied' : 'Copy';
  }

  private copyCode(): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.codeText);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => {
        this.copied = true;
        setTimeout(() => {
          this.copied = false;
        }, 1500);
      })
      .catch(() => {
      });
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text(this.codeLabel())
          .fontSize(10)
          .fontColor('#9CA3AF')
          .fontFamily('monospace')
          .layoutWeight(1)
        Button(this.copyLabel())
          .fontSize(11)
          .height(24)
          .padding({ left: 10, right: 10 })
          .backgroundColor('#374151')
          .fontColor('#E5E7EB')
          .onClick(() => {
            this.copyCode();
          })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 6 })
      Text(this.codeText)
        .fontSize(12)
        .fontFamily('monospace')
        .fontColor(this.panelTextColor)
        .width('100%')
        .textAlign(TextAlign.Start)
        .padding({ left: 10, right: 10, top: 6, bottom: 10 })
        .copyOption(CopyOptions.InApp)
    }
    .width('100%')
    .borderRadius(6)
    .backgroundColor(this.panelColor)
  }
}
