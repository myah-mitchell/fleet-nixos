"""Draws the SSH login banner.

Reads the name, already drawn in large letters by figlet, from the file
given as the first argument, and the body text from the file given as the
second. Prints both inside one border: the name centred, a rule, then the
body.
"""

import sys

WAVE = "'`'*-._.-*"
# The same wave, started three characters in. The bottom border then begins
# on the character the top border's corner leads with, so the two look
# balanced.
ROTATED_WAVE = WAVE[3:] + WAVE[:3]
PADDING = 1


def wave(width, motif):
    """Repeats the motif and cuts it to exactly `width` characters."""
    if width <= 0:
        return ""
    return (motif * (width // len(motif) + 2))[:width]


def frame(name_art, body):
    name_lines = name_art.splitlines() or [""]
    body_lines = body.splitlines() or [""]
    # The first line of the body is indented like the start of a paragraph.
    body_lines[0] = "  " + body_lines[0]

    content_width = max(len(line) for line in name_lines + body_lines)
    inner_width = content_width + PADDING * 2
    outer_width = inner_width + 2

    def row(text="", centre=False):
        if centre:
            text = text.center(content_width)
        else:
            text = text.ljust(content_width)
        return "|" + " " * PADDING + text + " " * PADDING + "|"

    lines = [".*" + wave(outer_width - 3, WAVE) + ".", row()]
    lines.extend(row(line, centre=True) for line in name_lines)
    lines.extend([row(), "|" + "=" * inner_width + "|", row()])
    lines.extend(row(line) for line in body_lines)
    lines.extend([row(), wave(outer_width, ROTATED_WAVE)])
    return "\n".join(lines)


def main():
    with open(sys.argv[1], encoding="utf-8") as name_file:
        name_art = name_file.read()
    with open(sys.argv[2], encoding="utf-8") as body_file:
        body = body_file.read()
    print(frame(name_art, body))


if __name__ == "__main__":
    main()
