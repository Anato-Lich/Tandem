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
    .mono { font-family: ui-monospace, "SF Mono", Menlo, monospace; }
  </style>
</helmet>
'''
TAIL = '''</x-dc>
</body>
</html>
'''
LAP = '<svg class="ic" viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="11" rx="1.6"></rect><path d="M2 18.5h20"></path></svg>'
PH = '<svg class="ic" viewBox="0 0 24 24"><rect x="7" y="2.5" width="10" height="19" rx="2.4"></rect><path d="M10.5 5.2h3"></path></svg>'

GREEN = "#30D158"; AMBER = "#FF9F0A"; RED = "#FF453A"; TRACK = "#48484A"
WBG = "#2C2C2E"; MUTED = "#98989D"; INK = "#F5F5F7"


def sz(icon, n, extra=""):
    return icon.replace('class="ic"', f'class="ic" style="width:{n}px;height:{n}px{extra}"')


def bolt(size=11, color=AMBER):
    return f'<svg class="ic bolt" viewBox="0 0 24 24" style="width:{size}px;height:{size}px;color:{color}"><path d="M13 2 5 13h6l-1 9 8-11h-6z"></path></svg>'


def level_color(p):
    return RED if p < 20 else (AMBER if p < 50 else GREEN)


def ring(p, color, size=62, sw=5.5, icon=LAP, bolt_badge=False, icon_size=24):
    r = (size - sw) / 2 - 1
    c = 2 * math.pi * r
    off = c * (1 - p / 100)
    badge = ''
    if bolt_badge:
        badge = f'<div style="position:absolute;right:-3px;top:-3px;width:18px;height:18px;border-radius:9px;background:{AMBER};display:flex;align-items:center;justify-content:center">{bolt(10, "#1B1408")}</div>'
    inner = f'<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:{INK}">{sz(icon, icon_size)}</div>' if icon else ''
    return (f'<div style="position:relative;width:{size}px;height:{size}px">'
            f'<svg viewBox="0 0 {size} {size}" style="width:{size}px;height:{size}px;transform:rotate(-90deg)">'
            f'<circle cx="{size/2}" cy="{size/2}" r="{r:.1f}" fill="none" stroke="{TRACK}" stroke-width="{sw}"></circle>'
            f'<circle cx="{size/2}" cy="{size/2}" r="{r:.1f}" fill="none" stroke="{color}" stroke-width="{sw}" stroke-linecap="round" stroke-dasharray="{c:.1f}" stroke-dashoffset="{off:.1f}"></circle></svg>'
            f'{inner}{badge}</div>')


def bar(p, color, h=6):
    return f'<div style="height:{h}px;border-radius:{h/2}px;background:{TRACK};overflow:hidden"><div style="width:{p}%;height:100%;border-radius:{h/2}px;background:{color}"></div></div>'


def write(name, body, bg):
    html = HEAD + f'<div style="width:100%;min-height:100vh;background:{bg};box-sizing:border-box">' + body + '</div>\n' + TAIL
    open(f"{name}.dc.html", "w").write(html)


MAC = dict(name="MacBook Pro", p=71, chg=False, l2="−13.4 W", l3="4:19")
PHN = dict(name="iPhone", p=64, chg=True, l2="16.5 W", ad="45 W", l3="80 % · 14 мин")
MAC2 = dict(name="MacBook Pro", p=71, chg=True, l2="62.0 W", ad="96 W", l3="80 % · 9 мин")

# ---------- menu bar (approved) ----------
mb = (f'<div style="display:flex;align-items:center;gap:10px;padding:0 6px">'
      f'<div style="display:flex;align-items:center;gap:4px">{sz(LAP, 16)}<span>71 %</span></div>'
      f'<div style="display:flex;align-items:center;gap:4px">{sz(PH, 16)}<span>64 %</span>{bolt(10, "#E5E5EA")}</div></div>')
strip = (f'<div style="padding:28px 24px 24px;display:flex;flex-direction:column;gap:14px">'
         f'<div style="height:28px;border-radius:6px;background:#1C1C1E;display:flex;align-items:center;justify-content:flex-end;gap:16px;padding:0 12px;color:#E5E5EA;font-size:13px;font-weight:500">{mb}'
         f'<div style="display:flex;align-items:center;gap:14px;opacity:0.85"><svg class="ic" viewBox="0 0 24 24" style="width:16px;height:16px"><path d="M5 12.5a9 9 0 0 1 14 0"></path><path d="M8.5 15.5a5 5 0 0 1 7 0"></path><circle cx="12" cy="18.5" r="0.8"></circle></svg><span>Пн 7 сент. 13:04</span></div></div>'
         f'<div style="font-size:12px;color:#3A3A3C;line-height:1.4">Утверждено: два значка с процентами, молния при зарядке.</div></div>')
write("MenuBarA", strip, "#8A8D92")

# ---------- popover ----------
def popover_frame(inner, w=300):
    return (f'<div style="padding:24px;display:flex;justify-content:center"><div style="width:{w}px;background:{WBG};border-radius:12px;box-shadow:0 12px 40px rgba(0,0,0,.45), 0 0 0 0.5px rgba(255,255,255,.12);padding:14px 14px 10px;display:flex;flex-direction:column;gap:12px">{inner}'
            f'<div style="height:0.5px;background:#48484A"></div>'
            f'<div style="display:flex;align-items:center;justify-content:space-between;font-size:11px;color:{MUTED}"><span>Обновлено 12 с назад</span>'
            f'<div style="display:flex;gap:6px"><span style="padding:3px 9px;border-radius:6px;background:#3A3A3C;color:{INK}">Обновить</span><span style="padding:3px 9px;border-radius:6px;background:#3A3A3C;color:{INK}">Настройки…</span></div></div></div></div>')


def head(d):
    icon = LAP if d["name"].startswith("Mac") else PH
    nm = d["name"] + (f' <span style="display:inline-flex;vertical-align:-1px">{bolt(11)}</span>' if d["chg"] else '')
    return (f'<div style="display:flex;align-items:center;gap:8px;font-size:13px;font-weight:500"><div style="color:{MUTED};display:flex">{icon}</div><span style="flex-grow:1">{nm}</span><span style="font-weight:600">{d["p"]} %</span></div>'
            f'{bar(d["p"], level_color(d["p"]))}')


def cols(d):
    if d["chg"]:
        return [("16.5 W", "зарядка", AMBER, bolt(9, AMBER)), ("45 W", "адаптер", INK, ""), ("14 мин", "до 80 %", INK, "")]
    return [("−13.4 W", "потребление", INK, ""), ("—", "адаптер", MUTED, ""), ("4:19", "осталось", INK, "")]


def stat(v, cap, color, icon):
    return (f'<div style="display:flex;flex-direction:column;gap:1px;white-space:nowrap;min-width:64px">'
            f'<span style="display:inline-flex;align-items:center;gap:4px;font-size:12px;font-weight:600;color:{color}" class="mono">{icon}{v}</span>'
            f'<span style="font-size:9.5px;color:{MUTED};letter-spacing:.02em">{cap}</span></div>')


def row(d):
    return f'<div style="display:flex;flex-direction:column;gap:8px">{head(d)}<div style="display:flex;gap:18px;padding-left:28px">{"".join(stat(*c) for c in cols(d))}</div></div>'


write("Main", popover_frame(row(MAC) + row(PHN)), "#1D1D1F")

# ---------- widgets ----------
def widget_frame(inner, w, h):
    return f'<div style="padding:24px"><div style="width:{w}px;height:{h}px;box-sizing:border-box;background:#3A3A3C;border-radius:22px;padding:16px;box-shadow:0 10px 30px rgba(0,0,0,.25);display:flex;flex-direction:column;justify-content:space-between">{inner}</div></div>'


def concentric(mac_chg=False):
    out = ring(71, level_color(71), 86, 7, '', False, 0)
    inn = ring(64, level_color(64), 62, 7, '', False, 0)
    return (f'<div style="position:relative;width:86px;height:86px">{out}'
            f'<div style="position:absolute;left:12px;top:12px;opacity:.85">{inn}</div>'
            f'<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center">{bolt(14, AMBER)}</div></div>')


def small_col(icon, p, t, chg=False, align="flex-start"):
    return (f'<div style="display:flex;flex-direction:column;gap:2px;align-items:{align}">'
            f'<div style="display:flex;align-items:center;gap:4px;color:{MUTED};font-size:12px;font-weight:600">{sz(icon, 13)}<span style="color:{INK}">{p} %</span>{bolt(9) if chg else ""}</div>'
            f'<div style="font-size:9.5px;color:{MUTED};white-space:nowrap;letter-spacing:-0.01em">{t}</div></div>')


def small(mac_chg):
    mac_t = "80 % · 9 мин" if mac_chg else "4:19"
    return (f'<div style="display:flex;justify-content:center">{concentric(mac_chg)}</div>'
            f'<div style="display:flex;justify-content:space-between">{small_col(LAP, 71, mac_t, mac_chg)}{small_col(PH, 64, "80 % · 14 мин", True, "flex-end")}</div>')


sB = small(False)
write("SmallB", widget_frame(sB, 170, 170), "#8A8D92")
write("SmallB2", widget_frame(small(True), 170, 170), "#8A8D92")


def ring_tile_w(d):
    icon = LAP if d["name"].startswith("Mac") else PH
    if d["chg"]:
        l2 = f'<span style="color:{AMBER}">{d["l2"]}</span> · {d["ad"]}'
    else:
        l2 = d["l2"]
    return (f'<div style="flex:1 1 0;display:flex;align-items:center;gap:10px;min-width:0">'
            f'{ring(d["p"], level_color(d["p"]), 56, 5.5, icon, d["chg"], 22)}'
            f'<div style="display:flex;flex-direction:column;gap:3px;min-width:0;white-space:nowrap"><div style="font-size:24px;font-weight:600;letter-spacing:-0.02em;line-height:1">{d["p"]} %</div>'
            f'<div style="font-size:10.5px;color:{MUTED};line-height:1.2">{l2}</div><div style="font-size:10.5px;color:{INK};line-height:1.2">{d["l3"]}</div></div></div>')


def medium(a, b):
    return f'<div style="display:flex;gap:10px;height:100%;align-items:center">{ring_tile_w(a)}<div style="width:0.5px;align-self:stretch;background:#5A5A5E"></div>{ring_tile_w(b)}</div>'


write("MediumRings", widget_frame(medium(MAC, PHN), 360, 170), "#8A8D92")
write("MediumRings2", widget_frame(medium(MAC2, PHN), 360, 170), "#8A8D92")

# ---------- canvas ----------
P1 = "page-1"; P2 = "page-2"
ab = []


def add(f, x, y, w, h, page, title=None):
    e = {"file": f, "x": x, "y": y, "w": w, "h": h, "page": page}
    if title:
        e["title"] = title
    ab.append(e)


add("MenuBarA.dc.html", 0, 0, 420, 150, P1, "Строка меню · выбрано")
add("Main.dc.html", 0, 300, 348, 300, P1, "Окно · 3 колонки")
add("SmallB.dc.html", 0, 0, 218, 218, P2, "Малый · iPhone на зарядке")
add("SmallB2.dc.html", 300, 0, 218, 218, P2, "Малый · оба на зарядке")
add("MediumRings.dc.html", 0, 360, 408, 218, P2, "Средний · iPhone на зарядке")
add("MediumRings2.dc.html", 500, 360, 408, 218, P2, "Средний · оба на зарядке")
notes = [
    {"id": "n-menubar", "x": 0, "y": -170, "w": 420, "page": P1, "text": "Строка меню: утверждена."},
    {"id": "n-popover", "x": 0, "y": 760, "w": 600, "page": P1, "text": "Окно: три колонки всегда одни и те же: мощность со знаком, адаптер, время. На зарядке время это «до 80 %», от батареи «осталось». Зарядку показывает молния у имени. Цвет полосы по уровню: до 20 % красный, до 50 % жёлтый, выше зелёный.\nБез плашек, значение над подписью, всё в одну строку."},
    {"id": "n-widgets", "x": 0, "y": -210, "w": 560, "page": P2, "text": "Средний: у обоих устройств три строки одинаковой структуры: заряд, мощность и адаптер, время. Без слова «через», строки не переносятся. Малый: вложенные кольца, Mac снаружи, iPhone внутри, под значками время работы или время до 80 %. Молния в центре означает, что хотя бы одно устройство на зарядке, какое именно, показывают молнии у процентов. Справа сценарий, когда оба устройства на зарядке: у Mac 62 W от 96‑ваттного адаптера."},
]
canvas = {"artboards": ab, "annotations": notes, "pages": [{"id": P1, "name": "Строка меню и окно"}, {"id": P2, "name": "Виджеты"}], "launch": {"view": "canvas", "page": P1}}
json.dump(canvas, open("canvas.json", "w"), ensure_ascii=False, indent=1)
print("generated", len(ab), "artboards")
