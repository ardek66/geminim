import net, asyncnet, asyncdispatch,
       uri, strutils,
       os, osproc, md5

import response, config

var settings: Settings
var certMD5: string

proc getUserDir(path: string): (string, string) =
  var i = 2
  while i < path.len:
    if path[i] in {DirSep, AltSep}: break
    inc i

  result = (path[2..<i], path[i..^1])

proc serveScript(res: Uri, zone: Zone, query = ""): Future[Response] {.async.} =
  result.meta = SuccessResp
  
  let script = res.path.relativePath(zone.key)

  if script == ".":
    return response(StatusError, "ATTEMPTING TO ACCESS CGI DIR.")
  
  let scriptFile = zone.val / script

  if not fileExists(scriptFile):
    return response(StatusNotFound, "CGI SCRIPT " & script & " NOT FOUND.")

  putEnv("SCRIPT_NAME", script.extractFilename)
  putEnv("SCRIPT_FILENAME", scriptFile)
  putEnv("SERVER_NAME", res.hostname)
  putEnv("SERVER_PORT", $settings.port)
  putEnv("QUERY_STRING", query)
  
  let (body, outp) = execCmdEx(scriptFile)
  
  if outp != 0:
    var errorMsg = script & " FAILED"
    if query.len > 0: errorMsg.add " WITH QUERY: '" & query & '\''
    return response(StatusError, errorMsg & '.')

  result.meta.add body

proc serveDir(path, resPath: string): Future[Response] {.async.} =
  template link(path: string): string =
    "=> " / path

  result.meta = SuccessResp
  
  let headerPath = path / settings.dirHeader
  if fileExists(headerPath):
    let banner = readFile(headerPath)
    result.meta.add banner & "\n"
  
  result.meta.add "### Index of " & resPath.normalizedPath & "\n"
  
  if resPath.parentDir != "":
    result.meta.add link(resPath.splitPath.head) & " [..]" & "\n"
  for kind, file in path.walkDir:
    let fileName = file.extractFilename
    if fileName.toLowerAscii == "index.gemini" or
       fileName.toLowerAscii == "index.gmi":
      return response(file)
    
    result.meta.add link(resPath / fileName) & ' ' & fileName
    case kind:
    of pcFile: result.meta.add " [FILE]"
    of pcDir: result.meta.add " [DIR]"
    of pcLinkToFile, pcLinkToDir: result.meta.add " [SYMLINK]"
    result.meta.add "\n"

proc parseRequest(line: string): Future[Response] {.async.} =
  let res = parseUri(line)
  
  if line.len > 1024 or res.hostname.len * res.scheme.len == 0:
    return response(StatusMalformedRequest, "MALFORMED REQUEST")

  let vhostRoot = settings.rootDir / res.hostname
  
  if not dirExists(vhostRoot) or res.scheme != "gemini":
    return response(StatusProxyRefused, "PROXY REFUSED")
  
  var
    rootDir = vhostRoot
    filePath = rootDir / res.path
      
  if res.path.startsWith("/~"):
    let (user, newPath) = res.path.getUserDir
    rootDir = settings.homeDir % [user] / res.hostname
    filePath = rootDir / newPath

  var resPath = res.path
  if not filePath.startsWith rootDir:
    filePath = vhostRoot
    resPath = "/"

  if settings.vhosts.hasKey res.hostname:
    let zone = settings.vhosts[res.hostname].findZone(resPath)
    case zone.ztype
    of ZoneRedirect:
      return response(StatusRedirect, zone.val)
    of ZoneRedirectPerm:
      return response(StatusRedirectPerm, zone.val)
    of ZoneCgi:
      return await res.serveScript(zone)
    of ZoneInputCgi:
      if res.query.len == 0:
        return response(StatusInputRequired, "ENTER INPUT")
      return await res.serveScript(zone, res.query)
    else: discard

  if fileExists(filePath):
    return response(filePath)
  elif dirExists(filePath):
    return await serveDir(filePath, resPath)
    
  return response(StatusNotFound, "'" & res.path & "' NOT FOUND")

proc handle(client: AsyncSocket) {.async.} =
  let line = await client.recvLine()
  if line.len > 0:
    echo line
    try:
      let resp = await parseRequest(line)
      if resp.code == StatusNull:
        await client.send resp.meta
      else:
        await client.send strResp(resp.code, resp.meta)
        
        if resp.code == StatusSuccess:
          while not resp.fileStream.atEnd:
            await client.send resp.fileStream.readStr(BufferSize)
          resp.fileStream.close()
    
    except:
      await client.send TempErrorResp
      echo getCurrentExceptionMsg()
      
  client.close()

proc serve() {.async.} =
  let ctx = newContext(certFile = settings.certFile,
                       keyFile = settings.keyFile)

  var server = newAsyncSocket()
  server.setSockOpt(OptReuseAddr, true)
  server.setSockOpt(OptReusePort, true)
  server.bindAddr(Port(settings.port))
  server.listen()

  ctx.wrapSocket(server)
  ctx.sessionIdContext = certMD5
  
  while true:
    try:
      let client = await server.accept()
      ctx.wrapConnectedSocket(client, handshakeAsServer)
      await client.handle()
    except:
      echo getCurrentExceptionMsg()

if paramCount() != 1:
  echo "USAGE:"
  echo "./geminim <path/to/config.ini>"
elif fileExists(paramStr(1)):
  settings = readSettings(paramStr(1))
  certMD5 = readFile(settings.certFile).getMD5()
  waitFor serve()
else:
  echo paramStr(1) & ": file not found"
