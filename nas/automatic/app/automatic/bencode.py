"""Just enough bencode to read a .torrent: its file list and its info hash.

The info hash is the SHA-1 of the info dictionary's ORIGINAL bytes, so the
decoder records where that dictionary starts and ends instead of re-encoding it.
Re-encoding is only byte-identical when the source was canonical, and a hash that
is off by one byte names a different torrent.
"""

import hashlib


class BencodeError(ValueError):
    pass


def _decode(data, i, spans, depth):
    if depth > 64:
        raise BencodeError("nested too deeply")
    if i >= len(data):
        raise BencodeError("truncated")
    c = data[i:i + 1]
    if c == b"i":
        j = data.find(b"e", i)
        if j < 0:
            raise BencodeError("unterminated integer")
        try:
            return int(data[i + 1:j]), j + 1
        except ValueError:
            raise BencodeError("bad integer") from None
    if c == b"l":
        i += 1
        out = []
        while data[i:i + 1] != b"e":
            v, i = _decode(data, i, spans, depth + 1)
            out.append(v)
        return out, i + 1
    if c == b"d":
        i += 1
        out = {}
        while data[i:i + 1] != b"e":
            k, i = _decode(data, i, spans, depth + 1)
            if not isinstance(k, bytes):
                raise BencodeError("dictionary key is not a string")
            if k in out:
                # libtorrent reads the first copy of a key, Python keeps the last: a
                # torrent with both would show this gate one file list and the client
                # another. No honest encoder writes a key twice.
                raise BencodeError("a dictionary repeats a key")
            start = i
            v, i = _decode(data, i, spans, depth + 1)
            if k == b"info" and depth == 0:
                spans["info"] = (start, i)
            out[k] = v
        return out, i + 1
    if c.isdigit():
        j = data.find(b":", i)
        if j < 0:
            raise BencodeError("bad string length")
        try:
            n = int(data[i:j])
        except ValueError:
            raise BencodeError("bad string length") from None
        s = j + 1
        if s + n > len(data):
            raise BencodeError("truncated string")
        return data[s:s + n], s + n
    raise BencodeError(f"unexpected byte at {i}")


def decode(data):
    spans = {}
    value, end = _decode(data, 0, spans, 0)
    return value, spans


def lenient_hash(data):
    """The info hash of a .torrent the strict reader refused, when the info dictionary
    can still be found: so a refusal can be reported against the right release."""
    i = data.find(b"4:info")
    if i < 0:
        return None
    start = i + 6
    depth, j = 0, start
    try:
        # Walk the bencoded value at `start` without building it.
        stack = []
        while True:
            c = data[j:j + 1]
            if c in (b"d", b"l"):
                stack.append(c); j += 1
            elif c == b"e":
                stack.pop(); j += 1
            elif c == b"i":
                j = data.index(b"e", j) + 1
            elif c.isdigit():
                k = data.index(b":", j)
                j = k + 1 + int(data[j:k])
            else:
                return None
            if not stack:
                break
        return hashlib.sha1(data[start:j]).hexdigest()
    except (ValueError, IndexError):
        return None


def _text(b):
    return b.decode("utf-8", "replace") if isinstance(b, bytes) else str(b)


def _walk_file_tree(tree, prefix, out):
    # BitTorrent v2: {name: {name: {"": {"length": n}}}}
    for name, node in tree.items():
        if name == b"" and isinstance(node, dict):
            out.append(("/".join(prefix), int(node.get(b"length", 0))))
        elif isinstance(node, dict):
            _walk_file_tree(node, prefix + [_text(name)], out)


def torrent_info(data):
    """Return {"hash", "name", "files": [(path, size), ...]} for raw .torrent bytes.

    Anything malformed raises BencodeError, never another exception type."""
    try:
        return _torrent_info(data)
    except BencodeError:
        raise
    except (ValueError, TypeError, AttributeError, KeyError, RecursionError) as e:
        raise BencodeError(f"malformed torrent ({type(e).__name__})") from None


def _torrent_info(data):
    meta, spans = decode(data)
    if not isinstance(meta, dict) or not isinstance(meta.get(b"info"), dict) or "info" not in spans:
        raise BencodeError("no info dictionary")
    info = meta[b"info"]
    start, end = spans["info"]
    name = _text(info.get(b"name.utf-8", info.get(b"name", b"")))
    files = []
    # libtorrent's rules, not looser ones: path.utf-8 only when it is a non-empty list,
    # and a v2 "file tree" only in a v2 torrent. Anything else would let this read a
    # different list from the one qBittorrent writes.
    def _parts(f):
        p8 = f.get(b"path.utf-8")
        return p8 if isinstance(p8, list) and p8 else f.get(b"path", [])
    if isinstance(info.get(b"files"), list):
        for f in info[b"files"]:
            files.append(("/".join([name] + [_text(p) for p in _parts(f)]), int(f.get(b"length", 0))))
    elif info.get(b"meta version") == 2 and isinstance(info.get(b"file tree"), dict):
        tree = info[b"file tree"]
        only = next(iter(tree.values())) if len(tree) == 1 else None
        single = isinstance(only, dict) and b"" in only
        _walk_file_tree(tree, [] if single else [name], files)
    else:
        files.append((name, int(info.get(b"length", 0))))
    return {"hash": hashlib.sha1(data[start:end]).hexdigest(), "name": name, "files": files}
