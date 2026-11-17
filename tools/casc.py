#!/usr/bin/env python3
"""Minimal read-only reader for a local World of Warcraft install (CASC storage).

Only reads; never writes inside the game folder.

    python3 tools/casc.py <fileDataID>=<output path> [<fileDataID>=<output path> ...]

.blp textures are converted to .png when the output path ends in .png.
"""
import glob
import io
import os
import struct
import sys
import zlib
from bisect import bisect_right
from itertools import accumulate

WOW = '/Applications/World of Warcraft'
LOCALE_ENUS = 0x2


class Encrypted(Exception):
    pass


def blte(buf):
    if buf[:4] != b'BLTE':
        raise ValueError('not a BLTE block')
    hsize = struct.unpack('>I', buf[4:8])[0]
    if hsize == 0:
        return _chunk(buf[8:])
    count = int.from_bytes(buf[9:12], 'big')
    sizes, pos = [], 12
    for _ in range(count):
        sizes.append(struct.unpack('>I', buf[pos:pos + 4])[0])
        pos += 24
    out, pos = [], hsize
    for csize in sizes:
        out.append(_chunk(buf[pos:pos + csize]))
        pos += csize
    return b''.join(out)


def _chunk(c):
    mode = c[:1]
    if mode == b'N':
        return c[1:]
    if mode == b'Z':
        return zlib.decompress(c[1:])
    if mode == b'F':
        return blte(c[1:])
    if mode == b'E':
        raise Encrypted()
    raise ValueError('unknown BLTE mode %r' % mode)


class Casc:
    def __init__(self, root=WOW):
        self.root = root
        self.data_dir = os.path.join(root, 'Data', 'data')
        self.build = self._build_info()
        self.cfg = self._config(self.build['Build Key'])
        self._load_idx()
        enc_ekey = bytes.fromhex(self.cfg['encoding'].split()[1])
        self._load_encoding(self.read_ekey(enc_ekey))
        self.files = {}

    # ---- config ----
    def _build_info(self):
        with open(os.path.join(self.root, '.build.info')) as f:
            lines = [l.rstrip('\n') for l in f if l.strip()]
        names = [h.split('!')[0] for h in lines[0].split('|')]
        rows = [dict(zip(names, l.split('|'))) for l in lines[1:]]
        active = [r for r in rows if r.get('Active') == '1'] or rows
        return active[0]

    def _config(self, key):
        path = os.path.join(self.root, 'Data', 'config', key[:2], key[2:4], key)
        cfg = {}
        with open(path) as f:
            for line in f:
                if ' = ' in line:
                    k, v = line.strip().split(' = ', 1)
                    cfg[k] = v
        return cfg

    # ---- local index ----
    def _load_idx(self):
        self.idx = {}
        for bucket in range(16):
            names = sorted(glob.glob(os.path.join(self.data_dir, '%02x*.idx' % bucket)))
            if not names:
                continue
            with open(names[-1], 'rb') as f:
                d = f.read()
            hsize = struct.unpack('<I', d[0:4])[0]
            key_bytes = d[14]
            pos = (8 + hsize + 0x0F) & ~0x0F
            esize = struct.unpack('<I', d[pos:pos + 4])[0]
            pos += 8
            rec = key_bytes + 9
            for i in range(pos, pos + esize, rec):
                key = d[i:i + key_bytes]
                hi = d[i + key_bytes]
                lo = struct.unpack('>I', d[i + key_bytes + 1:i + key_bytes + 5])[0]
                size = struct.unpack('<I', d[i + key_bytes + 5:i + key_bytes + 9])[0]
                self.idx.setdefault(key, ((hi << 2) | (lo >> 30), lo & 0x3FFFFFFF, size))

    def read_ekey(self, ekey):
        entry = self.idx.get(ekey[:9])
        if entry is None:
            raise KeyError('not downloaded locally')
        archive, offset, size = entry
        with open(os.path.join(self.data_dir, 'data.%03d' % archive), 'rb') as f:
            f.seek(offset + 30)
            return blte(f.read(size - 30))

    # ---- encoding (content key -> encoded key) ----
    def _load_encoding(self, d):
        if d[:2] != b'EN':
            raise ValueError('bad encoding file')
        self.hc, self.he = d[3], d[4]
        cpage_kb, _epage_kb, ccount, _ecount = struct.unpack('>HHII', d[5:17])
        espec = struct.unpack('>I', d[18:22])[0]
        pos = 22 + espec
        self.enc_first = [d[pos + i * (self.hc + 16):pos + i * (self.hc + 16) + self.hc] for i in range(ccount)]
        self.enc_pages = pos + ccount * (self.hc + 16)
        self.enc_psize = cpage_kb * 1024
        self.enc = d

    def ekey_for(self, ckey):
        p = bisect_right(self.enc_first, ckey) - 1
        if p < 0:
            raise KeyError('content key not in encoding')
        d, i = self.enc, self.enc_pages + p * self.enc_psize
        end = i + self.enc_psize
        while i < end and d[i]:
            kc = d[i]
            if d[i + 6:i + 6 + self.hc] == ckey:
                return d[i + 6 + self.hc:i + 6 + self.hc + self.he]
            i += 6 + self.hc + self.he * kc
        raise KeyError('content key not in encoding')

    def read_ckey(self, ckey):
        return self.read_ekey(self.ekey_for(ckey))

    # ---- root (fileDataID -> content key) ----
    def load_root(self, wanted=None):
        d = self.read_ckey(bytes.fromhex(self.cfg['root']))
        if d[:4] != b'TSFM':
            raise ValueError('unsupported root format %r' % d[:4])
        a, b = struct.unpack('<II', d[4:12])
        if a < 100:           # newer header: size, version, total, named
            version, pos = b, a
        else:                 # older header: total, named
            version, pos = 0, 12
        n = len(d)
        while pos < n:
            count = struct.unpack('<I', d[pos:pos + 4])[0]
            if version >= 2:
                locale, f1, f2 = struct.unpack('<III', d[pos + 4:pos + 16])
                content = f1 | f2 | (d[pos + 16] << 17)
                pos += 17
            else:
                content, locale = struct.unpack('<II', d[pos + 4:pos + 12])
                pos += 12
            deltas = struct.unpack('<%di' % count, d[pos:pos + 4 * count])
            pos += 4 * count
            keys = pos
            pos += 16 * count
            if not content & 0x10000000:
                pos += 8 * count
            enus = bool(locale & LOCALE_ENUS)
            for i, acc in enumerate(accumulate(deltas)):
                fid = acc + i
                if wanted is not None and fid not in wanted:
                    continue
                if fid not in self.files or enus:
                    self.files[fid] = d[keys + 16 * i:keys + 16 * i + 16]
        return self

    def read_file(self, fid):
        return self.read_ckey(self.files[fid])


def save(data, out):
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    if out.lower().endswith('.png') and data[:4] in (b'BLP2', b'BLP1'):
        from PIL import Image
        Image.open(io.BytesIO(data)).save(out)
    else:
        with open(out, 'wb') as f:
            f.write(data)


def main(argv):
    jobs = [(int(a.split('=', 1)[0]), a.split('=', 1)[1]) for a in argv]
    casc = Casc()
    casc.load_root({fid for fid, _ in jobs})
    for fid, out in jobs:
        try:
            data = casc.read_file(fid)
            save(data, out)
            print('ok   %-9d %8d bytes  %s' % (fid, len(data), out))
        except Encrypted:
            print('FAIL %-9d encrypted' % fid)
        except KeyError as e:
            print('FAIL %-9d %s' % (fid, e.args[0] if e.args else 'not in this build'))


if __name__ == '__main__':
    main(sys.argv[1:])
