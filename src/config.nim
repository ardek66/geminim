import parsecfg, strutils, tables, os, streams
export tables

type
  ZoneType* = enum
    ZoneNull
    ZoneRedirect
    ZoneRedirectPerm
    ZoneCGI
    ZoneInputCGI

  Zone* = object
    parentIdx: int
    key*, val*: string
    ztype*: ZoneType

  VHost = object
    rootDir*: string
    zones*: seq[Zone]
  
  Settings* = object
    port*: int
    certFile*, keyFile*: string
    vhosts*: Table[string, VHost]
    homeDir*: string
    dirHeader*: string

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
  a[i].parentIdx = -1
  
  var j = i - 1
  while j > -1:
    if a[i].key.isRelativeTo a[j].key:
      a[i].parentIdx = if a[j].parentIdx < 0: j
                       else: a[j].parentIdx
      break
    else:
      j = a[j].parentIdx

proc findZone*(a: VHost, p: string): Zone =
  case a.zones.len
  of 0: return
  of 1:
    if p.isRelativeTo a.zones[0].key: return a.zones[0]
  else:
    var
      i = 0
      j = a.zones.high
      m: int
    
    while i <= j:
      m = (i+j) div 2
      
      let res = cmp(p, a.zones[m].key)
      if res > 0: i = m+1
      elif res < 0: j = m-1
      else: return a.zones[m]

    while m > -1:
      if p.isRelativeTo a.zones[m].key:
        return a.zones[m]

      m = a.zones[m].parentIdx

proc readSettings*(path: string): Settings =
  result = Settings(
    port: 1965,
    certFile: "mycert.pem",
    keyFile: "mykey.pem",
    homeDir: defaultHome,
    dirHeader: "header.gemini")

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
          of "port": result.port = e.value.parseInt
          of "certfile": result.certfile = e.value
          of "keyfile": result.keyfile = e.value
          of "homedir": result.homeDir = e.value
          of "dirheader": result.dirHeader = e.value
        else:
          if keyval.len == 1 and e.key == "rootDir":
            if dirExists(e.value):
              result.vhosts[keyval[0]] = VHost(rootDir: e.value)
            else:
              echo e.value & " does not exist or is not a directory"
              echo "Not adding " & e.key & " to hosts\n"
          elif result.vhosts.hasKey(keyval[0]):
            let zoneType =
              case keyval[1]
              of "redirectZones": ZoneRedirect
              of "permRedirectZones": ZoneRedirectPerm
              of "cgiZones": ZoneCGI
              of "inputCgiZones": ZoneInputCGI
              else: ZoneNull

            if zoneType == ZoneNull:
              echo "Option " & keyval[1] & " does not exist."
            else:
              result.vhosts[keyval[0]].zones.insertSort Zone(key: e.key,
                                                             val: e.value,
                                                             ztype: zoneType)
      else: discard
