#!/usr/bin/env python3
"""Reference copy of road_aliases.py from the Road to KML project (for comparison tests)."""

import argparse
import re
import unicodedata
from functools import lru_cache
from itertools import islice, product

STATES = {
    "al": ("Alabama",              ["Ala."],                [],              [],                                   []),
    "ak": ("Alaska",               [],                      [],              [],                                   []),
    "az": ("Arizona",              ["Ariz."],               [],              [],                                   []),
    "ar": ("Arkansas",             ["Ark."],                [],              [],                                   []),
    "ca": ("California",           ["Calif.", "Cal."],      [],              [],                                   []),
    "co": ("Colorado",             ["Colo."],               [],              [],                                   []),
    "ct": ("Connecticut",          ["Conn."],               [],              [],                                   ["Conn", "CT"]),
    "de": ("Delaware",             ["Del."],                [],              [],                                   ["Del"]),
    "dc": ("District of Columbia", ["D.C."],                [],              [],                                   []),
    "fl": ("Florida",              ["Fla."],                [],              ["State Road"],                       []),
    "ga": ("Georgia",              ["Ga."],                 [],              [],                                   []),
    "hi": ("Hawaii",               [],                      [],              [],                                   []),
    "id": ("Idaho",                ["Ida."],                [],              [],                                   []),
    "il": ("Illinois",             ["Ill."],                [],              [],                                   []),
    "in": ("Indiana",              ["Ind."],                [],              ["State Road"],                       []),
    "ia": ("Iowa",                 [],                      [],              [],                                   []),
    "ks": ("Kansas",               ["Kan.", "Kans."],       ["K"],           [],                                   []),
    "ky": ("Kentucky",             ["Ky."],                 [],              [],                                   []),
    "la": ("Louisiana",            ["La."],                 [],              [],                                   []),
    "me": ("Maine",                [],                      [],              [],                                   []),
    "md": ("Maryland",             ["Md."],                 [],              [],                                   ["MD"]),
    "ma": ("Massachusetts",        ["Mass."],               [],              [],                                   ["Mass", "MA"]),
    "mi": ("Michigan",             ["Mich."],               ["M"],           ["State Trunkline", "Trunkline"],     ["Mich"]),
    "mn": ("Minnesota",            ["Minn."],               ["MNTH"],        ["Trunk Highway", "State Trunk Highway"], []),
    "ms": ("Mississippi",          ["Miss."],               [],              [],                                   []),
    "mo": ("Missouri",             ["Mo."],                 [],              [],                                   []),
    "mt": ("Montana",              ["Mont."],               [],              [],                                   []),
    "ne": ("Nebraska",             ["Neb.", "Nebr."],       ["N"],           [],                                   []),
    "nv": ("Nevada",               ["Nev."],                [],              [],                                   []),
    "nh": ("New Hampshire",        ["N.H."],                [],              [],                                   ["NH"]),
    "nj": ("New Jersey",           ["N.J."],                [],              [],                                   ["NJ"]),
    "nm": ("New Mexico",           ["N.M.", "N.Mex."],      [],              ["State Road"],                       ["NM"]),
    "ny": ("New York",             ["N.Y."],                ["NYS"],         [],                                   ["NY"]),
    "nc": ("North Carolina",       ["N.C."],                [],              [],                                   ["NC"]),
    "nd": ("North Dakota",         ["N.D.", "N.Dak."],      [],              [],                                   ["ND"]),
    "oh": ("Ohio",                 [],                      [],              [],                                   []),
    "ok": ("Oklahoma",             ["Okla."],               [],              [],                                   []),
    "or": ("Oregon",               ["Ore.", "Oreg."],       [],              [],                                   []),
    "pa": ("Pennsylvania",         ["Pa.", "Penna.", "Penn."], [],           [],                                   ["Penn", "PA"]),
    "ri": ("Rhode Island",         ["R.I."],                [],              [],                                   ["RI"]),
    "sc": ("South Carolina",       ["S.C."],                [],              [],                                   ["SC"]),
    "sd": ("South Dakota",         ["S.D.", "S.Dak."],      [],              [],                                   ["SD"]),
    "tn": ("Tennessee",            ["Tenn."],               [],              [],                                   []),
    "tx": ("Texas",                ["Tex."],                [],              [],                                   []),
    "ut": ("Utah",                 [],                      [],              [],                                   []),
    "vt": ("Vermont",              ["Vt."],                 [],              [],                                   []),
    "va": ("Virginia",             ["Va."],                 [],              [],                                   ["VA"]),
    "wa": ("Washington",           ["Wash."],               [],              [],                                   []),
    "wv": ("West Virginia",        ["W.Va.", "W. Va.", "W.V."], [],          [],                                   ["WV"]),
    "wi": ("Wisconsin",            ["Wis.", "Wisc."],       ["WIS", "STH"],  ["State Trunk Highway", "Trunk Highway"], ["Wisc"]),
    "wy": ("Wyoming",              ["Wyo."],                ["WYO"],         [],                                   []),
}

STATE_INPUT_EXTRAS = {
    "washington state": "wa", "wash state": "wa", "wa state": "wa",
    "washington dc": "dc", "washington d c": "dc", "wash dc": "dc",
    "district of columbia": "dc", "the district": "dc", "d c": "dc",
    "n mex": "nm", "n dak": "nd", "s dak": "sd", "w va": "wv",
}

ROUTE_CLASSES = {
    "I": ["Interstate", "I", "IH", "Int", "Interstate Highway", "Interstate Hwy",
          "Interstate Route", "Interstate Rte"],
    "US": ["US", "U.S.", "U. S.", "US Route", "U.S. Route", "US Rte", "US Rt",
           "US Highway", "U.S. Highway", "US Hwy", "U.S. Hwy", "US Hiway",
           "United States Highway", "United States Route", "United States Hwy"],
    "STATE": ["State Route", "State Rte", "State Rt", "SR", "St Rt", "St Rte",
              "St Route", "State Highway", "State Hwy", "SH", "St Hwy",
              "St Highway", "State Road", "State Rd", "St Rd", "Trunk Highway",
              "TH", "State Trunk Highway", "STH", "State Trunkline", "Trunkline",
              "State Hiway"],
    "GENERIC": ["Route", "Rte", "Rt", "Highway", "Hwy", "Hiway", "Hgwy"],
    "COUNTY": ["County Road", "County Rd", "Co Road", "Co Rd", "CR", "Cnty Road",
               "Cnty Rd", "County Route", "County Rte", "Co Route", "Co Rte",
               "County Highway", "County Hwy", "Co Highway", "Co Hwy", "Cnty Hwy",
               "CH", "CTH", "County Trunk Highway", "County Trunk"],
    "TOWNSHIP": ["Township Road", "Township Rd", "Twp Road", "Twp Rd", "TR", "TSR",
                 "Township Route", "Twp Rte", "Township Highway", "Township Hwy",
                 "Twp Hwy"],
    "FM": ["FM", "F.M.", "FM Road", "FM Rd", "FMRD", "Farm to Market Road",
           "Farm to Market Rd", "Farm to Market", "Farm Road", "Farm Rd",
           "Farm Market Road", "Farm Market Rd", "RM", "R.M.", "RM Road", "RM Rd",
           "RMRD", "Ranch to Market Road", "Ranch to Market Rd", "Ranch to Market",
           "Ranch Road", "Ranch Rd", "RR"],
    "LOOP": ["Loop", "State Loop", "SL", "Lp"],
    "SPUR": ["Spur", "State Spur"],
    "PARK": ["Park Road", "Park Rd", "PR"],
    "BELTWAY": ["Beltway", "BW"],
    "FOREST": ["Forest Service Road", "Forest Service Rd", "Forest Road",
               "Forest Rd", "FS Road", "FS Rd", "FSR", "FR", "NF", "NFS Road",
               "NFS Rd", "NFSR", "National Forest Road"],
    "BIA": ["BIA Route", "BIA Rte", "BIA Road", "BIA Rd", "BIA Highway", "BIA Hwy",
            "BIA", "Indian Route"],
}

ROUTE_DISPLAY = {
    "I": ["I-{n}", "I {n}", "I{n}", "I- {n}", "Interstate {n}",
          "Interstate Highway {n}", "IH {n}", "IH-{n}"],
    "US": ["US {n}", "US-{n}", "US{n}", "U.S. {n}", "US Route {n}", "U.S. Route {n}",
           "US Highway {n}", "US Hwy {n}", "U.S. Highway {n}",
           "United States Highway {n}"],
    "COUNTY": ["County Road {n}", "CR {n}", "CR-{n}", "Co Rd {n}", "County Rd {n}",
               "County Route {n}", "County Highway {n}", "Co Hwy {n}", "CTH {n}"],
    "TOWNSHIP": ["Township Road {n}", "Twp Rd {n}", "TR {n}", "Township Highway {n}"],
    "FM": ["FM {n}", "FM-{n}", "FM {n} Rd", "Farm to Market Road {n}",
           "Farm-to-Market Rd {n}", "RM {n}", "Ranch to Market Road {n}",
           "Ranch Road {n}", "RR {n}"],
    "LOOP": ["Loop {n}", "State Loop {n}", "SL {n}"],
    "SPUR": ["Spur {n}", "State Spur {n}"],
    "PARK": ["Park Road {n}", "PR {n}"],
    "BELTWAY": ["Beltway {n}", "BW {n}", "BW-{n}"],
    "FOREST": ["Forest Service Road {n}", "Forest Road {n}", "FS Rd {n}", "FR {n}",
               "NF {n}", "NF-{n}", "NFSR {n}"],
    "BIA": ["BIA Route {n}", "BIA Rd {n}", "BIA {n}"],
}

STATE_ROUTE_WORDS = ["Route", "Rte", "Rt", "Highway", "Hwy", "State Route",
                     "State Rte", "State Highway", "State Hwy", "State Road",
                     "State Rd", "SR", "SH"]

STATE_AGNOSTIC_DISPLAY = ["State Route {n}", "SR {n}", "SR-{n}", "State Highway {n}",
                          "SH {n}", "State Road {n}", "Route {n}", "Rte {n}",
                          "Highway {n}", "Hwy {n}"]

STREET_TYPES = [
    ["Alley", "Aly", "Ally"],
    ["Annex", "Anx"],
    ["Arcade", "Arc"],
    ["Avenue", "Ave", "Av", "~Aven", "~Avenu", "~Avn", "~Avnue"],
    ["Bayou", "Byu"],
    ["Beach", "Bch"],
    ["Bend", "Bnd"],
    ["Bluff", "Blf"],
    ["Bluffs", "Blfs"],
    ["Bottom", "Btm"],
    ["Boulevard", "Blvd", "Boul", "~Boulv"],
    ["Branch", "Br", "~Brnch"],
    ["Bridge", "Brg", "~Brdge"],
    ["Brook", "Brk"],
    ["Brooks", "Brks"],
    ["Bypass", "Byp", "~Bypa", "~Byps"],
    ["Camp", "Cp"],
    ["Canyon", "Cyn", "~Cnyn"],
    ["Cape", "Cpe"],
    ["Causeway", "Cswy", "~Causwa"],
    ["Center", "Ctr", "Centre", "~Cntr"],
    ["Circle", "Cir", "~Circ", "~Crcl"],
    ["Cliff", "Clf"],
    ["Cliffs", "Clfs"],
    ["Club", "Clb"],
    ["Common", "Cmn"],
    ["Commons", "Cmns"],
    ["Corner", "Cor"],
    ["Corners", "Cors"],
    ["Course", "Crse"],
    ["Court", "Ct", "~Crt"],
    ["Courts", "Cts"],
    ["Cove", "Cv"],
    ["Creek", "Crk"],
    ["Crescent", "Cres", "~Crsnt"],
    ["Crest", "Crst"],
    ["Crossing", "Xing", "~Crssng"],
    ["Crossroad", "Xrd"],
    ["Crossroads", "Xrds"],
    ["Curve", "Curv"],
    ["Dale", "Dl"],
    ["Dam", "Dm"],
    ["Divide", "Dv", "~Dvd"],
    ["Drive", "Dr", "Drv"],
    ["Drives", "Drs"],
    ["Esplanade", "Esp"],
    ["Estate", "Est"],
    ["Estates", "Ests"],
    ["Expressway", "Expy", "Expwy", "~Expw", "~Exwy"],
    ["Extension", "Ext", "~Extn", "~Extd", "~Exd"],
    ["Extensions", "Exts"],
    ["Falls", "Fls"],
    ["Ferry", "Fry"],
    ["Field", "Fld"],
    ["Fields", "Flds"],
    ["Flat", "Flt"],
    ["Flats", "Flts"],
    ["Ford", "Frd"],
    ["Forest", "Frst"],
    ["Forge", "Frg"],
    ["Fork", "Frk"],
    ["Forks", "Frks"],
    ["Fort", "Ft"],
    ["Freeway", "Fwy", "Frwy", "~Frway"],
    ["Garden", "Gdn"],
    ["Gardens", "Gdns"],
    ["Gateway", "Gtwy"],
    ["Glen", "Gln"],
    ["Green", "Grn"],
    ["Grove", "Grv"],
    ["Harbor", "Hbr", "Harbour"],
    ["Haven", "Hvn"],
    ["Heights", "Hts", "~Hgts"],
    ["Highway", "Hwy", "Hiway", "~Hgwy"],
    ["Hill", "Hl"],
    ["Hills", "Hls"],
    ["Hollow", "Holw"],
    ["Inlet", "Inlt"],
    ["Island", "Is"],
    ["Islands", "Iss"],
    ["Junction", "Jct", "~Jctn"],
    ["Key", "Ky"],
    ["Knoll", "Knl"],
    ["Lake", "Lk"],
    ["Lakes", "Lks"],
    ["Landing", "Lndg"],
    ["Lane", "Ln"],
    ["Light", "Lgt"],
    ["Lock", "Lck"],
    ["Lodge", "Ldg"],
    ["Loop", "Lp"],
    ["Manor", "Mnr"],
    ["Meadow", "Mdw"],
    ["Meadows", "Mdws"],
    ["Mill", "Ml"],
    ["Mills", "Mls"],
    ["Mission", "Msn"],
    ["Motorway", "Mtwy"],
    ["Mount", "Mt", "~Mnt"],
    ["Mountain", "Mtn"],
    ["Neck", "Nck"],
    ["Orchard", "Orch"],
    ["Overpass", "Opas"],
    ["Parkway", "Pkwy", "Pky", "~Pkway", "~Pwy"],
    ["Passage", "Psge"],
    ["Pine", "Pne"],
    ["Pines", "Pnes"],
    ["Place", "Pl"],
    ["Plain", "Pln"],
    ["Plains", "Plns"],
    ["Plaza", "Plz", "~Plza"],
    ["Point", "Pt"],
    ["Points", "Pts"],
    ["Port", "Prt"],
    ["Promenade", "Prom"],
    ["Radial", "Radl"],
    ["Ranch", "Rnch"],
    ["Rapids", "Rpds"],
    ["Ridge", "Rdg"],
    ["Ridges", "Rdgs"],
    ["River", "Riv"],
    ["Road", "Rd"],
    ["Roads", "Rds"],
    ["Route", "Rte", "Rt"],
    ["Shoal", "Shl"],
    ["Shore", "Shr"],
    ["Shores", "Shrs"],
    ["Skyway", "Skwy"],
    ["Spring", "Spg"],
    ["Springs", "Spgs"],
    ["Square", "Sq", "~Sqr"],
    ["Station", "Sta", "~Stn"],
    ["Stravenue", "Stra"],
    ["Stream", "Strm"],
    ["Street", "St", "Str"],
    ["Streets", "Sts"],
    ["Summit", "Smt"],
    ["Terrace", "Ter", "Terr"],
    ["Throughway", "Thruway", "Trwy", "Thwy"],
    ["Trace", "Trce"],
    ["Track", "Trak"],
    ["Trafficway", "Trfy"],
    ["Trail", "Trl", "Tr"],
    ["Tunnel", "Tunl"],
    ["Turnpike", "Tpke", "Tpk", "~Tnpk", "~Trpk"],
    ["Underpass", "Upas"],
    ["Valley", "Vly"],
    ["View", "Vw"],
    ["Village", "Vlg"],
    ["Vista", "Vis", "~Vst"],
    ["Way", "Wy"],
    ["Well", "Wl"],
    ["Wells", "Wls"],
]

DIRECTIONALS = [
    ["North", "N"],
    ["South", "S"],
    ["East", "E"],
    ["West", "W"],
    ["Northeast", "NE", "N.E.", "North East"],
    ["Northwest", "NW", "N.W.", "North West"],
    ["Southeast", "SE", "S.E.", "South East"],
    ["Southwest", "SW", "S.W.", "South West"],
    ["Northbound", "NB"],
    ["Southbound", "SB"],
    ["Eastbound", "EB"],
    ["Westbound", "WB"],
]

MODIFIERS = [
    ["Business", "Bus", "Busn"],
    ["Alternate", "Alt"],
    ["Truck", "Trk"],
    ["Connector", "Conn"],
    ["Express", "Exp"],
    ["HOV"],
    ["Toll"],
    ["Service", "Svc", "~Serv"],
    ["Frontage", "Frtg"],
    ["Ramp"],
    ["Spur"],
]

WORDS = [
    ["Saint", "St"],
    ["Sainte", "Ste"],
    ["Doctor", "Dr"],
    ["Junior", "Jr"],
    ["Senior", "Sr"],
    ["General", "Gen"],
    ["President", "Pres"],
    ["Governor", "Gov"],
    ["Senator", "Sen"],
    ["Reverend", "Rev"],
    ["Captain", "Capt"],
    ["Colonel", "Col"],
    ["Lieutenant", "Lt"],
    ["Admiral", "Adm"],
    ["Sergeant", "Sgt"],
    ["Professor", "Prof"],
    ["Monsignor", "Msgr"],
    ["Corporal", "Cpl"],
    ["Commander", "Cmdr"],
    ["Major", "Maj"],
    ["Private", "Pvt"],
    ["Memorial", "Meml", "Mem"],
    ["National", "Natl"],
    ["International", "Intl"],
    ["Industrial", "Indl"],
    ["University", "Univ"],
    ["Airport", "Arpt"],
    ["County", "Co", "Cnty"],
    ["Township", "Twp"],
    ["Upper", "Upr"],
    ["Lower", "Lwr"],
    ["Little", "Ltl"],
    ["Railroad", "RR"],
    ["Railway", "Rwy"],
    ["and", "&"],
]

NAMED_ROADS = [
    ["Martin Luther King Jr", "Martin Luther King Junior", "Martin Luther King",
     "Martin L King Jr", "Martin L King", "M L King Jr", "M L King", "MLK Jr", "MLK",
     "Dr Martin Luther King Jr", "Dr Martin Luther King", "Doctor Martin Luther King Jr",
     "Dr M L King Jr", "Dr MLK Jr", "Dr MLK", "Rev Dr Martin Luther King Jr"],
    ["John F Kennedy", "John Fitzgerald Kennedy", "JFK", "J F K", "President John F Kennedy",
     "Pres John F Kennedy"],
    ["Lyndon B Johnson", "Lyndon Baines Johnson", "LBJ", "L B J", "Lyndon Johnson"],
    ["Franklin D Roosevelt", "Franklin Delano Roosevelt", "FDR", "F D R"],
    ["Cesar E Chavez", "Cesar Chavez", "César Chávez", "César E. Chávez"],
    ["George Washington Memorial Parkway", "George Washington Parkway", "GW Parkway",
     "G W Parkway", "GW Memorial Parkway", "GWMP"],
    ["Baltimore-Washington Parkway", "BW Parkway", "B W Parkway", "Baltimore Washington Parkway"],
    ["Rock Creek and Potomac Parkway", "Rock Creek & Potomac Parkway", "Rock Creek Parkway"],
    ["Dulles Airport Access Road", "Dulles Access Road", "DAAR"],
    ["Jones Falls Expressway", "JFX"],
    ["New Jersey Turnpike", "NJ Turnpike", "N J Turnpike", "NJTP"],
    ["Garden State Parkway", "GSP"],
    ["Atlantic City Expressway", "AC Expressway", "ACE"],
    ["Pennsylvania Turnpike", "PA Turnpike", "Penna Turnpike", "Penn Turnpike"],
    ["Massachusetts Turnpike", "Mass Turnpike", "Mass Pike", "Masspike", "MA Turnpike"],
    ["New York State Thruway", "NYS Thruway", "New York Thruway", "NY Thruway",
     "NY State Thruway", "Governor Thomas E Dewey Thruway", "Thomas E Dewey Thruway"],
    ["Long Island Expressway", "LIE", "L I E"],
    ["Brooklyn-Queens Expressway", "Brooklyn Queens Expressway", "BQE"],
    ["Franklin D Roosevelt East River Drive", "FDR Drive", "F D R Drive",
     "Franklin D Roosevelt Drive", "Franklin Delano Roosevelt Drive"],
    ["Palisades Interstate Parkway", "Palisades Parkway", "PIP"],
    ["Taconic State Parkway", "Taconic Parkway"],
    ["Florida's Turnpike", "Florida Turnpike", "FL Turnpike", "Fla Turnpike"],
    ["President George Bush Turnpike", "George Bush Turnpike", "Pres George Bush Turnpike",
     "PGBT", "Bush Turnpike"],
    ["Dallas North Tollway", "DNT", "North Dallas Tollway"],
    ["Sam Rayburn Tollway", "SRT"],
    ["MoPac", "Mo Pac", "Mo-Pac", "Missouri Pacific"],
    ["Pacific Coast Highway", "PCH"],
    ["Jean Baptiste Point DuSable Lake Shore Drive", "Jean Baptiste Point Du Sable Lake Shore Drive",
     "DuSable Lake Shore Drive", "Du Sable Lake Shore Drive", "Lake Shore Drive", "LSD"],
]

RENAMED_ROADS = [
    ("va", ["51013"], "Arlington County, VA",
     ["Langston Boulevard", "Lee Highway"]),
    ("va", ["51013", "51510"], "Arlington County and Alexandria, VA",
     ["Richmond Highway", "Jefferson Davis Highway"]),
    ("tx", ["48453"], "Austin (Travis County), TX",
     ["Azie Morton Road", "Robert E Lee Road"]),
    ("tx", ["48453"], "Austin (Travis County), TX",
     ["William Holland Avenue", "Jeff Davis Avenue"]),
    ("tx", ["48201"], "Houston (Harris County), TX",
     ["Emancipation Avenue", "Dowling Street"]),
]

_PUNCT_MAP = str.maketrans({
    "’": "'", "‘": "'", "`": "'", "´": "'",
    "–": "-", "—": "-", "‒": "-", "−": "-",
})


def _strip_accents(s: str) -> str:
    return "".join(
        c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c)
    )


def tokenize(text) -> list:
    s = str(text or "").translate(_PUNCT_MAP)
    s = s.replace("&", " & ")
    s = re.sub(r'[/,;:()\[\]{}"!?#*+=<>|\\]', " ", s)
    s = s.replace("-", " ")
    s = re.sub(r"(?<=[A-Za-z])(?=\d)", " ", s)
    out = []
    for orig in s.split():
        norm = _strip_accents(orig).lower().replace(".", "").replace("'", "")
        if norm:
            out.append((norm, orig))
    return out


def _key(form: str) -> tuple:
    return tuple(n for n, _ in tokenize(form))


def _norm_phrase(form: str) -> str:
    return " ".join(_key(form))


_RX_BRACKET = set("$*+?()[{}|")


def _rx_chars(s: str) -> str:
    out = []
    for ch in s:
        if ch.isalnum():
            out.append(ch)
        elif ch == "'":
            out.append("('|’)?")
        elif ch == ".":
            out.append("[.]?")
        elif ch in " -":
            out.append("[ -]*")
        elif ch == "]":
            out.append("[]]")
        elif ch in _RX_BRACKET:
            out.append(f"[{ch}]")
        elif ch in '^\\"':
            continue
        else:
            out.append(ch)
    return "".join(out)


def _rx_phrase(form: str) -> str:
    parts = []
    for tok in form.split():
        r = _rx_chars(tok)
        bare = tok.replace(".", "")
        if bare.isalpha() and len(bare) <= 4 and not tok.endswith("."):
            r += "[.]?"
        parts.append(r)
    return "[ -]*".join(parts)


def _rx_literal(orig: str) -> str:
    def one(s):
        if re.fullmatch(r"[A-Za-z]{2,}s", s):
            return _rx_chars(s[:-1]) + "('|’)?" + s[-1]
        r = _rx_chars(s)
        if len(s) == 1 and s.isalpha():
            r += "[.]?"
        return r
    r = one(orig)
    plain = _strip_accents(orig)
    if plain != orig:
        r = f"({r}|{one(plain)})"
    return r


def _rx_alt(rx_list) -> str:
    seen, out = set(), []
    for r in rx_list:
        if r and r not in seen:
            seen.add(r)
            out.append(r)
    return out[0] if len(out) == 1 else "(" + "|".join(out) + ")"


class Elem:
    __slots__ = ("kind", "key", "alts", "rx")

    def __init__(self, kind, key, alts, rx):
        self.kind = kind
        self.key = key
        self.alts = alts
        self.rx = rx

    def __repr__(self):
        return f"<{self.kind} {self.key} {self.alts[:3]}>"


_GROUPS = {}
_GROUP_INDEX = {}
_GROUP_KIND = {}
_SPECIAL = {"st": ("street", "saint"), "dr": ("drive", "doctor")}


def _gid(forms):
    return "_".join(_key(forms[0].lstrip("~")))


def _register_group(kind, forms):
    gid = _gid(forms)
    if gid in _GROUPS:
        return
    _GROUPS[gid] = [f for f in forms if not f.startswith("~")]
    _GROUP_KIND[gid] = kind
    for f in forms:
        k = _key(f.lstrip("~"))
        if k in _SPECIAL or (len(k) == 1 and k[0] in _SPECIAL):
            continue
        _GROUP_INDEX.setdefault(k, gid)


for _forms in STREET_TYPES:
    _register_group("type", _forms)
for _forms in DIRECTIONALS:
    _register_group("dir", _forms)
for _forms in MODIFIERS:
    _register_group("mod", _forms)
for _forms in WORDS:
    _register_group("word", _forms)

_TYPE_WORDS = {k[0] for k, g in _GROUP_INDEX.items() if len(k) == 1 and _GROUP_KIND[g] == "type"}
_TYPE_WORDS |= {"st", "dr"}
_DIR_WORDS = {w for k, g in _GROUP_INDEX.items() if _GROUP_KIND[g] == "dir" for w in k}
_TRAILING_WORDS = _DIR_WORDS | {
    w for k, g in _GROUP_INDEX.items()
    if _GROUP_KIND[g] == "mod" or g in ("extension", "bypass")
    for w in k
}
_AVENUE_WORDS = {k[0] for k, g in _GROUP_INDEX.items() if g == "avenue" and len(k) == 1}
_GROUP_MAXLEN = max(len(k) for k in _GROUP_INDEX)

_ONES = ["", "First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth"]
_TEENS = ["Tenth", "Eleventh", "Twelfth", "Thirteenth", "Fourteenth", "Fifteenth",
          "Sixteenth", "Seventeenth", "Eighteenth", "Nineteenth"]
_TENS_ORD = {2: "Twentieth", 3: "Thirtieth", 4: "Fortieth", 5: "Fiftieth",
             6: "Sixtieth", 7: "Seventieth", 8: "Eightieth", 9: "Ninetieth"}
_TENS = {2: "Twenty", 3: "Thirty", 4: "Forty", 5: "Fifty", 6: "Sixty",
         7: "Seventy", 8: "Eighty", 9: "Ninety"}


def _ordinal_word(n):
    if n < 10:
        return _ONES[n]
    if n < 20:
        return _TEENS[n - 10]
    tens, ones = divmod(n, 10)
    return _TENS_ORD[tens] if ones == 0 else f"{_TENS[tens]}-{_ONES[ones]}"


def _ordinal_suffix(n):
    if 10 <= n % 100 <= 20:
        return "th"
    return {1: "st", 2: "nd", 3: "rd"}.get(n % 10, "th")


_ORD_INDEX = {_key(_ordinal_word(n)): n for n in range(1, 100)}
_ORD_RE = re.compile(r"(\d+)(st|nd|rd|th)")

_NAMED = {}
_NAMED_INDEX = {}


def _type_alternatives(word_norm):
    gid = _GROUP_INDEX.get((word_norm,))
    if gid and _GROUP_KIND.get(gid) == "type":
        return _GROUPS[gid]
    return None


def _expand_type_forms(forms):
    out = []
    for f in forms:
        toks = f.split()
        alts = _type_alternatives(_key(toks[-1])[-1]) if toks else None
        if alts:
            out.extend(" ".join(toks[:-1] + [a]) for a in alts)
        else:
            out.append(f)
    return list(dict.fromkeys(out))


for _forms in NAMED_ROADS:
    _nid = "named:" + "_".join(_key(_forms[0]))
    _NAMED[_nid] = _expand_type_forms(_forms)
    for _f in _NAMED[_nid]:
        _NAMED_INDEX.setdefault(_key(_f), _nid)
_NAMED_MAXLEN = max(len(k) for k in _NAMED_INDEX)

_RENAMES = {}
_RENAME_INDEX = {}
for _n, (_st, _fips, _where, _forms) in enumerate(RENAMED_ROADS):
    _rid = f"rename{_n}:" + "_".join(_key(_forms[0]))
    _RENAMES[_rid] = (_st, set(_fips), _where, _expand_type_forms(_forms))
    for _f in _RENAMES[_rid][3]:
        _RENAME_INDEX.setdefault(_key(_f), []).append(_rid)
_RENAME_MAXLEN = max((len(k) for k in _RENAME_INDEX), default=1)

_STAVE_INDEX = {}
for _abbr, (_name, _forms, _pfx, _words, _nick) in STATES.items():
    if not _nick:
        continue
    _STAVE_INDEX[_key(_name)] = (_abbr, False)
    for _nk in _nick:
        _STAVE_INDEX[_key(_nk)] = (_abbr, len(_nk) <= 2)
_STAVE_MAXLEN = max(len(k) for k in _STAVE_INDEX)

_CLASS_INDEX = {}
for _cls, _prefixes in ROUTE_CLASSES.items():
    for _p in _prefixes:
        _CLASS_INDEX.setdefault(_key(_p), _cls)

_STATE_FORM_INDEX = {}
for _abbr, (_name, _forms, _pfx, _words, _nick) in STATES.items():
    for _f in [_abbr, _name] + _forms:
        _STATE_FORM_INDEX.setdefault(_key(_f), (_abbr, False))
    for _f in _pfx:
        _STATE_FORM_INDEX.setdefault(_key(_f), (_abbr, len(_key(_f)[0]) == 1))

_AFTER_STATE_INDEX = {}
for _w in STATE_ROUTE_WORDS + ROUTE_CLASSES["STATE"]:
    _AFTER_STATE_INDEX.setdefault(_key(_w), "STATE")
for _abbr, (_name, _forms, _pfx, _words, _nick) in STATES.items():
    for _w in _words:
        _AFTER_STATE_INDEX.setdefault(_key(_w), "STATE")
for _cls in ("COUNTY", "TOWNSHIP", "FM", "LOOP", "SPUR", "PARK", "BELTWAY"):
    for _p in ROUTE_CLASSES[_cls]:
        _AFTER_STATE_INDEX.setdefault(_key(_p), _cls)

_ROUTE_MAXLEN = max(len(k) for k in list(_CLASS_INDEX) + list(_STATE_FORM_INDEX))
_AFTER_MAXLEN = max(len(k) for k in _AFTER_STATE_INDEX)

_STATE_LOOKUP = {}
for _abbr, (_name, _forms, _pfx, _words, _nick) in STATES.items():
    for _f in [_abbr, _name] + _forms:
        _STATE_LOOKUP[_norm_phrase(_f)] = _abbr
_STATE_LOOKUP.update(STATE_INPUT_EXTRAS)

_STATEY = {"STATE", "GENERIC"}
_LETTER_CLASSES = {"COUNTY", "GENERIC", "TOWNSHIP"}
_NOT_ROUTE_CODES = {"ne", "nw", "se", "sw", "nb", "sb", "eb", "wb", "of", "at", "to",
                    "on", "in", "by", "the", "and"}


def resolve_state(text):
    if not text:
        return None
    t = _norm_phrase(str(text))
    if t in _STATE_LOOKUP:
        return _STATE_LOOKUP[t]
    return None


def state_name(abbr):
    return STATES[abbr][0] if abbr in STATES else (abbr or "").upper()


def _route_number(tok, cls, state):
    if re.fullmatch(r"\d{1,4}[a-z]?", tok) and not _ORD_RE.fullmatch(tok):
        return tok.upper()
    if (cls in _LETTER_CLASSES or (cls == "STATE" and state == "mo")) \
            and re.fullmatch(r"[a-z]{1,2}", tok) \
            and tok not in _TYPE_WORDS and tok not in _NOT_ROUTE_CODES:
        return tok.upper()
    return None


def _num_rx(num):
    m = re.fullmatch(r"(\d+)([A-Z]*)", num)
    if m and m.group(2):
        return f"{m.group(1)}[ -]*{m.group(2)}"
    return num


def _state_prefixes(abbr):
    name, forms, pfx, words, _ = STATES[abbr]
    return [abbr.upper(), name] + forms + pfx, STATE_ROUTE_WORDS + words


def _route_render(cls, num, state, ctx):
    n = num
    display, parts = [], []

    if cls in _STATEY:
        st = state or ctx
        same_state = ctx is None or st is None or st == ctx
        if st in STATES:
            prefixes, words = _state_prefixes(st)
            name = STATES[st][0]
            up = st.upper()
            display += [f"{p}-{n}" for p in STATES[st][2]]
            display += [f"{p} {n}" for p in STATES[st][2]]
            display += [f"{up} {n}", f"{up}-{n}", f"{up}{n}", f"{name} Route {n}",
                        f"{name} State Route {n}", f"{name} Highway {n}",
                        f"{name} State Highway {n}", f"{up} Route {n}", f"{up} Highway {n}",
                        f"{name} {n}"]
            display += [f"{name} {w} {n}" for w in STATES[st][3]]
            parts.append(
                f"{_rx_alt(_rx_phrase(p) for p in prefixes)}"
                f"([ -]*{_rx_alt(_rx_phrase(w) for w in words)})?"
            )
        if same_state or cls == "GENERIC":
            display += [d.format(n=n) for d in STATE_AGNOSTIC_DISPLAY]
            parts.append(_rx_alt(_rx_phrase(p) for p in
                                 ROUTE_CLASSES["STATE"] + ROUTE_CLASSES["GENERIC"]))
        if cls == "GENERIC":
            display += [f"US {n}", f"US Route {n}", f"US Highway {n}"]
            parts.append(_rx_alt(_rx_phrase(p) for p in ROUTE_CLASSES["US"]))
    else:
        display += [d.format(n=n) for d in ROUTE_DISPLAY.get(cls, [])]
        if cls == "US":
            display += [f"Route {n}", f"Highway {n}", f"Hwy {n}"]
            parts.append(_rx_alt(_rx_phrase(p) for p in
                                 ROUTE_CLASSES["US"] + ROUTE_CLASSES["GENERIC"]))
        else:
            parts.append(_rx_alt(_rx_phrase(p) for p in ROUTE_CLASSES[cls]))

    display = list(dict.fromkeys(display))
    body = parts[0] if len(parts) == 1 else "(" + "|".join(parts) + ")"
    if not body.startswith("("):
        body = f"({body})"
    return display, f"{body}[ -]*{_num_rx(n)}"


def _route_elem(cls, num, state, ctx):
    display, rx = _route_render(cls, num, state, ctx)
    return Elem("route", ("r", cls, num, state), display, rx)


def _try_route(toks, i, ctx):
    n = len(toks)
    for L in range(min(_ROUTE_MAXLEN, n - i - 1), 0, -1):
        key = tuple(t[0] for t in toks[i:i + L])
        j = i + L
        cls = _CLASS_INDEX.get(key)
        if cls:
            num = _route_number(toks[j][0], cls, ctx)
            if num:
                return _route_elem(cls, num, ctx if cls in _STATEY else None, ctx), j + 1
        st = _STATE_FORM_INDEX.get(key)
        if st:
            abbr, needs_ctx = st
            if needs_ctx and ctx not in (None, abbr):
                continue
            num = _route_number(toks[j][0], "STATE", abbr)
            if num:
                return _route_elem("STATE", num, abbr, ctx), j + 1
            for L2 in range(min(_AFTER_MAXLEN, n - j - 1), 0, -1):
                k2 = tuple(t[0] for t in toks[j:j + L2])
                cls2 = _AFTER_STATE_INDEX.get(k2)
                if cls2:
                    num = _route_number(toks[j + L2][0], cls2, abbr)
                    if num:
                        return _route_elem(cls2, num, abbr, ctx), j + L2 + 1
    return None


def _try_index(toks, i, index, maxlen):
    n = len(toks)
    for L in range(min(maxlen, n - i), 0, -1):
        key = tuple(t[0] for t in toks[i:i + L])
        if key in index:
            return index[key], L
    return None


def _orig(toks, i, L):
    return " ".join(t[1] for t in toks[i:i + L])


def _rename_at(toks, i, ctx, county):
    n = len(toks)
    for L in range(min(_RENAME_MAXLEN, n - i), 0, -1):
        rids = _RENAME_INDEX.get(tuple(t[0] for t in toks[i:i + L]))
        for rid in rids or ():
            st, fips, _, _ = _RENAMES[rid]
            if ctx == st and county in fips:
                return rid, L
    return None


def parse_uncached(name, ctx=None, county=None):
    toks = tokenize(name)
    n = len(toks)
    trailing = [t[0] in _TRAILING_WORDS for t in toks]
    suffix_pos = [all(trailing[i + 1:]) for i in range(n)]
    elems = []
    i = 0
    while i < n:
        r = _try_route(toks, i, ctx)
        if r:
            elems.append(r[0])
            i = r[1]
            continue

        hit = _rename_at(toks, i, ctx, county) if county else None
        if hit:
            rid, L = hit
            forms = _RENAMES[rid][3]
            elems.append(Elem("named", ("n", rid), forms,
                              _rx_alt(_rx_phrase(f) for f in forms)))
            i += L
            continue

        hit = _try_index(toks, i, _NAMED_INDEX, _NAMED_MAXLEN)
        if hit:
            nid, L = hit
            forms = _NAMED[nid]
            elems.append(Elem("named", ("n", nid), forms,
                              _rx_alt(_rx_phrase(f) for f in forms)))
            i += L
            continue

        hit = _try_index(toks, i, _STAVE_INDEX, _STAVE_MAXLEN)
        if hit:
            (abbr, needs_upper), L = hit
            nxt = toks[i + L][0] if i + L < n else ""
            if nxt in _AVENUE_WORDS and (not needs_upper or toks[i][1].isupper()):
                name_, _, _, _, nick = STATES[abbr]
                forms = [name_] + nick
                elems.append(Elem("group", ("g", "stave:" + abbr), forms,
                                  _rx_alt(_rx_phrase(f) for f in forms)))
                i += L
                continue

        tok = toks[i][0]
        m = _ORD_RE.fullmatch(tok)
        hit = None if m else _try_index(toks, i, _ORD_INDEX, 2)
        if m or hit:
            num = int(m.group(1)) if m else hit[0]
            L = 1 if m else hit[1]
            forms = [f"{num}{_ordinal_suffix(num)}"]
            if 1 <= num <= 99:
                forms.append(_ordinal_word(num))
            elems.append(Elem("ordinal", ("o", num), forms,
                              _rx_alt(_rx_phrase(f) for f in forms)))
            i += L
            continue

        if tok in _SPECIAL:
            gid = _SPECIAL[tok][0] if suffix_pos[i] else _SPECIAL[tok][1]
            L = 1
        else:
            hit = _try_index(toks, i, _GROUP_INDEX, _GROUP_MAXLEN)
            gid, L = hit if hit else (None, 0)
        if gid:
            forms = _GROUPS[gid]
            if (_GROUP_KIND[gid] == "dir" and L == 1 and len(tok) == 1 and i == 0
                    and i + 1 < n and toks[i + 1][0] in _TYPE_WORDS and suffix_pos[i + 1]):
                forms = [toks[i][1].upper()]
            elems.append(Elem("group", ("g", gid), forms,
                              _rx_alt(_rx_phrase(f) for f in forms)))
            i += L
            continue

        orig = toks[i][1]
        elems.append(Elem("word", ("w", tok), [orig], _rx_literal(orig.replace(".", "")
                                                                     if len(tok) > 1 else orig)))
        i += 1
    return tuple(elems)


@lru_cache(maxsize=300000)
def parse(name, ctx=None, county=None):
    return parse_uncached(name, ctx, county)


def _elem_eq(a, b):
    if a.kind == "route" and b.kind == "route":
        _, c1, n1, s1 = a.key
        _, c2, n2, s2 = b.key
        if n1 != n2:
            return False
        if c1 != c2:
            pair = {c1, c2}
            if not ("GENERIC" in pair and pair & {"STATE", "US"}):
                return False
        if c1 in _STATEY and c2 in _STATEY and s1 and s2 and s1 != s2:
            return False
        return True
    return a.key == b.key


def _ctx(state):
    if not state:
        return None
    s = str(state).strip().lower()
    return s if s in STATES else resolve_state(state)


def _county(county):
    county = str(county or "").strip()
    return county if re.fullmatch(r"\d{5}", county) else None


class RoadMatcher:
    def __init__(self, road_name, state=None, county=None):
        self.ctx = _ctx(state)
        self.county = _county(county)
        self.road_name = road_name
        self.query = parse(road_name, self.ctx, self.county)

    def matches(self, candidate, contains=True):
        if not isinstance(candidate, str) or not candidate.strip() or not self.query:
            return False
        cand = parse(candidate, self.ctx, self.county)
        q = self.query
        m, n = len(q), len(cand)
        if not contains:
            return m == n and all(_elem_eq(a, b) for a, b in zip(q, cand))
        for i in range(n - m + 1):
            if all(_elem_eq(q[k], cand[i + k]) for k in range(m)):
                return True
        return False


def overpass_regex(road_name, state=None, county=None):
    elems = parse(road_name, _ctx(state), _county(county))
    return "[ -]*".join(e.rx for e in elems)


def overpass_tag_regex(road_name, state=None, county=None):
    return f"(^|;) *{overpass_regex(road_name, state, county)} *(;|$)"


def expand_variants(road_name, state=None, limit=500, county=None):
    elems = parse(road_name, _ctx(state), _county(county))
    if not elems:
        return [road_name] if road_name else []
    out = [road_name.strip()]
    for combo in islice(product(*[e.alts for e in elems]), limit * 4):
        s = " ".join(combo)
        if s not in out:
            out.append(s)
        if len(out) >= limit:
            break
    return out


def count_variants(road_name, state=None, county=None):
    total = 1
    for e in parse(road_name, _ctx(state), _county(county)):
        total *= max(1, len(e.alts))
    return total


def rename_hint(road_name, state=None, county=None):
    ctx, county = _ctx(state), _county(county)
    toks = tokenize(road_name)
    for i in range(len(toks)):
        for L in range(min(_RENAME_MAXLEN, len(toks) - i), 0, -1):
            for rid in _RENAME_INDEX.get(tuple(t[0] for t in toks[i:i + L]), ()):
                st, fips, where, forms = _RENAMES[rid]
                if st == ctx and county not in fips:
                    others = [f for f in (RENAMED_ROADS[int(rid[6:rid.index(":")])][3])]
                    return (f"'{road_name}' matches a road renamed in {where} "
                            f"({' / '.join(others)}). Add that county with --county "
                            "to search both names.")
    return None


def describe(road_name, state=None, sample=25, county=None):
    ctx, county = _ctx(state), _county(county)
    where = state_name(ctx) if ctx else ""
    if county:
        where += f", county {county}"
    lines = [f"Road: {road_name!r}" + (f"   (searching in {where})" if where else "")]
    for e in parse(road_name, ctx, county):
        lines.append(f"  [{e.kind:7}] " + " | ".join(e.alts[:14])
                     + (f"  (+{len(e.alts) - 14} more)" if len(e.alts) > 14 else ""))
    total = count_variants(road_name, ctx, county)
    lines.append(f"  {total} spelling combination(s); first {min(sample, total)}:")
    for v in expand_variants(road_name, ctx, limit=sample, county=county):
        lines.append(f"    {v}")
    hint = rename_hint(road_name, ctx, county)
    if hint:
        lines.append(f"  Note: {hint}")
    lines.append("  Overpass regex:")
    lines.append(f"    {overpass_tag_regex(road_name, ctx, county)}")
    return "\n".join(lines)
