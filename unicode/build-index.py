#!/usr/bin/env python3
"""Build the nano-unicode search index.

Emits "<char>\t<NAME>" per line, which is exactly what fuzzel --dmenu shows
and nano-unicode's `cut -f1` recovers the character from. Searching the
displayed line matches on the name, so typing "grinning" finds the emoji and
typing "em dash" finds the punctuation.

Two sources, in order:

  UnicodeData.txt   every named codepoint. This is the same corpus fcitx5's
                    unicode addon searched, so the replacement is not a
                    downgrade in coverage.

  emoji-test.txt    the fully-qualified emoji *sequences* — flags, ZWJ
                    families, skin-tone variants — which are multi-codepoint
                    and therefore cannot appear in UnicodeData.txt at all.

Single-codepoint emoji already arrive via UnicodeData, so the emoji pass skips
anything of length 1 and the two sources never produce a duplicate entry.
"""

import sys

# Categories with nothing to paste: controls, surrogates (not even encodable),
# private use, unassigned, and the line/paragraph separators.
SKIP_CATEGORIES = {"Cc", "Cs", "Co", "Cn", "Zl", "Zp"}


def read_unicode_data(path, seen):
    """Yield index lines for every named, pasteable codepoint."""
    with open(path, encoding="utf-8") as handle:
        for row in handle:
            fields = row.split(";")
            if len(fields) < 3:
                continue
            code, name, category = fields[0], fields[1], fields[2]
            # Names in angle brackets are not real names: "<control>" and the
            # "<CJK Ideograph, First>" range markers, which describe a span
            # rather than a character.
            if name.startswith("<") or category in SKIP_CATEGORIES:
                continue
            char = chr(int(code, 16))
            if char in seen:
                continue
            seen.add(char)
            yield f"{char}\t{name}"


def read_emoji_sequences(path, seen):
    """Yield index lines for multi-codepoint fully-qualified emoji."""
    with open(path, encoding="utf-8") as handle:
        for row in handle:
            row = row.rstrip("\n")
            # The file's header explains the qualification statuses in prose,
            # so match on the data column only after dropping comment lines.
            if not row or row.startswith("#"):
                continue
            data, _, comment = row.partition("#")
            if "fully-qualified" not in data:
                continue
            codepoints = data.split(";")[0].split()
            if len(codepoints) < 2:
                continue
            char = "".join(chr(int(cp, 16)) for cp in codepoints)
            if char in seen:
                continue
            seen.add(char)
            # The comment reads " <emoji> E<version> <name>"; the name is
            # whatever follows the version token.
            parts = comment.strip().split(" ", 2)
            if len(parts) < 3:
                continue
            yield f"{char}\t{parts[2].upper()}"


def main():
    unicode_data, emoji_test, destination = sys.argv[1:4]
    seen = set()
    lines = list(read_unicode_data(unicode_data, seen))
    lines += list(read_emoji_sequences(emoji_test, seen))
    with open(destination, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    print(f"nano-unicode index: {len(lines)} entries", file=sys.stderr)


if __name__ == "__main__":
    main()
