// Tables from road_aliases.py, unchanged. Add to them freely; the first form in each list
// is the "full" spelling, and forms starting with "~" are accepted when reading names but
// never generated as search terms.

// swiftlint:disable line_length

/// postal code -> (full name, other written forms, route-only prefixes, extra route words, avenue nicknames)
struct StateRow {
    let abbr: String
    let name: String
    let forms: [String]
    let prefixes: [String]
    let words: [String]
    let nicknames: [String]
}

enum AliasTables {
    static let states: [StateRow] = [
        StateRow(abbr: "al", name: "Alabama", forms: ["Ala."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "ak", name: "Alaska", forms: [], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "az", name: "Arizona", forms: ["Ariz."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "ar", name: "Arkansas", forms: ["Ark."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "ca", name: "California", forms: ["Calif.", "Cal."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "co", name: "Colorado", forms: ["Colo."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "ct", name: "Connecticut", forms: ["Conn."], prefixes: [], words: [], nicknames: ["Conn", "CT"]),
        StateRow(abbr: "de", name: "Delaware", forms: ["Del."], prefixes: [], words: [], nicknames: ["Del"]),
        StateRow(abbr: "dc", name: "District of Columbia", forms: ["D.C."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "fl", name: "Florida", forms: ["Fla."], prefixes: [], words: ["State Road"], nicknames: []),
        StateRow(abbr: "ga", name: "Georgia", forms: ["Ga."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "hi", name: "Hawaii", forms: [], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "id", name: "Idaho", forms: ["Ida."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "il", name: "Illinois", forms: ["Ill."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "in", name: "Indiana", forms: ["Ind."], prefixes: [], words: ["State Road"], nicknames: []),
        StateRow(abbr: "ia", name: "Iowa", forms: [], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "ks", name: "Kansas", forms: ["Kan.", "Kans."], prefixes: ["K"], words: [], nicknames: []),
        StateRow(abbr: "ky", name: "Kentucky", forms: ["Ky."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "la", name: "Louisiana", forms: ["La."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "me", name: "Maine", forms: [], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "md", name: "Maryland", forms: ["Md."], prefixes: [], words: [], nicknames: ["MD"]),
        StateRow(abbr: "ma", name: "Massachusetts", forms: ["Mass."], prefixes: [], words: [], nicknames: ["Mass", "MA"]),
        StateRow(abbr: "mi", name: "Michigan", forms: ["Mich."], prefixes: ["M"], words: ["State Trunkline", "Trunkline"], nicknames: ["Mich"]),
        StateRow(abbr: "mn", name: "Minnesota", forms: ["Minn."], prefixes: ["MNTH"], words: ["Trunk Highway", "State Trunk Highway"], nicknames: []),
        StateRow(abbr: "ms", name: "Mississippi", forms: ["Miss."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "mo", name: "Missouri", forms: ["Mo."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "mt", name: "Montana", forms: ["Mont."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "ne", name: "Nebraska", forms: ["Neb.", "Nebr."], prefixes: ["N"], words: [], nicknames: []),
        StateRow(abbr: "nv", name: "Nevada", forms: ["Nev."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "nh", name: "New Hampshire", forms: ["N.H."], prefixes: [], words: [], nicknames: ["NH"]),
        StateRow(abbr: "nj", name: "New Jersey", forms: ["N.J."], prefixes: [], words: [], nicknames: ["NJ"]),
        StateRow(abbr: "nm", name: "New Mexico", forms: ["N.M.", "N.Mex."], prefixes: [], words: ["State Road"], nicknames: ["NM"]),
        StateRow(abbr: "ny", name: "New York", forms: ["N.Y."], prefixes: ["NYS"], words: [], nicknames: ["NY"]),
        StateRow(abbr: "nc", name: "North Carolina", forms: ["N.C."], prefixes: [], words: [], nicknames: ["NC"]),
        StateRow(abbr: "nd", name: "North Dakota", forms: ["N.D.", "N.Dak."], prefixes: [], words: [], nicknames: ["ND"]),
        StateRow(abbr: "oh", name: "Ohio", forms: [], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "ok", name: "Oklahoma", forms: ["Okla."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "or", name: "Oregon", forms: ["Ore.", "Oreg."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "pa", name: "Pennsylvania", forms: ["Pa.", "Penna.", "Penn."], prefixes: [], words: [], nicknames: ["Penn", "PA"]),
        StateRow(abbr: "ri", name: "Rhode Island", forms: ["R.I."], prefixes: [], words: [], nicknames: ["RI"]),
        StateRow(abbr: "sc", name: "South Carolina", forms: ["S.C."], prefixes: [], words: [], nicknames: ["SC"]),
        StateRow(abbr: "sd", name: "South Dakota", forms: ["S.D.", "S.Dak."], prefixes: [], words: [], nicknames: ["SD"]),
        StateRow(abbr: "tn", name: "Tennessee", forms: ["Tenn."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "tx", name: "Texas", forms: ["Tex."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "ut", name: "Utah", forms: [], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "vt", name: "Vermont", forms: ["Vt."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "va", name: "Virginia", forms: ["Va."], prefixes: [], words: [], nicknames: ["VA"]),
        StateRow(abbr: "wa", name: "Washington", forms: ["Wash."], prefixes: [], words: [], nicknames: []),
        StateRow(abbr: "wv", name: "West Virginia", forms: ["W.Va.", "W. Va.", "W.V."], prefixes: [], words: [], nicknames: ["WV"]),
        StateRow(abbr: "wi", name: "Wisconsin", forms: ["Wis.", "Wisc."], prefixes: ["WIS", "STH"], words: ["State Trunk Highway", "Trunk Highway"], nicknames: ["Wisc"]),
        StateRow(abbr: "wy", name: "Wyoming", forms: ["Wyo."], prefixes: ["WYO"], words: [], nicknames: []),
    ]

    static let stateInputExtras: [(String, String)] = [
        ("washington state", "wa"), ("wash state", "wa"), ("wa state", "wa"),
        ("washington dc", "dc"), ("washington d c", "dc"), ("wash dc", "dc"),
        ("district of columbia", "dc"), ("the district", "dc"), ("d c", "dc"),
        ("n mex", "nm"), ("n dak", "nd"), ("s dak", "sd"), ("w va", "wv"),
    ]

    /// Route classes in the order road_aliases.py defines them.
    static let routeClassOrder = ["I", "US", "STATE", "GENERIC", "COUNTY", "TOWNSHIP", "FM", "LOOP",
                                  "SPUR", "PARK", "BELTWAY", "FOREST", "BIA"]

    static let routeClasses: [String: [String]] = [
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
    ]

    static let routeDisplay: [String: [String]] = [
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
    ]

    static let stateRouteWords = ["Route", "Rte", "Rt", "Highway", "Hwy", "State Route",
                                  "State Rte", "State Highway", "State Hwy", "State Road",
                                  "State Rd", "SR", "SH"]

    static let stateAgnosticDisplay = ["State Route {n}", "SR {n}", "SR-{n}", "State Highway {n}",
                                       "SH {n}", "State Road {n}", "Route {n}", "Rte {n}",
                                       "Highway {n}", "Hwy {n}"]

    static let streetTypes: [[String]] = [
        ["Alley", "Aly", "Ally"], ["Annex", "Anx"], ["Arcade", "Arc"],
        ["Avenue", "Ave", "Av", "~Aven", "~Avenu", "~Avn", "~Avnue"],
        ["Bayou", "Byu"], ["Beach", "Bch"], ["Bend", "Bnd"], ["Bluff", "Blf"], ["Bluffs", "Blfs"],
        ["Bottom", "Btm"], ["Boulevard", "Blvd", "Boul", "~Boulv"], ["Branch", "Br", "~Brnch"],
        ["Bridge", "Brg", "~Brdge"], ["Brook", "Brk"], ["Brooks", "Brks"],
        ["Bypass", "Byp", "~Bypa", "~Byps"], ["Camp", "Cp"], ["Canyon", "Cyn", "~Cnyn"],
        ["Cape", "Cpe"], ["Causeway", "Cswy", "~Causwa"], ["Center", "Ctr", "Centre", "~Cntr"],
        ["Circle", "Cir", "~Circ", "~Crcl"], ["Cliff", "Clf"], ["Cliffs", "Clfs"], ["Club", "Clb"],
        ["Common", "Cmn"], ["Commons", "Cmns"], ["Corner", "Cor"], ["Corners", "Cors"],
        ["Course", "Crse"], ["Court", "Ct", "~Crt"], ["Courts", "Cts"], ["Cove", "Cv"],
        ["Creek", "Crk"], ["Crescent", "Cres", "~Crsnt"], ["Crest", "Crst"],
        ["Crossing", "Xing", "~Crssng"], ["Crossroad", "Xrd"], ["Crossroads", "Xrds"],
        ["Curve", "Curv"], ["Dale", "Dl"], ["Dam", "Dm"], ["Divide", "Dv", "~Dvd"],
        ["Drive", "Dr", "Drv"], ["Drives", "Drs"], ["Esplanade", "Esp"], ["Estate", "Est"],
        ["Estates", "Ests"], ["Expressway", "Expy", "Expwy", "~Expw", "~Exwy"],
        ["Extension", "Ext", "~Extn", "~Extd", "~Exd"], ["Extensions", "Exts"], ["Falls", "Fls"],
        ["Ferry", "Fry"], ["Field", "Fld"], ["Fields", "Flds"], ["Flat", "Flt"], ["Flats", "Flts"],
        ["Ford", "Frd"], ["Forest", "Frst"], ["Forge", "Frg"], ["Fork", "Frk"], ["Forks", "Frks"],
        ["Fort", "Ft"], ["Freeway", "Fwy", "Frwy", "~Frway"], ["Garden", "Gdn"], ["Gardens", "Gdns"],
        ["Gateway", "Gtwy"], ["Glen", "Gln"], ["Green", "Grn"], ["Grove", "Grv"],
        ["Harbor", "Hbr", "Harbour"], ["Haven", "Hvn"], ["Heights", "Hts", "~Hgts"],
        ["Highway", "Hwy", "Hiway", "~Hgwy"], ["Hill", "Hl"], ["Hills", "Hls"], ["Hollow", "Holw"],
        ["Inlet", "Inlt"], ["Island", "Is"], ["Islands", "Iss"], ["Junction", "Jct", "~Jctn"],
        ["Key", "Ky"], ["Knoll", "Knl"], ["Lake", "Lk"], ["Lakes", "Lks"], ["Landing", "Lndg"],
        ["Lane", "Ln"], ["Light", "Lgt"], ["Lock", "Lck"], ["Lodge", "Ldg"], ["Loop", "Lp"],
        ["Manor", "Mnr"], ["Meadow", "Mdw"], ["Meadows", "Mdws"], ["Mill", "Ml"], ["Mills", "Mls"],
        ["Mission", "Msn"], ["Motorway", "Mtwy"], ["Mount", "Mt", "~Mnt"], ["Mountain", "Mtn"],
        ["Neck", "Nck"], ["Orchard", "Orch"], ["Overpass", "Opas"],
        ["Parkway", "Pkwy", "Pky", "~Pkway", "~Pwy"], ["Passage", "Psge"], ["Pine", "Pne"],
        ["Pines", "Pnes"], ["Place", "Pl"], ["Plain", "Pln"], ["Plains", "Plns"],
        ["Plaza", "Plz", "~Plza"], ["Point", "Pt"], ["Points", "Pts"], ["Port", "Prt"],
        ["Promenade", "Prom"], ["Radial", "Radl"], ["Ranch", "Rnch"], ["Rapids", "Rpds"],
        ["Ridge", "Rdg"], ["Ridges", "Rdgs"], ["River", "Riv"], ["Road", "Rd"], ["Roads", "Rds"],
        ["Route", "Rte", "Rt"], ["Shoal", "Shl"], ["Shore", "Shr"], ["Shores", "Shrs"],
        ["Skyway", "Skwy"], ["Spring", "Spg"], ["Springs", "Spgs"], ["Square", "Sq", "~Sqr"],
        ["Station", "Sta", "~Stn"], ["Stravenue", "Stra"], ["Stream", "Strm"],
        ["Street", "St", "Str"], ["Streets", "Sts"], ["Summit", "Smt"], ["Terrace", "Ter", "Terr"],
        ["Throughway", "Thruway", "Trwy", "Thwy"], ["Trace", "Trce"], ["Track", "Trak"],
        ["Trafficway", "Trfy"], ["Trail", "Trl", "Tr"], ["Tunnel", "Tunl"],
        ["Turnpike", "Tpke", "Tpk", "~Tnpk", "~Trpk"], ["Underpass", "Upas"], ["Valley", "Vly"],
        ["View", "Vw"], ["Village", "Vlg"], ["Vista", "Vis", "~Vst"], ["Way", "Wy"], ["Well", "Wl"],
        ["Wells", "Wls"],
    ]

    static let directionals: [[String]] = [
        ["North", "N"], ["South", "S"], ["East", "E"], ["West", "W"],
        ["Northeast", "NE", "N.E.", "North East"], ["Northwest", "NW", "N.W.", "North West"],
        ["Southeast", "SE", "S.E.", "South East"], ["Southwest", "SW", "S.W.", "South West"],
        ["Northbound", "NB"], ["Southbound", "SB"], ["Eastbound", "EB"], ["Westbound", "WB"],
    ]

    static let modifiers: [[String]] = [
        ["Business", "Bus", "Busn"], ["Alternate", "Alt"], ["Truck", "Trk"], ["Connector", "Conn"],
        ["Express", "Exp"], ["HOV"], ["Toll"], ["Service", "Svc", "~Serv"], ["Frontage", "Frtg"],
        ["Ramp"], ["Spur"],
    ]

    static let words: [[String]] = [
        ["Saint", "St"], ["Sainte", "Ste"], ["Doctor", "Dr"], ["Junior", "Jr"], ["Senior", "Sr"],
        ["General", "Gen"], ["President", "Pres"], ["Governor", "Gov"], ["Senator", "Sen"],
        ["Reverend", "Rev"], ["Captain", "Capt"], ["Colonel", "Col"], ["Lieutenant", "Lt"],
        ["Admiral", "Adm"], ["Sergeant", "Sgt"], ["Professor", "Prof"], ["Monsignor", "Msgr"],
        ["Corporal", "Cpl"], ["Commander", "Cmdr"], ["Major", "Maj"], ["Private", "Pvt"],
        ["Memorial", "Meml", "Mem"], ["National", "Natl"], ["International", "Intl"],
        ["Industrial", "Indl"], ["University", "Univ"], ["Airport", "Arpt"],
        ["County", "Co", "Cnty"], ["Township", "Twp"], ["Upper", "Upr"], ["Lower", "Lwr"],
        ["Little", "Ltl"], ["Railroad", "RR"], ["Railway", "Rwy"], ["and", "&"],
    ]

    static let namedRoads: [[String]] = [
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

    /// (state, county FIPS codes, where, [new name, old name, ...]): the names are the
    /// same road ONLY inside the listed counties.
    static let renamedRoads: [(state: String, fips: [String], whereText: String, forms: [String])] = [
        ("va", ["51013"], "Arlington County, VA", ["Langston Boulevard", "Lee Highway"]),
        ("va", ["51013", "51510"], "Arlington County and Alexandria, VA",
         ["Richmond Highway", "Jefferson Davis Highway"]),
        ("tx", ["48453"], "Austin (Travis County), TX", ["Azie Morton Road", "Robert E Lee Road"]),
        ("tx", ["48453"], "Austin (Travis County), TX", ["William Holland Avenue", "Jeff Davis Avenue"]),
        ("tx", ["48201"], "Houston (Harris County), TX", ["Emancipation Avenue", "Dowling Street"]),
    ]
}
