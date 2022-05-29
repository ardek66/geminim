import parsecfg, strutils, tables, os, streams
export tables

type
  ZoneType* = enum
    ZoneNull
    ZoneRedirect
    ZoneRedirectPerm
    ZoneCGI
    ZoneInputCGI
    ZoneCert

  Zone* = object
    key*, val*: string
    ztype*: ZoneType

  ZoneBucket = tuple
    shortest, longest: int
  
  VHost = object
    zones*: seq[Zone]
    zoneBuckets: seq[ZoneBucket]
  
  Settings* = object
    rootDir*: string
    port*: int
    certFile*, keyFile*: string
    vhosts*: Table[string, VHost]
    homeDir*: string
    dirHeader*: string
    titanSettings*: TitanSettings

  TitanSettings* = object
    password*: string
    passwordRequired*: bool
    uploadLimit*: int
    redirect*: bool

const defaultHome =
  when defined(posix): "/home/$#/"
  else: "C:\\Users\\$#\\"

proc insertSort(a: var seq[Zone], x: Zone) =
  a.setLen(a.len + 1)
  var i = a.high
  
  while i > 0 and a[i-1].key > x.key:
    a[i] = a[i-1]
    dec i

  a[i] = x

# Learning romanian would be easier than reading the thing below
proc initZoneParents(v: var Vhost) =
  v.zoneBuckets.setLen(v.zones.len)
  
  var
    i, j: int
  
  while i < v.zones.len:
    j = i + 1
    
    while j < v.zones.len:
      if v.zones[j].key.isRelativeTo v.zones[i].key:
        v.zoneBuckets[j] = (i, i) # Initialise both shortest and longest path to the same value
      else:
        v.zoneBuckets[j] = (j, j)
        break
      inc j

    i = j

  for i in 0..v.zones.high:
    j = i + 1
    
    while j < v.zones.len:
      if v.zoneBuckets[j].shortest != v.zoneBuckets[j-1].shortest: break
      if v.zones[j].key.isRelativeTo v.zones[i].key:
        v.zoneBuckets[j].longest = i
        
      inc j


proc findZone*(a: VHost, p: string): Zone =
  case a.zones.len
  of 0: return
  of 1:
    if p.isRelativeTo a.zones[0].key: return a.zones[0]
  else:
    var
      i = 0
      j = a.zones.len
    
    while i < j:
      let
        m = (i+j) div 2
        res = cmp(p, a.zones[m].key)
      if res > 0: i = m + 1
      elif res < 0: j = m
      else: return a.zones[m]

    if i < 1:
      if p.isRelativeTo a.zones[0].key:
        return a.zones[0]
    else:
      var j = i - 1
      let minIdx = a.zoneBuckets[j].shortest
      
      if p.isRelativeTo a.zones[minIdx].key:
        result = a.zones[minIdx]
        while j > minIdx:
          if p.isRelativeTo a.zones[j].key:
            return a.zones[j]
          
          j = a.zoneBuckets[j].longest

proc readSettings*(path: string): Settings =
  result = Settings(
    rootDir: "pub/",
    port: 1965,
    certFile: "mycert.pem",
    keyFile: "mykey.pem",
    homeDir: defaultHome,
    dirHeader: "header.gemini",
    titanSettings: TitanSettings(
      password: "titanpassword",
      passwordRequired: true,
      uploadLimit: 10485760,
      redirect: true)
  )

  var f = newFilestream(path, fmRead)
  if f != nil:
    var p: CfgParser
    p.open(f, path)

    var
      section: string
      keyval: seq[string]
    while true:
      var e = next(p)
      case e.kind
      of cfgEof: break
      of cfgError: echo e.msg
      of cfgSectionStart:
        section = e.section
        keyval = section.split('/', 1)
      of cfgKeyValuePair:
        if section.len == 0:
          case e.key.toLowerAscii
          of "rootdir": result.rootDir = e.value
          of "port": result.port = e.value.parseInt
          of "certfile": result.certfile = e.value
          of "keyfile": result.keyfile = e.value
          of "homedir": result.homeDir = e.value
          of "dirheader": result.dirHeader = e.value
        elif section == "titan":
          case e.key.toLowerAscii
          of "password": result.titanSettings.password = e.value
          of "passwordrequired": result.titanSettings.passwordRequired = e.value.parseBool
          of "uploadlimit": result.titanSettings.uploadLimit = e.value.parseInt
          of "redirect": result.titanSettings.redirect = e.value.parseBool
        else:
          let zoneType =
            case keyval[1]
            of "redirectZones": ZoneRedirect
            of "permRedirectZones": ZoneRedirectPerm
            of "cgiZones": ZoneCGI
            of "inputCgiZones": ZoneInputCGI
            of "restrictedZones": ZoneCert
            else: ZoneNull

          if zoneType == ZoneNull:
            echo "Option " & keyval[1] & " does not exist."
          else:
            let zone = Zone(key: e.key, val: e.value, ztype: zoneType)
            if result.vhosts.hasKeyOrPut(keyval[0], VHost(zones: @[zone])):
              result.vhosts[keyval[0]].zones.insertSort zone
      else: discard
      
    p.close()
    for host in result.vhosts.mvalues:
      host.initZoneParents()
