import cairosvg, os
def shade(h, f):
    h=h.lstrip('#'); r,g,b=[int(h[i:i+2],16) for i in (0,2,4)]
    if f>0: r,g,b=[int(c+(255-c)*f) for c in (r,g,b)]
    else: r,g,b=[int(c*(1+f)) for c in (r,g,b)]
    return '#%02x%02x%02x'%(r,g,b)
SPARK='<path d="M0,-46 C6,-10 10,-6 46,0 C10,6 6,10 0,46 C-6,10 -10,6 -46,0 C-10,-6 -6,-10 0,-46Z" fill="{c}" transform="translate(724,300)"/>'
G={
'brand':'<path d="M650,372 C612,302 420,300 402,392 C388,462 470,490 520,506 C582,525 652,548 640,632 C626,722 430,726 374,650" stroke="url(#sg)" stroke-width="84"/>',
'restaurant':'<path d="M300,616 C300,480 396,404 512,404 C628,404 724,480 724,616 Z"/><path d="M262,664 H762"/><path d="M512,404 V372"/><circle cx="512" cy="352" r="22" fill="#fff" stroke="none"/><path d="M400,560 C410,512 440,478 480,462" stroke-width="36" opacity=".55"/>',
'kirana':'<g transform="translate(0,22)"><path d="M300,352 H724 L766,462 C756,520 649,520 639,462 C629,520 522,520 512,462 C502,520 395,520 385,462 C375,520 268,520 258,462 Z"/><path d="M322,540 V716 H702 V540"/><path d="M466,716 V616 H558 V716"/></g>',
'supermarket':'<path d="M248,330 H324 L384,606 H690 L744,414 H352"/><circle cx="420" cy="690" r="36"/><circle cx="662" cy="690" r="36"/><path d="M470,470 H652" stroke-width="40" opacity=".55"/>',
'pharmacy':'<path d="M450,296 H574 V450 H728 V574 H574 V728 H450 V574 H296 V450 H450 Z"/>',
'retail':'<path d="M318,424 H706 L682,722 H342 Z"/><path d="M420,424 V386 C420,332 460,300 512,300 C564,300 604,332 604,386 V424"/><circle cx="420" cy="480" r="16" fill="#fff" stroke="none"/><circle cx="604" cy="480" r="16" fill="#fff" stroke="none"/>',
}
C={'brand':'#0F2557','restaurant':'#E2563D','kirana':'#C77A0A','supermarket':'#1F6FB2','pharmacy':'#1F7F78','retail':'#8E3B8F'}
def svg(k, rounded=False, bg=True, fg=True):
    c=C[k]
    top=shade(c,0.18) if k!='brand' else '#1D3F8F'
    bot=shade(c,-0.28) if k!='brand' else '#0A1A40'
    rx=' rx="224"' if rounded else ''
    body=''
    if bg: body+=f'<rect width="1024" height="1024"{rx} fill="url(#bg)"/><rect width="1024" height="1024"{rx} fill="url(#gl)"/>'
    if fg:
        stroke='#fff'
        body+=f'<g fill="none" stroke="{stroke}" stroke-width="56" stroke-linecap="round" stroke-linejoin="round">{G[k]}</g>'
        body+=SPARK.format(c='#FFC857' if k=='brand' else '#ffffff')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{top}"/><stop offset="1" stop-color="{bot}"/></linearGradient>
<radialGradient id="gl" cx=".3" cy=".22" r=".8"><stop offset="0" stop-color="#fff" stop-opacity=".22"/><stop offset=".6" stop-color="#fff" stop-opacity="0"/></radialGradient>
<linearGradient id="sg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFC857"/><stop offset="1" stop-color="#FF6B3D"/></linearGradient></defs>
{body}</svg>'''
os.makedirs('svg',exist_ok=True)
for k in C:
    for name,kw in {'full':{}, 'round':{'rounded':True}, 'fg':{'bg':False}, 'bgonly':{'fg':False}}.items():
        open(f'svg/{k}_{name}.svg','w').write(svg(k,**kw))
    cairosvg.svg2png(url=f'svg/{k}_round.svg', write_to=f'prev_{k}.png', output_width=256, output_height=256)
