import parsecfg, strutils

type Settings* = object
  hostname*: string
  port*: int
  dir*: string
  certFile*, keyFile*: string

proc get(dict: Config, value, default: string): string =
  result = dict.getSectionValue("", value)
  if result.len < 1: return default

proc readSettings*(path: string): Settings =
  let conf = loadConfig(path)

  result = Settings(
    hostname: conf.get("hostname", "localhost"),
    port: conf.get("port", "1965").parseInt,
    dir: conf.get("dir", "pub"),
    certFile: conf.get("certFile", "mycert.pem"),
    keyFile: conf.get("keyFile", "mykey.pem"))
