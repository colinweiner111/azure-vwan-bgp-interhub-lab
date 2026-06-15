from PIL import Image, ImageDraw, ImageFont

W, H = 2200, 1300
img = Image.new("RGB", (W, H), "white")
draw = ImageDraw.Draw(img)


def get_font(size, bold=False):
    candidates = [
        "C:/Windows/Fonts/segoeui.ttf",
        "C:/Windows/Fonts/segoeuib.ttf" if bold else "C:/Windows/Fonts/segoeui.ttf",
        "C:/Windows/Fonts/arial.ttf",
        "C:/Windows/Fonts/calibri.ttf",
    ]
    for c in candidates:
        try:
            return ImageFont.truetype(c, size)
        except OSError:
            continue
    return ImageFont.load_default()


def rounded_box(x1, y1, x2, y2, fill, outline, width=2, radius=20):
    draw.rounded_rectangle((x1, y1, x2, y2), radius=radius, fill=fill, outline=outline, width=width)


def center_text(x1, y1, x2, y2, text, font, fill="#111827"):
    bbox = draw.multiline_textbbox((0, 0), text, font=font, align="center", spacing=6)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    x = x1 + (x2 - x1 - tw) / 2
    y = y1 + (y2 - y1 - th) / 2
    draw.multiline_text((x, y), text, font=font, fill=fill, align="center", spacing=6)


def line(p1, p2, fill="#334155", width=3, dashed=False):
    if not dashed:
        draw.line([p1, p2], fill=fill, width=width)
        return
    # simple dashed line
    x1, y1 = p1
    x2, y2 = p2
    steps = 40
    for i in range(steps):
        if i % 2 == 0:
            t1 = i / steps
            t2 = (i + 1) / steps
            xa = x1 + (x2 - x1) * t1
            ya = y1 + (y2 - y1) * t1
            xb = x1 + (x2 - x1) * t2
            yb = y1 + (y2 - y1) * t2
            draw.line([(xa, ya), (xb, yb)], fill=fill, width=2)


f_title = get_font(42, bold=True)
f_h2 = get_font(30, bold=True)
f_h3 = get_font(24, bold=True)
f_body = get_font(20)
f_small = get_font(18)

# Panels
rounded_box(40, 30, 2140, 900, "#f8fbff", "#bfdbfe", width=3, radius=24)
center_text(40, 35, 2140, 85, "Azure Virtual WAN Fabric - vwan-bgp-interhub-lab3", f_title, "#0f172a")

rounded_box(40, 940, 2140, 1260, "#fffaf0", "#fdba74", width=3, radius=24)
center_text(40, 945, 2140, 995, "On-Prem ER Simulation - 10.0.0.0/16", f_h2, "#7c2d12")

# vWAN core
vwan_cx, vwan_cy, vwan_r = 1080, 170, 90
draw.ellipse((vwan_cx - vwan_r, vwan_cy - vwan_r, vwan_cx + vwan_r, vwan_cy + vwan_r), fill="#dbeafe", outline="#0369a1", width=5)
center_text(vwan_cx - vwan_r, vwan_cy - vwan_r, vwan_cx + vwan_r, vwan_cy + vwan_r, "vWAN\nBackbone", f_h3, "#0c4a6e")

# Hub columns
def draw_hub(x, title, hub_prefix, gw_name, s1, s2):
    rounded_box(x - 300, 280, x + 300, 860, "#f9fbff", "#dbeafe", width=2, radius=18)
    center_text(x - 300, 286, x + 300, 330, title, f_h2, "#0f172a")

    # hub circle
    draw.ellipse((x - 80, 350, x + 80, 510), fill="#dbeafe", outline="#1d4ed8", width=4)
    center_text(x - 80, 350, x + 80, 510, hub_prefix, f_h3, "#1e3a8a")

    # gateway box
    rounded_box(x - 190, 540, x + 190, 645, "#fee2e2", "#b91c1c", width=4, radius=14)
    center_text(x - 190, 540, x + 190, 645, gw_name, f_h3, "#7f1d1d")

    # spokes
    rounded_box(x - 230, 680, x + 230, 760, "#dcfce7", "#15803d", width=3, radius=12)
    rounded_box(x - 230, 780, x + 230, 860, "#dcfce7", "#15803d", width=3, radius=12)
    center_text(x - 230, 680, x + 230, 760, s1, f_body, "#14532d")
    center_text(x - 230, 780, x + 230, 860, s2, f_body, "#14532d")

    # local links
    line((x, 510), (x, 540), width=3)
    line((x, 510), (x - 120, 700), width=2)
    line((x, 510), (x - 120, 800), width=2)

    # return gateway anchor
    return (x, 540)

x1, x2, x3 = 470, 1080, 1690
gw1 = draw_hub(
    x1,
    "Hub1 - westus",
    "10.16.0.0/24",
    "hub1-westus-vpngw\nconn-er-path",
    "spoke1\n10.16.4.0/22\nvm 10.16.4.10",
    "spoke2\n10.16.8.0/22\nvm 10.16.8.10",
)
gw2 = draw_hub(
    x2,
    "Hub2 - westus3",
    "10.32.0.0/24",
    "hub2-westus3-vpngw\nconn-er-path-hub2",
    "spoke3\n10.32.4.0/22\nvm 10.32.4.10",
    "spoke4\n10.32.8.0/22\nvm 10.32.8.10",
)
gw3 = draw_hub(
    x3,
    "Hub3 - eastus2",
    "10.48.0.0/24",
    "hub3-eastus2-vpngw\nconn-er-path-hub3",
    "spoke5\n10.48.4.0/22\nvm 10.48.4.10",
    "spoke6\n10.48.8.0/22\nvm 10.48.8.10",
)

# vWAN to hubs
line((vwan_cx, vwan_cy + vwan_r), (x1, 350), width=3)
line((vwan_cx, vwan_cy + vwan_r), (x2, 350), width=3)
line((vwan_cx, vwan_cy + vwan_r), (x3, 350), width=3)

# On-prem nodes
rounded_box(240, 1035, 700, 1175, "#fff7ed", "#c2410c", width=4, radius=14)
center_text(240, 1035, 700, 1175, "frr-router\n10.0.0.10\nPrimary Transit", f_h2, "#7c2d12")

rounded_box(820, 1035, 1320, 1175, "#fff7ed", "#c2410c", width=4, radius=14)
center_text(820, 1035, 1320, 1175, "frr-router-backup\n10.0.0.11\nStandby Router", f_h2, "#7c2d12")

rounded_box(1460, 1060, 1860, 1160, "#fff7ed", "#c2410c", width=4, radius=14)
center_text(1460, 1060, 1860, 1160, "onprem-vm\n10.0.1.10", f_h2, "#7c2d12")

line((700, 1105), (820, 1105), width=2)
line((700, 1128), (1460, 1110), width=2)

# S2S/BGP dashed links to gateways
frr_anchor = (700, 1050)
line(frr_anchor, gw1, dashed=True)
line(frr_anchor, gw2, dashed=True)
line(frr_anchor, gw3, dashed=True)

# Labels for overlays
rounded_box(760, 980, 930, 1025, "#f3e8ff", "#c084fc", width=2, radius=8)
center_text(760, 980, 930, 1025, "IPSec + BGP", f_small, "#6b21a8")
rounded_box(960, 980, 1130, 1025, "#f3e8ff", "#c084fc", width=2, radius=8)
center_text(960, 980, 1130, 1025, "IPSec + BGP", f_small, "#6b21a8")
rounded_box(1160, 980, 1330, 1025, "#f3e8ff", "#c084fc", width=2, radius=8)
center_text(1160, 980, 1330, 1025, "IPSec + BGP", f_small, "#6b21a8")

# Save
img.save("image/network-topology.png", format="PNG")
print("Saved image/network-topology.png")
