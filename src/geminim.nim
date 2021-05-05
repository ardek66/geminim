import net, asyncnet, asyncdispatch,
       uri, strutils,
       os, osproc, md5

import response, config

type Server = object
  socket: AsyncSocket
  ctx: SslContext
  settings: Settings
  certMD5: string

proc initServer(settings: Settings): Server =
  result.ctx = newContext(certFile = settings.certFile,
                          keyFile = settings.keyFile)

  result.settings = settings
  result.certMD5 = readFile(settings.certFile).getMD5()
  result.socket = newAsyncSocket()

proc getUserDir(path: string): (string, string) =
  var i = 2
  while i < path.len:
    if path[i] in {DirSep, AltSep}: break
    inc i

  result = (path[2..<i], path[i..^1])

proc serveScript(server: Server, res: Uri, zone: Zone, query = ""): Future[Response] {.async.} =
  let script = res.path.relativePath(zone.key)

  if script == ".":
    return response(StatusError, "ATTEMPTING TO ACCESS CGI DIR: " & zone.key & "'.")
  
  let scriptFile = zone.val / script

  if not fileExists(scriptFile):
    return response(StatusNotFound, "CGI SCRIPT " & script & " NOT FOUND.")

  putEnv("SCRIPT_NAME", scriptFile.extractFilename)
  putEnv("SCRIPT_FILENAME", scriptFile)
  putEnv("SERVER_NAME", res.hostname)
  putEnv("SERVER_PORT", $server.settings.port)
  putEnv("QUERY_STRING", query)
  
  let (body, outp) = execCmdEx(scriptFile)
  
  if outp != 0:
    var errorMsg = script & " FAILED"
    if query.len > 0: errorMsg.add " WITH QUERY: '" & query & '\''
    return response(StatusError, errorMsg & '.')

  result.meta.add body

proc serveDir(server: Server, path, resPath: string): Future[Response] {.async.} =
  template link(path: string): string =
    "=> " / path

  result.meta = SuccessResp
  
  let headerPath = path / server.settings.dirHeader
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

proc parseRequest(server: Server, line: string): Future[Response] {.async.} =
  if line.len > 1024 or res.hostname.len * res.scheme.len == 0:
    return response(StatusMalformedRequest, "MALFORMED REQUEST: '" & line & "'.")

  let
    res = parseUri(line)
    vhostRoot = server.settings.rootDir / res.hostname
  
  if not dirExists(vhostRoot) or res.scheme != "gemini":
    return response(StatusProxyRefused, "PROXY REFUSED: '" & line & "'.")
  
  var
    rootDir = vhostRoot
    filePath = rootDir / res.path
      
  if res.path.startsWith("/~"):
    let (user, newPath) = res.path.getUserDir
    rootDir = server.settings.homeDir % [user] / res.hostname
    filePath = rootDir / newPath

  var resPath = res.path
  if not filePath.startsWith rootDir:
    filePath = vhostRoot
    resPath = "/"

  if server.settings.vhosts.hasKey res.hostname:
    let zone = server.settings.vhosts[res.hostname].findZone(resPath)
    case zone.ztype
    of ZoneRedirect:
      return response(StatusRedirect, zone.val)
    of ZoneRedirectPerm:
      return response(StatusRedirectPerm, zone.val)
    of ZoneCgi:
      return await server.serveScript(res, zone)
    of ZoneInputCgi:
      if res.query.len == 0:
        return response(StatusInputRequired, "ENTER INPUT")
      return await server.serveScript(res, zone, res.query)
    else: discard

  if fileExists(filePath):
    return response(filePath)
  elif dirExists(filePath):
    return await server.serveDir(filePath, resPath)
    
  return response(StatusNotFound, "'" & res.path & "' NOT FOUND")

proc handle(server: Server, client: AsyncSocket) {.async.} =
  server.ctx.wrapConnectedSocket(client, handshakeAsServer)
  try:
    let line = await client.recvLine()
    if line.len > 0:
      echo line
      let resp = await server.parseRequest(line)
      
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

proc serve(server: Server) {.async.} =
  server.ctx.sessionIdContext = server.certMD5
  server.ctx.wrapSocket(server.socket)
  
  server.socket.setSockOpt(OptReuseAddr, true)
  server.socket.setSockOpt(OptReusePort, true)
  server.socket.bindAddr(Port(server.settings.port))
  server.socket.listen()

  while true:
    try:
      let client = await server.socket.accept()
      yield server.handle(client)
    except:
      echo getCurrentExceptionMsg()

proc main() =
  if paramCount() != 1:
    echo "USAGE:"
    echo "./geminim <path/to/config.ini>"
  else:
    let file = paramStr(1)
    if fileExists(file):
      let server = initServer(file.readSettings)
      waitFor server.serve()
    else:
      echo file & ": file not found"

main()
