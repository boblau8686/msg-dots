#!/usr/bin/env python3
"""
Generate docs/demo.gif — animated colour-block walkthrough of EasyQuote.

Usage:  python3 docs/make_demo_gif.py
Needs:  Pillow, ffmpeg
"""

import os, subprocess, shutil
from PIL import Image, ImageDraw, ImageFont

# ---------------------------------------------------------------------------
# Canvas
# ---------------------------------------------------------------------------
SCALE  = 2
FW, FH = 860, 500
W,  H  = FW * SCALE, FH * SCALE
FPS    = 12
s      = SCALE

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
C_WIN_BG        = (255, 255, 255)
C_TITLEBAR      = (235, 235, 235)
C_TRAFFIC_R     = (255,  96,  89)
C_TRAFFIC_Y     = (255, 189,  68)
C_TRAFFIC_G     = ( 40, 200,  64)
C_SIDEBAR_BG    = (244, 245, 247)
C_SIDEBAR_SEL   = (  7, 193,  96)
C_SIDEBAR_LINE  = (225, 225, 225)
C_CHAT_BG       = (255, 255, 255)
C_CHAT_HDR      = (247, 247, 247)
C_CHAT_HDR_LINE = (218, 218, 218)
C_RECV_BG       = (235, 235, 235)   # light gray — received bubble
C_RECV_BORDER   = (215, 215, 215)
C_SENT_BG       = (149, 236, 105)   # WeChat green — sent bubble
C_AVATAR_A      = (100, 150, 210)   # other person avatar
C_AVATAR_B      = ( 55, 115, 175)   # self avatar
C_INPUT_AREA    = (255, 255, 255)
C_INPUT_TOOLBAR = (248, 248, 248)
C_INPUT_SEP     = (218, 218, 218)
C_CURSOR        = ( 30,  90, 200)
C_LABEL_RED     = (229,  57,  53)
C_LABEL_HI      = (255,  70,  50)
C_LABEL_WHITE   = (255, 255, 255)
C_QUOTE_BG      = (232, 242, 255)
C_QUOTE_STRIPE  = ( 55, 115, 210)
C_QUOTE_TEXT    = ( 50,  80, 150)
C_HOTKEY_BG     = ( 30,  50, 100)
C_HOTKEY_TEXT   = (255, 255, 255)
C_CAPTION_BG    = ( 28,  28,  32, 210)
C_CAPTION_TEXT  = (245, 245, 245)

# ---------------------------------------------------------------------------
# Fonts
# ---------------------------------------------------------------------------
HEITI_L = "/System/Library/Fonts/STHeiti Light.ttc"
HEITI_M = "/System/Library/Fonts/STHeiti Medium.ttc"

def fnt(path, pt):
    try:    return ImageFont.truetype(path, pt * s)
    except: return ImageFont.load_default()

F_TITLE   = fnt(HEITI_L, 10)
F_HEADER  = fnt(HEITI_M, 11)
F_LABEL   = fnt(HEITI_M, 13)
F_HOTKEY  = fnt(HEITI_M, 16)
F_CAPTION = fnt(HEITI_M, 18)   # big, centred caption
F_QUOTE   = fnt(HEITI_L, 10)

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
TITLEBAR_H = 28 * s
SIDEBAR_W  = 220 * s
CHAT_HDR_H = 44 * s
TOOLBAR_H  = 38 * s
INPUT_H    = 80 * s
AVATAR_R   = 16 * s
BUBBLE_R   = 8  * s
LABEL_R    = 14 * s

CHAT_X = SIDEBAR_W
CHAT_W = W - SIDEBAR_W
MSGS_TOP = TITLEBAR_H + CHAT_HDR_H
MSGS_BOT = H - TOOLBAR_H - INPUT_H

# Messages: (label, side, avatar_colour, bubble_bg, width_fraction)
# width_fraction: fraction of max-available bubble width
MSGS = [
    ("E", "recv", C_AVATAR_A, C_RECV_BG,  0.62),
    ("D", "sent", C_AVATAR_B, C_SENT_BG,  0.42),
    ("C", "recv", C_AVATAR_A, C_RECV_BG,  0.55),
    ("B", "sent", C_AVATAR_B, C_SENT_BG,  0.70),
    ("A", "recv", C_AVATAR_A, C_RECV_BG,  0.38),
]

BUBBLE_H = 42 * s   # fixed shorter height

def compute_layout():
    n   = len(MSGS)
    gap = 14 * s
    # centre the stack vertically in the messages area
    total = n * BUBBLE_H + (n - 1) * gap
    y0    = MSGS_TOP + ((MSGS_BOT - MSGS_TOP) - total) // 2

    pad   = 12 * s                        # outer padding
    max_w = CHAT_W - AVATAR_R * 2 - pad * 3   # max bubble width

    rects   = []   # (bx0,by0,bx1,by1, ax,ay, av_c, bb_c, side)
    lcenter = []   # label circle centre

    y = y0
    for lbl, side, av_c, bb_c, wf in MSGS:
        bw = int(max_w * wf)
        if side == "recv":
            ax  = CHAT_X + pad + AVATAR_R
            bx0 = ax + AVATAR_R + pad
            bx1 = bx0 + bw
            lx  = bx1 + LABEL_R + 6 * s
        else:
            ax  = CHAT_X + CHAT_W - pad - AVATAR_R
            bx1 = ax - AVATAR_R - pad
            bx0 = bx1 - bw
            lx  = bx0 - LABEL_R - 6 * s
        ay = y + BUBBLE_H // 2
        rects.append((bx0, y, bx1, y + BUBBLE_H, ax, ay, av_c, bb_c, side))
        lcenter.append((lx, ay))
        y += BUBBLE_H + gap
    return rects, lcenter

RECTS, LABEL_CENTERS = compute_layout()

# Sidebar items
SIDEBAR_ITEMS = [True, False, False, False, False, False]
ITEM_H = 52 * s

# ---------------------------------------------------------------------------
# Draw helpers
# ---------------------------------------------------------------------------
def rr(draw, box, r, fill, outline=None, width=1):
    draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)

def circ(draw, cx, cy, r, fill, outline=None, width=1):
    draw.ellipse([cx-r, cy-r, cx+r, cy+r], fill=fill, outline=outline, width=width)

# ---------------------------------------------------------------------------
# Scene parts
# ---------------------------------------------------------------------------
def draw_titlebar(draw):
    draw.rectangle([0, 0, W, TITLEBAR_H], fill=C_TITLEBAR)
    for xi, c in [(20*s, C_TRAFFIC_R), (36*s, C_TRAFFIC_Y), (52*s, C_TRAFFIC_G)]:
        circ(draw, xi, TITLEBAR_H // 2, 6*s, c)
    title = "微信"
    tw = draw.textlength(title, font=F_TITLE)
    draw.text(((W - tw) / 2, TITLEBAR_H // 2 - 8*s), title, font=F_TITLE, fill=(90, 90, 90))

def draw_sidebar(draw):
    draw.rectangle([0, TITLEBAR_H, SIDEBAR_W, H], fill=C_SIDEBAR_BG)
    sb_y = TITLEBAR_H + 8*s
    rr(draw, [12*s, sb_y, SIDEBAR_W - 12*s, sb_y + 24*s], r=12*s, fill=(215, 215, 218))
    iy = TITLEBAR_H + 44*s
    for sel in SIDEBAR_ITEMS:
        bg   = C_SIDEBAR_SEL if sel else C_WIN_BG
        bar  = (255,255,255,130) if sel else (205, 210, 220)
        draw.rectangle([0, iy, SIDEBAR_W, iy + ITEM_H], fill=bg)
        circ(draw, 28*s, iy + ITEM_H // 2, 18*s, (255,255,255) if sel else (185,190,205))
        rr(draw, [54*s, iy+13*s, SIDEBAR_W-16*s, iy+25*s], r=4*s, fill=bar)
        rr(draw, [54*s, iy+30*s, SIDEBAR_W-44*s, iy+40*s], r=4*s, fill=bar)
        draw.line([54*s, iy+ITEM_H-1, SIDEBAR_W, iy+ITEM_H-1], fill=C_SIDEBAR_LINE)
        iy += ITEM_H

def draw_chat_chrome(draw):
    # sidebar divider
    draw.line([SIDEBAR_W, TITLEBAR_H, SIDEBAR_W, H], fill=C_SIDEBAR_LINE, width=1)
    # chat background
    draw.rectangle([CHAT_X, TITLEBAR_H, W, H], fill=C_CHAT_BG)
    # header
    draw.rectangle([CHAT_X, TITLEBAR_H, W, TITLEBAR_H + CHAT_HDR_H], fill=C_CHAT_HDR)
    draw.line([CHAT_X, TITLEBAR_H + CHAT_HDR_H, W, TITLEBAR_H + CHAT_HDR_H],
              fill=C_CHAT_HDR_LINE)
    rr(draw, [CHAT_X+18*s, TITLEBAR_H+13*s, CHAT_X+140*s, TITLEBAR_H+30*s],
       r=5*s, fill=(200, 204, 212))
    # toolbar
    tb_y = MSGS_BOT
    draw.rectangle([CHAT_X, tb_y, W, tb_y + TOOLBAR_H], fill=C_INPUT_TOOLBAR)
    draw.line([CHAT_X, tb_y, W, tb_y], fill=C_INPUT_SEP)
    for xi in range(5):
        circ(draw, CHAT_X + (24 + xi * 30)*s, tb_y + TOOLBAR_H // 2, 8*s, (188, 192, 200))
    # input area
    draw.rectangle([CHAT_X, MSGS_BOT + TOOLBAR_H, W, H], fill=C_INPUT_AREA)

def draw_messages(draw):
    for bx0, y0, bx1, y1, ax, ay, av_c, bb_c, side in RECTS:
        circ(draw, ax, ay, AVATAR_R, av_c)
        outline = C_RECV_BORDER if side == "recv" else None
        ow = s if side == "recv" else 0
        rr(draw, [bx0, y0, bx1, y1], r=BUBBLE_R, fill=bb_c, outline=outline, width=ow)
        # text placeholder bar inside bubble
        blen = (bx1 - bx0) - 20*s
        mid  = (y0 + y1) // 2
        blk  = (195, 195, 195) if side == "recv" else (120, 200, 80)
        rr(draw, [bx0 + 10*s, mid - 7*s, bx0 + 10*s + blen, mid + 7*s], r=4*s, fill=blk)

def draw_input(draw, quote_idx=None, cursor_vis=True):
    ia_y = MSGS_BOT + TOOLBAR_H
    if quote_idx is not None:
        lbl = MSGS[quote_idx][0]
        qh = 26 * s
        rr(draw, [CHAT_X + 8*s, ia_y + 6*s, W - 8*s, ia_y + 6*s + qh], r=6*s, fill=C_QUOTE_BG)
        rr(draw, [CHAT_X + 8*s, ia_y + 6*s, CHAT_X + 13*s, ia_y + 6*s + qh], r=4*s, fill=C_QUOTE_STRIPE)
        draw.text((CHAT_X + 18*s, ia_y + 6*s + 5*s),
                  f"引用消息 {lbl}", font=F_QUOTE, fill=C_QUOTE_TEXT)
        cur_y = ia_y + 6*s + qh + 8*s
    else:
        cur_y = ia_y + 14*s
    if cursor_vis:
        draw.line([CHAT_X + 14*s, cur_y, CHAT_X + 14*s, cur_y + 20*s],
                  fill=C_CURSOR, width=2*s)

def draw_labels(draw, visible=True, highlight=None):
    if not visible:
        return
    for i, (lbl, *_) in enumerate(MSGS):
        cx, cy = LABEL_CENTERS[i]
        fill = C_LABEL_HI if highlight == i else C_LABEL_RED
        circ(draw, cx, cy, LABEL_R, fill)
        bbox = draw.textbbox((0, 0), lbl, font=F_LABEL)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        draw.text((cx - tw/2 - bbox[0], cy - th/2 - bbox[1]), lbl, font=F_LABEL, fill=C_LABEL_WHITE)

def draw_hotkey(draw, alpha=1.0):
    txt = "⌃Q"
    tw  = draw.textlength(txt, font=F_HOTKEY)
    bw  = int(tw + 24*s)
    bh  = 34 * s
    bx  = CHAT_X + (CHAT_W - bw) // 2
    by  = MSGS_TOP + 18*s
    def bl(c): return tuple(int(v * alpha + 248*(1-alpha)) for v in c)
    rr(draw, [bx, by, bx+bw, by+bh], r=9*s, fill=bl(C_HOTKEY_BG))
    draw.text((bx + 12*s, by + 7*s), txt, font=F_HOTKEY, fill=bl(C_HOTKEY_TEXT))

def draw_caption(draw, text):
    """Large centred caption in the middle of the chat area."""
    tw = draw.textlength(text, font=F_CAPTION)
    th = 22 * s
    bw = int(tw + 32*s)
    bh = th + 12*s
    bx = CHAT_X + (CHAT_W - bw) // 2
    by = MSGS_TOP + ((MSGS_BOT - MSGS_TOP) - bh) // 2 - 30*s   # slightly above centre

    # Semi-transparent pill — draw on a temp RGBA layer
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    odraw   = ImageDraw.Draw(overlay)
    odraw.rounded_rectangle([bx, by, bx+bw, by+bh], radius=10*s,
                             fill=(28, 28, 32, 200))
    # Composite onto the main image (which is RGB)
    base = draw._image   # grab the underlying Image
    base.paste(Image.alpha_composite(base.convert("RGBA"), overlay).convert("RGB"))

    # Redraw text on top (draw still references base)
    draw.text(((CHAT_X + CHAT_W//2) - tw//2, by + 6*s),
              text, font=F_CAPTION, fill=C_CAPTION_TEXT)

# ---------------------------------------------------------------------------
# Frame factory
# ---------------------------------------------------------------------------
def frame(hotkey=0.0, labels=False, highlight=None,
          quote_idx=None, cursor_vis=True, caption=""):
    img  = Image.new("RGB", (W, H), C_WIN_BG)
    draw = ImageDraw.Draw(img)
    draw_titlebar(draw)
    draw_sidebar(draw)
    draw_chat_chrome(draw)
    draw_messages(draw)
    draw_input(draw, quote_idx=quote_idx, cursor_vis=cursor_vis)
    if hotkey > 0:
        draw_hotkey(draw, hotkey)
    if labels:
        draw_labels(draw, highlight=highlight)
    if caption:
        draw_caption(draw, caption)
    return img.resize((FW, FH), Image.LANCZOS)

# ---------------------------------------------------------------------------
# Animation: caption-first, then action, then next caption
# ---------------------------------------------------------------------------
def ease_out(t):
    return 1 - (1 - t) ** 2

frames = []
def add(img, n=1): frames.extend([img] * n)
def sec(n):        return max(1, round(n * FPS))

# ── Step 1: intro caption ──────────────────────────────────
cap = "在聊天输入框中输入文字时..."
for _ in range(sec(1.5)):
    add(frame(caption=cap))

# ── Step 1: show chat with cursor blinking ─────────────────
for i in range(sec(2.0)):
    add(frame(cursor_vis=(i % 8 < 4)))

# ── Step 2 caption: 按快捷键 ───────────────────────────────
cap = "按 ⌃Q 触发快速引用"
for _ in range(sec(1.5)):
    add(frame(caption=cap))

# ── Step 2 action: hotkey badge fade-in, hold ─────────────
for i in range(sec(0.4)):
    add(frame(hotkey=ease_out(i / max(1, sec(0.4)-1)), cursor_vis=False))
for _ in range(sec(0.8)):
    add(frame(hotkey=1.0, cursor_vis=False))

# ── Step 3 caption: 字母圈出现 ────────────────────────────
cap = "消息旁出现字母圈（A = 最新）"
for _ in range(sec(1.5)):
    add(frame(caption=cap))

# ── Step 3 action: all labels appear at once, hold ────────
for _ in range(sec(2.0)):
    add(frame(labels=True, cursor_vis=False))

# ── Step 4 caption: 按字母 ────────────────────────────────
cap = "按对应字母键选择要引用的消息"
for _ in range(sec(1.5)):
    add(frame(labels=True, caption=cap, cursor_vis=False))

# ── Step 4 action: flash label C (index 2) ────────────────
for i in range(sec(0.8)):
    hl = 2 if (i % 6 < 3) else None
    add(frame(labels=True, highlight=hl, cursor_vis=False))

# ── Step 5 caption: 引用触发 ──────────────────────────────
cap = "「引用」自动触发，可继续输入文字"
for _ in range(sec(1.5)):
    add(frame(quote_idx=2, cursor_vis=False, caption=cap))

# ── Step 5 action: quote box + blinking cursor ────────────
for i in range(sec(2.5)):
    add(frame(quote_idx=2, cursor_vis=(i % 8 < 4)))

# ── Pause before loop ─────────────────────────────────────
for _ in range(sec(0.5)):
    add(frame(cursor_vis=False))

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
HERE    = os.path.dirname(os.path.abspath(__file__))
FDIR    = os.path.join(HERE, "_frames")
OUT_GIF = os.path.join(HERE, "demo.gif")
os.makedirs(FDIR, exist_ok=True)

print(f"rendering {len(frames)} frames at {FW}×{FH} (render {W}×{H}) …")
for idx, f in enumerate(frames):
    f.save(os.path.join(FDIR, f"frame_{idx:04d}.png"))

print("encoding GIF …")
subprocess.run([
    "ffmpeg", "-y",
    "-framerate", str(FPS),
    "-i", os.path.join(FDIR, "frame_%04d.png"),
    "-vf", ("split[s0][s1];"
            "[s0]palettegen=max_colors=200:stats_mode=diff[p];"
            "[s1][p]paletteuse=dither=bayer:bayer_scale=3"),
    OUT_GIF,
], check=True, capture_output=True)

shutil.rmtree(FDIR)
kb = os.path.getsize(OUT_GIF) // 1024
print(f"✅  {OUT_GIF}  ({kb} KB,  {len(frames)} frames @ {FPS} fps)")
