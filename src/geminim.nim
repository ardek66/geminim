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

proc processCGI(server: Server, client: AsyncSocket, scriptFilename: string, uri: Uri): Future[void] {.async.} =
  let
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
        "REQUEST_URI": $uri
      }.newStringTable

    var p = startProcess(scriptFilename, env = envTable)
    while not p.outputStream.atEnd:
      await client.send p.outputStream.readStr(BufferSize)
    p.close()
  

proc processTitanRequest(server: Server, client: AsyncSocket, req: string): Future[Response] {.async.} =
  let
    params = split($req, ";")
    res = params[0].parseUri

  if params.len < 2:
    return response(StatusMalformedRequest)
 
  # TODO: unduplicate this part
  let vhostRoot = server.settings.rootDir / res.hostname
  
  if not dirExists(vhostRoot):
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

  var 
    size: int
    token: string
  for i in 0..params.high:
    if i == 0: # actual path
      continue 

    let keyVal = params[i].split("=")
    if keyVal.len != 2:
      return response(StatusMalformedRequest, "Bad parameter: " & params[i])
    if keyVal[0] == "size":
      try:
        size = keyVal[1].parseInt()
      except ValueError:
        return response(StatusMalformedRequest, "Size " & keyVal[1] & " is invalid")
    if keyVal[0] == "token":
      token = keyVal[1].decodeUrl

  if size == 0:
    return response(StatusMalformedRequest, "No file size specified")
  if size > server.settings.titanUploadLimit:
    return response(StatusError,
      "File size exceeds limit of " & $server.settings.titanUploadLimit & " bytes.")

  if token != server.settings.titanPass and server.settings.titanPassRequired:
    return response(StatusNotAuthorised, "Token not recognized")

  let (parent, _ )= filePath.splitPath

  if dirExists(parent):
    if dirExists(filePath): # We're writing index.gmi in an existing directory
      filePath = filePath / "index.gmi"
  else: # we're writing a file in a new directory
    try:
      createDir(parent)
    except:
      return response(StatusError, "Could not create directory: " & parent)

  let buffer = await client.recv(size)
  try:
    let file = openAsync(filePath, fmWrite)

    await file.write(buffer)
    file.close()
  except:
    echo getCurrentExceptionMsg()
    return response(StatusError, "")

  if server.settings.titanRedirect:
    result = response(StatusRedirect, ($res).replace("titan://", "gemini://"))
  else:
    result = response(StatusSuccess, "text/gemini\r\nSuccessfully wrote file")


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
    if fileName.toLowerAscii in ["index.gemini", "index.gmi"]:
      return await server.serveFile(file)
    
    result.meta.add link(resPath / fileName) & ' ' & fileName
    case kind:
    of pcFile: result.meta.add " [FILE]"
    of pcDir: result.meta.add " [DIR]"
    of pcLinkToFile, pcLinkToDir: result.meta.add " [SYMLINK]"
    result.meta.add "\n"

proc parseGeminiRequest(server: Server, res: Uri): Future[Response] {.async.} =
  let vhostRoot = server.settings.rootDir / res.hostname
  
  if not dirExists(vhostRoot):
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

      if(line.len > 1024):
        await client.send strResp(StatusMalformedRequest, "REQUEST IS TOO LONG.")
      
      let uri = parseUri(line)
      if uri.hostname.len == 0 or uri.scheme.len == 0:
        await client.send strResp(StatusMalformedRequest, "MALFORMED REQUEST: '" & line & "'.")

      case uri.scheme
      of "gemini":
        let resp = await server.parseGeminiRequest(uri)
        
        case resp.code
        of StatusNull:
          await client.send resp.meta
          
        of StatusCGI:
          await server.processCGI(client, resp.meta, uri)

        else:
          await client.send strResp(resp.code, resp.meta)
      
          if resp.code == StatusSuccess:
            while true:
              let buffer = await resp.file.read(BufferSize)
              if buffer.len < 1: break
              await client.send buffer
            
            resp.file.close()

      of "titan":
        let resp = await server.processTitanRequest(client, line)
        case resp.code
        of StatusCGI:
          await server.processCGI(client, resp.meta, uri)
          
        else:
          await client.send strResp(resp.code, resp.meta)
             
      else:
        await client.send strResp(StatusMalformedRequest, "UNSUPORTED PROTOCOL: '" & uri.scheme & "'.")
          
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
