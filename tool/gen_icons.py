#!/usr/bin/env python3
"""Render every launcher icon axiotask ships from the ONE SVG master (#225).

There is exactly one hand-authored icon in this repository:

    assets/branding/axiotask.svg

Everything else — the Linux hicolor theme set, the legacy Android launcher
bitmaps and the three adaptive-icon layers — is DERIVED from it here. No raster
in the tree is hand-exported; if one ever is, the recorded hashes in
assets/branding/icons.sha256 stop matching and test/packaging/app_icon_test.dart
fails. Edit the master, re-run this script, commit the master + the rasters +
the manifest together.

The five layers, and how each is derived from the master:

  full        the master untouched — rounded tile + mark. Linux hicolor PNGs and
              the legacy (pre-API-26) Android launcher bitmap.
  round       the tile's corner radius raised to a full circle, for launchers
              that ask for android:roundIcon on API 25 and below.
  foreground  the mark alone on transparency, scaled by 72/108 about the canvas
              centre. An adaptive icon shows only the middle 72dp of its 108dp
              canvas, so art placed 1:1 would appear zoomed compared with the
              desktop tile; that scale makes the launcher icon read at the same
              visual size, and it lands the whole glyph well inside the 66dp
              safe-zone circle, where no mask (circle, squircle, teardrop) can
              clip it.
  background  the tile alone with its corner radius dropped, because the OS mask
              — not the art — decides the silhouette of an adaptive icon.
  monochrome  the glyph alone in flat black, on the same adaptive scale (the
              shade pass dropped). Android 13+ tints this for themed icons, so
              no tone may be baked in.

Renderer: python3 `cairosvg` (Fedora: `sudo dnf install python3-cairosvg`,
otherwise `pip install cairosvg`). Exactly ONE renderer on purpose — two
rasterizers produce different bytes for the same SVG, which would make the
recorded hashes meaningless. If cairosvg is missing this script exits 3 and
renders nothing rather than pretending to have succeeded.

Usage:
    tool/gen_icons.py                 regenerate every raster + rewrite the manifest
    tool/gen_icons.py --check         render to a temp dir and diff against the
                                      committed files; non-zero exit on any drift
    tool/gen_icons.py --root DIR      operate on DIR instead of the repo root
    tool/gen_icons.py --help          this text

Exit codes: 0 ok · 1 drift or error · 3 renderer unavailable.
"""

import argparse
import copy
import hashlib
import os
import sys
import tempfile
import xml.etree.ElementTree as ET

SVG_NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG_NS)

MASTER = "assets/branding/axiotask.svg"
MANIFEST = "assets/branding/icons.sha256"

# freedesktop icon-theme sizes an application icon is expected to provide.
HICOLOR_SIZES = (16, 24, 32, 48, 64, 128, 256, 512)
HICOLOR_SVG = "linux/packaging/icons/hicolor/scalable/apps/axiotask.svg"

# Android density buckets: (legacy launcher px, adaptive-layer px for 108dp).
ANDROID_DENSITIES = {
    "mdpi": (48, 108),
    "hdpi": (72, 162),
    "xhdpi": (96, 216),
    "xxhdpi": (144, 324),
    "xxxhdpi": (192, 432),
}


# An adaptive icon renders its 108dp canvas but only ever SHOWS the middle 72dp.
# Placing the mark 1:1 there would make the launcher icon look zoomed next to the
# desktop tile, so the foreground/monochrome layers are scaled about the centre
# by 72/108 — which also parks the glyph far inside the 66dp safe zone.
_ADAPTIVE_SCALE = 72 / 108
_ADAPTIVE_TRANSFORM = (
    f"translate({256 * (1 - _ADAPTIVE_SCALE):.4f} {256 * (1 - _ADAPTIVE_SCALE):.4f}) "
    f"scale({_ADAPTIVE_SCALE:.6f})"
)


def _hicolor_png(size):
    return f"linux/packaging/icons/hicolor/{size}x{size}/apps/axiotask.png"


def _mipmap(density, name):
    return f"android/app/src/main/res/mipmap-{density}/{name}.png"


# ── SVG derivation ─────────────────────────────────────────────────────────────
# Each variant is a small, explicit edit of the master's element tree. Working on
# the parsed tree (not string surgery) means a renamed id fails loudly instead of
# silently producing an empty layer.


def _index(root):
    """id -> (element, parent). Raises if the master lost a load-bearing id."""
    found = {}
    for parent in root.iter():
        for child in parent:
            el_id = child.get("id")
            if el_id:
                found[el_id] = (child, parent)
    return found


def _require(index, el_id):
    if el_id not in index:
        sys.exit(
            f"error: {MASTER} has no element with id={el_id!r} — the generator "
            f"derives every platform layer from that id; restore it or update "
            f"this script and test/packaging/app_icon_test.dart together."
        )
    return index[el_id]


def _drop(index, el_id):
    element, parent = _require(index, el_id)
    parent.remove(element)


def _variant(master_root, name):
    root = copy.deepcopy(master_root)
    index = _index(root)
    if name == "full":
        pass
    elif name == "round":
        tile, _ = _require(index, "bg-tile")
        tile.set("rx", "256")
        tile.set("ry", "256")
    elif name == "foreground":
        _drop(index, "bg")
        mark, _ = _require(index, "mark")
        mark.set("transform", _ADAPTIVE_TRANSFORM)
    elif name == "background":
        _drop(index, "mark")
        tile, _ = _require(index, "bg-tile")
        # An adaptive background is full-bleed: the OS mask cuts the silhouette,
        # so a rounded tile here would show as a rounded shape inside the mask.
        tile.set("rx", "0")
        tile.set("ry", "0")
    elif name == "monochrome":
        _drop(index, "bg")
        _drop(index, "mark-shade")
        mark, _ = _require(index, "mark")
        mark.set("transform", _ADAPTIVE_TRANSFORM)
        glyph, _ = _require(index, "mark-glyph")
        glyph.set("fill", "#000000")
        glyph.attrib.pop("fill-opacity", None)
    else:  # pragma: no cover - programmer error
        raise ValueError(name)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


# ── Rendering ─────────────────────────────────────────────────────────────────


def _renderer():
    try:
        import cairosvg  # noqa: PLC0415 - optional, probed on purpose
    except ImportError:
        print(
            "error: python3 cairosvg is not installed — cannot render the icon "
            "master.\n  Fedora: sudo dnf install python3-cairosvg\n"
            "  otherwise: pip install cairosvg",
            file=sys.stderr,
        )
        raise SystemExit(3)
    return cairosvg


def _write_png(cairosvg, svg_bytes, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cairosvg.svg2png(
        bytestring=svg_bytes,
        output_width=size,
        output_height=size,
        write_to=path,
    )


def _plan(master_bytes, master_root):
    """[(relative path, size or None, svg bytes)] — the whole generated set."""
    variants = {
        name: _variant(master_root, name)
        for name in ("full", "round", "foreground", "background", "monochrome")
    }
    jobs = []
    for size in HICOLOR_SIZES:
        jobs.append((_hicolor_png(size), size, variants["full"]))
    # The scalable entry IS the master: a copy, so the theme and the source can
    # never disagree.
    jobs.append((HICOLOR_SVG, None, master_bytes))
    for density, (legacy_px, adaptive_px) in ANDROID_DENSITIES.items():
        jobs.append((_mipmap(density, "ic_launcher"), legacy_px, variants["full"]))
        jobs.append(
            (_mipmap(density, "ic_launcher_round"), legacy_px, variants["round"])
        )
        jobs.append(
            (
                _mipmap(density, "ic_launcher_foreground"),
                adaptive_px,
                variants["foreground"],
            )
        )
        jobs.append(
            (
                _mipmap(density, "ic_launcher_background"),
                adaptive_px,
                variants["background"],
            )
        )
        jobs.append(
            (
                _mipmap(density, "ic_launcher_monochrome"),
                adaptive_px,
                variants["monochrome"],
            )
        )
    return sorted(jobs)


def _render_all(root_dir, out_dir):
    cairosvg = _renderer()
    master_path = os.path.join(root_dir, MASTER)
    if not os.path.exists(master_path):
        sys.exit(f"error: master icon not found at {master_path}")
    with open(master_path, "rb") as handle:
        master_bytes = handle.read()
    master_root = ET.fromstring(master_bytes)

    written = []
    for rel, size, svg_bytes in _plan(master_bytes, master_root):
        dest = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if size is None:
            with open(dest, "wb") as handle:
                handle.write(svg_bytes)
        else:
            _write_png(cairosvg, svg_bytes, dest, size)
        written.append(rel)
    return written


def _sha256(path):
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def _manifest_text(base_dir, paths):
    return "".join(
        f"{_sha256(os.path.join(base_dir, rel))}  {rel}\n" for rel in sorted(paths)
    )


# ── Commands ──────────────────────────────────────────────────────────────────


def generate(root_dir):
    written = _render_all(root_dir, root_dir)
    manifest_path = os.path.join(root_dir, MANIFEST)
    os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8") as handle:
        handle.write(
            "# sha256 of every file tool/gen_icons.py renders from "
            f"{MASTER}.\n"
            "# Regenerate with: tool/gen_icons.py — never edit a raster by hand.\n"
        )
        handle.write(_manifest_text(root_dir, written))
    print(f"generated {len(written)} files + {MANIFEST}")
    return 0


def check(root_dir):
    with tempfile.TemporaryDirectory(prefix="axiotask-icons-") as tmp:
        written = _render_all(root_dir, tmp)
        drift = []
        for rel in written:
            committed = os.path.join(root_dir, rel)
            if not os.path.exists(committed):
                drift.append(f"{rel}: missing (the generator produces it)")
            elif _sha256(committed) != _sha256(os.path.join(tmp, rel)):
                drift.append(f"{rel}: differs from a fresh render of {MASTER}")

        manifest_path = os.path.join(root_dir, MANIFEST)
        expected = _manifest_text(tmp, written)
        if not os.path.exists(manifest_path):
            drift.append(f"{MANIFEST}: missing")
        else:
            with open(manifest_path, encoding="utf-8") as handle:
                recorded = "".join(
                    line
                    for line in handle.readlines()
                    if line.strip() and not line.startswith("#")
                )
            if recorded != expected:
                drift.append(f"{MANIFEST}: does not match the rendered set")

    if drift:
        print("icon drift detected:", file=sys.stderr)
        for line in drift:
            print(f"  {line}", file=sys.stderr)
        print(
            "re-run tool/gen_icons.py and commit the result "
            "(rasters are generated, never hand-edited).",
            file=sys.stderr,
        )
        return 1
    print(f"ok — {len(written)} generated files match a fresh render of {MASTER}")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        prog="tool/gen_icons.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the committed rasters match a fresh render (no writes)",
    )
    parser.add_argument(
        "--root",
        default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        help="tree to operate on (default: the repository root)",
    )
    args = parser.parse_args(argv)
    return check(args.root) if args.check else generate(args.root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
