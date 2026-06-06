"""
Generates changed_modules.txt by comparing current games files against originals.
Run this after any sync operation to update the module highlight list.
"""

import re
import os

def extract_modules(content):
    """Extract {normalized_name: original_name} from a lua file using run() block analysis."""
    modules = {}
    for m in re.finditer(r'''(?:vain|vape)(?:\.Categories\.\w+|\.Legit|\.Blatant):\s*CreateModule\s*\(\s*\{[^}]*?Name\s*=\s*['"]([^'"]+)['"]''', content, re.DOTALL):
        name = m.group(1)
        norm = re.sub(r'[\s\-_]', '', name).lower()
        modules[norm] = name
    return modules

def extract_module_blocks(content):
    """Extract {normalized_name: block_content} using paren-depth tracking on run() blocks."""
    blocks = {}
    lines = content.split('\n')

    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r'^run\(function\(\)', line.strip()):
            depth = 0
            start = i
            block_lines = []
            while i < len(lines):
                l = lines[i]
                for ch in l:
                    if ch == '(':
                        depth += 1
                    elif ch == ')':
                        depth -= 1
                block_lines.append(l)
                i += 1
                if depth == 0:
                    break
            block = '\n'.join(block_lines)
            # Find module name in this block
            m = re.search(r'''Name\s*=\s*['"]([^'"]+)['"]''', block)
            if m:
                name = m.group(1)
                norm = re.sub(r'[\s\-_]', '', name).lower()
                blocks[norm] = (name, block)
        else:
            i += 1

    return blocks

def generate_changed():
    base = os.path.dirname(os.path.abspath(__file__))
    changed = {}  # name -> tag

    # ── 6872274481.lua: compare current vs .bak ──────────────────────────────
    games_path = os.path.join(base, 'games', '6872274481.lua')
    bak_path = games_path + '.bak'

    if os.path.exists(bak_path):
        print('Comparing 6872274481.lua against .bak ...')
        with open(games_path, encoding='utf-8') as f:
            current_content = f.read()
        with open(bak_path, encoding='utf-8') as f:
            bak_content = f.read()

        current_blocks = extract_module_blocks(current_content)
        bak_blocks = extract_module_blocks(bak_content)

        for norm, (name, block) in current_blocks.items():
            if norm not in bak_blocks:
                changed[name] = 'NEW'
                print(f'  NEW: {name}')
            elif block.strip() != bak_blocks[norm][1].strip():
                changed[name] = 'UPD'
                print(f'  UPD: {name}')
    else:
        print('No .bak found for 6872274481.lua, skipping.')

    # ── 606849621.lua: compare current vs download ────────────────────────────
    games2_path = os.path.join(base, 'games', '606849621.lua')
    dl2_path = r'C:\Users\timov\Downloads\606849621.lua'

    if os.path.exists(dl2_path) and os.path.exists(games2_path):
        print('Comparing 606849621.lua against download ...')
        with open(games2_path, encoding='utf-8') as f:
            current2 = f.read()
        with open(dl2_path, encoding='utf-8') as f:
            dl2 = f.read()

        current2_blocks = extract_module_blocks(current2)
        dl2_blocks = extract_module_blocks(dl2)

        for norm, (name, block) in current2_blocks.items():
            if norm not in dl2_blocks:
                changed[name] = 'NEW'
                print(f'  NEW: {name}')
            elif block.strip() != dl2_blocks[norm][1].strip():
                changed[name] = 'UPD'
                print(f'  UPD: {name}')
    else:
        print('Skipping 606849621.lua comparison (missing files).')

    # ── Write output ──────────────────────────────────────────────────────────
    out_path = os.path.join(base, 'changed_modules.txt')
    lines = []
    for name, tag in sorted(changed.items(), key=lambda x: (x[1], x[0])):
        lines.append(f'{tag}:{name}')

    with open(out_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + ('\n' if lines else ''))

    print(f'\nWrote {len(lines)} entries to {out_path}')
    for l in lines:
        print(f'  {l}')

if __name__ == '__main__':
    generate_changed()
