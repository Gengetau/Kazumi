#!/usr/bin/env python3
"""Generate the procedural branding used by the SyncPlay test build.

The script intentionally has no application/runtime dependencies.  Pillow is
used only by this development-time generator to rasterise the same geometric
design that is retained as ``icon_source.svg``.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageColor, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
BRANDING = ROOT / "test_distribution" / "branding"

BACKGROUND = "#18243A"
BACKGROUND_EDGE = "#2E4565"
BLUE = "#8FE4FF"
BLUE_DARK = "#29496A"
AMBER = "#FFCB69"
AVATAR_BACKGROUND = "#E7EDF7"
AVATAR_FOREGROUND = "#8998AE"


def _svg_source() -> str:
    return """<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <title>Kazumi SyncPlay Test procedural icon</title>
  <desc>Geometric play triangle, chat bubble, and test marker.</desc>
  <rect x="32" y="32" width="960" height="960" rx="220" fill="#18243A"/>
  <rect x="52" y="52" width="920" height="920" rx="202" fill="none" stroke="#2E4565" stroke-width="20"/>
  <path d="M300 320 L300 704 L650 512 Z" fill="#8FE4FF"/>
  <path d="M492 610 H790 C823 610 850 637 850 670 V730 C850 763 823 790 790 790 H740 L700 850 L682 790 H552 C519 790 492 763 492 730 Z" fill="#29496A" stroke="#8FE4FF" stroke-width="24" stroke-linejoin="round"/>
  <circle cx="580" cy="700" r="18" fill="#8FE4FF"/>
  <circle cx="650" cy="700" r="18" fill="#8FE4FF"/>
  <circle cx="720" cy="700" r="18" fill="#8FE4FF"/>
  <path d="M780 145 L842 181 L842 253 L780 289 L718 253 L718 181 Z" fill="#FFCB69" stroke="#18243A" stroke-width="14" stroke-linejoin="round"/>
  <path d="M756 217 L774 235 L807 197" fill="none" stroke="#18243A" stroke-width="18" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
"""


def _scaled_points(points: Iterable[tuple[float, float]], scale: int) -> list[tuple[int, int]]:
    return [(round(x * scale), round(y * scale)) for x, y in points]


def _draw_icon_layer(size: int, include_background: bool) -> Image.Image:
    scale = max(1, size // 256)
    canvas_size = 1024 * scale
    image = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    def box(values: tuple[float, float, float, float]) -> tuple[int, int, int, int]:
        return tuple(round(value * scale) for value in values)  # type: ignore[return-value]

    def width(value: float) -> int:
        return max(1, round(value * scale))

    if include_background:
        draw.rounded_rectangle(
            box((32, 32, 992, 992)),
            radius=round(220 * scale),
            fill=BACKGROUND,
        )
        draw.rounded_rectangle(
            box((52, 52, 972, 972)),
            radius=round(202 * scale),
            outline=BACKGROUND_EDGE,
            width=width(20),
        )

    draw.polygon(
        _scaled_points(((300, 320), (300, 704), (650, 512)), scale),
        fill=BLUE,
    )

    bubble = box((492, 610, 850, 790))
    draw.rounded_rectangle(
        bubble,
        radius=round(60 * scale),
        fill=BLUE_DARK,
        outline=BLUE,
        width=width(24),
    )
    draw.polygon(
        _scaled_points(((740, 790), (700, 850), (682, 790)), scale),
        fill=BLUE_DARK,
    )
    draw.line(
        _scaled_points(((740, 790), (700, 850), (682, 790)), scale),
        fill=BLUE,
        width=width(24),
        joint="curve",
    )
    for x in (580, 650, 720):
        draw.ellipse(box((x - 18, 682, x + 18, 718)), fill=BLUE)

    draw.polygon(
        _scaled_points(
            ((780, 145), (842, 181), (842, 253), (780, 289), (718, 253), (718, 181)),
            scale,
        ),
        fill=AMBER,
        outline=BACKGROUND,
    )
    draw.line(
        _scaled_points(((756, 217), (774, 235), (807, 197)), scale),
        fill=BACKGROUND,
        width=width(18),
        joint="curve",
    )

    if size != canvas_size:
        image = image.resize((size, size), Image.Resampling.LANCZOS)
    return image


def _draw_avatar(size: int = 180) -> Image.Image:
    scale = max(1, size // 90)
    large = size * scale
    image = Image.new(
        "RGBA",
        (large, large),
        ImageColor.getcolor(AVATAR_BACKGROUND, "RGBA"),
    )
    draw = ImageDraw.Draw(image)

    def box(values: tuple[float, float, float, float]) -> tuple[int, int, int, int]:
        return tuple(round(value * scale) for value in values)  # type: ignore[return-value]

    draw.rounded_rectangle(
        box((0, 0, size, size)),
        radius=round(28 * scale),
        fill=AVATAR_BACKGROUND,
    )
    draw.ellipse(box((61, 35, 119, 93)), fill=AVATAR_FOREGROUND)
    draw.rounded_rectangle(
        box((38, 96, 142, 153)),
        radius=round(28 * scale),
        fill=AVATAR_FOREGROUND,
    )
    draw.rounded_rectangle(
        box((38, 138, 142, 153)),
        radius=round(7 * scale),
        fill=AVATAR_FOREGROUND,
    )
    if large != size:
        image = image.resize((size, size), Image.Resampling.LANCZOS)
    return image


def _save_png(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True)


def _save_jpeg(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.convert("RGB").save(path, format="JPEG", quality=95, optimize=True)


def _save_ico(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(
        path,
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )


def generate() -> None:
    BRANDING.mkdir(parents=True, exist_ok=True)
    icon = _draw_icon_layer(1024, include_background=True)
    foreground = _draw_icon_layer(1024, include_background=False)
    avatar = _draw_avatar()

    (BRANDING / "icon_source.svg").write_text(_svg_source(), encoding="utf-8")
    _save_png(icon, BRANDING / "icon_1024.png")
    _save_png(foreground, BRANDING / "icon_foreground_1024.png")
    _save_png(avatar, BRANDING / "neutral_avatar.png")

    # Keep every packaged logo path procedural as well.  The launcher-icon
    # tool may regenerate Android/Windows outputs from the same source later.
    _save_png(icon, ROOT / "assets/images/logo/logo_android.png")
    _save_png(icon, ROOT / "assets/images/logo/logo_ios.png")
    _save_png(icon.resize((512, 512), Image.Resampling.LANCZOS), ROOT / "assets/images/logo/logo_linux.png")
    _save_png(icon, ROOT / "assets/images/logo/logo_rounded.png")
    _save_ico(icon, ROOT / "assets/images/logo/logo_lanczos.ico")
    _save_ico(icon, ROOT / "assets/images/logo/logo_windows.ico")
    _save_ico(icon, ROOT / "windows/runner/resources/app_icon.ico")
    _save_jpeg(avatar, ROOT / "assets/images/noface.jpeg")

    for density, pixels in {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }.items():
        _save_png(
            icon.resize((pixels, pixels), Image.Resampling.LANCZOS),
            ROOT / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png",
        )
        foreground_pixels = round(pixels * 2.25)
        _save_png(
            foreground.resize((foreground_pixels, foreground_pixels), Image.Resampling.LANCZOS),
            ROOT / f"android/app/src/main/res/drawable-{density}/ic_launcher_foreground.png",
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    generate()
    print(f"Generated procedural SyncPlay test branding under {BRANDING}")


if __name__ == "__main__":
    main()
