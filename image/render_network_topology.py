import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Circle, FancyArrowPatch


def rr(ax, x, y, w, h, fc, ec, lw=1.8, r=0.15):
    patch = FancyBboxPatch(
        (x, y),
        w,
        h,
        boxstyle=f"round,pad=0.02,rounding_size={r}",
        facecolor=fc,
        edgecolor=ec,
        linewidth=lw,
    )
    ax.add_patch(patch)
    return patch


def label(ax, x, y, text, size=10, weight="normal", color="#0f172a", ha="center", va="center"):
    ax.text(x, y, text, fontsize=size, fontweight=weight, color=color, ha=ha, va=va)


def conn(ax, p1, p2, color="#334155", lw=1.5, style="-", arrow=False, rad=0.0):
    if arrow:
        patch = FancyArrowPatch(
            p1,
            p2,
            arrowstyle="-|>",
            mutation_scale=12,
            linewidth=lw,
            linestyle=style,
            color=color,
            connectionstyle=f"arc3,rad={rad}",
        )
        ax.add_patch(patch)
    else:
        patch = FancyArrowPatch(
            p1,
            p2,
            arrowstyle="-",
            linewidth=lw,
            linestyle=style,
            color=color,
            connectionstyle=f"arc3,rad={rad}",
        )
        ax.add_patch(patch)


def main():
    fig, ax = plt.subplots(figsize=(18, 10), dpi=220)
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 100)
    ax.axis("off")
    fig.patch.set_facecolor("white")
    ax.set_facecolor("white")

    # Regions
    rr(ax, 20, 35, 77, 60, "#f8fbff", "#bfdbfe", lw=1.2, r=0.4)
    label(ax, 58.5, 94, "Azure Virtual WAN Fabric  (vwan-bgp-interhub-lab3)", size=14, weight="bold")

    rr(ax, 20, 4, 77, 25, "#fffaf0", "#fed7aa", lw=1.2, r=0.4)
    label(ax, 58.5, 27, "On-Prem ER Simulation  (10.0.0.0/16)", size=13, weight="bold")

    # vWAN backbone
    vwan = Circle((10, 66), 5.5, facecolor="#e0f2fe", edgecolor="#0369a1", linewidth=2.2)
    ax.add_patch(vwan)
    label(ax, 10, 66, "vWAN\nBackbone", size=11, weight="bold", color="#0c4a6e")

    hubs = [
        {
            "name": "Hub1 - westus",
            "x": 33,
            "hub": "10.16.0.0/24",
            "gw": "hub1-westus-vpngw\nconn-er-path",
            "s1": "spoke1\n10.16.4.0/22\nvm 10.16.4.10",
            "s2": "spoke2\n10.16.8.0/22\nvm 10.16.8.10",
        },
        {
            "name": "Hub2 - westus3",
            "x": 58,
            "hub": "10.32.0.0/24",
            "gw": "hub2-westus3-vpngw\nconn-er-path-hub2",
            "s1": "spoke3\n10.32.4.0/22\nvm 10.32.4.10",
            "s2": "spoke4\n10.32.8.0/22\nvm 10.32.8.10",
        },
        {
            "name": "Hub3 - eastus2",
            "x": 83,
            "hub": "10.48.0.0/24",
            "gw": "hub3-eastus2-vpngw\nconn-er-path-hub3",
            "s1": "spoke5\n10.48.4.0/22\nvm 10.48.4.10",
            "s2": "spoke6\n10.48.8.0/22\nvm 10.48.8.10",
        },
    ]

    # Draw hubs
    for h in hubs:
        x = h["x"]
        label(ax, x, 86.5, h["name"], size=12, weight="bold")

        hub = Circle((x, 73), 4.0, facecolor="#dbeafe", edgecolor="#1d4ed8", linewidth=2.0)
        ax.add_patch(hub)
        label(ax, x, 73, h["hub"], size=11, weight="bold", color="#1e3a8a")

        rr(ax, x + 6, 79.2, 18.5, 6.7, "#fee2e2", "#b91c1c", lw=1.8, r=0.15)
        label(ax, x + 15.25, 82.55, h["gw"], size=10.5, weight="bold", color="#7f1d1d")

        rr(ax, x + 6, 67.5, 18.5, 6.9, "#dcfce7", "#15803d", lw=1.6, r=0.15)
        rr(ax, x + 6, 56.8, 18.5, 6.9, "#dcfce7", "#15803d", lw=1.6, r=0.15)
        label(ax, x + 15.25, 70.95, h["s1"], size=10.5, color="#14532d")
        label(ax, x + 15.25, 60.25, h["s2"], size=10.5, color="#14532d")

        conn(ax, (x + 3.7, 73), (x + 6, 82.5), lw=1.2)
        conn(ax, (x + 4.0, 73), (x + 6, 71.0), lw=1.2)
        conn(ax, (x + 3.6, 72), (x + 6, 60.3), lw=1.2)

        conn(ax, (10 + 5.4, 66), (x - 4.2, 73), lw=1.5)

    # On-prem nodes
    rr(ax, 36, 12.5, 16, 8, "#fff7ed", "#c2410c", lw=1.8, r=0.15)
    label(ax, 44, 16.4, "frr-router\n10.0.0.10\nPrimary Transit", size=11, weight="bold", color="#7c2d12")

    rr(ax, 60.5, 11.5, 18, 8, "#fff7ed", "#c2410c", lw=1.8, r=0.15)
    label(ax, 69.5, 15.4, "frr-router-backup\n10.0.0.11\nStandby Router", size=11, color="#7c2d12")

    rr(ax, 82, 11.5, 14.5, 8, "#fff7ed", "#c2410c", lw=1.8, r=0.15)
    label(ax, 89.25, 15.3, "onprem-vm\n10.0.1.10", size=11, color="#7c2d12")

    conn(ax, (52, 16.5), (60.5, 15.8), lw=1.2)
    conn(ax, (52, 15.3), (82, 15.5), lw=1.2)

    # S2S/BGP overlays
    gws = [(54.5, 82.5), (79.5, 82.5), (97.5, 82.5)]
    for gx, gy in gws:
        conn(ax, (44, 20.5), (gx, gy - 0.2), style=(0, (2, 2)), lw=1.2, color="#475569", arrow=True, rad=0.0)

    rr(ax, 41.5, 22.4, 11, 2.5, "#f3e8ff", "#c084fc", lw=1.0, r=0.08)
    label(ax, 47.0, 23.65, "IPSec + BGP", size=10, weight="bold", color="#6b21a8")

    # Legend
    rr(ax, 1.5, 87, 16.5, 10.5, "#f8fafc", "#cbd5e1", lw=1.0, r=0.2)
    label(ax, 9.75, 96.2, "Legend", size=11, weight="bold")
    rr(ax, 2.7, 93.7, 4.0, 1.8, "#fee2e2", "#b91c1c", lw=1.2, r=0.05)
    label(ax, 8.2, 94.6, "VPN Gateway", size=9, ha="left")
    rr(ax, 2.7, 91.1, 4.0, 1.8, "#dcfce7", "#15803d", lw=1.2, r=0.05)
    label(ax, 8.2, 92.0, "Spoke VNet + VM", size=9, ha="left")
    rr(ax, 2.7, 88.5, 4.0, 1.8, "#fff7ed", "#c2410c", lw=1.2, r=0.05)
    label(ax, 8.2, 89.4, "On-Prem Nodes", size=9, ha="left")

    fig.tight_layout(pad=0.3)
    fig.savefig("image/network-topology.png", dpi=220, bbox_inches="tight", facecolor="white")


if __name__ == "__main__":
    main()
