#!/usr/bin/env python3
"""
オリジナル曲ジェネレーター（CC0 / 著作権フリー）

サンプル音源は一切使わず、コードだけで音を合成して作った曲です。
エリアごとに2曲ずつ（+タイトル曲2曲）を audio/ に書き出します。

  audio/<曲ID>_<1|2>_a.ogg  : 土台（パッド・ベース・キック）   … いつも鳴る
  audio/<曲ID>_<1|2>_b.ogg  : 盛り上げ（メロディ・ハイハット・スネア・アルペジオ）
                               … ファイト中・アピールが高いときにフェードイン

どの曲も 8小節で完全ループし、テンポは各エリアの bpm（data/areas/*.tres）と一致しています。
自分の曲（OGG）に差し替える場合も、同じファイル名・同じBPM・ぴったり整数小節にしてください。

必要なもの: python3, numpy, scipy, ffmpeg
使い方   : python3 tools/make_music.py
"""
import os, subprocess, sys, tempfile
import numpy as np
from scipy.signal import butter, lfilter, fftconvolve
from scipy.io import wavfile

SR = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "audio")

NOTE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
SCALES = {
    "major": [0, 2, 4, 5, 7, 9, 11],
    "minor": [0, 2, 3, 5, 7, 8, 10],
    "penta_major": [0, 2, 4, 7, 9],
    "mixolydian": [0, 2, 4, 5, 7, 9, 10],
}
# 16分音符単位のリズム（1小節=16）。(開始, 長さ)
RHY = {
    "flow":   [(0, 2), (2, 2), (4, 4), (8, 2), (10, 2), (12, 4)],
    "sync":   [(0, 3), (3, 3), (6, 2), (8, 4), (12, 2), (14, 2)],
    "sparse": [(0, 6), (8, 8)],
    "hop":    [(0, 1), (2, 1), (4, 1), (6, 2), (8, 1), (10, 1), (12, 2), (14, 1)],
    "drive":  [(i * 2, 2) for i in range(8)],
    "long":   [(0, 8), (8, 4), (12, 4)],
    "bell":   [(0, 4), (4, 2), (6, 2), (8, 4), (12, 4)],
}


def note_pc(name):
    pc = NOTE[name[0]]
    if len(name) > 1 and name[1] == "#":
        pc += 1
    elif len(name) > 1 and name[1] == "b":
        pc -= 1
    return pc % 12


def parse_chord(sym, octave):
    root = NOTE[sym[0]]
    i = 1
    if i < len(sym) and sym[i] in "#b":
        root += 1 if sym[i] == "#" else -1
        i += 1
    q = sym[i:]
    third = 3 if (q.startswith("m") and not q.startswith("maj")) else 4
    tones = [0, third, 7]
    if q in ("7", "m7"):
        tones.append(10)
    base = 12 * (octave + 1) + root
    return base, tones


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12.0)


# ---------------- 音色 ----------------

def tt(n):
    return np.arange(n) / SR


def tri(f, n):
    p = (f * tt(n)) % 1.0
    return 2 * np.abs(2 * p - 1) - 1


def sine(f, n):
    return np.sin(2 * np.pi * f * tt(n))


def pulse(f, n, w=0.3):
    return np.where((f * tt(n)) % 1.0 < w, 1.0, -1.0)


def saw(f, n):
    return 2 * ((f * tt(n)) % 1.0) - 1


def adsr(n, a, d, s, r):
    e = np.ones(n)
    na, nd, nr = int(a * SR), int(d * SR), int(r * SR)
    na = min(na, n)
    e[:na] = np.linspace(0, 1, na, endpoint=False) if na > 0 else 1
    nd = min(nd, max(n - na, 0))
    if nd > 0:
        e[na:na + nd] = np.linspace(1, s, nd)
    e[na + nd:] = s
    nr = min(nr, n)
    if nr > 0:
        e[n - nr:] *= np.linspace(1, 0, nr)
    return e


def v_pad(f, dur):
    n = int(dur * SR)
    w = tri(f * 0.997, n) + tri(f * 1.003, n) + 0.5 * sine(f, n)
    return w * adsr(n, 0.25, 0.1, 0.9, 0.5) * 0.35


def v_bass(f, dur):
    n = int(dur * SR)
    w = sine(f, n) + 0.35 * tri(f * 2, n)
    return w * adsr(n, 0.006, 0.12, 0.7, 0.06)


def v_pluck(f, dur, k=7.0):
    n = int(dur * SR)
    w = tri(f, n) + 0.3 * sine(f * 2, n)
    return w * np.exp(-tt(n) * k) * adsr(n, 0.002, 0.0, 1.0, 0.02)


def v_bell(f, dur):
    n = int(dur * SR)
    t = tt(n)
    w = sine(f, n) + 0.5 * sine(f * 2.0, n) * np.exp(-t * 6) + 0.25 * sine(f * 3.01, n) * np.exp(-t * 9)
    return w * np.exp(-t * 3.5) * adsr(n, 0.002, 0, 1, 0.03)


def v_lead(f, dur, kind):
    n = int(dur * SR)
    t = tt(n)
    vib = 1 + 0.004 * np.sin(2 * np.pi * 5.2 * t) * np.clip(t * 4 - 0.3, 0, 1)
    ph = np.cumsum(f * vib) / SR
    if kind == "saw":
        w = 2 * (ph % 1.0) - 1
    elif kind == "tri":
        w = 2 * np.abs(2 * (ph % 1.0) - 1) - 1
    else:
        w = np.where(ph % 1.0 < 0.3, 1.0, -1.0)
    return w * adsr(n, 0.01, 0.1, 0.65, 0.07)


def v_kick(soft=1.0):
    n = int(0.28 * SR)
    t = tt(n)
    f = 45 + 120 * np.exp(-t * 28)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 12) * soft


def v_snare(rng):
    n = int(0.22 * SR)
    t = tt(n)
    noise = rng.standard_normal(n) * np.exp(-t * 22)
    return noise * 0.7 + np.sin(2 * np.pi * 190 * t) * np.exp(-t * 28) * 0.5


def v_hat(rng, open_=False):
    n = int((0.16 if open_ else 0.05) * SR)
    t = tt(n)
    return rng.standard_normal(n) * np.exp(-t * (18 if open_ else 70))


def lp(x, fc, order=2):
    b, a = butter(order, fc / (SR / 2))
    return lfilter(b, a, x)


def hp(x, fc, order=2):
    b, a = butter(order, fc / (SR / 2), btype="high")
    return lfilter(b, a, x)


def put(buf, t, wave):
    i = int(round(t * SR))
    if i >= len(buf):
        return
    e = min(len(buf), i + len(wave))
    buf[i:e] += wave[: e - i]


# ---------------- 作曲 ----------------

def make_melody(rng, spec):
    lo, hi = spec["lead_range"]
    kr = note_pc(spec["key"])
    sc = SCALES[spec["scale"]]
    scale_notes = [m for m in range(lo, hi + 1) if (m - kr) % 12 in sc]
    r = spec["rhythms"]
    names = [r[0], r[0], r[-1], r[-1], r[0], r[0], r[len(r) // 2], r[0]]
    notes = []
    prev = None
    for b in range(8):
        chord = spec["chords"][b]
        base, tones = parse_chord(chord, 0)
        pcs = {(base + t) % 12 for t in tones}
        pat = RHY[names[b]]
        for k, (st, ln) in enumerate(pat):
            last = b == 7 and k == len(pat) - 1
            strong = st % 4 == 0
            cands = [m for m in range(lo, hi + 1) if m % 12 in pcs]
            if last:
                root_pc = kr
                rc = [m for m in range(lo, hi + 1) if m % 12 == root_pc]
                p = min(rc, key=lambda m: abs(m - (prev or (lo + hi) // 2)))
                ln = 16 - st
            elif prev is None:
                p = min(cands, key=lambda m: abs(m - (lo + hi) // 2))
            elif strong and rng.random() < 0.75:
                near = sorted(cands, key=lambda m: abs(m - prev))[:3]
                p = near[rng.integers(len(near))]
            else:
                idx = min(range(len(scale_notes)), key=lambda i: abs(scale_notes[i] - prev))
                idx = int(np.clip(idx + rng.choice([-2, -1, -1, 1, 1, 2]), 0, len(scale_notes) - 1))
                p = scale_notes[idx]
            prev = p
            notes.append((b, st, ln, p))
    return notes


def bass_events(chord):
    base, tones = parse_chord(chord, 2)
    r, f5 = base, base + 7
    return {
        "root": [(0, 8, r), (8, 8, r)],
        "pump": [(k * 2, 2, r if k % 2 == 0 else r + 12) for k in range(8)],
        "walk": [(0, 4, r), (4, 4, f5), (8, 4, r + 12), (12, 4, f5)],
        "long": [(0, 16, r)],
        "hop": [(0, 4, r), (6, 2, f5), (8, 4, r), (12, 2, r + 12), (14, 2, f5)],
    }


DRUM = {
    "basic":  dict(kick=[0, 8], snare=[4, 12]),
    "four":   dict(kick=[0, 4, 8, 12], snare=[4, 12]),
    "sparse": dict(kick=[0, 10], snare=[12]),
    "hop":    dict(kick=[0, 6, 8], snare=[4, 12]),
}


def render(spec, seed):
    rng = np.random.default_rng(seed)
    bpm = spec["bpm"]
    beat = 60.0 / bpm
    s16 = beat / 4
    bar = 4 * beat
    N = int(round(8 * bar * SR))
    total = 2 * N + 3 * SR
    bufs = {k: np.zeros(total) for k in ["pad", "bass", "kick", "snare", "hat", "lead", "arp"]}
    melody = make_melody(rng, spec)
    dr = DRUM[spec["drums"]]
    kick_w = v_kick(spec.get("kick_gain", 1.0))
    snare_w = v_snare(rng)
    hat_c, hat_o = v_hat(rng), v_hat(rng, True)
    arp_k = spec.get("arp_decay", 8.0)

    for rep in range(2):
        t0 = rep * 8 * bar
        for b in range(8):
            tb = t0 + b * bar
            chord = spec["chords"][b]
            # パッド
            if spec.get("pad_long", False) and b % 2 == 1:
                pass
            else:
                base, tones = parse_chord(chord, 3)
                plen = bar * (2 if spec.get("pad_long", False) else 1)
                for t in tones:
                    put(bufs["pad"], tb, v_pad(hz(base + t), plen))
            # ベース
            for st, ln, m in bass_events(chord)[spec["bass"]]:
                put(bufs["bass"], tb + st * s16, v_bass(hz(m), ln * s16 * 0.92))
            # ドラム
            for st in dr["kick"]:
                put(bufs["kick"], tb + st * s16, kick_w)
            for st in dr["snare"]:
                put(bufs["snare"], tb + st * s16, snare_w)
            step = spec["hat"]
            for st in range(0, 16, step):
                off = (st % 4) != 0
                w = (hat_o if (spec.get("open_hat") and st % 8 == 2 and False) else hat_c)
                put(bufs["hat"], tb + st * s16, w * (1.0 if off else 0.55))
            # アルペジオ
            if spec.get("arp"):
                base, tones = parse_chord(chord, 4)
                cts = [base + t for t in tones]
                seq = [cts[0], cts[1], cts[2], cts[0] + 12, cts[2], cts[1]]
                astep = spec["arp"]
                for i, st in enumerate(range(0, 16, astep)):
                    put(bufs["arp"], tb + st * s16, v_pluck(hz(seq[i % len(seq)]), astep * s16 * 0.95, arp_k))
        # メロディ
        for (b, st, ln, p) in melody:
            tb = t0 + b * bar + st * s16
            dur = ln * s16 * spec.get("gate", 0.95)
            f = hz(p)
            if spec["lead"] == "bell":
                w = v_bell(f, max(dur, 0.4))
            elif spec["lead"] == "pluck":
                w = v_pluck(f, max(dur, 0.2), 5.0)
            else:
                w = v_lead(f, dur, spec["lead"])
            put(bufs["lead"], tb, w)

    # フィルタ・エコー・リバーブ（ループの継ぎ目が自然につながるよう2周ぶん作って後ろ半分を使う）
    g = {"pad": 0.10, "bass": 0.34, "kick": 0.55, "snare": 0.26, "hat": 0.10, "lead": 0.20, "arp": 0.13}
    g.update(spec.get("gain", {}))
    pad = lp(bufs["pad"], 1800)
    bass = lp(bufs["bass"], 450)
    kick = bufs["kick"]
    snare = lp(hp(bufs["snare"], 250), 6000)
    hat = hp(bufs["hat"], 6500)
    lead = lp(bufs["lead"], spec.get("lead_lp", 4200))
    arp = lp(bufs["arp"], 5000)
    if spec.get("echo"):
        d = int(beat * 0.75 * SR)
        e = lead.copy()
        for k in range(1, 4):
            e[k * d:] += lead[: total - k * d] * (0.45 ** k)
        lead = e
    ir_n = int(0.9 * SR)
    ir = rng.standard_normal(ir_n) * np.exp(-tt(ir_n) * 4.5)
    ir /= np.sqrt((ir ** 2).sum())
    wet_amt = spec.get("reverb", 0.18)

    def rev(x):
        return x + wet_amt * fftconvolve(x, ir)[:total]

    A = rev(pad * g["pad"]) + bass * g["bass"] + kick * g["kick"]
    B = rev(lead * g["lead"] + arp * g["arp"]) + snare * g["snare"] + hat * g["hat"]
    A, B = A[N:2 * N], B[N:2 * N]
    peak = np.max(np.abs(A + B))
    k = 0.8 / max(peak, 1e-6)
    return A * k, B * k


def write_ogg(x, path):
    x = np.tanh(x * 1.1) / np.tanh(1.1)
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with tempfile.TemporaryDirectory() as d:
        w = os.path.join(d, "t.wav")
        wavfile.write(w, SR, pcm)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", w, "-c:a", "libvorbis",
                        "-q:a", "3", "-ac", "1", path], check=True)


# ---------------- 曲リスト ----------------
def S(**kw):
    return kw

SONGS = {
    "title": [
        S(bpm=110, key="C", scale="major", chords="C G Am F C G F G".split(), bass="root", drums="basic", hat=2,
          lead="saw", lead_range=(67, 86), rhythms=["flow", "sync"], arp=2, lead_lp=3200),
        S(bpm=110, key="F", scale="major", chords="F C G Am F C G C".split(), bass="walk", drums="basic", hat=2,
          lead="pluck", lead_range=(69, 88), rhythms=["bell", "flow"], arp=2),
    ],
    "harbor": [
        S(bpm=120, key="D", scale="major", chords="D A Bm G D A G A".split(), bass="root", drums="basic", hat=2,
          lead="saw", lead_range=(66, 85), rhythms=["flow", "sync"], arp=2, lead_lp=3200),
        S(bpm=120, key="D", scale="major", chords="D Bm G A D Bm Em A".split(), bass="pump", drums="four", hat=2,
          lead="pulse", lead_range=(66, 85), rhythms=["sync", "drive"], arp=4),
    ],
    "upstream": [
        S(bpm=132, key="E", scale="penta_major", chords="E B C#m A E B A B".split(), bass="walk", drums="basic", hat=2,
          lead="pluck", lead_range=(68, 90), rhythms=["flow", "drive"], arp=2, arp_decay=9.0),
        S(bpm=132, key="E", scale="penta_major", chords="E C#m A B E C#m A B".split(), bass="pump", drums="four", hat=2,
          lead="bell", lead_range=(68, 92), rhythms=["bell", "flow"], arp=2),
    ],
    "midstream": [
        S(bpm=124, key="F", scale="major", chords="F C Dm Bb F C Bb C".split(), bass="walk", drums="basic", hat=2,
          lead="tri", lead_range=(65, 84), rhythms=["flow", "long"], arp=0, reverb=0.22),
        S(bpm=124, key="F", scale="major", chords="F Dm Bb C F Am Bb C".split(), bass="root", drums="basic", hat=2,
          lead="saw", lead_range=(65, 84), rhythms=["sync", "flow"], arp=4, lead_lp=2800),
    ],
    "downstream": [
        S(bpm=100, key="A", scale="minor", chords="Am F C G Am Dm E Am".split(), bass="long", drums="basic", hat=4,
          lead="saw", lead_range=(57, 76), rhythms=["long", "sparse"], pad_long=True, lead_lp=2200, reverb=0.25,
          gain={"pad": 0.13}),
        S(bpm=100, key="A", scale="minor", chords="Am G F E Am F G Am".split(), bass="root", drums="sparse", hat=4,
          lead="tri", lead_range=(57, 76), rhythms=["sparse", "long"], pad_long=True, lead_lp=2200, reverb=0.25),
    ],
    "estuary": [
        S(bpm=115, key="G", scale="mixolydian", chords="G F C G G F C D".split(), bass="walk", drums="basic", hat=2,
          lead="bell", lead_range=(67, 88), rhythms=["bell", "flow"], arp=2, echo=True, reverb=0.28),
        S(bpm=115, key="G", scale="mixolydian", chords="G Bm C G G Bm F D".split(), bass="root", drums="hop", hat=2,
          lead="pluck", lead_range=(67, 88), rhythms=["sync", "bell"], arp=4, echo=True, reverb=0.28),
    ],
    "stream": [
        S(bpm=148, key="B", scale="minor", chords="Bm G D A Bm G A Bm".split(), bass="pump", drums="four", hat=1,
          lead="pulse", lead_range=(66, 88), rhythms=["drive", "flow"], arp=1, arp_decay=12.0, gain={"hat": 0.07}),
        S(bpm=148, key="B", scale="minor", chords="Bm A G A Bm G D A".split(), bass="pump", drums="four", hat=2,
          lead="saw", lead_range=(66, 88), rhythms=["sync", "drive"], arp=2, lead_lp=3600),
    ],
    "swamp": [
        S(bpm=92, key="E", scale="minor", chords="Em C Am B7 Em C D Em".split(), bass="long", drums="sparse", hat=4,
          lead="tri", lead_range=(52, 72), rhythms=["sparse", "long"], pad_long=True, lead_lp=1800, reverb=0.32,
          gain={"pad": 0.14, "hat": 0.06}),
        S(bpm=92, key="E", scale="minor", chords="Em Bm C D Em C B7 Em".split(), bass="hop", drums="sparse", hat=4,
          lead="bell", lead_range=(55, 76), rhythms=["sparse", "bell"], pad_long=True, reverb=0.32),
    ],
    "pond": [
        S(bpm=100, key="C", scale="major", chords="C Am F G C Em F G".split(), bass="root", drums="basic", hat=4,
          lead="bell", lead_range=(72, 91), rhythms=["bell", "flow"], arp=2, arp_decay=10.0, reverb=0.26,
          gain={"snare": 0.14, "kick": 0.4}),
        S(bpm=100, key="C", scale="major", chords="C F Am G C F G C".split(), bass="walk", drums="basic", hat=4,
          lead="pluck", lead_range=(72, 91), rhythms=["flow", "bell"], arp=4, reverb=0.26,
          gain={"snare": 0.14, "kick": 0.4}),
    ],
    "lake": [
        S(bpm=112, key="A", scale="penta_major", chords="A E F#m D A E D E".split(), bass="long", drums="basic", hat=2,
          lead="saw", lead_range=(69, 90), rhythms=["long", "flow"], arp=2, pad_long=True, echo=True, reverb=0.3,
          lead_lp=2800),
        S(bpm=112, key="A", scale="penta_major", chords="A F#m D E A E D A".split(), bass="walk", drums="basic", hat=2,
          lead="bell", lead_range=(69, 92), rhythms=["bell", "long"], arp=4, echo=True, reverb=0.3),
    ],
    "paddy": [
        S(bpm=96, key="C", scale="penta_major", chords="C F C G C F G C".split(), bass="hop", drums="hop", hat=4,
          lead="pluck", lead_range=(67, 88), rhythms=["hop", "flow"], gate=0.5, arp=0),
        S(bpm=96, key="C", scale="penta_major", chords="C G F G C Am F G".split(), bass="pump", drums="basic", hat=2,
          lead="bell", lead_range=(67, 88), rhythms=["hop", "sync"], gate=0.6, arp=4),
    ],
}


def main():
    os.makedirs(OUT, exist_ok=True)
    only = set(sys.argv[1:])
    for sid, variants in SONGS.items():
        if only and sid not in only:
            continue
        for v, spec in enumerate(variants, start=1):
            seed = (sum(map(ord, sid)) * 31 + v * 7919) & 0xFFFF
            A, B = render(spec, seed)
            write_ogg(A, os.path.join(OUT, f"{sid}_{v}_a.ogg"))
            write_ogg(B, os.path.join(OUT, f"{sid}_{v}_b.ogg"))
            print("ok", sid, v, f"{len(A) / SR:.2f}s")


if __name__ == "__main__":
    main()
