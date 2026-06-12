import re, sys

path = 'Place_8444591321.rbxlx'
data = open(path, 'r', encoding='utf-8', errors='ignore').read()

def unescape(s):
    for a, b in [('&quot;', '"'), ('&lt;', '<'), ('&gt;', '>'), ('&amp;', '&'), ('&apos;', "'"), ('&#10;', '\n'), ('&#9;', '\t')]:
        s = s.replace(a, b)
    return s

target = sys.argv[1]  # e.g. "berserker-kit-controller"
idx = data.find(f'<string name="Name">{target}</string>')
if idx < 0:
    print(f"NOT FOUND: {target}")
    sys.exit(1)

seg = data[idx:idx + 120000]
m = re.search(r'<ProtectedString name="Source">(.*?)</ProtectedString>', seg, re.S)
if not m:
    print("no source")
    sys.exit(1)
src = unescape(m.group(1))

# print interesting lines: remote names, ability calls, attributes
keys = ['Client:Get', 'SendToServer', 'FireServer', 'InvokeServer', 'CallServer',
        'useAbility', 'canUseAbility', 'GetAttribute', 'AddTag', 'GetTagged',
        ':Get(', 'getAbility', 'cooldown', 'Cooldown', 'Detonate', 'Summon',
        'Stack', 'stack', 'Place', 'Mount', 'Travel', 'Launch']
seen = set()
for ln in src.splitlines():
    st = ln.strip()
    if not st or st in seen:
        continue
    if any(k in ln for k in keys):
        seen.add(st)
        print(st[:200])
