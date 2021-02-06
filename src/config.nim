import parsecfg, strutils, strtabs, os, streams

type CgiConf = tuple
  dir, virtDir: string

type Settings* = object
  port*: int
  certFile*, keyFile*: string
  vhosts*: StringTableRef
  redirects*: StringTableRef
  authZones*: StringTableRef
  homeDir*: string
  certsDir*: string
  dirHeader*: string
  cgi*: CgiConf

const defaultHome =
  when defined(posix): "/home/$#/"
  else: "C:\\Users\\$#\\"

proc readSettings*(path: string): Settings =
  result = Settings(
    port: 1965,
    certFile: "mycert.pem",
    keyFile: "mykey.pem",
    vhosts: newStringTable(modeCaseSensitive),
    redirects: newStringTable(modeCaseSensitive),
    authZones: newStringTable(modeCaseSensitive),
    homeDir: defaultHome,
    certsDir: "certs",
    dirHeader: "header.gemini",
    cgi: (dir: "cgi/", virtDir: ""))

  var f = newFilestream(path, fmRead)
  if f != nil:
    var p: CfgParser
    p.open(f, path)

    var section: string
    while true:
      var e = next(p)
      case e.kind
      of cfgEof: break
      of cfgError: echo e.msg
      of cfgSectionStart: section = e.section
      of cfgKeyValuePair:
        case section.toLowerAscii
        of "":
          case e.key.toLowerAscii
          of "port": result.port = e.value.parseInt
          of "certfile": result.certfile = e.value
          of "keyfile": result.keyfile = e.value
          of "homedir": result.homeDir = e.value
          of "certsdir": result.certsDir = e.value
          of "dirheader": result.dirHeader = e.value
        of "vhosts":
          if dirExists(e.value):
            result.vhosts[e.key] = e.value
          else:
            echo e.value & " does not exist or is not a directory"
            echo "Not adding " & e.key & " to hosts\n"
        of "redirects":
          result.redirects[e.key] = e.value
        of "authorizedzones":
          result.authZones[e.key] = e.value
        of "cgi":
          case e.key.toLowerAscii
          of "dir":
            if dirExists(e.value): result.cgi.dir = e.value
            else: echo "CGI directory " & e.value & " does not exist\n"
          of "virtdir": result.cgi.virtDir = e.value

      else: discard
