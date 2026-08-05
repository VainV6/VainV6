import re, sys

path = sys.argv[1] if len(sys.argv) > 1 else 'games/6872274481.lua'
src = open(path, 'r', encoding='utf-8', errors='ignore').read()
s = src
# strip long comments/strings, line comments, quoted strings
s = re.sub(r'--\[\[.*?\]\]', ' ', s, flags=re.S)
s = re.sub(r'--[^\n]*', ' ', s)
s = re.sub(r'"(?:\\.|[^"\\])*"', '""', s)
s = re.sub(r"'(?:\\.|[^'\\])*'", "''", s)
s = re.sub(r'\[\[.*?\]\]', ' ', s, flags=re.S)

def wc(p):
    return len(re.findall(r'\b' + p + r'\b', s))

print("paren  () balance:", s.count('(') - s.count(')'))
print("brace  {} balance:", s.count('{') - s.count('}'))
print("bracket [] balance:", s.count('[') - s.count(']'))
print("repeat:", wc('repeat'), " until:", wc('until'), "(should be equal)")
print("function:", wc('function'), " end:", wc('end'))
