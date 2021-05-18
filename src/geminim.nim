import net, asyncnet, asyncdispatch, asyncfile,
       uri, strutils, strtabs, streams,
       os, osproc, md5, mimetypes

import response, config

var m = newMimeTypes()
m.register(ext = "gemini", mimetype = "text/gemini")
m.register(ext = "gmi", mimetype = "text/gemini")

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

proc serveFile(server: Server, path: string): Future[Response] {.async.} =
  result = response(StatusSuccess, m.getMimetype(path.splitFile.ext))
  result.file = openAsync(path)

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
      return await server.serveFile(file)
    
    result.meta.add link(resPath / fileName) & ' ' & fileName
    case kind:
    of pcFile: result.meta.add " [FILE]"
    of pcDir: result.meta.add " [DIR]"
    of pcLinkToFile, pcLinkToDir: result.meta.add " [SYMLINK]"
    result.meta.add "\n"

proc parseRequest(server: Server, res: Uri): Future[Response] {.async.} =
  if len($res) > 1024 or res.hostname.len * res.scheme.len == 0:
    return response(StatusMalformedRequest, "MALFORMED REQUEST: '" & $res & "'.")

  let vhostRoot = server.settings.rootDir / res.hostname
  
  if not dirExists(vhostRoot) or res.scheme != "gemini":
    return response(StatusProxyRefused, "PROXY REFUSED: '" & $res & "'.")
  
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
      return response(StatusCGI, zone.val)
    else: discard

  if fileExists(filePath):
    return await server.serveFile(filePath)
  elif dirExists(filePath):
    return await server.serveDir(filePath, resPath)
    
  return response(StatusNotFound, "'" & res.path & "' NOT FOUND")
  
proc handle(server: Server, client: AsyncSocket) {.async.} =
  server.ctx.wrapConnectedSocket(client, handshakeAsServer)
  
  try:
    let line = await client.recvLine()
    if line.len > 0:
      echo line
      let
        uri = parseUri(line)
        resp = await server.parseRequest(uri)
      
      case resp.code
      of StatusNull:
        await client.send resp.meta
      
      of StatusCGI:
          let
            scriptFilename = resp.meta
            scriptName = scriptFilename.extractFileName()

          if not fileExists(scriptFilename):
            await client.send strResp(StatusNotFound, "CGI SCRIPT " & scriptName & " NOT FOUND.")
          else:
            let envTable =
              {
                "SCRIPT_NAME": scriptName,
                "SCRIPT_FILENAME": scriptFilename,
                "SERVER_NAME": uri.hostname,
                "SERVER_PORT": $server.settings.port,
                "PATH_INFO": uri.path,
                "QUERY_STRING": uri.query,
              }.newStringTable

            var p = startProcess(scriptFilename, env = envTable)
            while not p.outputStream.atEnd:
              await client.send p.outputStream.readStr(BufferSize)
            p.close()
          
      else:
        await client.send strResp(resp.code, resp.meta)
      
        if resp.code == StatusSuccess:
          while true:
            let buffer = await resp.file.read(BufferSize)
            if buffer.len < 1: break
            await client.send buffer
            
          resp.file.close()
          
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
