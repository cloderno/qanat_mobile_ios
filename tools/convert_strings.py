"""
Переносит строки из Android-проекта в Localizable.strings / Localizable.stringsdict.

    python tools/convert_strings.py ../qanat_mobile_android/app/src/main/res

Ключи — те же имена, что в Android (login_title, chat_photos…), чтобы правки текстов
переносились одним запуском. values/ — русский (язык по умолчанию), values-kk, values-en.
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

LANGS = {"values": "ru", "values-kk": "kk", "values-en": "en"}
OUT = Path(__file__).resolve().parent.parent / "Qanat" / "Resources"


def android_text(raw: str) -> str:
    """Текст Android-ресурса → обычная строка: снимает кавычки-обёртки и экранирование."""
    text = raw.strip()
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        text = text[1:-1]
    else:
        text = re.sub(r"\s+", " ", text)
    out, i = [], 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            out.append({"n": "\n", "t": "\t"}.get(nxt, nxt))
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def ios_format(text: str) -> str:
    """%s → %@ (в Foundation строка — объект), позиционные %1$s → %1$@."""
    return re.sub(r"%(\d+\$)?s", lambda m: "%" + (m.group(1) or "") + "@", text)


def escape_strings(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def element_text(el) -> str:
    # Вложенная разметка (<b>, <xliff:g>) — берём только текст.
    return "".join(el.itertext())


def xml_escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def convert(res: Path):
    for folder, lang in LANGS.items():
        strings, plurals = {}, {}
        for file in sorted((res / folder).glob("strings*.xml")):
            root = ET.parse(file).getroot()
            for el in root:
                name = el.get("name")
                if el.get("translatable") == "false" and folder != "values":
                    continue
                if el.tag == "string":
                    strings[name] = ios_format(android_text(element_text(el)))
                elif el.tag == "plurals":
                    plurals[name] = {
                        item.get("quantity"): ios_format(android_text(element_text(item))) for item in el
                    }
        out_dir = OUT / f"{lang}.lproj"
        out_dir.mkdir(parents=True, exist_ok=True)
        lines = [f'"{k}" = "{escape_strings(v)}";' for k, v in sorted(strings.items())]
        (out_dir / "Localizable.strings").write_text(
            "/* Сгенерировано tools/convert_strings.py из Android-ресурсов — не править вручную. */\n"
            + "\n".join(lines) + "\n",
            encoding="utf-8",
        )
        (out_dir / "Localizable.stringsdict").write_text(stringsdict(plurals), encoding="utf-8")
        print(f"{lang}: {len(strings)} строк, {len(plurals)} plurals")


def stringsdict(plurals: dict) -> str:
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
    ]
    for name, items in sorted(plurals.items()):
        sample = next(iter(items.values()))
        # Число — первый %d (позиционный или нет); остальные аргументы остаются в самой строке.
        spec = re.search(r"%(\d+\$)?d", sample)
        position = spec.group(1) or ""
        parts += [
            f"  <key>{name}</key>",
            "  <dict>",
            "    <key>NSStringLocalizedFormatKey</key>",
            f"    <string>%{position}#@value@</string>",
            "    <key>value</key>",
            "    <dict>",
            "      <key>NSStringFormatSpecTypeKey</key>",
            "      <string>NSStringPluralRuleType</string>",
            "      <key>NSStringFormatValueTypeKey</key>",
            "      <string>d</string>",
        ]
        for quantity, text in items.items():
            parts += [f"      <key>{quantity}</key>", f"      <string>{xml_escape(text)}</string>"]
        parts += ["    </dict>", "  </dict>"]
    parts += ["</dict>", "</plist>", ""]
    return "\n".join(parts)


if __name__ == "__main__":
    convert(Path(sys.argv[1]))
