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
    svg.ic { width: 20px; height: 20px; fill: none; stroke: currentColor; stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
    svg.bolt { fill: currentColor; stroke: none; }
  </style>
</helmet>
'''
TAIL = '''</x-dc>
</body>
</html>
'''
LAP = '<svg class="ic" viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="11" rx="1.6"></rect><path d="M2 18.5h20"></path></svg>'
PH = '<svg class="ic" viewBox="0 0 24 24"><rect x="7" y="2.5" width="10" height="19" rx="2.4"></rect><path d="M10.5 5.2h3"></path></svg>'
GREEN = "#30D158"; AMBER = "#FF9F0A"; RED = "#FF453A"; BLUE = "#64D2FF"; TRACK = "#48484A"
MUTED = "#98989D"; INK = "#F5F5F7"; WBG = "#3A3A3C"; LINE = "#5A5A5E"

def sz(icon, n):
    return icon.replace('class="ic"', f'class="ic" style="width:{n}px;height:{n}px"')
def bolt(size=11, color=AMBER):
    return f'<svg class="ic bolt" viewBox="0 0 24 24" style="width:{size}px;height:{size}px;color:{color}"><path d="M13 2 5 13h6l-1 9 8-11h-6z"></path></svg>'
def level_color(p):  # proposed rule: green, red below 20 (no orange band — orange is charging)
    return RED if p < 20 else GREEN

def ring(p, color, size=60, sw=6.5, icon=LAP, badge=False, icon_size=24):
    r = (size - sw) / 2 - 1; c = 2 * math.pi * r; off = c * (1 - p / 100)
    b = f'<div style="position:absolute;right:-3px;top:-3px;width:18px;height:18px;border-radius:9px;background:{AMBER};display:flex;align-items:center;justify-content:center">{bolt(10, "#1B1408")}</div>' if badge else ''
    return (f'<div style="position:relative;width:{size}px;height:{size}px;flex:none">'
            f'<svg viewBox="0 0 {size} {size}" style="width:{size}px;height:{size}px;transform:rotate(-90deg)">'
            f'<circle cx="{size/2}" cy="{size/2}" r="{r:.1f}" fill="none" stroke="{TRACK}" stroke-width="{sw}"></circle>'
            f'<circle cx="{size/2}" cy="{size/2}" r="{r:.1f}" fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round" stroke-dasharray="{c:.1f}" stroke-dashoffset="{off:.1f}"></circle></svg>'
            f'<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:{INK}">{sz(icon, icon_size)}</div>{b}</div>')

def write(name, body, w=408, h=218):
    html = HEAD + f'<div style="width:{w}px;height:{h}px;background:#8A8D92;box-sizing:border-box;padding:24px;overflow:hidden">' + body + '</div>\n' + TAIL
    open(f"{name}.dc.html", "w").write(html)

def frame(inner, w=360, h=170, pad=14):
    return f'<div style="width:{w}px;height:{h}px;box-sizing:border-box;background:{WBG};border-radius:22px;padding:{pad}px;display:flex;gap:10px;box-shadow:0 10px 30px rgba(0,0,0,.25)">{inner}</div>'

def hair():
    return f'<div style="width:0.5px;background:{LINE};align-self:stretch"></div>'

# data as on the user's screenshot
MAC = dict(p=32, chg=True, icon=LAP, power="136/140 W", status="80 % · 27 min", bars=[90,90,90,90,90,90,86,74,60,44,30,32], states=list("mmmmmmbbbbbc"), sys="24 W")
PHN = dict(p=38, chg=False, icon=PH, power="", status="13:21", bars=[62,78,92,86,80,74,68,60,54,48,42,38], states=list("ccbbbbbbbbbb"), sys="")

# ---- helpers for small bars sparkline (12 bins × 2 h)
COLS = {"b": GREEN, "c": AMBER, "m": BLUE}
def bars(vals, w=140, h=34, states=None):
    n = len(vals); bw = w / n
    out = f'<svg viewBox="0 0 {w} {h}" style="width:{w}px;height:{h}px">'
    for i, v in enumerate(vals):
        col = COLS[states[i]] if states else GREEN
        op = 1.0 if i == n - 1 else 0.7
        bh = max(2, v / 100 * h)
        out += f'<rect x="{i*bw+1:.1f}" y="{h-bh:.1f}" width="{bw-2:.1f}" height="{bh:.1f}" rx="1.2" fill="{col}" opacity="{op}"></rect>'
    return out + '</svg>'

# ================= A · Столбики за сутки в середине =================
def tileA(d):
    power = f'<span style="color:{AMBER};font-size:13px;font-weight:600">{d["power"]}</span>' if d["chg"] else f'<span style="font-size:13px;color:{MUTED}">от батареи</span>'
    return (f'<div style="flex:1 1 0;display:flex;flex-direction:column;justify-content:space-between;min-width:0">'
            f'<div style="display:flex;align-items:center;gap:10px">{ring(d["p"], level_color(d["p"]), 52, 6, d["icon"], d["chg"], 22)}<div style="display:flex;flex-direction:column;gap:2px">{power}</div></div>'
            f'{bars(d["bars"], 150, 36, d["states"])}'
            f'<div style="display:flex;align-items:baseline;justify-content:space-between"><span style="font-size:30px;font-weight:600;letter-spacing:-0.02em;line-height:1">{d["p"]} %</span><span style="font-size:12.5px;color:{INK};white-space:nowrap">{d["status"]}</span></div></div>')
write("MediumA", frame(tileA(MAC) + hair() + tileA(PHN)))

# ================= B · Полоса уровня с отметкой 80 % =================
def tileB(d):
    power = f'<span style="color:{AMBER};font-size:13px;font-weight:600">{d["power"]}</span>' if d["chg"] else f'<span style="font-size:13px;color:{MUTED}">от батареи</span>'
    col = level_color(d["p"])
    bar = (f'<div style="position:relative;height:8px;border-radius:4px;background:{TRACK}"><div style="width:{d["p"]}%;height:100%;border-radius:4px;background:{col}"></div>'
           f'<div style="position:absolute;left:80%;top:-3px;width:2px;height:14px;border-radius:1px;background:{INK};opacity:.6"></div></div>')
    return (f'<div style="flex:1 1 0;display:flex;flex-direction:column;justify-content:space-between;min-width:0">'
            f'<div style="display:flex;align-items:center;gap:12px">{ring(d["p"], col, 58, 6.5, d["icon"], d["chg"], 24)}<div style="display:flex;flex-direction:column;gap:3px"><span style="font-size:32px;font-weight:600;letter-spacing:-0.02em;line-height:1">{d["p"]} %</span>{power}</div></div>'
            f'<div style="display:flex;flex-direction:column;gap:6px">{bar}<div style="display:flex;justify-content:space-between;font-size:11.5px;color:{MUTED}"><span>{"до 80 %" if d["chg"] else "осталось"}</span><span style="color:{INK}">{d["status"]}</span></div></div></div>')
write("MediumB", frame(tileB(MAC) + hair() + tileB(PHN)))

# ================= C · Крупное кольцо с процентом внутри =================
def tileC(d):
    col = level_color(d["p"])
    size = 110; sw = 9; r = (size - sw) / 2 - 1; c = 2 * math.pi * r; off = c * (1 - d["p"] / 100)
    b = f'<div style="position:absolute;right:2px;top:2px;width:22px;height:22px;border-radius:11px;background:{AMBER};display:flex;align-items:center;justify-content:center">{bolt(12, "#1B1408")}</div>' if d["chg"] else ''
    big = (f'<div style="position:relative;width:{size}px;height:{size}px;flex:none">'
           f'<svg viewBox="0 0 {size} {size}" style="width:{size}px;height:{size}px;transform:rotate(-90deg)"><circle cx="{size/2}" cy="{size/2}" r="{r:.1f}" fill="none" stroke="{TRACK}" stroke-width="{sw}"></circle>'
           f'<circle cx="{size/2}" cy="{size/2}" r="{r:.1f}" fill="none" stroke="{col}" stroke-width="{sw}" stroke-linecap="round" stroke-dasharray="{c:.1f}" stroke-dashoffset="{off:.1f}"></circle></svg>'
           f'<div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:1px"><span style="font-size:26px;font-weight:600;letter-spacing:-0.02em;line-height:1">{d["p"]} %</span><span style="color:{MUTED}">{sz(d["icon"], 16)}</span></div>{b}</div>')
    lines = ((f'<span style="color:{AMBER};font-size:14px;font-weight:600">{d["power"]}</span>' if d["chg"] else f'<span style="font-size:14px;color:{MUTED}">от батареи</span>')
             + f'<span style="font-size:11px;color:{MUTED}">{"до 80 %" if d["chg"] else "осталось"}</span><span style="font-size:15px;font-weight:600;color:{INK}">{d["status"]}</span>')
    return (f'<div style="flex:1 1 0;display:flex;align-items:center;gap:14px;min-width:0">{big}<div style="display:flex;flex-direction:column;gap:5px;min-width:0;white-space:nowrap">{lines}</div></div>')
write("MediumC", frame(tileC(MAC) + hair() + tileC(PHN)))

# ================= D · Сегодня одной строкой =================
def tileD(d, today):
    col = level_color(d["p"])
    power = f'<span style="color:{AMBER};font-size:13px;font-weight:600">{d["power"]}</span>' if d["chg"] else f'<span style="font-size:13px;color:{MUTED}">от батареи</span>'
    cells = "".join(f'<div style="display:flex;flex-direction:column;gap:1px;min-width:0"><span style="font-size:12.5px;font-weight:600;white-space:nowrap">{v}</span><span style="font-size:9.5px;color:{MUTED};white-space:nowrap">{k}</span></div>' for k, v in today)
    return (f'<div style="flex:1 1 0;display:flex;flex-direction:column;justify-content:space-between;min-width:0">'
            f'<div style="display:flex;align-items:center;gap:10px">{ring(d["p"], col, 54, 6, d["icon"], d["chg"], 22)}<div style="display:flex;flex-direction:column;gap:2px"><span style="font-size:30px;font-weight:600;letter-spacing:-0.02em;line-height:1">{d["p"]} %</span>{power}</div></div>'
            f'<div style="display:flex;gap:14px">{cells}</div>'
            f'<div style="display:flex;justify-content:space-between;font-size:11.5px;color:{MUTED}"><span>{"до 80 %" if d["chg"] else "осталось"}</span><span style="color:{INK}">{d["status"]}</span></div></div>')
write("MediumD", frame(tileD(MAC, [("диапазон", "32–90 %"), ("у розетки", "1 ч 12 мин"), ("система", "24 W")]) + hair() + tileD(PHN, [("диапазон", "38–92 %"), ("у розетки", "0 мин"), ("система", "2 W")])))

# -*- coding: utf-8 -*-
PLUG = '<svg class="ic" viewBox="0 0 24 24"><path d="M9 3v5M15 3v5"></path><path d="M6 8h12v3a6 6 0 0 1-12 0z"></path><path d="M12 17v4"></path></svg>'
BOLT_BADGE = f'<div style="width:18px;height:18px;border-radius:9px;background:{AMBER};display:flex;align-items:center;justify-content:center">{bolt(10, "#1B1408")}</div>'
EXCL_BADGE = f'<div style="width:18px;height:18px;border-radius:9px;background:{AMBER};display:flex;align-items:center;justify-content:center;color:#1B1408;font-size:12px;font-weight:800;line-height:1">!</div>'

def ring2(p, color, size=52, sw=6, icon=LAP, badge="", icon_size=22, dim=False, empty=False):
    r = (size - sw) / 2 - 1; c = 2 * math.pi * r; off = c * (1 - (p or 0) / 100)
    arc = '' if empty else f'<circle cx="{size/2}" cy="{size/2}" r="{r:.1f}" fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round" stroke-dasharray="{c:.1f}" stroke-dashoffset="{off:.1f}"></circle>'
    b = f'<div style="position:absolute;right:-3px;top:-3px">{badge}</div>' if badge else ''
    return (f'<div style="position:relative;width:{size}px;height:{size}px;flex:none">'
            f'<div style="opacity:{0.45 if dim else 1}"><svg viewBox="0 0 {size} {size}" style="width:{size}px;height:{size}px;transform:rotate(-90deg)"><circle cx="{size/2}" cy="{size/2}" r="{r:.1f}" fill="none" stroke="{TRACK}" stroke-width="{sw}"></circle>{arc}</svg>'
            f'<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:{INK}">{sz(icon, icon_size)}</div></div>{b}</div>')

def tile(st):
    dim = st.get("dim", False); op = 0.45 if dim else 1
    top_icon = st.get("top_icon", "")
    weight = 600 if st.get("top_color") in (AMBER, BLUE) else 500
    top = f'<span style="display:inline-flex;align-items:center;gap:4px;color:{st.get("top_color", MUTED)};font-size:13px;font-weight:{weight}">{top_icon}{st["top"]}</span>'
    b = bars(st["bars"], 150, 36, st["states"]) if st.get("bars") else f'<div style="height:36px;border-radius:6px;background:{TRACK};opacity:.5"></div>'
    pct = "—" if st.get("empty") else f'{st["p"]} %'
    return (f'<div style="flex:1 1 0;display:flex;flex-direction:column;justify-content:space-between;min-width:0">'
            f'<div style="display:flex;align-items:center;gap:10px">{ring2(st["p"], st.get("color", GREEN), 52, 6, st["icon"], st.get("badge", ""), 22, dim, st.get("empty", False))}<div style="display:flex;flex-direction:column;gap:2px;opacity:{op}">{top}</div></div>'
            f'<div style="opacity:{op}">{b}</div>'
            f'<div style="display:flex;align-items:baseline;justify-content:space-between;opacity:{op}"><span style="font-size:30px;font-weight:600;letter-spacing:-0.02em;line-height:1">{pct}</span><span style="font-size:12.5px;color:{INK};white-space:nowrap">{st["bottom"]}</span></div></div>')

MB = [90,90,90,90,90,90,86,74,60,44,30,32]
PB = [62,78,92,86,80,74,68,60,54,48,42,38]
MAC_STATES = [
 ("От батареи",        dict(icon=LAP, p=32, top="−13 W", bars=MB, states=list("mmmmmmbbbbbb"), bottom="4:19")),
 ("Зарядка",           dict(icon=LAP, p=32, top="62/140 W", top_color=AMBER, badge=BOLT_BADGE, bars=MB, states=list("mmmmmmbbbbbc"), bottom="80 % · 27 min")),
 ("От сети, заряжен",  dict(icon=LAP, p=90, top="13/140 W", top_color=BLUE, top_icon=sz(PLUG, 13), bars=[90]*12, states=list("mmmmmmmmmmmm"), bottom="заряжен")),
 ("От сети, ожидание", dict(icon=LAP, p=62, top="13/140 W", top_color=BLUE, top_icon=sz(PLUG, 13), bars=[70,68,66,64,62,62,62,62,62,62,62,62], states=list("bbbbbmmmmmmm"), bottom="ожидание")),
 ("Низкий заряд",      dict(icon=LAP, p=14, color=RED, top="−13 W", bars=[80,74,66,58,50,44,38,32,26,22,18,14], states=list("bbbbbbbbbbbb"), bottom="1:02")),
]
PH_STATES = [
 ("От батареи",          dict(icon=PH, p=38, top="от батареи", bars=PB, states=list("ccbbbbbbbbbb"), bottom="13:21")),
 ("Зарядка",             dict(icon=PH, p=38, top="36/45 W", top_color=AMBER, badge=BOLT_BADGE, bars=PB, states=list("ccbbbbbbbbbc"), bottom="80 % · 14 min")),
 ("Заряжен, на проводе", dict(icon=PH, p=100, top="45 W", top_color=BLUE, top_icon=sz(PLUG, 13), bars=[62,78,92,100,100,100,100,100,100,100,100,100], states=list("cccmmmmmmmmm"), bottom="заряжен")),
 ("Нет связи > 5 мин",   dict(icon=PH, p=38, top="нет связи с 14:32", badge=EXCL_BADGE, dim=True, bars=PB, states=list("ccbbbbbbbbbb"), bottom="14:32")),
 ("Ни разу не виден",    dict(icon=PH, p=None, top="нет данных", empty=True, bars=None, states=None, bottom="")),
]

def sheet(title, states):
    tiles = ""
    for name, st in states:
        tiles += (f'<div style="display:flex;flex-direction:column;gap:8px;width:180px"><div style="font-size:11px;color:#3A3A3C;font-weight:600">{name}</div>'
                  f'<div style="width:180px;height:170px;box-sizing:border-box;background:{WBG};border-radius:18px;padding:14px;display:flex;box-shadow:0 8px 24px rgba(0,0,0,.2)">{tile(st)}</div></div>')
    return f'<div style="display:flex;flex-direction:column;gap:10px"><div style="font-size:13px;font-weight:700;color:#2A2A2C">{title}</div><div style="display:flex;gap:16px;flex-wrap:wrap">{tiles}</div></div>'

write("StatesMac", sheet("MacBook", MAC_STATES), 1040, 250)
write("StatesPhone", sheet("iPhone", PH_STATES), 1040, 250)

def combo(m, p):
    return frame(tile(m) + hair() + tile(p))
combos = [
 ("Оба на зарядке", MAC_STATES[1][1], PH_STATES[1][1]),
 ("Mac от сети, iPhone от батареи", MAC_STATES[2][1], PH_STATES[0][1]),
 ("Mac от батареи, iPhone нет связи", MAC_STATES[0][1], PH_STATES[3][1]),
 ("Mac ожидание, iPhone заряжен", MAC_STATES[3][1], PH_STATES[2][1]),
]
body = '<div style="display:flex;gap:24px;flex-wrap:wrap">' + "".join(f'<div style="display:flex;flex-direction:column;gap:8px"><div style="font-size:11px;color:#3A3A3C;font-weight:600">{n}</div>{combo(m, p)}</div>' for n, m, p in combos) + '</div>'
write("Combos", body, 830, 480)

ab = [
    {"file": "MediumA.dc.html", "x": 0, "y": 0, "w": 408, "h": 218, "title": "A · Столбики за сутки (выбрано)"},
    {"file": "StatesMac.dc.html", "x": 0, "y": 340, "w": 1040, "h": 250, "title": "Состояния · MacBook"},
    {"file": "StatesPhone.dc.html", "x": 0, "y": 710, "w": 1040, "h": 250, "title": "Состояния · iPhone"},
    {"file": "Combos.dc.html", "x": 0, "y": 1080, "w": 830, "h": 480, "title": "Сочетания в целом виджете"},
]
notes = [
    {"id": "n-a", "x": 500, "y": 0, "w": 540, "text": "Вариант A утверждён: столбики по два часа в трёх состояниях (зелёный от батареи, оранжевый зарядка, синий от сети), последний ярче, кольцо зелёное, красное ниже 20 %, оранжевый только у зарядки."},
    {"id": "n-states", "x": 1100, "y": 340, "w": 420, "text": "Правила по плиткам.\nВерхняя строка: от батареи → «−13 W» у Mac, «от батареи» у iPhone; зарядка → «62/140 W» оранжевым и молния на кольце; от сети без зарядки → значок вилки и «13/140 W» синим (у iPhone на проводе после 100 % → «45 W»).\nНижняя строка справа: от батареи → время работы; зарядка → «80 % · N min»; от сети → «заряжен» при ≥ 80 % или полном заряде, иначе «ожидание».\nНет связи > 5 мин: плитка приглушена, восклицательный знак на кольце вместо молнии, сверху «нет связи с 14:32», внизу последний процент и время последнего ответа.\nНи разу не виден: пустое кольцо, «—» вместо процента, «нет данных», столбиков нет."},
]
json.dump({"artboards": ab, "annotations": notes, "launch": {"view": "canvas"}}, open("canvas.json", "w"), ensure_ascii=False, indent=1)
print("states ok")
