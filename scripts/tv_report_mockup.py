#!/usr/bin/env python3
"""Generate a TV daily-report screensaver mockup (1920x1080)."""
import calendar
from datetime import date, datetime
from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
M = 64  # outer margin

# ---- palette (dark, app-aligned: blue work, ember accent, teal calm) ----
BG       = (11, 13, 18)
BG2      = (8, 9, 13)
CARD     = (22, 26, 34)
CARD_HI  = (28, 33, 44)
LINE     = (40, 46, 58)
TXT      = (242, 244, 248)
MUT      = (150, 161, 178)
DIM      = (104, 114, 132)
BLUE     = (79, 140, 255)
EMBER    = (245, 178, 44)     # today / accent of the day
EMBER_HI = (255, 206, 90)
TEAL     = (63, 199, 192)
PINK     = (255, 111, 156)
GREEN    = (70, 209, 138)

FD = "/usr/share/fonts/truetype/dejavu/"
def f(name, sz): return ImageFont.truetype(FD + name, sz)
SANS   = lambda s: f("DejaVuSans.ttf", s)
BOLD   = lambda s: f("DejaVuSans-Bold.ttf", s)
LIB = "/usr/share/fonts/truetype/liberation/"
SERIF  = lambda s: ImageFont.truetype(LIB + "LiberationSerif-Regular.ttf", s)
SERIFI = lambda s: ImageFont.truetype(LIB + "LiberationSerif-Italic.ttf", s)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

# subtle vertical gradient background
for y in range(H):
    t = y / H
    d.line([(0, y), (W, y)], fill=tuple(int(BG[i] + (BG2[i]-BG[i])*t) for i in range(3)))

def text(x, y, s, font, fill=TXT, anchor="la"):
    d.text((x, y), s, font=font, fill=fill, anchor=anchor)

def card(x, y, w, h, fill=CARD, r=22, outline=None):
    d.rounded_rectangle([x, y, x+w, y+h], radius=r, fill=fill, outline=outline, width=1)

def wrap(s, font, maxw):
    out, line = [], ""
    for word in s.split():
        t = (line + " " + word).strip()
        if d.textlength(t, font=font) <= maxw:
            line = t
        else:
            if line: out.append(line)
            line = word
    if line: out.append(line)
    return out

today = date(2026, 6, 21)
dt = datetime(2026, 6, 21, 5, 0)

# ================= HEADER =================
text(M, 44, today.strftime("%A"), BOLD(66), TXT)
text(M, 124, today.strftime("%B %-d, %Y").upper(), SANS(28), EMBER)
# right side: greeting + weather + updated
text(W-M, 52, "Good morning", SANS(30), MUT, anchor="ra")
text(W-M, 96, "72°  Sunny  ·  Ravenswood Manor", SANS(26), DIM, anchor="ra")
text(W-M, 134, "updated " + dt.strftime("%-I:%M %p"), SANS(20), DIM, anchor="ra")

# ================= QUOTE BAND =================
qy = 186
d.line([(M, qy), (W-M, qy)], fill=LINE, width=1)
quote = "You have power over your mind — not outside events. Realize this, and you will find strength."
text(M, qy+26, quote, SERIFI(36), EMBER_HI)
text(M, qy+78, "— Marcus Aurelius", SERIF(24), MUT)

# ================= LAYOUT GRID =================
TOP = 320
BOT = H - M               # 1016
LX, LW = M, 1112          # left column
RX = LX + LW + 36         # right column
RW = (W - M) - RX

# ---------- LEFT: THIS WEEK ----------
text(LX, TOP-44, "THIS WEEK", BOLD(28), TXT)
wk_y, wk_h = TOP, 250
cell_w = (LW - 6*10) / 7
week_events = {
    0: [("9:00a", "Farmers Market", TEAL), ("4:00p", "Call Mom", BLUE)],   # Sun (today)
    1: [("8–4:30", "Work", BLUE), ("5:30p", "Dentist", PINK)],
    2: [("8–4:30", "Work", BLUE)],
    3: [("8–4:30", "Work", BLUE), ("6:00p", "Soccer", GREEN)],
    4: [("8–4:30", "Work", BLUE)],
    5: [("8–3:00", "Work", BLUE), ("7:00p", "Date night", PINK)],
    6: [("11:00a", "ArtWalk", EMBER)],
}
day_names = ["SUN","MON","TUE","WED","THU","FRI","SAT"]
for i in range(7):
    cx = LX + i*(cell_w+10)
    is_today = (i == 0)
    card(cx, wk_y, cell_w, wk_h, fill=CARD_HI if is_today else CARD, r=16,
         outline=EMBER if is_today else None)
    dnum = 21 + i
    text(cx+14, wk_y+12, day_names[i], BOLD(20), EMBER if is_today else MUT)
    text(cx+cell_w-14, wk_y+8, str(dnum), BOLD(26 if is_today else 22),
         TXT if is_today else DIM, anchor="ra")
    ey = wk_y + 56
    for tm, label, col in week_events.get(i, []):
        d.rounded_rectangle([cx+10, ey, cx+cell_w-10, ey+38], radius=8, fill=(col[0]//5, col[1]//5, col[2]//5))
        d.rectangle([cx+10, ey, cx+14, ey+38], fill=col)
        text(cx+22, ey+4, tm, SANS(15), col)
        text(cx+22, ey+20, label[:11], SANS(15), TXT)
        ey += 46

# ---------- LEFT BOTTOM: TO-DOS + GROCERIES ----------
b_y = wk_y + wk_h + 40
b_h = BOT - b_y
half = (LW - 28) / 2

# To-dos
card(LX, b_y, half, b_h)
text(LX+26, b_y+22, "TO-DO THIS WEEK", BOLD(26), TXT)
todos = [
    ("Submit timecard", "Fri", EMBER),
    ("Renew car registration", "", None),
    ("Email contractor re: gate", "", None),
    ("Buy Amelia’s birthday gift", "Sat", PINK),
    ("Book oil change", "", None),
    ("Fix back fence latch", "", None),
]
ty = b_y + 74
for label, due, col in todos:
    d.rounded_rectangle([LX+26, ty+4, LX+50, ty+28], radius=7, outline=DIM, width=2)
    text(LX+66, ty, label, SANS(24), TXT)
    if due:
        chip_w = d.textlength(due, font=SANS(18)) + 24
        d.rounded_rectangle([LX+half-26-chip_w, ty+2, LX+half-26, ty+28], radius=12,
                            fill=(col[0]//5, col[1]//5, col[2]//5))
        text(LX+half-26-chip_w/2, ty+5, due, SANS(18), col, anchor="ma")
    ty += 46

# Groceries
gx = LX + half + 28
card(gx, b_y, half, b_h)
text(gx+26, b_y+22, "GROCERIES", BOLD(26), TXT)
groceries = ["Milk","Eggs","Coffee beans","Spinach","Chicken thighs",
             "Olive oil","Bananas","Greek yogurt","Sourdough","Pasta","Tomatoes","Parmesan"]
gy = b_y + 74
col_w = (half - 52) / 2
for idx, item in enumerate(groceries):
    cc = idx % 2
    rr = idx // 2
    ix = gx + 26 + cc*col_w
    iy = gy + rr*46
    d.ellipse([ix, iy+5, ix+22, iy+27], outline=GREEN, width=2)
    text(ix+34, iy, item, SANS(23), TXT)

# ---------- RIGHT TOP: MONTH ----------
card(RX, TOP, RW, 320)
text(RX+26, TOP+20, "JUNE 2026", BOLD(26), TXT)
cal = calendar.Calendar(firstweekday=6)  # Sunday-first
weeks = cal.monthdayscalendar(2026, 6)
event_days = {21, 22, 24, 26, 27, 28, 13, 6, 19}
gx0 = RX + 26
gy0 = TOP + 70
gcw = (RW - 52) / 7
for i, dn in enumerate(["S","M","T","W","T","F","S"]):
    text(gx0 + i*gcw + gcw/2, gy0, dn, BOLD(18), DIM, anchor="ma")
ry = gy0 + 34
for wk in weeks:
    for i, dnum in enumerate(wk):
        if dnum == 0: continue
        cx = gx0 + i*gcw + gcw/2
        cy = ry + 16
        if dnum == 21:
            d.ellipse([cx-20, cy-18, cx+20, cy+22], fill=EMBER)
            text(cx, cy, str(dnum), BOLD(22), (10,10,12), anchor="mm")
        else:
            text(cx, cy, str(dnum), SANS(21), TXT if dnum in event_days else MUT, anchor="mm")
            if dnum in event_days:
                d.ellipse([cx-3, cy+20, cx+3, cy+26], fill=BLUE)
    ry += 40

# ---------- RIGHT BOTTOM: SUGGESTED NEARBY ----------
s_y = TOP + 320 + 36
s_h = BOT - s_y
card(RX, s_y, RW, s_h)
text(RX+26, s_y+22, "NEARBY THIS WEEK", BOLD(26), TXT)
text(RX+RW-26, s_y+26, "3 invites", SANS(20), EMBER, anchor="ra")
sugg = [
    ("Movies in the Parks", "Fri 8:30p · Horner Park · Free", EMBER),
    ("Lincoln Square Summer Fest", "Sat 11a · 0.8 mi · Festival", TEAL),
    ("Ravenswood Manor Block Party", "Sun Jun 28 · your block", BLUE),
]
sy = s_y + 78
cardw = RW - 52
for title, meta, col in sugg:
    ch = 84
    d.rounded_rectangle([RX+26, sy, RX+26+cardw, sy+ch], radius=14, fill=CARD_HI)
    d.rounded_rectangle([RX+26, sy, RX+34, sy+ch], radius=4, fill=col)
    text(RX+52, sy+14, title, BOLD(24), TXT)
    text(RX+52, sy+48, meta, SANS(20), MUT)
    # accept pill
    d.rounded_rectangle([RX+26+cardw-110, sy+24, RX+26+cardw-20, sy+60], radius=18,
                        outline=col, width=2)
    text(RX+26+cardw-65, sy+34, "Accept", SANS(18), col, anchor="ma")
    sy += ch + 16

out = "tv-report-mockup.png"
img.save(out, "PNG")
print("wrote", out, img.size)
