# Filelists for training: Matcha gets "wav|phonemes", Vocos gets wav paths. 150 lines held out for checks.
import os, random, sys
voice = sys.argv[1]; root = os.path.dirname(os.path.abspath(__file__))
rows = [l.rstrip("\n").split("|") for l in open(f"{root}/{voice}/meta.txt")]
rows = [(f"{root}/{voice}/wavs/{k}.wav", ph.strip()) for k, ph, _ in rows if ph.strip()]
random.seed(1); random.shuffle(rows); val, train = rows[:150], rows[150:]
os.makedirs(f"{root}/mouthy", exist_ok=True)
for name, part in [("train", train), ("val", val)]:
    open(f"{root}/mouthy/{name}.txt", "w").write("".join(f"{w}|{p}\n" for w, p in part))
    open(f"{root}/mouthy/vocos-{name}.txt", "w").write("".join(f"{w}\n" for w, _ in part))
print(len(train), "train,", len(val), "val")
