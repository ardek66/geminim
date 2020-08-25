import parsecfg, strutils, strtabs, os

type CgiConf = tuple
  dir, virtDir: string

type Settings* = object
  vhosts*: StringTableRef
  port*: int
  certFile*, keyFile*: string
  homeDir*: string
  cgi*: CgiConf

const defaultHome =
  when defined(posix): "/home/"
  else: "C:\\Users\\"

proc get(dict: Config, value, default: string, section = ""): string =
  result = dict.getSectionValue(section, value)
  if result.len < 1: return default

proc readSettings*(path: string): Settings =
  let conf = loadConfig(path)

  result = Settings(
    vhosts: newStringTable(modeCaseSensitive),
    port: conf.get("port", "1965").parseInt,
    certFile: conf.get("certFile", "mycert.pem"),
    keyFile: conf.get("keyFile", "mykey.pem"),
    homeDir: conf.get("homeDir", defaultHome),
    cgi: (dir: conf.get("dir", "cgi/", section = "CGI"),
          virtDir: conf.get("virtDir", "", section = "CGI")))

  for rawHostname in conf.get("hostnames", "localhost").split(','):
    let
      hostname = rawHostname.strip
      dir = conf.get("dir", hostname, section = hostname)
    if dirExists(dir): result.vhosts[hostname] = dir
    else: echo "Directory " & dir & " does not exist. Not adding to hosts."
