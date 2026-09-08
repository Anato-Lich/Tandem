import json, math

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
    svg.ic { fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
  </style>
</helmet>
'''
TAIL = '''</x-dc>
</body>
</html>
'''
GREEN = "#30D158"; AMBER = "#FF9F0A"; RED = "#FF453A"; BLUE = "#64D2FF"; PURPLE = "#BF5AF2"
BG = "#1C1C1E"; CARD = "#2C2C2E"; MUTED = "#98989D"; INK = "#F5F5F7"; LINE = "#3D3D40"; INK2 = "#C7C7CC"

# ---- data: 24 h ending "now" = 16:00. hours as x in [0,24]
# flat 90 % till 11:40, then discharge to 24 %; a charging block 02:10→04:30 (from 62 to 90) before that.
def series():
    pts = []
    n = 97
    for i in range(n):
        t = i / (n - 1) * 24
        if t < 2.17: v = 90 - t * 13            # 90 → 62
        elif t < 4.5: v = 62 + (t - 2.17) * 12  # charge to ~90
        elif t < 19.6: v = 90
        else: v = 90 - (t - 19.6) * 15         # → 24 at 24h
        pts.append((t, max(0, min(100, v))))
    return pts
PTS = series()
CHARGE = [(2.17, 4.5)]           # hours
NOW_H = 16                       # clock label at the right edge
LABELS = [(6 - 0, "22"), (12, "04"), (18, "10"), (24, "16")]  # x hours → clock

W, H = 470, 230
def card(inner, title="24 hours", legend="", w=W, h=H):
    return (f'<div style="width:{w}px;height:{h}px;box-sizing:border-box;background:{CARD};border-radius:14px;padding:12px 14px 8px;display:flex;flex-direction:column;gap:6px">'
            f'<div style="display:flex;justify-content:space-between;align-items:center;font-size:11px;color:{MUTED};letter-spacing:.08em;text-transform:uppercase"><span>{title}</span><span style="text-transform:none;letter-spacing:0;display:flex;gap:12px">{legend}</span></div>'
            f'{inner}</div>')

def scale(w, h, padl=26, padr=10, padt=8, padb=18):
    pw = w - padl - padr; ph = h - padt - padb
    def X(t): return padl + t / 24 * pw
    def Y(v): return padt + (100 - v) / 100 * ph
    return X, Y, pw, ph, padl, padr, padt, padb

def axes(w, h, X, Y, ylabels=True, xlabels=True, grid="dash"):
    out = []
    for gy in (0, 50, 100):
        y = Y(gy)
        if grid == "dash":
            out.append(f'<line x1="{X(0):.1f}" y1="{y:.1f}" x2="{X(24):.1f}" y2="{y:.1f}" stroke="{LINE}" stroke-width="0.7" stroke-dasharray="2 4"></line>')
        elif grid == "solid":
            out.append(f'<line x1="{X(0):.1f}" y1="{y:.1f}" x2="{X(24):.1f}" y2="{y:.1f}" stroke="{LINE}" stroke-width="0.6"></line>')
        if ylabels:
            out.append(f'<text x="{X(0)-6:.1f}" y="{y+3.5:.1f}" font-size="9.5" fill="{MUTED}" text-anchor="end" font-family="system-ui">{gy}</text>')
    if xlabels:
        for t, lb in LABELS:
            out.append(f'<text x="{X(t):.1f}" y="{h-4}" font-size="9.5" fill="{MUTED}" text-anchor="middle" font-family="system-ui">{lb}</text>')
    return "".join(out)

def path(X, Y, pts):
    return " ".join(f"{X(t):.1f},{Y(v):.1f}" for t, v in pts)

def smooth_path(X, Y, pts):
    # Catmull-Rom → cubic bezier, gentle
    P = [(X(t), Y(v)) for t, v in pts]
    d = f"M{P[0][0]:.1f},{P[0][1]:.1f}"
    for i in range(len(P) - 1):
        p0 = P[i - 1] if i > 0 else P[i]; p1 = P[i]; p2 = P[i + 1]; p3 = P[i + 2] if i + 2 < len(P) else P[i + 1]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d += f" C{c1[0]:.1f},{c1[1]:.1f} {c2[0]:.1f},{c2[1]:.1f} {p2[0]:.1f},{p2[1]:.1f}"
    return d

def write(name, body, w=W + 40, h=H + 40):
    html = HEAD + f'<div style="width:{w}px;height:{h}px;background:{BG};box-sizing:border-box;padding:20px;overflow:hidden">' + body + '</div>\n' + TAIL
    open(f"{name}.dc.html", "w").write(html)

def bolt(x, y, size=9, color=AMBER):
    s = size / 24
    return (f'<g transform="translate({x - size/2:.1f},{y - size/2:.1f}) scale({s:.3f})"><path d="M13 2 5 13h6l-1 9 8-11h-6z" fill="{color}"></path></g>')

# ================= A · Health: gradient area, charge markers on the axis =================
def chartA():
    w, h = W - 28, H - 46
    X, Y, pw, ph, *_ = scale(w, h)
    d = smooth_path(X, Y, PTS)
    area = d + f" L{X(24):.1f},{Y(0):.1f} L{X(0):.1f},{Y(0):.1f} Z"
    marks = "".join(f'<rect x="{X(a):.1f}" y="{Y(0)+5:.1f}" width="{X(b)-X(a):.1f}" height="3" rx="1.5" fill="{AMBER}"></rect>{bolt(X(a)-6, Y(0)+6.5, 8)}' for a, b in CHARGE)
    lx, ly = X(24), Y(PTS[-1][1])
    return card(f'''<svg viewBox="0 0 {w} {h}" style="width:{w}px;height:{h}px">
<defs><linearGradient id="ga" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{GREEN}" stop-opacity="0.35"></stop><stop offset="1" stop-color="{GREEN}" stop-opacity="0"></stop></linearGradient></defs>
{axes(w, h, X, Y, grid="dash")}
<path d="{area}" fill="url(#ga)"></path>
<path d="{d}" fill="none" stroke="{GREEN}" stroke-width="2.2" stroke-linejoin="round" stroke-linecap="round"></path>
{marks}
<line x1="{lx:.1f}" y1="{Y(100):.1f}" x2="{lx:.1f}" y2="{Y(0):.1f}" stroke="{LINE}" stroke-width="0.8"></line>
<circle cx="{lx:.1f}" cy="{ly:.1f}" r="6" fill="{GREEN}" opacity="0.25"></circle><circle cx="{lx:.1f}" cy="{ly:.1f}" r="3" fill="{GREEN}"></circle>
</svg>''', legend=f'<span style="color:{MUTED}"><span style="color:{AMBER}">▬</span> зарядка</span>')
write("ChartA", chartA())

# ================= B · Столбцы как в Настройках iOS =================
def chartB():
    w, h = W - 28, H - 46
    X, Y, pw, ph, *_ = scale(w, h)
    bars = ""
    n = 48
    for i in range(n):
        t0 = i * 24 / n; t1 = (i + 1) * 24 / n; tm = (t0 + t1) / 2
        # value at tm
        v = min(PTS, key=lambda p: abs(p[0] - tm))[1]
        charging = any(a <= tm <= b for a, b in CHARGE)
        col = AMBER if charging else GREEN
        op = 1.0 if i == n - 1 else 0.85
        bars += f'<rect x="{X(t0)+1:.1f}" y="{Y(v):.1f}" width="{X(t1)-X(t0)-2:.1f}" height="{Y(0)-Y(v):.1f}" rx="1.5" fill="{col}" opacity="{op}"></rect>'
    return card(f'''<svg viewBox="0 0 {w} {h}" style="width:{w}px;height:{h}px">
{axes(w, h, X, Y, grid="solid")}
{bars}
<line x1="{X(0):.1f}" y1="{Y(80):.1f}" x2="{X(24):.1f}" y2="{Y(80):.1f}" stroke="{INK2}" stroke-width="0.8" stroke-dasharray="3 3" opacity="0.6"></line>
<text x="{X(24):.1f}" y="{Y(80)-3:.1f}" font-size="9" fill="{MUTED}" text-anchor="end" font-family="system-ui">80 %</text>
</svg>''', legend=f'<span style="color:{MUTED}"><span style="color:{GREEN}">▮</span> от батареи</span><span style="color:{MUTED}"><span style="color:{AMBER}">▮</span> зарядка</span>')
write("ChartB", chartB())

# ================= C · Линия, окрашенная по состоянию =================
def chartC():
    w, h = W - 28, H - 46
    X, Y, pw, ph, *_ = scale(w, h)
    segs = ""
    # split into charging / battery segments
    def in_charge(t): return any(a <= t <= b for a, b in CHARGE)
    cur = []; state = in_charge(PTS[0][0])
    groups = []
    for t, v in PTS:
        s = in_charge(t)
        if s != state and cur:
            groups.append((state, cur + [(t, v)])); cur = [(t, v)]; state = s
        else:
            cur.append((t, v))
    groups.append((state, cur))
    for s, g in groups:
        col = AMBER if s else INK2
        segs += f'<path d="{smooth_path(X, Y, g)}" fill="none" stroke="{col}" stroke-width="2.4" stroke-linejoin="round" stroke-linecap="round"></path>'
        if s:
            a = smooth_path(X, Y, g) + f" L{X(g[-1][0]):.1f},{Y(0):.1f} L{X(g[0][0]):.1f},{Y(0):.1f} Z"
            segs += f'<path d="{a}" fill="{AMBER}" opacity="0.12"></path>'
            segs += bolt(X(g[0][0]), Y(g[0][1]) - 10, 10)
    lx, ly = X(24), Y(PTS[-1][1])
    return card(f'''<svg viewBox="0 0 {w} {h}" style="width:{w}px;height:{h}px">
{axes(w, h, X, Y, grid="dash")}
{segs}
<circle cx="{lx:.1f}" cy="{ly:.1f}" r="3.2" fill="{INK}"></circle>
<text x="{lx-8:.1f}" y="{ly-8:.1f}" font-size="10" font-weight="600" fill="{INK}" text-anchor="end" font-family="system-ui">24 %</text>
</svg>''', legend=f'<span style="color:{MUTED}"><span style="color:{INK2}">▬</span> от батареи</span><span style="color:{MUTED}"><span style="color:{AMBER}">▬</span> зарядка</span>')
write("ChartC", chartC())

# ================= D · Полоса состояний + линия (как Сон в Здоровье) =================
def chartD():
    w, h = W - 28, H - 46
    X, Y, pw, ph, padl, padr, padt, padb = scale(w, h, padb=34)
    d = smooth_path(X, Y, PTS)
    lx, ly = X(24), Y(PTS[-1][1])
    # state strip under the chart: green = battery, amber = charging, with rounded pills
    strip_y = h - 26; sh = 8
    strip = f'<rect x="{X(0):.1f}" y="{strip_y}" width="{X(24)-X(0):.1f}" height="{sh}" rx="4" fill="{INK}" opacity="0.10"></rect>'
    for a, b in CHARGE:
        strip += f'<rect x="{X(a):.1f}" y="{strip_y}" width="{X(b)-X(a):.1f}" height="{sh}" rx="4" fill="{AMBER}"></rect>'
    # discharge "session" pill (last stretch) subtle
    strip += f'<rect x="{X(19.6):.1f}" y="{strip_y}" width="{X(24)-X(19.6):.1f}" height="{sh}" rx="4" fill="{GREEN}" opacity="0.55"></rect>'
    return card(f'''<svg viewBox="0 0 {w} {h}" style="width:{w}px;height:{h}px">
{axes(w, h, X, Y, grid="dash", xlabels=False)}
<path d="{d}" fill="none" stroke="{INK2}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"></path>
<circle cx="{lx:.1f}" cy="{ly:.1f}" r="3.2" fill="{INK}"></circle>
{strip}
{"".join(f'<text x="{X(t):.1f}" y="{h-4}" font-size="9.5" fill="{MUTED}" text-anchor="middle" font-family="system-ui">{lb}</text>' for t, lb in LABELS)}
</svg>''', legend=f'<span style="color:{MUTED}"><span style="color:{AMBER}">▮</span> зарядка</span><span style="color:{MUTED}"><span style="color:{GREEN}">▮</span> расход</span>')
write("ChartD", chartD())


# ================= B2 · Столбцы с тремя состояниями + мощность =================
import math as _m
MAINS = [(4.5, 19.6)]   # plugged, not charging (Mac on the adapter, held at 90 %)
def state_at(t):
    if any(a <= t <= b for a, b in CHARGE): return "charge"
    if any(a <= t <= b for a, b in MAINS): return "mains"
    return "battery"
COL = {"charge": AMBER, "mains": BLUE, "battery": GREEN}

def legend_row(title, legend, top=0):
    return (f'<div style="display:flex;justify-content:space-between;align-items:center;font-size:11px;color:{MUTED};letter-spacing:.08em;text-transform:uppercase;margin-top:{top}px">'
            f'<span>{title}</span><span style="text-transform:none;letter-spacing:0;display:flex;gap:12px">{legend}</span></div>')

def chartB2(hsub=92):
    w, h = W - 28, 150
    X, Y, pw, ph, *_ = scale(w, h, padb=6)
    n = 48
    bars = ""
    for i in range(n):
        t0 = i * 24 / n; t1 = (i + 1) * 24 / n; tm = (t0 + t1) / 2
        v = min(PTS, key=lambda p: abs(p[0] - tm))[1]
        st = state_at(tm)
        op = 1.0 if i == n - 1 else 0.85
        bars += f'<rect x="{X(t0)+1:.1f}" y="{Y(v):.1f}" width="{X(t1)-X(t0)-2:.1f}" height="{Y(0)-Y(v):.1f}" rx="1.5" fill="{COL[st]}" opacity="{op}"></rect>'
    level = (f'<svg viewBox="0 0 {w} {h}" style="width:{w}px;height:{h}px">'
             f'{axes(w, h, X, Y, grid="solid", xlabels=False)}{bars}'
             f'<line x1="{X(0):.1f}" y1="{Y(80):.1f}" x2="{X(24):.1f}" y2="{Y(80):.1f}" stroke="{INK2}" stroke-width="0.8" stroke-dasharray="3 3" opacity="0.6"></line>'
             f'<text x="{X(24):.1f}" y="{Y(80)-3:.1f}" font-size="9" fill="{MUTED}" text-anchor="end" font-family="system-ui">80 %</text></svg>')
    ph2 = hsub
    Xp, Yp, pw2, php, padl, padr, padt, padb = scale(w, ph2, padt=6, padb=18)
    def YW(wv, maxw=100): return padt + (maxw - wv) / maxw * php
    pbars = ""
    for i in range(n):
        t0 = i * 24 / n; t1 = (i + 1) * 24 / n; tm = (t0 + t1) / 2
        st = state_at(tm)
        if st == "charge":
            a, b = CHARGE[0]; f = (tm - a) / (b - a); wv = 62 - f * 42
            pbars += f'<rect x="{Xp(t0)+1:.1f}" y="{YW(wv):.1f}" width="{Xp(t1)-Xp(t0)-2:.1f}" height="{YW(0)-YW(wv):.1f}" rx="1.5" fill="{AMBER}" opacity="0.85"></rect>'
        elif st == "mains":
            wv = 13 + (4 if int(tm * 2) % 3 == 0 else 0)
            pbars += f'<rect x="{Xp(t0)+1:.1f}" y="{YW(wv):.1f}" width="{Xp(t1)-Xp(t0)-2:.1f}" height="{YW(0)-YW(wv):.1f}" rx="1.5" fill="{BLUE}" opacity="0.55"></rect>'
    sysp = [(t, 9 + 6 * abs(_m.sin(t * 1.3)) + (12 if 20 < t < 24 else 0)) for t, _ in PTS]
    sline = " ".join(f"{Xp(t):.1f},{YW(v):.1f}" for t, v in sysp)
    gridp = "".join(f'<line x1="{Xp(0):.1f}" y1="{YW(g):.1f}" x2="{Xp(24):.1f}" y2="{YW(g):.1f}" stroke="{LINE}" stroke-width="0.6"></line><text x="{Xp(0)-6:.1f}" y="{YW(g)+3.5:.1f}" font-size="9.5" fill="{MUTED}" text-anchor="end" font-family="system-ui">{g}</text>' for g in (0, 50, 100))
    xl = "".join(f'<text x="{Xp(t):.1f}" y="{ph2-4}" font-size="9.5" fill="{MUTED}" text-anchor="middle" font-family="system-ui">{lb}</text>' for t, lb in LABELS)
    power = (f'<svg viewBox="0 0 {w} {ph2}" style="width:{w}px;height:{ph2}px">{gridp}{pbars}'
             f'<polyline points="{sline}" fill="none" stroke="{PURPLE}" stroke-width="1.6" stroke-linejoin="round"></polyline>{xl}</svg>')
    legend1 = (f'<span style="color:{MUTED}"><span style="color:{GREEN}">▮</span> от батареи</span>'
               f'<span style="color:{MUTED}"><span style="color:{AMBER}">▮</span> зарядка</span>'
               f'<span style="color:{MUTED}"><span style="color:{BLUE}">▮</span> от сети</span>')
    legend2 = (f'<span style="color:{MUTED}"><span style="color:{AMBER}">▮</span> от адаптера, W</span>'
               f'<span style="color:{MUTED}"><span style="color:{PURPLE}">▬</span> система, W</span>')
    inner = legend_row("Заряд · 24 часа", legend1) + level + legend_row("Мощность", legend2, 6) + power
    return f'<div style="width:{W}px;box-sizing:border-box;background:{CARD};border-radius:14px;padding:12px 14px 8px;display:flex;flex-direction:column;gap:6px">{inner}</div>'

write("ChartB2", chartB2(), W + 40, 150 + 92 + 90)

ab = [
    {"file": "ChartB.dc.html", "x": 0, "y": 0, "w": W + 40, "h": H + 40, "title": "B · Столбцы (выбрано)"},
    {"file": "ChartB2.dc.html", "x": 600, "y": 0, "w": W + 40, "h": 150 + 92 + 90, "title": "B2 · Три состояния + мощность"},
]
notes = [
    {"id": "n-b", "x": 0, "y": -150, "w": 510, "text": "B · выбранное направление: столбики по полчаса."},
    {"id": "n-b2", "x": 600, "y": -190, "w": 510, "text": "B2 · доработка. Три состояния: зелёный от батареи, янтарный зарядка, синий от сети без зарядки (Mac на адаптере, удержание 90 %). Под уровнем второй график: янтарные столбики это мощность от адаптера во время зарядки (видно, как спадает к 80 %), синие тонкие столбики это приход от сети, когда батарея заряжена, фиолетовая линия это потребление системы. Общая ось времени, подписи только внизу. В режиме колонок такой блок займёт место текущего графика, во вкладках оба графика поместятся по высоте."},
]
json.dump({"artboards": ab, "annotations": notes, "launch": {"view": "canvas"}}, open("canvas.json", "w"), ensure_ascii=False, indent=1)
print("ok")
