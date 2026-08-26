#!/usr/bin/env python3
"""
Convert uBlock Origin's filter lists into WKContentRuleList JSON.

WKWebView cannot load a Firefox extension, but WebKit ships the same declarative
content-blocking engine Safari content blockers use. Feeding it uBO's actual lists
gets the blocking without the extension.

What carries over: network blocking (including third-party, resource-type and
domain scoping) and cosmetic `##selector` hiding. What does not: scriptlet
injection (`##+js(...)`), procedural cosmetics (`:has-text`, `:xpath`), `$redirect`,
and `$csp`. Those are uBO-engine features with no WebKit equivalent, and they are
skipped rather than mistranslated.

Usage:  ./build-blocklist.py [--out DIR] [--offline]
"""

import argparse
import json
import os
import re
import sys
import urllib.request

# uBO's own default set.
#
# "uBlock filters" is NOT one file. uBO splits it by the year a rule was added --
# filters.txt holds only the current year's, and everything it learned before that
# lives in filters-2020 through filters-2026, filters-general and quick-fixes. This
# fetched filters.txt alone for months, which meant shipping the newest slice of uBO's
# knowledge and none of the accumulated rest: the overwhelming majority of the ad hosts
# these sites use were never in the compiled lists at all.
_UBO = "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/"
SOURCES = [
    ("easylist",      "https://easylist.to/easylist/easylist.txt"),
    ("easyprivacy",   "https://easylist.to/easylist/easyprivacy.txt"),
    # Peter Lowe's ad-server list, the third of uBO's enabled-by-default sets.
    ("plowe",         "https://pgl.yoyo.org/adservers/serverlist.php"
                      "?hostformat=adblockplus&mimetype=plaintext"),
    ("ubo-filters",   _UBO + "filters.txt"),
    ("ubo-2020",      _UBO + "filters-2020.txt"),
    ("ubo-2021",      _UBO + "filters-2021.txt"),
    ("ubo-2022",      _UBO + "filters-2022.txt"),
    ("ubo-2023",      _UBO + "filters-2023.txt"),
    ("ubo-2024",      _UBO + "filters-2024.txt"),
    ("ubo-2025",      _UBO + "filters-2025.txt"),
    ("ubo-2026",      _UBO + "filters-2026.txt"),
    ("ubo-general",   _UBO + "filters-general.txt"),
    ("ubo-quickfix",  _UBO + "quick-fixes.txt"),
    ("ubo-privacy",   _UBO + "privacy.txt"),
    ("ubo-badware",   _UBO + "badware.txt"),
    ("ubo-resources", _UBO + "resource-abuse.txt"),
    ("ubo-unbreak",   _UBO + "unbreak.txt"),
]

# WebKit compiles at most this many rules per list; we split across lists instead
# of silently dropping the tail.
MAX_RULES_PER_LIST = 45_000

RESOURCE_TYPES = {
    "script": "script",
    "image": "image",
    "stylesheet": "style-sheet",
    "object": "media",
    "media": "media",
    "font": "font",
    "xmlhttprequest": "raw",
    "subdocument": "document",
    "document": "document",
    "ping": "raw",
    "websocket": "raw",
    "other": "raw",
}

# Options that mean "this rule does something WebKit cannot express". Keeping the
# rule anyway would change its meaning, so drop it.
# Options that make the whole rule untranslatable: whatever they express, WebKit
# cannot, and guessing would over-block.
UNSUPPORTED_OPTS = {
    "csp", "removeparam", "replace", "empty",
    "mp4", "inline-script", "inline-font", "genericblock", "generichide",
    "specifichide", "elemhide", "badfilter", "cname", "urltransform",
    "permissions", "header", "method", "to", "from", "denyallow", "ipaddress",
}

# Options that only DECORATE a block: the rule still says "block this", and the part
# WebKit cannot do is the extra. Dropping the whole rule threw away the block as well,
# which cost hundreds of real ones -- including the anti-adblock detector scripts,
# whose whole purpose is to run when an advert did not.
DECORATIVE_OPTS = {"important", "redirect", "redirect-rule"}


def fetch(name, url, cache_dir):
    path = os.path.join(cache_dir, name + ".txt")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "blocklist-builder/1.0"})
        with urllib.request.urlopen(req, timeout=45) as r:
            data = r.read().decode("utf-8", "replace")
        with open(path, "w") as f:
            f.write(data)
        return data, "downloaded"
    except Exception as e:
        if os.path.exists(path):
            return open(path, encoding="utf-8", errors="replace").read(), f"cached ({e.__class__.__name__})"
        return "", f"FAILED ({e})"


# WebKit's content-blocker regex engine implements only a subset of PCRE, and a
# single unsupported construct fails the ENTIRE compiled list — not just that rule.
# Observed rejections: "Character class is not supported" (\w, \d, ...) and
# "Arbitrary atom repetitions are not supported" ({16}, {30,}).
_UNSUPPORTED_REGEX = re.compile(
    r"""\\[wWdDsSbB]      # shorthand character classes
      | \{\d              # {n} / {n,} / {n,m} repetitions
      | \(\?              # lookahead/lookbehind/non-capturing modifiers
      | \\[1-9]           # backreferences
      | \*\?              # lazy quantifiers
      | \+\?
    """,
    re.VERBOSE,
)


def _has_unescaped_pipe(pattern):
    """Alternation. Literal pipes we emit are escaped, so an unescaped one always
    comes from a raw-regex filter rule."""
    i = 0
    while i < len(pattern):
        if pattern[i] == "\\":
            i += 2
            continue
        if pattern[i] == "|":
            return True
        i += 1
    return False


def webkit_regex_ok(pattern):
    if _UNSUPPORTED_REGEX.search(pattern):
        return False
    # "Disjunctions are not supported yet"
    if _has_unescaped_pipe(pattern):
        return False
    # "Only ASCII characters are supported in pattern"
    if not pattern.isascii():
        return False
    return True


def escape_regex(s):
    return re.sub(r"([.+?^${}()|\[\]\\/])", r"\\\1", s)


def is_regex_domain(d):
    """uBO lets a regex stand where a hostname goes, in `$domain=` and before `##`.

    WebKit's if-domain takes hostnames only, so passing one through plants a `^`
    inside a domain pattern -- which it rejects, failing the ENTIRE compiled list.
    Two of the four lists were lost to exactly four such rules.
    """
    d = d.strip().lstrip("~")
    return len(d) > 2 and d.startswith("/") and d.endswith("/")


def has_stray_anchor(rx):
    """A `^` or `$` where WebKit forbids one: anywhere but the very ends.

    Structure-aware on purpose. The naive test flags `[^/]*`, which is the character
    class every domain-anchored rule is built from -- it read as 95% of the corpus
    being malformed.
    """
    i, n = 0, len(rx)
    in_class = False
    while i < n:
        c = rx[i]
        if c == "\\":
            i += 2
            continue
        if in_class:
            if c == "]":
                in_class = False
            i += 1
            continue
        if c == "[":
            in_class = True
            i += 1
            continue
        if c == "^" and i != 0:
            return True
        if c == "$" and i != n - 1:
            return True
        i += 1
    return False


def pattern_to_url_filter(pattern):
    """ABP pattern -> WebKit url-filter regex. Returns None if unrepresentable."""
    if pattern.startswith("/") and pattern.endswith("/") and len(pattern) > 2:
        return pattern[1:-1]          # already a regex

    anchor_start = False
    anchor_domain = False
    anchor_end = False

    if pattern.startswith("||"):
        pattern = pattern[2:]
        anchor_domain = True
    elif pattern.startswith("|"):
        pattern = pattern[1:]
        anchor_start = True

    # `||/^host\.example$/` -- uBO lets a regex stand where a hostname goes. The
    # literal check above runs before `||` is stripped, so these fell through and were
    # escaped as if they were text, planting a `^` in the middle of the generated
    # pattern. WebKit rejects a non-initial start-of-line assertion, and one rejected
    # rule fails the ENTIRE compiled list -- so a handful of these silently took two
    # of the four lists out of service. There is no domain-anchored-regex form in
    # WebKit to translate them into.
    if pattern.startswith("/") and pattern.endswith("/") and len(pattern) > 2:
        return None
    if pattern.endswith("|"):
        pattern = pattern[:-1]
        anchor_end = True

    out = []
    for ch in pattern:
        if ch == "*":
            out.append(".*")
        elif ch == "^":
            # ABP separator: any non-alphanumeric-ish char, or end of URL.
            out.append("[/:?=&]")
        else:
            out.append(escape_regex(ch))
    body = "".join(out)

    if anchor_domain:
        regex = r"^[^:]+://+([^:/]+\.)?" + body
    elif anchor_start:
        regex = "^" + body
    else:
        regex = body
    if anchor_end:
        regex += "$"
    return regex


def parse_options(optstr):
    """Returns (trigger_fragments, ok). ok=False means drop the rule."""
    trig = {}
    resource_types = []
    for raw in optstr.split(","):
        opt = raw.strip()
        if not opt:
            continue
        neg = opt.startswith("~")
        key = opt[1:] if neg else opt

        if key.startswith("domain="):
            doms = key[len("domain="):].split("|")
            # uBO lets a REGEX stand where a domain list goes:
            # `$domain=/^main\.example[a-z0-9-]+\.click$/`. WebKit's if-domain takes
            # hostnames only, and passing one through planted a `^` inside a domain
            # pattern -- which it rejects, failing the whole compiled list. This cost
            # two of the four lists, silently, while the shield still read "Blocking".
            if any(is_regex_domain(d) for d in doms if d):
                # Scoped to domains that cannot be expressed. Applying it unscoped
                # would over-block; dropping the exclusion would too.
                return None, False
            inc = [d.lower() for d in doms if d and not d.startswith("~")]
            exc = [d[1:].lower() for d in doms if d.startswith("~")]
            # WebKit rejects a rule carrying both; prefer the positive form.
            if inc:
                trig["if-domain"] = ["*" + d for d in inc]
            elif exc:
                trig["unless-domain"] = ["*" + d for d in exc]
            continue

        if key == "third-party":
            trig["load-type"] = ["first-party"] if neg else ["third-party"]
            continue
        if key in ("first-party", "1p"):
            trig["load-type"] = ["third-party"] if neg else ["first-party"]
            continue
        if key in ("match-case",):
            trig["url-filter-is-case-sensitive"] = True
            continue
        if key in ("popup", "popunder"):
            resource_types.append("popup")
            continue
        if key in RESOURCE_TYPES:
            if not neg:
                resource_types.append(RESOURCE_TYPES[key])
            continue
        if key in DECORATIVE_OPTS:
            # Keep the block, lose the decoration.
            continue
        if key in UNSUPPORTED_OPTS:
            return None, False
        # Unknown option: safer to drop than to over-block.
        return None, False

    if resource_types:
        mapped = sorted(set(t for t in resource_types if t != "popup"))
        if mapped:
            trig["resource-type"] = mapped
    return trig, True


def convert_line(line):
    line = line.strip()
    if not line or line[0] in "!#[" and not line.startswith("##"):
        if not (line.startswith("##") or "##" in line):
            return None

    # Cosmetic rules. Only plain `##`; every decorated variant (`#@#`, `#?#`,
    # `#$#`, `#@?#`, `#%#`) is a uBO engine feature WebKit has no equivalent for.
    if re.search(r"#[@$%?]+#", line):
        return None
    if "##" in line and not line.startswith("||"):
        domains, _, selector = line.partition("##")
        if not selector or selector.startswith("+js") or selector.startswith("^"):
            return None
        # Procedural cosmetics have no WebKit equivalent.
        if re.search(r":(has|has-text|matches-css|xpath|upward|remove|min-text-length|watch-attr|others|matches-path)\b", selector):
            return None
        if "#@#" in line:
            return None
        if domains and any(is_regex_domain(d) for d in domains.split(",") if d):
            return None
        trigger = {"url-filter": ".*"}
        if domains:
            inc = [d.lower() for d in domains.split(",") if d and not d.startswith("~")]
            if inc:
                trigger["if-domain"] = ["*" + d for d in inc]
        return {"trigger": trigger,
                "action": {"type": "css-display-none", "selector": selector}}

    if re.search(r"#[@$%?]*#", line):
        return None

    exception = line.startswith("@@")
    if exception:
        line = line[2:]

    pattern, _, optstr = line.partition("$")
    if not pattern:
        return None

    trig_extra = {}
    if optstr:
        trig_extra, ok = parse_options(optstr)
        if not ok:
            return None

    url_filter = pattern_to_url_filter(pattern)
    # Belt and braces for the whole class: an anchor somewhere WebKit will not accept.
    # Cheaper to drop one rule than to lose the 45,000 it is compiled alongside.
    if url_filter and has_stray_anchor(url_filter):
        return None
    if not url_filter or len(url_filter) > 1800:
        return None
    if not webkit_regex_ok(url_filter):
        return None

    trigger = {"url-filter": url_filter}
    trigger.update(trig_extra)
    action = {"type": "ignore-previous-rules"} if exception else {"type": "block"}
    return {"trigger": trigger, "action": action}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "macapp"))
    ap.add_argument("--cache", default=os.path.join(os.path.dirname(__file__), ".cache"))
    ap.add_argument("--offline", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.cache, exist_ok=True)
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    blocks, exceptions, cosmetics = [], [], []
    seen = set()
    stats = []

    for name, url in SOURCES:
        if args.offline:
            path = os.path.join(args.cache, name + ".txt")
            text = open(path, encoding="utf-8", errors="replace").read() if os.path.exists(path) else ""
            how = "offline-cache" if text else "MISSING"
        else:
            text, how = fetch(name, url, args.cache)

        kept = 0
        for line in text.splitlines():
            rule = convert_line(line)
            if not rule:
                continue
            key = json.dumps(rule, sort_keys=True)
            if key in seen:
                continue
            seen.add(key)
            if rule["action"]["type"] == "css-display-none":
                cosmetics.append(rule)
            elif rule["action"]["type"] == "ignore-previous-rules":
                exceptions.append(rule)
            else:
                blocks.append(rule)
            kept += 1
        stats.append((name, how, len(text.splitlines()), kept))

    # Splitting has a sharp edge: `ignore-previous-rules` only cancels rules earlier
    # in the SAME compiled list. WebKit evaluates each list independently, so an
    # exception that lands in a different chunk from the block it is meant to undo
    # simply stops working — silently over-blocking and breaking sites.
    #
    # So every block chunk carries the FULL exception set appended after it. The
    # duplication costs a little size and buys correct semantics.
    room = MAX_RULES_PER_LIST - len(exceptions)
    if room < 1000:
        print("ERROR: too many exceptions to pair with blocks", file=sys.stderr)
        return 1

    written = []
    chunks = [blocks[i:i + room] for i in range(0, len(blocks), room)] or [[]]
    for i, chunk in enumerate(chunks):
        payload = chunk + exceptions          # blocks first, then their exceptions
        fname = f"blocklist-{i}.json"
        with open(os.path.join(out_dir, fname), "w") as f:
            json.dump(payload, f, separators=(",", ":"))
        written.append((fname, len(payload)))

    # Cosmetic rules never interact with block/ignore, so they can live alone.
    for j, i in enumerate(range(0, len(cosmetics), MAX_RULES_PER_LIST)):
        fname = f"blocklist-cosmetic-{j}.json"
        with open(os.path.join(out_dir, fname), "w") as f:
            json.dump(cosmetics[i:i + MAX_RULES_PER_LIST], f, separators=(",", ":"))
        written.append((fname, len(cosmetics[i:i + MAX_RULES_PER_LIST])))

    ordered = blocks + exceptions + cosmetics

    print(f"{'source':<16} {'fetch':<26} {'lines':>8} {'kept':>8}")
    for name, how, total, kept in stats:
        print(f"{name:<16} {how:<26} {total:>8} {kept:>8}")
    print(f"\nblock={len(blocks)}  exception={len(exceptions)}  cosmetic={len(cosmetics)}")
    print(f"total rules: {len(ordered)}")
    for fname, n in written:
        size = os.path.getsize(os.path.join(out_dir, fname)) / 1024
        print(f"  {fname}: {n} rules, {size:.0f} KB")

    with open(os.path.join(out_dir, "blocklists-manifest.json"), "w") as f:
        json.dump({"lists": [w[0] for w in written], "rules": len(ordered)}, f)

    if not ordered:
        print("\nERROR: produced no rules", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
