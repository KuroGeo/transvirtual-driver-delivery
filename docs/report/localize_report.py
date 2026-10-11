"""Translate the shared report markup without changing its evidence or layout."""
import html
import json
import re
from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHINESE = re.compile(r'[\u4e00-\u9fff]')


class EnglishReport(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.translations = json.loads((HERE / 'english.json').read_text())
        self.output = []
        self.raw = None

    def translate(self, text):
        if not CHINESE.search(text) or text == '中文':
            return text
        if text.startswith('放大'):
            return 'Enlarge ' + self.translate(text[2:])
        if text not in self.translations:
            raise ValueError(f'Missing English report translation: {text!r}')
        return self.translations[text]

    def handle_decl(self, decl):
        self.output.append(f'<!{decl}>')

    def handle_starttag(self, tag, attrs):
        if tag in ('style', 'script'):
            self.raw = tag
        attrs = [(key, 'en' if tag == 'html' and key == 'lang'
                  else self.translate(value) if value is not None else None)
                 for key, value in attrs]
        if tag == 'track' and dict(attrs).get('srclang') == 'en':
            attrs.append(('default', None))
        rendered = ''.join(' ' + key if value is None else
                           f' {key}="{html.escape(value, quote=True)}"'
                           for key, value in attrs)
        self.output.append(f'<{tag}{rendered}>')

    def handle_endtag(self, tag):
        self.output.append(f'</{tag}>')
        if tag == self.raw:
            self.raw = None

    def handle_data(self, data):
        if self.raw:
            for source, target in {
                '阅读模式': 'Read', '演示模式': 'Present',
                '隐藏讲述提示': 'Hide notes', '讲述提示': 'Speaker notes',
                '82 秒视频：请打开线上汇报页第 09 节播放':
                '82-second video: open section 09 of the online report to play',
            }.items():
                data = data.replace(source, target)
            self.output.append(data)
        else:
            self.output.append(html.escape(self.translate(data), quote=False))

    def handle_comment(self, data):
        self.output.append(f'<!--{data}-->')


def english_report(document):
    parser = EnglishReport()
    parser.feed(document)
    parser.close()
    return ''.join(parser.output)
