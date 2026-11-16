"""Architecture diagram for the Teleport agent demo, 1920x1080.

    python3 diagram/architecture.py

Every element is placed by hand: no layout engine, so nothing overlaps by accident.
Icons are the official AWS Architecture Icons (release 2026-07-31), read from icons/.
That folder is not in the repository. To redraw the diagram, download the icon package
from https://aws.amazon.com/architecture/icons/ and copy into icons/ the SVG files named
in this script, plus a k3s logo saved as icons/k3s.png and the Teleport mark saved as
icons/teleport.svg.
Writes architecture.svg, and architecture.png when rsvg-convert is installed
(`brew install librsvg`).
"""

import base64
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ICONS = HERE / "icons"

W, H = 1920, 1080
FONT = "Helvetica Neue, Helvetica, Arial, sans-serif"
INK = "#232F3E"
GREY = "#5F6B7A"
ORANGE = "#ED7100"
GREEN = "#7AA116"
TEAL = "#00A4A6"
PURPLE = "#8C4FFF"
RED = "#D13212"

out = []


def add(s):
    out.append(s)


def icon(name, x, y, size):
    path = ICONS / name
    mime = "image/png" if path.suffix == ".png" else "image/svg+xml"
    data = base64.b64encode(path.read_bytes()).decode()
    add(f'<image x="{x}" y="{y}" width="{size}" height="{size}" href="data:{mime};base64,{data}"/>')


def text(x, y, s, size=16, color=INK, weight="normal", anchor="start"):
    s = s.replace("&", "&amp;").replace("<", "&lt;")
    add(
        f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" fill="{color}" '
        f'font-weight="{weight}" text-anchor="{anchor}">{s}</text>'
    )


def group(x, y, w, h, color, label, icon_name=None, fill="none", dash=None, label_color=None):
    """An AWS-style group: border, corner icon, label next to it."""
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" stroke="{color}" stroke-width="2"{d}/>')
    tx = x + 14
    if icon_name:
        icon(icon_name, x, y, 36)
        tx = x + 48
    text(tx, y + 24, label, 16, label_color or color)


def card(x, y, w, h, stroke=INK, fill="white", rx=8, width=1.5):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="{width}"/>')


def line(points, color=ORANGE, width=3, dash=None, arrow=True):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    marker = f' marker-end="url(#arrow-{color[1:]})"' if arrow else ""
    pts = " ".join(f"{x},{y}" for x, y in points)
    add(
        f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="{width}" '
        f'stroke-linejoin="round"{d}{marker}/>'
    )


def marker(color):
    return (
        f'<marker id="arrow-{color[1:]}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="4.5" '
        f'markerHeight="4.5" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>'
    )


add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
add(f"<defs>{marker(ORANGE)}{marker(GREY)}{marker(INK)}</defs>")
add(f'<rect width="{W}" height="{H}" fill="white"/>')

# ---- Title and legend -----------------------------------------------------------------------
text(40, 78, "An on-call agent with its own identity", 34, INK, "bold")
text(40, 116, "Claude Code reaches a database and a Kubernetes cluster", 20, GREY)
text(40, 142, "through Teleport, as the bot claude-oncall.", 20, GREY)

line([(40, 825), (110, 825)], ORANGE)
text(126, 831, "What the agent can reach, always through Teleport", 17, INK)
line([(40, 865), (110, 865)], GREY, 2, "7 5")
text(126, 871, "Certificates issued to the bot, renewed every 5 minutes", 17, INK)
text(40, 930, "The agent holds no password, no API key and no long-lived", 17, GREY)
text(40, 954, "credential: only certificates that expire in 15 minutes.", 17, GREY)

# ---- Laptop ---------------------------------------------------------------------------------
add(f'<rect x="40" y="270" width="460" height="450" rx="10" fill="#F7F8FA" stroke="{GREY}" stroke-width="2"/>')
text(60, 304, "Laptop", 18, GREY, "bold")

icon("Res_Client_48_Light.svg", 66, 466, 68)
text(100, 556, "Claude Code", 17, INK, "bold", "middle")

card(230, 330, 250, 76)
text(355, 362, "tsh mcp db", 18, INK, "bold", "middle")
text(355, 387, "MCP server for PostgreSQL", 15, GREY, anchor="middle")

card(230, 455, 250, 96, GREY, "#EEF1F5")
text(355, 486, "tbot", 18, INK, "bold", "middle")
text(355, 510, "bot claude-oncall", 15, GREY, anchor="middle")
text(355, 532, "15-minute certificates", 15, GREY, anchor="middle")

card(230, 600, 250, 76)
text(355, 632, "kubernetes-mcp-server", 18, INK, "bold", "middle")
text(355, 657, "MCP server for Kubernetes", 15, GREY, anchor="middle")

# Claude Code talks to its two MCP servers over stdio.
line([(134, 482), (180, 482), (180, 368), (224, 368)], INK, 2)
line([(134, 518), (180, 518), (180, 638), (224, 638)], INK, 2)
text(170, 425, "stdio", 14, GREY, anchor="end")
text(170, 585, "stdio", 14, GREY, anchor="end")

# tbot hands each MCP server its short-lived credential.
line([(300, 455), (300, 412)], GREY, 2, "7 5")
text(312, 438, "identity file", 14, GREY)
line([(300, 551), (300, 594)], GREY, 2, "7 5")
text(312, 579, "kubeconfig", 14, GREY)

# ---- AWS ------------------------------------------------------------------------------------
group(700, 40, 1190, 1000, INK, "AWS Cloud", "AWS-Cloud-logo_32.svg")
group(725, 100, 1140, 700, TEAL, "Region eu-west-1", "Region_32.svg", dash="8 6")
group(750, 160, 1090, 615, PURPLE, "VPC 10.42.0.0/16", "Virtual-private-cloud-VPC_32.svg")
group(775, 220, 690, 530, GREEN, "Public subnet: inbound 443 only", "Public-subnet_32.svg", fill="#F2F6E8")
group(1490, 220, 325, 530, TEAL, "Private subnet: no internet route", "Private-subnet_32.svg", fill="#E6F6F7")

# Elastic IP: the single way in.
icon("Res_Amazon-EC2_Elastic-IP-Address_48.svg", 822, 403, 64)
text(854, 492, "Elastic IP", 16, INK, "bold", "middle")
text(854, 514, "teleport.julien.org", 14, GREY, anchor="middle")
text(854, 534, "Let's Encrypt TLS", 14, GREY, anchor="middle")

# The EC2 instance and what runs on it.
group(950, 290, 490, 430, ORANGE, "EC2 instance, no SSH port", "EC2-instance-contents_32.svg", fill="white")

card(975, 348, 440, 150, INK, "#F7F8FA")
icon("teleport.svg", 993, 359, 30)
text(1032, 381, "Teleport Community Edition", 18, INK, "bold")
for i, (a, b) in enumerate([("Auth and", "Proxy"), ("Kubernetes", "Service"), ("Database", "Service")]):
    cx = 995 + i * 136
    card(cx, 400, 128, 76, ORANGE, "white", 6, 2)
    text(cx + 64, 432, a, 15, INK, anchor="middle")
    text(cx + 64, 453, b, 15, INK, anchor="middle")

card(975, 590, 440, 108, INK, "#F7F8FA")
icon("k3s.png", 993, 606, 44)
text(1050, 624, "k3s, namespace shop", 18, INK, "bold")
card(1050, 646, 120, 34, GREEN, "white", 17, 2)
text(1110, 669, "web: running", 14, INK, anchor="middle")
card(1182, 646, 215, 34, RED, "white", 17, 2)
text(1289, 669, "orders-api: CrashLoopBackOff", 14, INK, anchor="middle")

# Database.
icon("Arch_Amazon-RDS_48.svg", 1700, 398, 80)
text(1740, 504, "RDS PostgreSQL", 16, INK, "bold", "middle")
text(1740, 526, "database shop", 14, GREY, anchor="middle")
text(1740, 546, "IAM authentication", 14, GREY, anchor="middle")

# Account services, outside the VPC.
services = [
    ("Arch_AWS-CloudFormation_48.svg", "CloudFormation", "one stack creates and", "deletes everything"),
    ("Arch_AWS-Identity-and-Access-Management_48.svg", "IAM role", "lets Teleport sign in", "to RDS as oncall_ro"),
    ("Arch_AWS-Systems-Manager_48.svg", "Systems Manager", "host administration", "without SSH"),
    ("Arch_AWS-Secrets-Manager_48.svg", "Secrets Manager", "master password,", "used once to seed"),
    ("Arch_AWS-Budgets_48.svg", "Budgets", "cost alert", ""),
]
for i, (name, title, l1, l2) in enumerate(services):
    cx = 725 + 114 + i * 228
    icon(name, cx - 28, 853, 56)
    text(cx, 937, title, 16, INK, "bold", "middle")
    text(cx, 959, l1, 14, GREY, anchor="middle")
    text(cx, 979, l2, 14, GREY, anchor="middle")

# ---- Paths ----------------------------------------------------------------------------------
# Laptop to the Elastic IP. Three lines, same order top to bottom at both ends, so none cross.
line([(480, 368), (660, 368), (660, 420), (816, 420)], ORANGE)
text(504, 356, "TLS 443, bot certificate", 14, ORANGE)
line([(480, 503), (580, 503), (580, 435), (816, 435)], GREY, 2, "7 5")
text(504, 492, "join, renew", 14, GREY)
line([(480, 638), (620, 638), (620, 450), (816, 450)], ORANGE)
text(504, 662, "TLS 443, bot certificate", 14, ORANGE)

# Elastic IP to Teleport, then Teleport to each resource.
line([(888, 438), (989, 438)], ORANGE)
line([(1195, 476), (1195, 584)], ORANGE)
text(1210, 528, "as Kubernetes group", 14, ORANGE)
text(1210, 548, "oncall-readers", 14, ORANGE)
line([(1395, 438), (1694, 438)], ORANGE)
text(1597, 426, "IAM token, as oncall_ro", 14, ORANGE, anchor="middle")
text(1597, 460, "port 5432", 14, ORANGE, anchor="middle")

add("</svg>")

svg = HERE / "architecture.svg"
svg.write_text("\n".join(out))
print(f"wrote {svg.name}")
if shutil.which("rsvg-convert"):
    png = HERE / "architecture.png"
    subprocess.run(["rsvg-convert", "-w", str(W * 2), "-o", str(png), str(svg)], check=True)
    print(f"wrote {png.name} ({W * 2}x{H * 2})")
else:
    print("rsvg-convert not found: PNG not written")
