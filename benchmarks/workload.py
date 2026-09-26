"""Deterministic mixed browser-memory fixture; synthetic, no external requests.

Four articles, three 600-card boards, three 1200x800 canvas charts. Call render
with a tab index 0..9; readiness follows DOMContentLoaded and synchronous canvas
drawing (not a visible first-paint or rendering-speed measurement).
"""

import html


def render(index):
    index = int(index)
    kind = "article" if index < 4 else "board" if index < 7 else "canvas"
    title = f"{kind.title()} {index + 1}"
    if kind == "article":
        paragraphs = []
        for section in range(40):
            paragraphs.append(f"<h2>Section {section + 1}: observing the coast</h2>" +
                              "<p>The field notebook records changing light, tidal pools, and the paths between them. "
                              "A useful observation separates what was measured from what remains uncertain. "
                              "Readers compare the same conditions and keep their original notes available.</p>" * 6)
        body = "<article>" + "".join(paragraphs) + "</article>"
    elif kind == "board":
        body = '<div class="board">' + "".join(
            f'<section class="card"><svg viewBox="0 0 200 72"><rect width="200" height="72" fill="hsl({(n * 17) % 360},35%,82%)"/>'
            f'<path d="M0 65 L40 {10 + n % 40} L90 55 L140 12 L200 50" fill="none" stroke="#345" stroke-width="3"/></svg>'
            f'<h2>Field note {n + 1}</h2><p>A deterministic card with text, an inline image and a progress value.</p>'
            f'<progress max="100" value="{n % 101}"></progress><button type="button">Open note</button></section>'
            for n in range(600)) + '</div>'
    else:
        body = '<canvas width="1200" height="800"></canvas><p>A static chart with 100 series of 600 samples.</p>'
    return (f'''<!doctype html><html><head><meta charset="utf-8"><title>{html.escape(title)}</title>
<style>body{{margin:0;background:#f3f1ed;color:#26332f;font:16px system-ui}}header{{padding:24px 40px;background:#fff;border-bottom:1px solid #ddd}}
main{{padding:32px;max-width:1400px;margin:auto}}article{{max-width:760px;margin:auto;line-height:1.65}}h1{{margin:0}}h2{{font-size:19px}}
.board{{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:18px}}.card{{background:white;padding:16px;border:1px solid #ddd;border-radius:12px}}
.card svg{{width:100%}}button{{display:block;margin-top:12px;padding:8px 16px}}canvas{{width:100%;max-width:1200px;background:white}}</style>
<script>document.addEventListener('DOMContentLoaded',()=>{{
const canvas=document.querySelector('canvas');if(canvas){{const c=canvas.getContext('2d');
c.fillStyle='#fff';c.fillRect(0,0,1200,800);for(let series=0;series<100;series++){{c.strokeStyle=`hsla(${{series*29%360}},40%,40%,.35)`;c.beginPath();
for(let sample=0;sample<600;sample++){{const x=sample*2,y=400+250*Math.sin(sample/31+series/7)+70*Math.cos(sample/13+series);if(!sample)c.moveTo(x,y);else c.lineTo(x,y);}}c.stroke();}}}}
navigator.sendBeacon('/ready'+location.search,'ready');
}});</script></head><body><header><h1>{html.escape(title)}</h1><p>Synthetic browser workload · no external requests</p></header><main>{body}</main></body></html>''').encode()
