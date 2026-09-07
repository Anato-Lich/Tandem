import json, math, random

HEAD = '''<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
    body { margin: 0; font-family: -apple-system, system-ui, "SF Pro Text", "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; color: #F5F5F7; font-variant-numeric: tabular-nums; }
    a { color: #FF9F0A; } a:hover { color: #FFB340; }
    svg.ic { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
    svg.bolt { fill: currentColor; stroke: none; }
  </style>
</helmet>
'''
TAIL = '''</x-dc>
</body>
</html>
'''
# ---- icons (stroke, 24 grid) ----
LAP = '<svg class="ic" viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="11" rx="1.6"></rect><path d="M2 18.5h20"></path></svg>'
PH = '<svg class="ic" viewBox="0 0 24 24"><rect x="7" y="2.5" width="10" height="19" rx="2.4"></rect><path d="M10.5 5.2h3"></path></svg>'
HEART = '<svg class="ic" viewBox="0 0 24 24"><path d="M12 20s-7-4.5-7-10a4 4 0 0 1 7-2.5A4 4 0 0 1 19 10c0 5.5-7 10-7 10z"></path></svg>'
THERM = '<svg class="ic" viewBox="0 0 24 24"><path d="M10 4a2 2 0 0 1 4 0v9.5a4 4 0 1 1-4 0z"></path><path d="M12 10v6"></path></svg>'
PLUG = '<svg class="ic" viewBox="0 0 24 24"><path d="M9 3v5M15 3v5"></path><path d="M6 8h12v3a6 6 0 0 1-12 0z"></path><path d="M12 17v4"></path></svg>'
CPU = '<svg class="ic" viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2"></rect><rect x="9.5" y="9.5" width="5" height="5" rx="1"></rect><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"></path></svg>'
CYCLE = '<svg class="ic" viewBox="0 0 24 24"><path d="M20 12a8 8 0 0 1-14.5 4.6"></path><path d="M4 12a8 8 0 0 1 14.5-4.6"></path><path d="M4 17v-5h5M20 7v5h-5"></path></svg>'
CLOCK = '<svg class="ic" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"></circle><path d="M12 7.5V12l3 2"></path></svg>'
BATT = '<svg class="ic" viewBox="0 0 24 24"><rect x="3" y="7" width="16" height="10" rx="2.5"></rect><path d="M21 10.5v3"></path><rect x="5.5" y="9.5" width="8" height="5" rx="1" fill="currentColor" stroke="none"></rect></svg>'
CAL = '<svg class="ic" viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="15" rx="2"></rect><path d="M4 10h16M8 3v4M16 3v4"></path></svg>'
GAUGE = '<svg class="ic" viewBox="0 0 24 24"><path d="M4 16a8 8 0 1 1 16 0"></path><path d="M12 16l4-5"></path></svg>'

def bolt(size=11, color="#FF9F0A"):
    return f'<svg class="ic bolt" viewBox="0 0 24 24" style="width:{size}px;height:{size}px;color:{color}"><path d="M13 2 5 13h6l-1 9 8-11h-6z"></path></svg>'
def sz(icon, n):
    return icon.replace('class="ic"', f'class="ic" style="width:{n}px;height:{n}px"')

GREEN = "#30D158"; AMBER = "#FF9F0A"; RED = "#FF453A"; BLUE = "#64D2FF"; TRACK = "#3A3A3C"
BG = "#1C1C1E"; CARD = "#2C2C2E"; CARD2 = "#333336"; MUTED = "#98989D"; INK = "#F5F5F7"; LINE = "#3D3D40"

def level_color(p): return RED if p < 20 else (AMBER if p < 50 else GREEN)

def ring(p, color, size=64, sw=6, icon=LAP, badge=False, icon_size=24):
    r = (size - sw) / 2 - 1; c = 2 * math.pi * r; off = c * (1 - p / 100)
    b = f'<div style="position:absolute;right:-2px;top:-2px;width:18px;height:18px;border-radius:9px;background:{AMBER};display:flex;align-items:center;justify-content:center">{bolt(10, "#1B1408")}</div>' if badge else ''
    return (f'<div style="position:relative;width:{size}px;height:{size}px;flex:none">'
            f'<svg viewBox="0 0 {size} {size}" style="width:{size}px;height:{size}px;transform:rotate(-90deg)">'
            f'<circle cx="{size/2}" cy="{size/2}" r="{r:.1f}" fill="none" stroke="{TRACK}" stroke-width="{sw}"></circle>'
            f'<circle cx="{size/2}" cy="{size/2}" r="{r:.1f}" fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round" stroke-dasharray="{c:.1f}" stroke-dashoffset="{off:.1f}"></circle></svg>'
            f'<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:{INK}">{sz(icon, icon_size)}</div>{b}</div>')

def tint_icon(icon, color, size=26):
    return (f'<div style="width:{size}px;height:{size}px;border-radius:{size*0.3:.0f}px;background:{color}22;color:{color};display:flex;align-items:center;justify-content:center;flex:none">{sz(icon, 14)}</div>')

def spark(points, color, w=120, h=26, fill=True, spans=None):
    n = len(points); mx = max(points); mn = min(points); rng = max(1, mx - mn)
    xs = [i * (w - 2) / (n - 1) + 1 for i in range(n)]
    ys = [h - 3 - (p - mn) / rng * (h - 6) for p in points]
    path = " ".join(f"{x:.1f},{y:.1f}" for x, y in zip(xs, ys))
    area = f'<polygon points="1,{h} {path} {w-1},{h}" fill="{color}" opacity="0.14"></polygon>' if fill else ''
    sp = ""
    if spans:
        for a, b in spans:
            sp += f'<rect x="{a*w:.1f}" y="0" width="{(b-a)*w:.1f}" height="{h}" fill="{AMBER}" opacity="0.16"></rect>'
    return (f'<svg viewBox="0 0 {w} {h}" style="width:{w}px;height:{h}px;flex:none">{sp}{area}'
            f'<polyline points="{path}" fill="none" stroke="{color}" stroke-width="1.6" stroke-linejoin="round" stroke-linecap="round"></polyline>'
            f'<circle cx="{xs[-1]:.1f}" cy="{ys[-1]:.1f}" r="2.2" fill="{color}"></circle></svg>')

def chart(series, w=400, h=120, spans=None, labels=("01", "07", "13", "19"), grid=True):
    # series: list of (points, color)
    out = []
    if grid:
        for gy in (0, 50, 100):
            y = h - 16 - gy / 100 * (h - 24)
            out.append(f'<line x1="0" y1="{y:.1f}" x2="{w-26}" y2="{y:.1f}" stroke="{LINE}" stroke-width="0.6" stroke-dasharray="2 3"></line>')
            out.append(f'<text x="{w-2}" y="{y+3.5:.1f}" font-size="9" fill="{MUTED}" text-anchor="end" font-family="system-ui">{gy}</text>')
    if spans:
        for a, b, col in spans:
            out.append(f'<rect x="{a*(w-26):.1f}" y="8" width="{(b-a)*(w-26):.1f}" height="{h-24}" fill="{col}" opacity="0.14"></rect>')
    for pts, col in series:
        n = len(pts)
        xs = [i * (w - 26) / (n - 1) for i in range(n)]
        ys = [h - 16 - p / 100 * (h - 24) for p in pts]
        path = " ".join(f"{x:.1f},{y:.1f}" for x, y in zip(xs, ys))
        out.append(f'<polyline points="{path}" fill="none" stroke="{col}" stroke-width="1.8" stroke-linejoin="round"></polyline>')
        out.append(f'<circle cx="{xs[-1]:.1f}" cy="{ys[-1]:.1f}" r="3" fill="{col}"></circle>')
    for i, lb in enumerate(labels):
        x = (i * 6 + 6) / 24 * (w - 26) - 6
        out.append(f'<text x="{x:.1f}" y="{h-2}" font-size="9" fill="{MUTED}" font-family="system-ui">{lb}</text>')
    return f'<svg viewBox="0 0 {w} {h}" style="width:{w}px;height:{h}px">{"".join(out)}</svg>'

# ---- synthetic 24 h series ----
random.seed(3)
def series_mac():
    pts = []
    for i in range(48):
        t = i / 47
        if t < 0.25: v = 62 - t * 120          # discharge to ~32
        elif t < 0.42: v = 32 + (t - 0.25) * 400  # charge to 100
        else: v = 100 - (t - 0.42) * 17
        pts.append(max(0, min(100, v)))
    return pts
def series_phone():
    pts = []
    for i in range(48):
        t = i / 47
        if t < 0.82: v = 93 - t * 78
        else: v = 29 + (t - 0.82) * 195
        pts.append(max(0, min(100, v)))
    return pts
MACS = series_mac(); PHS = series_phone()

# ---- data ----
MAC = dict(name="MacBook Pro", p=90, chg=False, ext=True, color=GREEN, sys="32 W", ad="32/140 W", status="charged",
           health="98 %", cap="8389 / 8579 mAh", cycles="33", temp="30.4 °C", last="Вчера 22:04 → 02:31", last2="24 → 100 %", last3="ср. 14 W · пик 96 W · до 80 % за 2 ч 08 мин",
           today_range="41–100 %", today_charger="7 ч 27 мин", today_cycles="0.90", today_draw="11.3 W")
PHN = dict(name="iPhone", p=64, chg=True, ext=True, color=GREEN, sys="2 W", ad="36/45 W", status="80 % через 14 мин",
           health="100 %", cap="4966 / 4768 mAh", cycles="14", temp="28.9 °C", last="Сегодня 17:26 → сейчас", last2="28 → 64 %", last3="ср. 12.6 W · пик 15.6 W",
           today_range="28–88 %", today_charger="2 ч 12 мин", today_cycles="0.36", today_draw="1.4 W")

def write(name, body, w, h):
    html = HEAD + f'<div style="width:{w}px;height:{h}px;background:{BG};box-sizing:border-box;overflow:hidden">' + body + '</div>\n' + TAIL
    open(f"{name}.dc.html", "w").write(html)

# ================= Direction A: Карточки (Vorsaint-like rows) =================
def row(icon, tint, label, value, sub=None, extra="", last=False):
    border = "" if last else f"border-bottom:0.5px solid {LINE}"
    subhtml = f'<span style="font-size:10.5px;color:{MUTED}">{sub}</span>' if sub else ""
    return (f'<div style="display:flex;align-items:center;gap:10px;padding:9px 12px;{border}">'
            f'{tint_icon(icon, tint)}<div style="display:flex;flex-direction:column;gap:1px;min-width:0;flex:1 1 auto"><span style="font-size:12.5px;font-weight:500">{label}</span>'
            f'{subhtml}</div>{extra}<span style="font-size:13px;font-weight:600;white-space:nowrap">{value}</span></div>')
def card(inner, title=None):
    t = f'<div style="font-size:10.5px;letter-spacing:.08em;text-transform:uppercase;color:{MUTED};padding:0 4px 6px">{title}</div>' if title else ''
    return f'<div style="display:flex;flex-direction:column">{t}<div style="background:{CARD};border-radius:12px;overflow:hidden">{inner}</div></div>'
def hero(d, icon):
    chips = f'<span style="display:inline-flex;align-items:center;gap:4px;padding:3px 8px;border-radius:7px;background:{AMBER}22;color:{AMBER};font-size:11px;font-weight:600">{bolt(10)} {d["ad"]}</span>' if d["chg"] else f'<span style="display:inline-flex;align-items:center;gap:4px;padding:3px 8px;border-radius:7px;background:#ffffff14;color:{MUTED};font-size:11px;font-weight:600">{sz(PLUG,11)} {d["ad"]}</span>'
    chips += f'<span style="display:inline-flex;align-items:center;gap:4px;padding:3px 8px;border-radius:7px;background:#ffffff14;color:{INK};font-size:11px;font-weight:600">{sz(CLOCK,11)} {d["status"]}</span>'
    return (f'<div style="display:flex;align-items:center;gap:14px;padding:4px 4px 12px">{ring(d["p"], d["color"], 60, 6, icon, d["chg"], 24)}'
            f'<div style="display:flex;flex-direction:column;gap:6px;flex:1 1 auto"><div style="display:flex;align-items:baseline;justify-content:space-between"><span style="font-size:15px;font-weight:600">{d["name"]}</span><span style="font-size:30px;font-weight:600;letter-spacing:-0.02em;line-height:1">{d["p"]} %</span></div>'
            f'<div style="display:flex;gap:6px">{chips}</div></div></div>')
def colA(d, icon, pts, spans):
    battery = card(
        row(HEART, GREEN, "Здоровье", d["health"], d["cap"]) +
        row(CYCLE, BLUE, "Циклы", d["cycles"]) +
        row(THERM, AMBER, "Температура", d["temp"]) +
        row(CPU, "#BF5AF2", "Система", d["sys"], None, spark([28,31,35,30,29,33,32,30,32,34,31,32], "#BF5AF2", 90, 22) + '<span style="width:10px"></span>', True), "Батарея")
    charge = card(
        row(CAL, GREEN, d["last"], d["last2"], d["last3"], "", True), "Последняя зарядка")
    today = card(
        f'<div style="display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:0;padding:10px 12px">'
        + "".join(f'<div style="display:flex;flex-direction:column;gap:2px"><span style="font-size:13px;font-weight:600">{v}</span><span style="font-size:10px;color:{MUTED}">{k}</span></div>'
                  for k, v in (("диапазон", d["today_range"]), ("у розетки", d["today_charger"]), ("циклов", d["today_cycles"]), ("расход", d["today_draw"]))) + '</div>', "Сегодня")
    ch = card(f'<div style="padding:10px 10px 6px">{chart([(pts, d["color"])], 396, 110, [(a, b, AMBER) for a, b in spans])}</div>', "24 часа")
    return f'<div style="display:flex;flex-direction:column;gap:12px;width:420px">{hero(d, icon)}{battery}{charge}{today}{ch}</div>'
A = (f'<div style="display:flex;gap:20px;padding:20px 22px">{colA(MAC, LAP, MACS, [(0.25, 0.42)])}'
     f'<div style="width:0.5px;background:{LINE}"></div>{colA(PHN, PH, PHS, [(0.82, 1.0)])}</div>')
write("DirectionA", A, 924, 640)

# ================= Direction B: Панель с вкладками (compact) =================
def tabbar():
    return (f'<div style="display:flex;background:{CARD};border-radius:10px;padding:3px;gap:3px">'
            f'<div style="flex:1;display:flex;align-items:center;justify-content:center;gap:6px;padding:7px;border-radius:8px;background:#48484A;font-size:12.5px;font-weight:600">{sz(LAP,15)} MacBook Pro <span style="color:{MUTED};font-weight:500">90 %</span></div>'
            f'<div style="flex:1;display:flex;align-items:center;justify-content:center;gap:6px;padding:7px;border-radius:8px;font-size:12.5px;font-weight:500;color:{MUTED}">{sz(PH,15)} iPhone <span>64 %</span>{bolt(10)}</div></div>')
def bigrow(label, value, sub, icon, tint):
    return (f'<div style="display:flex;align-items:center;gap:12px;padding:12px 14px;border-bottom:0.5px solid {LINE}">{tint_icon(icon, tint, 30)}'
            f'<div style="flex:1;display:flex;flex-direction:column;gap:2px"><span style="font-size:13px;font-weight:500">{label}</span><span style="font-size:11px;color:{MUTED}">{sub}</span></div>'
            f'<span style="font-size:17px;font-weight:600;letter-spacing:-0.01em">{value}</span></div>')
B = (f'<div style="display:flex;flex-direction:column;gap:14px;padding:18px 18px;width:480px;box-sizing:border-box">{tabbar()}'
     f'<div style="display:flex;align-items:center;gap:16px;padding:6px 4px">{ring(90, GREEN, 84, 8, LAP, False, 32)}'
     f'<div style="display:flex;flex-direction:column;gap:4px"><span style="font-size:40px;font-weight:600;letter-spacing:-0.03em;line-height:1">90 %</span>'
     f'<span style="font-size:12px;color:{MUTED}">Заряжен · на адаптере 140 W</span></div>'
     f'<div style="margin-left:auto;display:flex;flex-direction:column;align-items:flex-end;gap:3px"><span style="font-size:20px;font-weight:600">32 W</span><span style="font-size:10.5px;color:{MUTED}">система</span>{spark([28,31,35,30,29,33,32,30,32,34,31,32], "#BF5AF2", 110, 22)}</div></div>'
     f'<div style="background:{CARD};border-radius:12px;overflow:hidden">'
     + bigrow("Здоровье батареи", "98 %", "8389 / 8579 mAh · 33 цикла", HEART, GREEN)
     + bigrow("Температура", "30.4 °C", "норма", THERM, AMBER)
     + bigrow("Последняя зарядка", "24 → 100 %", "Вчера 22:04 → 02:31 · до 80 % за 2 ч 08 мин", CAL, BLUE)
     + bigrow("Сегодня", "7 ч 27 мин", "у розетки · 0.90 цикла · расход 11.3 W", CLOCK, "#BF5AF2").replace(f"border-bottom:0.5px solid {LINE}", "")
     + f'</div><div style="background:{CARD};border-radius:12px;padding:10px 10px 6px"><div style="display:flex;justify-content:space-between;padding:0 4px 6px;font-size:10.5px;color:{MUTED};letter-spacing:.08em;text-transform:uppercase"><span>24 часа</span><span style="text-transform:none;letter-spacing:0"><span style="color:{AMBER}">▮</span> зарядка</span></div>{chart([(MACS, GREEN)], 424, 118, [(0.25, 0.42, AMBER)])}</div></div>')
write("DirectionB", B, 480, 640)

# ================= Direction C: Дашборд (shared chart) =================
def hero_tile(d, icon, accent):
    st = (f'<span style="display:inline-flex;align-items:center;gap:4px;color:{AMBER};font-size:12px;font-weight:600">{bolt(11)} {d["ad"]}</span>' if d["chg"]
          else f'<span style="display:inline-flex;align-items:center;gap:4px;color:{MUTED};font-size:12px;font-weight:600">{sz(PLUG,12)} {d["ad"]}</span>')
    return (f'<div style="flex:1;display:flex;align-items:center;gap:14px;background:{CARD};border-radius:14px;padding:14px 16px;border-left:3px solid {accent}">'
            f'{ring(d["p"], d["color"], 64, 6, icon, d["chg"], 26)}'
            f'<div style="display:flex;flex-direction:column;gap:4px;flex:1"><div style="display:flex;align-items:baseline;gap:10px"><span style="font-size:32px;font-weight:600;letter-spacing:-0.02em;line-height:1">{d["p"]} %</span><span style="font-size:13px;font-weight:600">{d["name"]}</span></div>'
            f'<div style="display:flex;gap:14px;align-items:center">{st}<span style="font-size:12px;color:{INK}">{d["status"]}</span><span style="font-size:12px;color:{MUTED}">система {d["sys"]}</span></div></div></div>')
def stat_card(title, icon, tint, mac, ph, sub_mac="", sub_ph=""):
    def cell(v, s, ic, col):
        subhtml = f'<span style="font-size:10px;color:{MUTED}">{s}</span>' if s else ""
        return (f'<div style="display:flex;align-items:center;gap:8px;flex:1"><span style="color:{col}">{sz(ic,13)}</span><div style="display:flex;flex-direction:column"><span style="font-size:14px;font-weight:600">{v}</span>{subhtml}</div></div>')
    return (f'<div style="flex:1;background:{CARD};border-radius:12px;padding:12px 14px;display:flex;flex-direction:column;gap:10px">'
            f'<div style="display:flex;align-items:center;gap:8px;font-size:11px;color:{MUTED};letter-spacing:.06em;text-transform:uppercase">{tint_icon(icon, tint, 22)}{title}</div>'
            f'<div style="display:flex;gap:8px">{cell(mac, sub_mac, LAP, GREEN)}{cell(ph, sub_ph, PH, BLUE)}</div></div>')
C = (f'<div style="display:flex;flex-direction:column;gap:14px;padding:18px 20px">'
     f'<div style="display:flex;gap:14px">{hero_tile(MAC, LAP, GREEN)}{hero_tile(PHN, PH, BLUE)}</div>'
     f'<div style="background:{CARD};border-radius:14px;padding:12px 14px 8px"><div style="display:flex;justify-content:space-between;align-items:center;padding:0 2px 8px"><span style="font-size:11px;color:{MUTED};letter-spacing:.08em;text-transform:uppercase">Заряд за 24 часа</span>'
     f'<span style="display:flex;gap:14px;font-size:11px;color:{MUTED}"><span><span style="color:{GREEN}">●</span> MacBook Pro</span><span><span style="color:{BLUE}">●</span> iPhone</span><span><span style="color:{AMBER}">▮</span> зарядка</span></span></div>'
     f'{chart([(MACS, GREEN), (PHS, BLUE)], 840, 170, [(0.25, 0.42, GREEN), (0.82, 1.0, BLUE)])}</div>'
     f'<div style="display:flex;gap:14px">'
     + stat_card("Здоровье", HEART, GREEN, "98 %", "100 %", "33 цикла", "14 циклов")
     + stat_card("Температура", THERM, AMBER, "30.4 °C", "28.9 °C")
     + stat_card("Последняя зарядка", CAL, BLUE, "24 → 100 %", "28 → 64 %", "вчера, 4 ч 27 мин", "идёт, 36/45 W")
     + stat_card("Сегодня", CLOCK, "#BF5AF2", "7 ч 27 мин", "2 ч 12 мин", "у розетки · 0.90 цикла", "у розетки · 0.36 цикла")
     + '</div></div>')
write("DirectionC", C, 880, 560)

# ---- canvas ----
ab = [
    {"file": "DirectionA.dc.html", "x": 0, "y": 0, "w": 924, "h": 640, "title": "A · Карточки"},
    {"file": "DirectionB.dc.html", "x": 1010, "y": 0, "w": 480, "h": 640, "title": "B · Панель с вкладками"},
    {"file": "DirectionC.dc.html", "x": 0, "y": 780, "w": 880, "h": 560, "title": "C · Дашборд"},
]
notes = [
    {"id": "n-a", "x": 0, "y": -200, "w": 620, "text": "A · Карточки. Две колонки, как сейчас, но каждая колонка это стопка сгруппированных карточек в духе Настроек macOS: значок в цветном кружке, подпись, значение справа, у системной мощности спарклайн. Шапка с кольцом, крупным процентом и двумя чипами: мощность и статус. Плюс: всё про одно устройство в одном столбце, читается сверху вниз. Минус: две колонки одинаковой структуры, ширина 920."},
    {"id": "n-b", "x": 1010, "y": -200, "w": 480, "text": "B · Панель с вкладками. Одно устройство на экране, переключатель сверху, компактное окно 480 в ширину. Крупное кольцо и процент, четыре большие строки, график. Нажатие на плитку виджета открывает нужную вкладку. Плюс: самое читаемое, ничего лишнего. Минус: оба устройства сразу не видно."},
    {"id": "n-c", "x": 0, "y": 620, "w": 880, "text": "C · Дашборд. Оба устройства в двух шапках сверху, один общий график на 24 часа с двумя линиями и подсветкой зарядок, ниже четыре карточки, где в каждой пара значений Mac и iPhone. Плюс: сравнение устройств с первого взгляда, пустого места нет, окно ниже. Минус: цифры одного устройства разбросаны по карточкам. Я за C, с подсветкой шапки того устройства, по которому кликнули в виджете."},
]
json.dump({"artboards": ab, "annotations": notes, "launch": {"view": "canvas"}}, open("canvas.json", "w"), ensure_ascii=False, indent=1)
print("ok")
