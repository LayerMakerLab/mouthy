# Reading scripts for the voice data: public-domain books (Project Gutenberg) plus programmatic numbers, times and dates.
import re, random, urllib.request, json, os
random.seed(7)
BOOKS = [1342, 1661, 11, 84, 98, 74, 1260, 345, 2591, 5200, 64317, 174, 120, 43, 1400, 236, 55, 35, 36, 2097, 244, 1184, 158, 161, 768]
os.makedirs("books", exist_ok=True)
def book(i):
    p = f"books/{i}.txt"
    if not os.path.exists(p):
        req = urllib.request.Request(f"https://www.gutenberg.org/cache/epub/{i}/pg{i}.txt", headers={"User-Agent": "Mozilla/5.0"})
        open(p, "wb").write(urllib.request.urlopen(req, timeout=60).read())
    t = open(p, encoding="utf-8", errors="ignore").read()
    s = re.search(r"\*\*\* ?START OF.*?\*\*\*", t); e = re.search(r"\*\*\* ?END OF", t)
    return t[s.end() if s else 0: e.start() if e else len(t)]
OK = re.compile(r"^[A-Za-z0-9 ,.;:!?'\"\-]+$")
def sentences(t):
    t = t.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"').replace("—", ", ").replace("_", "")
    t = re.sub(r"\s+", " ", t)
    t = re.sub(r"\b(Mr|Mrs|Dr|St|Mme|Messrs|Capt|Col|Gen|Prof|Rev)\. ", r"\1\u00a0", t)  # no split after a title
    for s in re.split(r'(?<=[.!?])["\']?\s+(?=["\']?[A-Z])', t):
        s = s.replace("\u00a0", ". ")
        s = s.strip().strip('"').strip()
        n = len(s.split())
        if 3 <= n <= 24 and OK.match(s) and s[-1] in ".!?" and not s.isupper() and '"' not in s and "--" not in s:
            yield s
pool = {}
for i in BOOKS:
    try: pool[i] = sorted(set(sentences(book(i))))
    except Exception as ex: print("skip", i, ex)
lines = []
for i, ss in pool.items():
    q = [s for s in ss if s.endswith("?")]; x = [s for s in ss if s.endswith("!")]; d = [s for s in ss if s[-1] == "."]
    lines += random.sample(q, min(len(q), 90)) + random.sample(x, min(len(x), 40)) + random.sample(d, min(len(d), 330))
# Programmatic lines: numbers, times, dates, money, counts (text is already spelled the way it should be said).
ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()
def say(n):
    if n < 20: return ONES[n]
    if n < 100: return TENS[n // 10] + ("" if n % 10 == 0 else "-" + ONES[n % 10])
    if n < 1000: return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + say(n % 100))
    return say(n // 1000) + " thousand" + ("" if n % 1000 == 0 else " " + say(n % 1000))
MONTHS = "January February March April May June July August September October November December".split()
DAYS = "Monday Tuesday Wednesday Thursday Friday Saturday Sunday".split()
ORD = "first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth".split()
def ordinal(n): return ORD[n - 1] if n <= 20 else (TENS[n // 10] + ("th" if n % 10 == 0 else "-" + ORD[n % 10 - 1])).replace("tyth", "tieth")
def clock():
    h, m = random.randint(1, 12), random.choice([0, 5, 10, 15, 20, 30, 45, random.randint(1, 59)])
    return say(h) + (" o'clock" if m == 0 else " oh " + ONES[m] if m < 10 else " " + say(m))
for _ in range(1200):
    k = random.randrange(5)
    if k == 0: lines.append(f"It's {clock()} {random.choice(['in the morning', 'in the afternoon', 'at night', 'right now'])}.")
    elif k == 1: lines.append(f"{random.choice(DAYS)}, {random.choice(MONTHS)} {ordinal(random.randint(1, 31))}.")
    elif k == 2: lines.append(f"That comes to {say(random.randint(2, 999))} dollars and {say(random.randint(1, 99))} cents.")
    elif k == 3: lines.append(f"There {random.choice(['are', 'were'])} {say(random.randint(2, 9999))} {random.choice(['files', 'messages', 'people', 'steps', 'miles', 'tries'])} {random.choice(['left', 'in total', 'so far', 'today'])}.")
    else: lines.append(f"Is it {clock()}, or closer to {clock()}?")
random.shuffle(lines)
json.dump(lines, open("lines.json", "w"), indent=0)
print(len(pool), "books,", len(lines), "lines,", sum(len(l.split()) for l in lines), "words; samples:")
for l in lines[:8]: print("  ", l)
