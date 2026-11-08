"""
Running tally of how each Overpass mirror answers, kept in a text file that
is never reset: every attempt from every run (command line, batch or the UI)
is added to it, so over days and weeks it shows which mirrors actually work.

The file (overpass_mirror_stats.txt, next to the scripts) is rewritten after
each attempt as a readable report. Its last line holds the raw counts so the
next run can carry on from them; delete the file to start over. Set the
ROAD_TO_KML_MIRROR_STATS environment variable to keep it somewhere else.

Recording can never stop a run: any problem with the file is reported once
and then ignored.
"""

import json
import os
import tempfile
import time
from datetime import datetime

DEFAULT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "overpass_mirror_stats.txt")
DATA_PREFIX = "# data: "

# Outcomes, in the order the report lists them.
SUCCEEDED = "Succeeded"
COULDNT_FINISH = "Couldn't finish the query (timeout / out of memory)"
BUSY = "Busy (rate limited / overloaded)"
REJECTED = "Rejected the query (HTTP 400)"
NO_REPLY = "No reply in time (timed out)"
CONNECTION = "Couldn't connect"
UNREADABLE = "Unreadable reply"
OTHER = "Other error"
ORDER = [SUCCEEDED, COULDNT_FINISH, BUSY, REJECTED, NO_REPLY, CONNECTION, UNREADABLE, OTHER]

_warned = False


def stats_path() -> str:
    return os.environ.get("ROAD_TO_KML_MIRROR_STATS") or DEFAULT_PATH


def classify_exception(exc) -> str:
    """Outcome name for an exception raised while reaching a mirror."""
    import requests
    if isinstance(exc, requests.HTTPError):
        resp = exc.response
        code = resp.status_code if resp is not None else None
        if code == 400:
            return REJECTED
        if code is None:
            return OTHER
        reason = (getattr(resp, "reason", "") or "").strip()
        return f"HTTP {code}" + (f" {reason}" if reason else "")
    if isinstance(exc, requests.Timeout):
        return NO_REPLY
    if isinstance(exc, requests.ConnectionError):
        return CONNECTION
    if isinstance(exc, ValueError):                       # JSON decoding
        return UNREADABLE
    text = str(exc).lower()
    if "timed out" in text or "timeout" in text:
        return NO_REPLY
    if "connection" in text:
        return CONNECTION
    return OTHER


def _now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def load(path=None) -> dict:
    """The saved counts, or an empty record if there is no file yet."""
    path = path or stats_path()
    empty = {"version": 1, "first": None, "updated": None, "mirrors": {}}
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return empty
    for line in reversed(lines):
        if line.startswith(DATA_PREFIX):
            data = json.loads(line[len(DATA_PREFIX):])
            data.setdefault("mirrors", {})
            return data
    raise ValueError("the data line at the end of the file is missing")


def _row(m: dict) -> tuple:
    attempts = sum(m["outcomes"].values())
    ok = m["outcomes"].get(SUCCEEDED, 0)
    return attempts, ok


def _pct(n, d) -> str:
    return f"{100.0 * n / d:5.1f}%" if d else "    -"


def render(data: dict, mirror_order=()) -> str:
    """The readable report, ending with the data line."""
    mirrors = data["mirrors"]
    order = list(dict.fromkeys(mirror_order)) + sorted(u for u in mirrors if u not in mirror_order)
    out = [
        "Overpass mirror outcomes  (road_to_kml)",
        "=" * 39,
        "Every attempt to reach an Overpass mirror is counted here, across all runs.",
        "The counts carry on from run to run; delete this file to start over.",
        f"First recorded: {data.get('first') or '-'}    Last updated: {data.get('updated') or '-'}",
        "",
    ]
    if not order:
        out.append("No attempts recorded yet.")
    else:
        width = max(len(u) for u in order)
        head = f"  {'Mirror':<{width}}  {'Attempts':>8}  {'Succeeded':>9}  {'Rate':>6}  Last success"
        out += ["SUMMARY  (mirrors are tried in this order; one further down is only",
                "         reached when the ones above it fail)",
                head, "  " + "-" * (len(head) - 2)]
        for u in order:
            m = mirrors.get(u, {"outcomes": {}})
            attempts, ok = _row(m)
            last = m.get("last_ok") or ("never" if attempts else "never tried")
            out.append(f"  {u:<{width}}  {attempts:>8}  {ok:>9}  {_pct(ok, attempts):>6}  {last}")
        retired = [u for u in order if mirror_order and u not in mirror_order]
        if retired:
            out.append("  (not in the script's current mirror list: " + ", ".join(retired) + ")")
        out += ["", "DETAILS"]
        tried = [u for u in order if u in mirrors]
        names_all = {n for u in tried for n in mirrors[u]["outcomes"]}
        nw = max([len(n) for n in names_all] or [10])
        for u in tried:
            m = mirrors[u]
            attempts, ok = _row(m)
            out += ["", u, f"  Attempts: {attempts}    Last attempt: {m.get('last_try') or '-'}"]
            if ok:
                out.append(f"  Average time for a successful reply: {m.get('ok_seconds', 0.0) / ok:.1f} s")
            names = [n for n in ORDER if n in m["outcomes"]] + \
                    sorted(n for n in m["outcomes"] if n not in ORDER)
            for n in names:
                c = m["outcomes"][n]
                out.append(f"    {n:<{nw}}  {c:>7}  {_pct(c, attempts)}")
    out += ["", DATA_PREFIX + json.dumps(data, sort_keys=True)]
    return "\n".join(out) + "\n"


class _Lock:
    """Keeps two runs at once from overwriting each other's counts."""

    def __init__(self, path):
        import hashlib
        key = hashlib.sha1(os.path.abspath(path).encode("utf-8")).hexdigest()[:12]
        self.path = os.path.join(tempfile.gettempdir(), f"road_to_kml_mirror_stats_{key}.lock")
        self.fh = None

    def __enter__(self):
        try:
            self.fh = open(self.path, "a+")
            if os.name == "nt":
                import msvcrt
                for _ in range(100):
                    try:
                        self.fh.seek(0)
                        msvcrt.locking(self.fh.fileno(), msvcrt.LK_NBLCK, 1)
                        break
                    except OSError:
                        time.sleep(0.05)
            else:
                import fcntl
                fcntl.flock(self.fh.fileno(), fcntl.LOCK_EX)
        except Exception:
            pass                       # locking is best-effort
        return self

    def __exit__(self, *exc):
        try:
            if os.name == "nt":
                import msvcrt
                self.fh.seek(0)
                msvcrt.locking(self.fh.fileno(), msvcrt.LK_UNLCK, 1)
            self.fh.close()
        except Exception:
            pass


def record(url: str, outcome: str, seconds: float = 0.0, mirror_order=(), path=None):
    """Add one attempt to the file. Never raises."""
    global _warned
    path = path or stats_path()
    try:
        with _Lock(path):
            try:
                data = load(path)
            except (ValueError, json.JSONDecodeError) as e:
                # Don't silently wipe weeks of counts: set the old file aside.
                keep = path[:-4] if path.endswith(".txt") else path
                keep += f".unreadable-{datetime.now():%Y%m%d-%H%M%S}.txt"
                os.replace(path, keep)
                print(f"  Note: couldn't read the mirror tally ({e}); kept it as {keep} "
                      "and started a new one.")
                data = load(path)
            now = _now()
            data["first"] = data.get("first") or now
            data["updated"] = now
            m = data["mirrors"].setdefault(url, {"outcomes": {}})
            m["outcomes"][outcome] = m["outcomes"].get(outcome, 0) + 1
            m["last_try"] = now
            if outcome == SUCCEEDED:
                m["ok_seconds"] = round(m.get("ok_seconds", 0.0) + seconds, 2)
                m["last_ok"] = now
            text = render(data, mirror_order)
            folder = os.path.dirname(os.path.abspath(path))
            fd, tmp = tempfile.mkstemp(prefix=".mirror_stats_", suffix=".tmp", dir=folder)
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
            os.replace(tmp, path)
    except Exception as e:
        if not _warned:
            _warned = True
            print(f"  Note: couldn't update the mirror tally at {path}: {e}")
